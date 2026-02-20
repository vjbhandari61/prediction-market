// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract PredictionMarket is ReentrancyGuard {
    using SafeERC20 for IERC20;

    error NotHost();
    error MarketNotOpen();
    error DeadlinePassed();
    error DeadlineNotPassed();
    error MarketNotResolved();
    error MarketNotExpired();
    error AlreadyClaimed();
    error ZeroShares();
    error ZeroPayout();
    error ZeroRefund();
    error ZeroFees();
    error BelowMinBet();
    error SlippageExceeded(uint256 sharesOut, uint256 minSharesOut);
    error ZeroAddress();
    error FeeTooHigh();
    error DeadlineInPast();
    error SeedTooSmall();

    uint256 public constant FEE_DENOMINATOR = 10_000;
    uint256 public constant MIN_BET         = 1e4;

    IERC20  public immutable collateral;
    address public immutable host;
    uint256 public immutable deadline;
    uint256 public immutable feeBps;
    string  public question;

    uint256 public yesPool;
    uint256 public noPool;

    mapping(address => uint256) public yesShares;
    mapping(address => uint256) public noShares;
    uint256 public totalYesShares;
    uint256 public totalNoShares;

    // Net effective collateral deposited per user (after fee deduction).
    // Used exclusively for refund calculation on expiry.
    mapping(address => uint256) public totalDeposited;

    uint256 public accruedFees;

    enum Status { OPEN, RESOLVED, EXPIRED }

    Status  public status;
    bool    public resolvedYes;

    /**
     * @notice Snapshot of distributable collateral taken at resolution time.
     *
     * WHY THIS EXISTS:
     *   claimReward() must divide each user's shares against a fixed total pot.
     *   If we read `balanceOf(address(this))` live, the balance shrinks with each
     *   claim, underpaying later claimants and leaving funds permanently stranded.
     *
     *   By snapshotting once in resolve(), every claimant sees the same denominator:
     *     payout = (userShares / totalWinningShares) × resolvedPot
     *   The sum of all payouts equals resolvedPot exactly (modulo rounding dust).
     */
    uint256 public resolvedPot;

    // Prevents double-claiming across both reward and refund paths.
    mapping(address => bool) public hasClaimed;

    event SharesBought(
        address indexed trader,
        bool    indexed isYes,
        uint256         amountIn,
        uint256         sharesOut,
        uint256         newYesPrice
    );
    event MarketResolved(bool yesWins, uint256 resolvedPot);
    event MarketExpired();
    event RewardClaimed(address indexed trader, uint256 payout);
    event RefundClaimed(address indexed trader, uint256 refund);
    event FeesWithdrawn(address indexed host, uint256 amount);

    modifier onlyHost() {
        if (msg.sender != host) revert NotHost();
        _;
    }

    constructor(
        address _collateral,
        string  memory _question,
        uint256 _deadline,
        uint256 _feeBps,
        uint256 _initialLiquidity,
        address _host
    ) {
        if (_collateral == address(0))    revert ZeroAddress();
        if (_host == address(0))          revert ZeroAddress();
        if (_deadline <= block.timestamp) revert DeadlineInPast();
        if (_feeBps > 1_000)              revert FeeTooHigh();
        if (_initialLiquidity < MIN_BET)  revert SeedTooSmall();

        collateral = IERC20(_collateral);
        question   = _question;
        deadline   = _deadline;
        feeBps     = _feeBps;
        host       = _host;
        status     = Status.OPEN;

        yesPool = _initialLiquidity;
        noPool  = _initialLiquidity;

        yesShares[_host]      = _initialLiquidity;
        noShares[_host]       = _initialLiquidity;
        totalYesShares        = _initialLiquidity;
        totalNoShares         = _initialLiquidity;

        totalDeposited[_host] = _initialLiquidity * 2;
    }

    /*** @notice Buy YES or NO shares using the CPMM formula. **/
    function buyShares(
        bool    isYes,
        uint256 amountIn,
        uint256 minSharesOut
    ) external nonReentrant {
        if (status != Status.OPEN)      revert MarketNotOpen();
        if (block.timestamp > deadline) revert DeadlinePassed();
        if (amountIn < MIN_BET)         revert BelowMinBet();

        uint256 fee          = (amountIn * feeBps) / FEE_DENOMINATOR;
        uint256 effectiveAmt = amountIn - fee;

        uint256 k = yesPool * noPool;
        uint256 sharesOut;

        if (isYes) {
            uint256 newNoPool  = noPool  + effectiveAmt;
            uint256 newYesPool = k / newNoPool;
            sharesOut          = yesPool - newYesPool;

            yesPool = newYesPool;
            noPool  = newNoPool;

            yesShares[msg.sender] += sharesOut;
            totalYesShares        += sharesOut;
        } else {
            uint256 newYesPool = yesPool + effectiveAmt;
            uint256 newNoPool  = k / newYesPool;
            sharesOut          = noPool - newNoPool;

            yesPool = newYesPool;
            noPool  = newNoPool;

            noShares[msg.sender] += sharesOut;
            totalNoShares        += sharesOut;
        }

        if (sharesOut == 0)           revert ZeroShares();
        if (sharesOut < minSharesOut) revert SlippageExceeded(sharesOut, minSharesOut);

        accruedFees                += fee;
        totalDeposited[msg.sender] += effectiveAmt;

        collateral.safeTransferFrom(msg.sender, address(this), amountIn);
        emit SharesBought(msg.sender, isYes, amountIn, sharesOut, yesPrice());
    }

    /**
     * @notice Host finalises the market. Snapshots the pot at this exact moment
     *         so all subsequent claimReward() calls share a fixed denominator.
     */
    function resolve(bool yesWins) external onlyHost {
        if (status != Status.OPEN)      revert MarketNotOpen();
        if (block.timestamp > deadline) revert DeadlinePassed();

        resolvedPot = collateral.balanceOf(address(this)) - accruedFees;
        status      = Status.RESOLVED;
        resolvedYes = yesWins;

        emit MarketResolved(yesWins, resolvedPot);
    }

    /**
     * @notice Winners claim their pro-rata share of resolvedPot.
     *
     *   payout = (userWinningShares / totalWinningShares) × resolvedPot
     *
     * Because resolvedPot is a snapshot (not a live balanceOf), claim order has
     * zero effect on individual payouts. The sum of all winner payouts equals
     * resolvedPot up to integer rounding dust (≤ 1 wei per claimer).
     *
     */
    function claimReward() external nonReentrant {
        if (status != Status.RESOLVED) revert MarketNotResolved();
        if (hasClaimed[msg.sender])    revert AlreadyClaimed();

        uint256 userShares;
        uint256 totalShares;

        if (resolvedYes) {
            userShares  = yesShares[msg.sender];
            totalShares = totalYesShares;
        } else {
            userShares  = noShares[msg.sender];
            totalShares = totalNoShares;
        }

        if (userShares == 0) revert ZeroShares();

        // Use snapshotted pot — NOT live balanceOf — so claim order is irrelevant.
        uint256 payout = (userShares * resolvedPot) / totalShares;
        if (payout == 0) revert ZeroPayout();

        hasClaimed[msg.sender] = true;

        if (resolvedYes) {
            yesShares[msg.sender] = 0;
        } else {
            noShares[msg.sender] = 0;
        }

        collateral.safeTransfer(msg.sender, payout);

        emit RewardClaimed(msg.sender, payout);
    }

    /**
     * @notice Traders reclaim net deposits when the market expires unresolved.
     *         Fees are NOT refunded — they belong to the host.
     *
     *   refund = totalDeposited[msg.sender]   (effectiveAmt after fee deduction)
     *
     * Status transition is lazy: the first claimRefund() call after the deadline
     * flips OPEN → EXPIRED. No separate "expire()" tx required.
     *
     */
    function claimRefund() external nonReentrant {
        if (block.timestamp <= deadline) revert DeadlineNotPassed();
        if (status == Status.RESOLVED)   revert MarketNotExpired();
        if (hasClaimed[msg.sender])      revert AlreadyClaimed();

        uint256 refund = totalDeposited[msg.sender];
        if (refund == 0) revert ZeroRefund();

        if (status == Status.OPEN) {
            status = Status.EXPIRED;
            emit MarketExpired();
        }

        totalDeposited[msg.sender] = 0;
        hasClaimed[msg.sender]     = true;

        collateral.safeTransfer(msg.sender, refund);

        emit RefundClaimed(msg.sender, refund);
    }

    /**
     * @notice Host withdraws accumulated trading fees.
     *         Safe at any point — fees are always segregated from user collateral.
     *
     */
    function withdrawFees() external onlyHost nonReentrant {
        uint256 fees = accruedFees;
        if (fees == 0) revert ZeroFees();

        accruedFees = 0;

        collateral.safeTransfer(host, fees);

        emit FeesWithdrawn(host, fees);
    }

    /// @notice Price of YES scaled to 1e18.
    function yesPrice() public view returns (uint256) {
        uint256 total = yesPool + noPool;
        if (total == 0) return 0;
        return (noPool * 1e18) / total;
    }

    /// @notice Price of NO scaled to 1e18.
    function noPrice() public view returns (uint256) {
        uint256 total = yesPool + noPool;
        if (total == 0) return 0;
        return (yesPool * 1e18) / total;
    }

    /**
     * @notice Preview shares and post-trade YES price without executing.
     *         Use this to compute minSharesOut before calling buyShares().
     */
    function quoteShares(bool isYes, uint256 amountIn)
        external view
        returns (uint256 sharesOut, uint256 priceAfter)
    {
        uint256 fee          = (amountIn * feeBps) / FEE_DENOMINATOR;
        uint256 effectiveAmt = amountIn - fee;
        uint256 k            = yesPool * noPool;

        if (isYes) {
            uint256 newNoPool  = noPool  + effectiveAmt;
            uint256 newYesPool = k / newNoPool;
            sharesOut  = yesPool - newYesPool;
            priceAfter = (newNoPool * 1e18) / (newYesPool + newNoPool);
        } else {
            uint256 newYesPool = yesPool + effectiveAmt;
            uint256 newNoPool  = k / newYesPool;
            sharesOut  = noPool - newNoPool;
            priceAfter = (newNoPool * 1e18) / (newYesPool + newNoPool);
        }
    }

    /// @notice True if deadline passed and market was never resolved.
    function isExpired() external view returns (bool) {
        return status == Status.OPEN && block.timestamp > deadline;
    }
}
