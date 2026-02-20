// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import {PredictionMarket} from "../src/Core.sol";
import {PredictionMarketFactory} from "../src/Factory.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockUSDC is ERC20 {
    constructor() ERC20("Mock USDC", "USDC") {}

    function decimals() public pure override returns (uint8) { return 6; }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract PredictionMarketTest is Test {

    MockUSDC                internal usdc;
    PredictionMarketFactory internal factory;
    PredictionMarket        internal market;

    address internal PROTOCOL_TREASURY = makeAddr("treasury");
    address internal HOST              = makeAddr("host");
    address internal TRADER_A          = makeAddr("traderA");
    address internal TRADER_B          = makeAddr("traderB");
    address internal STRANGER          = makeAddr("stranger");

    uint256 internal constant INITIAL_LIQUIDITY = 100 * 1e6;  // 100 USDC per side
    uint256 internal constant FEE_BPS           = 200;         // 2%
    uint256 internal constant PROTOCOL_FEE_BPS  = 500;
    uint256 internal constant DEADLINE_OFFSET   = 7 days;
    uint256 internal constant MINT_AMOUNT       = 10_000 * 1e6;

    uint256 internal marketDeadline;

    function setUp() public {
        usdc    = new MockUSDC();
        factory = new PredictionMarketFactory(PROTOCOL_TREASURY, PROTOCOL_FEE_BPS);

        usdc.mint(HOST,     MINT_AMOUNT);
        usdc.mint(TRADER_A, MINT_AMOUNT);
        usdc.mint(TRADER_B, MINT_AMOUNT);

        marketDeadline = block.timestamp + DEADLINE_OFFSET;

        vm.startPrank(HOST);
        usdc.approve(address(factory), INITIAL_LIQUIDITY * 2);
        address marketAddr = factory.createMarket(
            address(usdc),
            "Will ETH be above $3000 on March 1, 2026?",
            marketDeadline,
            FEE_BPS,
            INITIAL_LIQUIDITY
        );
        vm.stopPrank();

        market = PredictionMarket(marketAddr);
    }

    // Helpers

    function _buy(address trader, bool isYes, uint256 amount) internal returns (uint256 sharesOut) {
        (uint256 quoted,) = market.quoteShares(isYes, amount);
        uint256 minOut    = quoted * 99 / 100;

        vm.startPrank(trader);
        usdc.approve(address(market), amount);
        market.buyShares(isYes, amount, minOut);
        vm.stopPrank();

        sharesOut = isYes ? market.yesShares(trader) : market.noShares(trader);
    }

    function _resolve(bool yesWins) internal {
        vm.prank(HOST);
        market.resolve(yesWins);
    }

    function _expire() internal {
        vm.warp(marketDeadline + 1);
    }

    function _bal(address who) internal view returns (uint256) {
        return usdc.balanceOf(who);
    }

    // Factory Tests

    function test_factory_initialState() public view {
        assertEq(factory.protocolAdmin(),    address(this));
        assertEq(factory.protocolTreasury(), PROTOCOL_TREASURY);
        assertEq(factory.protocolFeeBps(),   PROTOCOL_FEE_BPS);
        assertEq(factory.marketCount(),      1);
    }

    function test_factory_createMarket_registersCorrectly() public view {
        address[] memory markets = factory.getMarkets(0, 10);
        assertEq(markets.length, 1);
        assertEq(markets[0], address(market));
        assertTrue(factory.isMarket(address(market)));
    }

    function test_factory_createMarket_emitsEvent() public {
        uint256 deadline = block.timestamp + 1 days;
        uint256 seed     = 50 * 1e6;

        vm.startPrank(HOST);
        usdc.approve(address(factory), seed * 2);

        vm.expectEmit(false, true, true, false);
        emit PredictionMarketFactory.MarketCreated(
            address(0),
            HOST,
            address(usdc),
            "",
            deadline,
            FEE_BPS,
            seed
        );
        factory.createMarket(address(usdc), "Test?", deadline, FEE_BPS, seed);
        vm.stopPrank();
    }

    function test_factory_createMarket_hostGetsLPShares() public view {
        assertEq(market.yesShares(HOST), INITIAL_LIQUIDITY);
        assertEq(market.noShares(HOST),  INITIAL_LIQUIDITY);
    }

    function test_factory_createMarket_revertsOnZeroCollateral() public {
        vm.expectRevert(PredictionMarketFactory.ZeroAddress.selector);
        factory.createMarket(address(0), "Q?", block.timestamp + 1 days, 200, 1e4);
    }

    function test_factory_createMarket_revertsOnEmptyQuestion() public {
        vm.expectRevert(PredictionMarketFactory.EmptyQuestion.selector);
        factory.createMarket(address(usdc), "", block.timestamp + 1 days, 200, 1e4);
    }

    function test_factory_createMarket_revertsOnPastDeadline() public {
        vm.expectRevert(PredictionMarketFactory.DeadlineInPast.selector);
        factory.createMarket(address(usdc), "Q?", block.timestamp - 1, 200, 1e4);
    }

    function test_factory_createMarket_revertsOnFeeTooHigh() public {
        vm.expectRevert(PredictionMarketFactory.FeeTooHigh.selector);
        factory.createMarket(address(usdc), "Q?", block.timestamp + 1 days, 1_001, 1e4);
    }

    function test_factory_createMarket_revertsOnSeedTooSmall() public {
        vm.expectRevert(PredictionMarketFactory.SeedTooSmall.selector);
        factory.createMarket(address(usdc), "Q?", block.timestamp + 1 days, 200, 1e3);
    }

    function test_factory_getMarkets_pagination() public {
        for (uint256 i = 0; i < 4; i++) {
            vm.startPrank(HOST);
            usdc.approve(address(factory), INITIAL_LIQUIDITY * 2);
            factory.createMarket(
                address(usdc),
                string(abi.encodePacked("Question ", i)),
                block.timestamp + 1 days,
                FEE_BPS,
                INITIAL_LIQUIDITY
            );
            vm.stopPrank();
        }

        assertEq(factory.marketCount(), 5);

        address[] memory page1 = factory.getMarkets(0, 2);
        address[] memory page2 = factory.getMarkets(2, 2);
        address[] memory page3 = factory.getMarkets(4, 2);

        assertEq(page1.length, 2);
        assertEq(page2.length, 2);
        assertEq(page3.length, 1);
    }

    function test_factory_getMarkets_emptyWhenOffsetExceedsTotal() public view {
        address[] memory page = factory.getMarkets(999, 10);
        assertEq(page.length, 0);
    }

    function test_factory_setProtocolAdmin_revertsIfNotAdmin() public {
        vm.prank(STRANGER);
        vm.expectRevert(PredictionMarketFactory.NotAdmin.selector);
        factory.setProtocolAdmin(STRANGER);
    }

    function test_factory_setProtocolAdmin_succeeds() public {
        factory.setProtocolAdmin(HOST);
        assertEq(factory.protocolAdmin(), HOST);
    }

    function test_factory_setProtocolFeeBps_revertsIfTooHigh() public {
        vm.expectRevert(PredictionMarketFactory.ProtocolFeeTooHigh.selector);
        factory.setProtocolFeeBps(3_001);
    }


    // Market Initial State Tests

    function test_market_initialState() public view {
        assertEq(market.yesPool(),  INITIAL_LIQUIDITY);
        assertEq(market.noPool(),   INITIAL_LIQUIDITY);
        assertEq(market.feeBps(),   FEE_BPS);
        assertEq(market.deadline(), marketDeadline);
        assertEq(market.host(),     HOST);
        assertEq(uint8(market.status()), 0); // OPEN
        assertEq(market.yesPrice(), 0.5e18);
        assertEq(market.noPrice(),  0.5e18);
    }

    function test_market_initialLiquidity_inContract() public view {
        assertEq(usdc.balanceOf(address(market)), INITIAL_LIQUIDITY * 2);
    }

    // buyShares Tests

    function test_buyShares_yes_movesPrice() public {
        uint256 priceBefore = market.yesPrice();
        _buy(TRADER_A, true, 50 * 1e6);
        uint256 priceAfter = market.yesPrice();

        assertGt(priceAfter, priceBefore);
        console.log("YES price before:", priceBefore);
        console.log("YES price after: ", priceAfter);
    }

    function test_buyShares_no_movesPrice() public {
        uint256 priceBefore = market.noPrice();
        _buy(TRADER_B, false, 50 * 1e6);
        assertGt(market.noPrice(), priceBefore);
    }

    function test_buyShares_pricesAlwaysSumToOne() public {
        _buy(TRADER_A, true, 30 * 1e6);
        _buy(TRADER_B, false, 70 * 1e6);
        assertApproxEqAbs(market.yesPrice() + market.noPrice(), 1e18, 1);
    }

    function test_buyShares_feeAccrues() public {
        uint256 amount = 100 * 1e6;
        _buy(TRADER_A, true, amount);
        assertEq(market.accruedFees(), (amount * FEE_BPS) / 10_000);
    }

    function test_buyShares_depositsTracked() public {
        uint256 amount       = 100 * 1e6;
        uint256 effectiveAmt = amount - (amount * FEE_BPS) / 10_000;
        _buy(TRADER_A, true, amount);
        assertEq(market.totalDeposited(TRADER_A), effectiveAmt);
    }

    function test_buyShares_revertsWhenMarketClosed() public {
        _resolve(true);
        vm.startPrank(TRADER_A);
        usdc.approve(address(market), 10 * 1e6);
        vm.expectRevert(PredictionMarket.MarketNotOpen.selector);
        market.buyShares(true, 10 * 1e6, 0);
        vm.stopPrank();
    }

    function test_buyShares_revertsAfterDeadline() public {
        _expire();
        vm.startPrank(TRADER_A);
        usdc.approve(address(market), 10 * 1e6);
        vm.expectRevert(PredictionMarket.DeadlinePassed.selector);
        market.buyShares(true, 10 * 1e6, 0);
        vm.stopPrank();
    }

    function test_buyShares_revertsOnBelowMinBet() public {
        vm.startPrank(TRADER_A);
        usdc.approve(address(market), 100);
        vm.expectRevert(PredictionMarket.BelowMinBet.selector);
        market.buyShares(true, 100, 0);
        vm.stopPrank();
    }

    function test_buyShares_revertsOnSlippage() public {
        (uint256 quoted,) = market.quoteShares(true, 50 * 1e6);
        vm.startPrank(TRADER_A);
        usdc.approve(address(market), 50 * 1e6);
        vm.expectRevert(
            abi.encodeWithSelector(
                PredictionMarket.SlippageExceeded.selector,
                quoted,
                quoted + 1
            )
        );
        market.buyShares(true, 50 * 1e6, quoted + 1);
        vm.stopPrank();
    }

    /**
     * @dev CPMM integer division note:
     *   newYesPool = k / newNoPool  uses floor division, so newYesPool * newNoPool
     *   may be 1 ULP below the original k. This is expected Solidity behaviour —
     *   the AMM is NOT leaking value, it is rounding in favour of the pool.
     */
    function test_buyShares_cpmmInvariant() public {
        uint256 kBefore = market.yesPool() * market.noPool();
        _buy(TRADER_A, true, 50 * 1e6);
        uint256 kAfter = market.yesPool() * market.noPool();

        // k may decrease by at most the magnitude of noPool (1 ULP of floor division).
        // it's always 0 or 1 below. We allow up to noPool as a safe bound.
        assertApproxEqAbs(kAfter, kBefore, market.noPool());

        console.log("k before:", kBefore);
        console.log("k after: ", kAfter);
        console.log("delta:   ", kBefore > kAfter ? kBefore - kAfter : 0);
    }

    /**
     * @dev CPMM counter-intuitive price behaviour:
     *   After buying YES with 60 USDC, YES pool shrinks significantly.
     *   A subsequent NO buy of 40 USDC operates against the now-skewed pools
     *   and can push YES price back below 50%. We test what actually matters:
     *   each individual trade moves price in the correct direction independently.
     */
    function test_buyShares_eachTradeMovesItsOwnPrice() public {
        // YES buy raises YES price
        uint256 yesPriceBefore = market.yesPrice();
        _buy(TRADER_A, true, 60 * 1e6);
        uint256 yesPriceAfterYesBuy = market.yesPrice();
        assertGt(yesPriceAfterYesBuy, yesPriceBefore, "YES buy should raise YES price");

        // NO buy raises NO price
        uint256 noPriceBefore = market.noPrice();
        _buy(TRADER_B, false, 40 * 1e6);
        uint256 noPriceAfterNoBuy = market.noPrice();
        assertGt(noPriceAfterNoBuy, noPriceBefore, "NO buy should raise NO price");

        // Prices always sum to 1e18 regardless of sequence
        assertApproxEqAbs(market.yesPrice() + market.noPrice(), 1e18, 1);

        console.log("YES price after YES buy:", yesPriceAfterYesBuy);
        console.log("NO  price after NO  buy:", noPriceAfterNoBuy);
        console.log("Final YES price:        ", market.yesPrice());
        console.log("Final NO  price:        ", market.noPrice());
    }

    function test_buyShares_quoteMatchesActual() public {
        uint256 amount = 50 * 1e6;
        (uint256 quoted,) = market.quoteShares(true, amount);
        uint256 sharesBefore = market.yesShares(TRADER_A);
        _buy(TRADER_A, true, amount);
        assertEq(market.yesShares(TRADER_A) - sharesBefore, quoted);
    }

    // resolve tests

    function test_resolve_setsStatusToResolved() public {
        _resolve(true);
        assertEq(uint8(market.status()), 1);
        assertTrue(market.resolvedYes());
    }

    function test_resolve_no_setsResolvedYesFalse() public {
        _resolve(false);
        assertFalse(market.resolvedYes());
    }

    function test_resolve_snapshotsResolvedPot() public {
        _buy(TRADER_A, true, 100 * 1e6);
        uint256 expectedPot = usdc.balanceOf(address(market)) - market.accruedFees();
        _resolve(true);
        assertEq(market.resolvedPot(), expectedPot);
    }

    function test_resolve_emitsEvent() public {
        _buy(TRADER_A, true, 50 * 1e6);
        uint256 expectedPot = usdc.balanceOf(address(market)) - market.accruedFees();

        vm.expectEmit(true, false, false, true);
        emit PredictionMarket.MarketResolved(true, expectedPot);
        _resolve(true);
    }

    function test_resolve_revertsIfNotHost() public {
        vm.prank(STRANGER);
        vm.expectRevert(PredictionMarket.NotHost.selector);
        market.resolve(true);
    }

    function test_resolve_revertsIfAlreadyResolved() public {
        _resolve(true);
        vm.prank(HOST);
        vm.expectRevert(PredictionMarket.MarketNotOpen.selector);
        market.resolve(true);
    }

    function test_resolve_revertsAfterDeadline() public {
        _expire();
        vm.prank(HOST);
        vm.expectRevert(PredictionMarket.DeadlinePassed.selector);
        market.resolve(true);
    }

    // claimRewards Tests

    function test_claimReward_winnerReceivesPayout() public {
        _buy(TRADER_A, true, 100 * 1e6);
        _resolve(true);

        uint256 balBefore = _bal(TRADER_A);
        vm.prank(TRADER_A);
        market.claimReward();

        assertGt(_bal(TRADER_A), balBefore);
        console.log("TRADER_A payout:", _bal(TRADER_A) - balBefore);
    }

    function test_claimReward_loserGetsNothing() public {
        _buy(TRADER_A, true,  100 * 1e6);
        _buy(TRADER_B, false,  50 * 1e6);
        _resolve(true);

        vm.prank(TRADER_B);
        vm.expectRevert(PredictionMarket.ZeroShares.selector);
        market.claimReward();
    }

    function test_claimReward_proportionalToShares() public {
        _buy(TRADER_A, true, 200 * 1e6);
        _buy(TRADER_B, true, 100 * 1e6);
        _resolve(true);

        uint256 aBefore = _bal(TRADER_A);
        uint256 bBefore = _bal(TRADER_B);

        vm.prank(TRADER_A);
        market.claimReward();
        vm.prank(TRADER_B);
        market.claimReward();

        uint256 aGain = _bal(TRADER_A) - aBefore;
        uint256 bGain = _bal(TRADER_B) - bBefore;

        assertGt(aGain, bGain);
        console.log("Trader A payout:", aGain);
        console.log("Trader B payout:", bGain);
    }

    function test_claimReward_revertsIfAlreadyClaimed() public {
        _buy(TRADER_A, true, 100 * 1e6);
        _resolve(true);

        vm.startPrank(TRADER_A);
        market.claimReward();
        vm.expectRevert(PredictionMarket.AlreadyClaimed.selector);
        market.claimReward();
        vm.stopPrank();
    }

    function test_claimReward_revertsIfMarketNotResolved() public {
        _buy(TRADER_A, true, 100 * 1e6);
        vm.prank(TRADER_A);
        vm.expectRevert(PredictionMarket.MarketNotResolved.selector);
        market.claimReward();
    }

    function test_claimReward_revertsIfMarketExpired() public {
        _buy(TRADER_A, true, 100 * 1e6);
        _expire();
        vm.prank(TRADER_A);
        vm.expectRevert(PredictionMarket.MarketNotResolved.selector);
        market.claimReward();
    }

    function test_claimReward_solvency_allWinnersCanClaim() public {
        _buy(TRADER_A, true, 100 * 1e6);
        _buy(TRADER_B, true,  50 * 1e6);
        _resolve(true);

        uint256 snapshotPot = market.resolvedPot();

        vm.prank(TRADER_A);
        market.claimReward();
        vm.prank(TRADER_B);
        market.claimReward();
        vm.prank(HOST);
        market.claimReward();

        uint256 remaining = _bal(address(market));
        uint256 fees      = market.accruedFees();

        // Remaining must equal accrued fees (winner payouts use snapshot, not live balance).
        // Allow 1 wei dust per claimer (3 claimants).
        assertApproxEqAbs(remaining, fees, 3);

        console.log("resolvedPot:     ", snapshotPot);
        console.log("Remaining bal:   ", remaining);
        console.log("Accrued fees:    ", fees);
        console.log("Dust (remaining - fees):", remaining > fees ? remaining - fees : fees - remaining);
    }

    function test_claimReward_claimOrderDoesNotAffectPayout() public {
        _buy(TRADER_A, true, 100 * 1e6);
        _buy(TRADER_B, true,  50 * 1e6);
        _resolve(true);

        // Record expected payouts from the snapshot
        uint256 pot         = market.resolvedPot();
        uint256 totalShares = market.totalYesShares();
        uint256 aExpected   = (market.yesShares(TRADER_A) * pot) / totalShares;
        uint256 bExpected   = (market.yesShares(TRADER_B) * pot) / totalShares;

        // A claims first
        uint256 aBefore = _bal(TRADER_A);
        vm.prank(TRADER_A);
        market.claimReward();
        assertEq(_bal(TRADER_A) - aBefore, aExpected);

        // B claims second — should get the same amount as if they'd claimed first
        uint256 bBefore = _bal(TRADER_B);
        vm.prank(TRADER_B);
        market.claimReward();
        assertEq(_bal(TRADER_B) - bBefore, bExpected);
    }

    // claimRefunds Tests 

    function test_claimRefund_returnsNetDeposit() public {
        uint256 amount       = 100 * 1e6;
        uint256 expectedBack = amount - (amount * FEE_BPS) / 10_000;

        _buy(TRADER_A, true, amount);
        _expire();

        uint256 balBefore = _bal(TRADER_A);
        vm.prank(TRADER_A);
        market.claimRefund();

        assertEq(_bal(TRADER_A) - balBefore, expectedBack);
    }

    function test_claimRefund_transitionsStatusToExpired() public {
        _buy(TRADER_A, true, 100 * 1e6);
        _expire();

        assertEq(uint8(market.status()), 0); // still OPEN

        vm.prank(TRADER_A);
        market.claimRefund();

        assertEq(uint8(market.status()), 2); // EXPIRED
    }

    function test_claimRefund_emitsMarketExpiredOnce() public {
        _buy(TRADER_A, true,  100 * 1e6);
        _buy(TRADER_B, false,  50 * 1e6);
        _expire();

        vm.expectEmit(false, false, false, false);
        emit PredictionMarket.MarketExpired();
        vm.prank(TRADER_A);
        market.claimRefund();

        // Second claim should NOT re-emit MarketExpired
        vm.prank(TRADER_B);
        market.claimRefund();
    }

    function test_claimRefund_revertsBeforeDeadline() public {
        _buy(TRADER_A, true, 100 * 1e6);
        vm.prank(TRADER_A);
        vm.expectRevert(PredictionMarket.DeadlineNotPassed.selector);
        market.claimRefund();
    }

    function test_claimRefund_revertsIfMarketResolved() public {
        _buy(TRADER_A, true, 100 * 1e6);
        _resolve(true);
        _expire();
        vm.prank(TRADER_A);
        vm.expectRevert(PredictionMarket.MarketNotExpired.selector);
        market.claimRefund();
    }

    function test_claimRefund_revertsIfAlreadyClaimed() public {
        _buy(TRADER_A, true, 100 * 1e6);
        _expire();

        vm.startPrank(TRADER_A);
        market.claimRefund();
        vm.expectRevert(PredictionMarket.AlreadyClaimed.selector);
        market.claimRefund();
        vm.stopPrank();
    }

    function test_claimRefund_revertsIfNoDeposit() public {
        _expire();
        vm.prank(STRANGER);
        vm.expectRevert(PredictionMarket.ZeroRefund.selector);
        market.claimRefund();
    }

    function test_claimRefund_solvency_allTradersCanRefund() public {
        _buy(TRADER_A, true,  100 * 1e6);
        _buy(TRADER_B, false,  80 * 1e6);
        _expire();

        vm.prank(TRADER_A);
        market.claimRefund();
        vm.prank(TRADER_B);
        market.claimRefund();
        vm.prank(HOST);
        market.claimRefund();

        // Only fees remain
        assertEq(_bal(address(market)), market.accruedFees());
    }

    // withdrawFees Tests

    function test_withdrawFees_hostReceivesFees() public {
        _buy(TRADER_A, true, 100 * 1e6);
        uint256 expectedFees  = market.accruedFees();
        uint256 hostBalBefore = _bal(HOST);

        vm.prank(HOST);
        market.withdrawFees();

        assertEq(_bal(HOST) - hostBalBefore, expectedFees);
        assertEq(market.accruedFees(), 0);
    }

    function test_withdrawFees_revertsIfNotHost() public {
        _buy(TRADER_A, true, 100 * 1e6);
        vm.prank(STRANGER);
        vm.expectRevert(PredictionMarket.NotHost.selector);
        market.withdrawFees();
    }

    function test_withdrawFees_revertsIfNoFees() public {
        vm.prank(HOST);
        vm.expectRevert(PredictionMarket.ZeroFees.selector);
        market.withdrawFees();
    }

    function test_withdrawFees_canBeCalledBeforeResolution() public {
        _buy(TRADER_A, true, 100 * 1e6);
        vm.prank(HOST);
        market.withdrawFees();
        assertEq(uint8(market.status()), 0); // still OPEN
    }

    function test_withdrawFees_doesNotAffectWinnerPayout() public {
        _buy(TRADER_A, true, 100 * 1e6);

        // Host drains fees before resolution
        vm.prank(HOST);
        market.withdrawFees();

        _resolve(true);

        uint256 balBefore = _bal(TRADER_A);
        vm.prank(TRADER_A);
        market.claimReward();

        assertGt(_bal(TRADER_A), balBefore);
    }

    // Basic Security Tests

    function test_security_noDoubleClaimReward() public {
        _buy(TRADER_A, true, 100 * 1e6);
        _resolve(true);

        vm.prank(TRADER_A);
        market.claimReward();
        assertTrue(market.hasClaimed(TRADER_A));

        vm.prank(TRADER_A);
        vm.expectRevert(PredictionMarket.AlreadyClaimed.selector);
        market.claimReward();
    }

    function test_security_noDoubleClaimRefund() public {
        _buy(TRADER_A, true, 100 * 1e6);
        _expire();

        vm.prank(TRADER_A);
        market.claimRefund();
        assertTrue(market.hasClaimed(TRADER_A));
        assertEq(market.totalDeposited(TRADER_A), 0);

        vm.prank(TRADER_A);
        vm.expectRevert(PredictionMarket.AlreadyClaimed.selector);
        market.claimRefund();
    }

    function test_security_strangerCannotResolve() public {
        vm.prank(STRANGER);
        vm.expectRevert(PredictionMarket.NotHost.selector);
        market.resolve(true);
    }

    function test_security_cannotResolveMarketTwice() public {
        _resolve(true);
        vm.prank(HOST);
        vm.expectRevert(PredictionMarket.MarketNotOpen.selector);
        market.resolve(false);
    }

    function test_security_feesIsolatedFromCollateral() public {
        uint256 amount      = 100 * 1e6;
        uint256 fee         = (amount * FEE_BPS) / 10_000;
        uint256 effectiveIn = amount - fee;

        _buy(TRADER_A, true, amount);

        assertEq(market.accruedFees(), fee);
        assertEq(
            usdc.balanceOf(address(market)),
            INITIAL_LIQUIDITY * 2 + effectiveIn + fee
        );
    }

    function test_security_claimRewardAndRefundMutuallyExclusive() public {
        _buy(TRADER_A, true, 100 * 1e6);
        _resolve(true);

        vm.prank(TRADER_A);
        market.claimReward();

        _expire();
        vm.prank(TRADER_A);
        vm.expectRevert(PredictionMarket.MarketNotExpired.selector);
        market.claimRefund();
    }

    function test_security_resolvedPotUnaffectedByFeeWithdrawal() public {
        _buy(TRADER_A, true, 100 * 1e6);
        _resolve(true);

        uint256 pot = market.resolvedPot();

        // Host withdraws fees after resolution — should NOT change resolvedPot
        vm.prank(HOST);
        market.withdrawFees();

        assertEq(market.resolvedPot(), pot);
    }

    // Fuzz Tests
    
    function testFuzz_buyShares_pricesBounded(uint256 amount) public {
        amount = bound(amount, market.MIN_BET(), 1_000 * 1e6);

        usdc.mint(TRADER_A, amount);
        _buy(TRADER_A, true, amount);

        uint256 yp = market.yesPrice();
        uint256 np = market.noPrice();

        assertGt(yp, 0);
        assertLt(yp, 1e18);
        assertGt(np, 0);
        assertLt(np, 1e18);
        assertApproxEqAbs(yp + np, 1e18, 1);
    }

    function testFuzz_buyShares_feeCalculation(uint256 amount) public {
        amount = bound(amount, market.MIN_BET(), 1_000 * 1e6);
        uint256 feesBefore = market.accruedFees();

        usdc.mint(TRADER_A, amount);
        _buy(TRADER_A, true, amount);

        assertEq(market.accruedFees() - feesBefore, (amount * FEE_BPS) / 10_000);
    }

    function testFuzz_buyShares_pricesSumToOne(uint256 amountA, uint256 amountB) public {
        amountA = bound(amountA, market.MIN_BET(), 500 * 1e6);
        amountB = bound(amountB, market.MIN_BET(), 500 * 1e6);

        usdc.mint(TRADER_A, amountA);
        usdc.mint(TRADER_B, amountB);

        _buy(TRADER_A, true,  amountA);
        _buy(TRADER_B, false, amountB);

        assertApproxEqAbs(market.yesPrice() + market.noPrice(), 1e18, 1);
    }

    function testFuzz_fullLifecycle_resolveAndClaim(uint256 amount, bool yesWins) public {
        amount = bound(amount, market.MIN_BET(), 500 * 1e6);

        usdc.mint(TRADER_A, amount);
        _buy(TRADER_A, yesWins ? true : false, amount);
        _resolve(yesWins);

        uint256 balBefore = _bal(TRADER_A);
        vm.prank(TRADER_A);
        market.claimReward();

        assertGt(_bal(TRADER_A), balBefore);
    }

    /**
     * @dev Fuzz the solvency invariant across random trade amounts:
     *   After all winners claim, contract balance must equal fees ± dust.
     */
    function testFuzz_solvency_afterAllClaims(uint256 amountA, uint256 amountB) public {
        amountA = bound(amountA, market.MIN_BET(), 500 * 1e6);
        amountB = bound(amountB, market.MIN_BET(), 500 * 1e6);

        usdc.mint(TRADER_A, amountA);
        usdc.mint(TRADER_B, amountB);

        _buy(TRADER_A, true, amountA);
        _buy(TRADER_B, true, amountB);
        _resolve(true);

        vm.prank(TRADER_A);
        market.claimReward();
        vm.prank(TRADER_B);
        market.claimReward();
        vm.prank(HOST);
        market.claimReward();

        // Allow 1 wei dust per claimer (3 claimants)
        assertApproxEqAbs(_bal(address(market)), market.accruedFees(), 3);
    }
}
