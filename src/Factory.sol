// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {PredictionMarket} from "./Core.sol";

contract PredictionMarketFactory is ReentrancyGuard {
    using SafeERC20 for IERC20;

    error ZeroAddress();
    error EmptyQuestion();
    error DeadlineInPast();
    error FeeTooHigh();
    error SeedTooSmall();
    error ProtocolFeeTooHigh();
    error NotAdmin();
    error InvalidPaginationRange();

    address public protocolAdmin;
    address public protocolTreasury;
    uint256 public protocolFeeBps;

    uint256 public constant MAX_MARKET_FEE_BPS  = 1_000;  // 10% max per-trade fee
    uint256 public constant MAX_PROTOCOL_FEE_BPS = 3_000; // 30% of market fee

    /*** @notice
    * allMarkets: the canonical ordered list of deployed markets.
    *   — Grows unbounded, but never iterated on-chain in write functions.
    *   — Use getMarkets() (paginated) for reads.
    *
    * marketsByHost: per-host list for convenience, alternative: index using a subgraph
    *
    * isMarket: ensures that given address is a valid market
    */
    uint256 public marketCount; // explicit counter to avoid allMarkets.length in loops

    address[] private _allMarkets;
    mapping(address => address[]) private _marketsByHost;
    mapping(address => bool)      public  isMarket;


    event MarketCreated(
        address indexed market,
        address indexed host,
        address indexed collateral,
        string  question,
        uint256 deadline,
        uint256 feeBps,
        uint256 initialLiquidity
    );
    event ProtocolAdminUpdated(address indexed oldAdmin, address indexed newAdmin);
    event ProtocolTreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event ProtocolFeeBpsUpdated(uint256 oldFee, uint256 newFee);

    constructor(address _treasury, uint256 _protocolFeeBps) {
        if (_treasury == address(0))                 revert ZeroAddress();
        if (_protocolFeeBps > MAX_PROTOCOL_FEE_BPS)  revert ProtocolFeeTooHigh();

        protocolAdmin    = msg.sender;
        protocolTreasury = _treasury;
        protocolFeeBps   = _protocolFeeBps;
    }

    modifier onlyAdmin() {
        if (msg.sender != protocolAdmin) revert NotAdmin();
        _;
    }

    /**
     * @notice Deploy a new prediction market.
     *
     * @param collateral        ERC-20 collateral token (e.g. USDC).
     * @param question          The prediction question stored on-chain.
     * @param deadline          Unix timestamp when trading closes.
     * @param feeBps            Per-trade fee in bps (max 1000 = 10%).
     * @param initialLiquidity  Seed per AMM side. Host must approve
     *                          2 × initialLiquidity to this factory first.
     *
     * @return market  Address of the deployed PredictionMarket.
     *
     */
    function createMarket(
        address collateral,
        string  calldata question,
        uint256 deadline,
        uint256 feeBps,
        uint256 initialLiquidity
    ) external nonReentrant returns (address market) {
        if (collateral == address(0))         revert ZeroAddress();
        if (bytes(question).length == 0)      revert EmptyQuestion();
        if (deadline <= block.timestamp)      revert DeadlineInPast();
        if (feeBps > MAX_MARKET_FEE_BPS)      revert FeeTooHigh();
        if (initialLiquidity < 1e4)           revert SeedTooSmall();

        uint256 totalSeed = initialLiquidity * 2;

        // nonReentrant prevents a malicious token re-entering here.
        IERC20(collateral).safeTransferFrom(msg.sender, address(this), totalSeed);

        PredictionMarket pm = new PredictionMarket(
            collateral,
            question,
            deadline,
            feeBps,
            initialLiquidity,
            msg.sender   // host
        );
        market = address(pm);

        IERC20(collateral).safeTransfer(market, totalSeed);

        _allMarkets.push(market);
        _marketsByHost[msg.sender].push(market);
        isMarket[market] = true;
        unchecked { ++marketCount; } // cannot overflow type(uint256).max

        emit MarketCreated(
            market,
            msg.sender,
            collateral,
            question,
            deadline,
            feeBps,
            initialLiquidity
        );
    }

    /**
     * @notice Paginated read of all markets. Use marketCount to determine total.
     * @param offset  Start index (0-based).
     * @param limit   Max items returned. Pass type(uint256).max for "all from offset".
     */
    function getMarkets(uint256 offset, uint256 limit)
        external view
        returns (address[] memory page)
    {
        uint256 total = _allMarkets.length;
        if (offset >= total) return new address[](0);

        uint256 end = offset + limit;
        if (end > total) end = total;

        uint256 size = end - offset;
        page = new address[](size);

        // Bounded loop — size is caller-controlled via limit, but the factory
        // emits events on every creation so frontends should index off-chain
        // and only call this for small page sizes.
        for (uint256 i = 0; i < size;) {
            page[i] = _allMarkets[offset + i];
            unchecked { ++i; }
        }
    }

    /**
     * @notice All markets created by a specific host.
     * @dev    Unbounded return — prefer off-chain indexing via MarketCreated events
     *         in production. Included here for completeness in POC.
     */
    function getMarketsByHost(address host)
        external view
        returns (address[] memory)
    {
        return _marketsByHost[host];
    }

    /// @notice Count of markets created by a specific host.
    function marketCountByHost(address host) external view returns (uint256) {
        return _marketsByHost[host].length;
    }

    /**
     * @notice Transfer protocol admin role.
     */
    function setProtocolAdmin(address newAdmin) external onlyAdmin {
        if (newAdmin == address(0)) revert ZeroAddress();
        emit ProtocolAdminUpdated(protocolAdmin, newAdmin);
        protocolAdmin = newAdmin;
    }

    function setProtocolTreasury(address newTreasury) external onlyAdmin {
        if (newTreasury == address(0)) revert ZeroAddress();
        emit ProtocolTreasuryUpdated(protocolTreasury, newTreasury);
        protocolTreasury = newTreasury;
    }

    function setProtocolFeeBps(uint256 newFeeBps) external onlyAdmin {
        if (newFeeBps > MAX_PROTOCOL_FEE_BPS) revert ProtocolFeeTooHigh();
        emit ProtocolFeeBpsUpdated(protocolFeeBps, newFeeBps);
        protocolFeeBps = newFeeBps;
    }
}
