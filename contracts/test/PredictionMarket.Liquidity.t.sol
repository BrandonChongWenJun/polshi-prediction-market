// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

import {BaseTest} from "./utils/BaseTest.sol";
import {PredictionMarket} from "../src/PredictionMarket.sol";

contract PredictionMarketLiquidityTest is BaseTest {
    uint256 internal id;

    function setUp() public override {
        super.setUp();
        id = _createBinaryUsdt(); // alice LP 1000 USDT, fee 2 %
    }

    function test_addLiquidity_balancedPool() public {
        vm.prank(bob);
        uint256 shares = pm.addLiquidity(id, 500e6, 0);
        assertEq(shares, 500e6);
        PredictionMarket.MarketView memory v = pm.getMarket(id);
        assertEq(v.pool[0], 1500e6);
        assertEq(v.pool[1], 1500e6);
        assertEq(v.totalLpShares, 1500e6);
        assertEq(pm.lpShares(id, bob), 500e6);
        assertEq(_bal(bob, id, 0), 0);
        _assertBacked(id);
    }

    function test_addLiquidity_imbalancedPoolKeepsPricesAndReturnsTokens() public {
        _buy(carol, id, 0, 300e6);
        uint256[] memory pBefore = pm.getPrices(id);
        PredictionMarket.MarketView memory v0 = pm.getMarket(id);

        vm.prank(bob);
        uint256 shares = pm.addLiquidity(id, 400e6, 0);

        PredictionMarket.MarketView memory v1 = pm.getMarket(id);
        uint256[] memory pAfter = v1.prices;
        assertApproxEqAbs(pAfter[0], pBefore[0], 1e10);
        assertApproxEqAbs(pAfter[1], pBefore[1], 1e10);
        // NO is the heavier side of the pool -> gets the full 400, YES gets less and the rest is returned
        assertEq(v1.pool[1], v0.pool[1] + 400e6);
        uint256 addedYes = (uint256(400e6) * v0.pool[0] + v0.pool[1] - 1) / v0.pool[1]; // rounded up
        assertEq(v1.pool[0], v0.pool[0] + addedYes);
        assertEq(_bal(bob, id, 0), 400e6 - addedYes);
        assertEq(_bal(bob, id, 1), 0);
        assertEq(shares, (uint256(400e6) * v0.totalLpShares) / v0.pool[1]);
        _assertBacked(id);
    }

    function test_revert_addLiquidity() public {
        vm.startPrank(bob);
        vm.expectRevert(PredictionMarket.ZeroAmount.selector);
        pm.addLiquidity(id, 0, 0);
        vm.expectRevert(abi.encodeWithSelector(PredictionMarket.SlippageExceeded.selector, 100e6, 100e6 + 1));
        pm.addLiquidity(id, 100e6, 100e6 + 1);
        vm.stopPrank();

        vm.prank(admin);
        pm.pause();
        vm.prank(bob);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        pm.addLiquidity(id, 100e6, 0);
        vm.prank(admin);
        pm.unpause();

        uint64 closeTime = pm.getMarket(id).closeTime;
        vm.warp(closeTime);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(PredictionMarket.TradingClosed.selector, id, closeTime));
        pm.addLiquidity(id, 100e6, 0);
    }

    function test_revert_addLiquidity_dustMintsZeroShares() public {
        _buy(carol, id, 0, 5000e6); // pool weight (max balance) now far above total LP shares
        PredictionMarket.MarketView memory v = pm.getMarket(id);
        assertGt(v.pool[1], v.totalLpShares);
        vm.prank(bob);
        vm.expectRevert(PredictionMarket.ZeroAmount.selector);
        pm.addLiquidity(id, 1, 0);
    }

    function test_getPool() public {
        _buy(carol, id, 1, 10e6);
        uint256[] memory pool = pm.getPool(id);
        assertEq(pool.length, 2);
        assertEq(pool[0], pm.getMarket(id).pool[0]);
    }

    function test_removeLiquidity_mergesBalancedPartAndReturnsRest() public {
        _buy(carol, id, 0, 300e6); // pool: YES scarce, NO abundant
        PredictionMarket.MarketView memory v0 = pm.getMarket(id);
        (uint256 quoteCol, uint256[] memory quoteTok) = pm.calcRemoveLiquidity(id, 500e6);
        uint256 before = usdt.balanceOf(alice);
        uint256 pending = pm.pendingFees(id, alice);

        vm.prank(alice);
        (uint256 col, uint256[] memory tok) = pm.removeLiquidity(id, 500e6, quoteCol);

        assertEq(col, quoteCol);
        assertEq(tok[0], quoteTok[0]);
        assertEq(tok[1], quoteTok[1]);
        uint256 yesShare = (v0.pool[0] * 500e6) / v0.totalLpShares;
        uint256 noShare = (v0.pool[1] * 500e6) / v0.totalLpShares;
        assertEq(col, yesShare); // min of the slice is merged into collateral
        assertEq(tok[0], 0);
        assertEq(tok[1], noShare - yesShare);
        assertEq(_bal(alice, id, 1), noShare - yesShare);
        assertEq(usdt.balanceOf(alice), before + col + pending); // fees paid on exit
        assertEq(pm.lpShares(id, alice), 500e6);
        assertEq(pm.pendingFees(id, alice), 0);
        _assertBacked(id);
    }

    function test_revert_removeLiquidity() public {
        vm.startPrank(alice);
        vm.expectRevert(PredictionMarket.ZeroAmount.selector);
        pm.removeLiquidity(id, 0, 0);
        vm.expectRevert(abi.encodeWithSelector(PredictionMarket.InsufficientLpShares.selector, 1000e6 + 1, 1000e6));
        pm.removeLiquidity(id, 1000e6 + 1, 0);
        vm.expectRevert(abi.encodeWithSelector(PredictionMarket.SlippageExceeded.selector, 100e6, 100e6 + 1));
        pm.removeLiquidity(id, 100e6, 100e6 + 1);
        vm.stopPrank();
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(PredictionMarket.InsufficientLpShares.selector, 1, 0));
        pm.removeLiquidity(id, 1, 0);
        vm.expectRevert(abi.encodeWithSelector(PredictionMarket.InsufficientLpShares.selector, 1000e6 + 1, 1000e6));
        pm.calcRemoveLiquidity(id, 1000e6 + 1);
    }

    function test_removeAllLiquidity_thenTradingNeedsNewLiquidity() public {
        _buy(bob, id, 1, 50e6);
        vm.prank(alice);
        pm.removeLiquidity(id, 1000e6, 0);
        PredictionMarket.MarketView memory v = pm.getMarket(id);
        assertEq(v.totalLpShares, 0);
        assertEq(v.pool[0], 0);
        assertEq(v.pool[1], 0);
        assertEq(v.prices[0], 0.5e18); // uniform when empty
        _assertBacked(id);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(PredictionMarket.NoLiquidity.selector, id));
        pm.buy(id, 0, 10e6, 0);
        vm.expectRevert(abi.encodeWithSelector(PredictionMarket.NoLiquidity.selector, id));
        pm.calcBuyAmount(id, 0, 10e6);
        vm.expectRevert(abi.encodeWithSelector(PredictionMarket.NoLiquidity.selector, id));
        pm.calcSellReturn(id, 0, 10e6);

        // re-seeding an empty pool needs at least the collateral's minimum liquidity
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(PredictionMarket.LiquidityTooLow.selector, 1e6, USDT_MIN_LIQ));
        pm.addLiquidity(id, 1e6, 0);
        // a new LP re-seeds the pool at uniform odds
        vm.prank(carol);
        uint256 shares = pm.addLiquidity(id, 200e6, 0);
        assertEq(shares, 200e6);
        assertEq(pm.getMarket(id).pool[0], 200e6);
        assertGt(_buy(bob, id, 0, 10e6), 0);
        _assertBacked(id);
    }

    function test_reseedEmptyPool_withZeroMinimumConfigured() public {
        vm.prank(alice);
        pm.removeLiquidity(id, 1000e6, 0);
        vm.prank(admin);
        pm.setCollateral(IERC20(address(usdt)), true, 0); // no minimum -> 1 base unit
        vm.prank(carol);
        assertEq(pm.addLiquidity(id, 1, 0), 1);
        assertEq(pm.getMarket(id).pool[0], 1);
        _assertBacked(id);
    }

    function test_removeLiquidity_allowedWhilePausedAndAfterClose() public {
        vm.prank(admin);
        pm.pause();
        vm.prank(alice);
        pm.removeLiquidity(id, 100e6, 0);
        vm.prank(admin);
        pm.unpause();
        vm.warp(pm.getMarket(id).closeTime + 1);
        vm.prank(alice);
        pm.removeLiquidity(id, 100e6, 0);
        assertEq(pm.lpShares(id, alice), 800e6);
    }

    function test_removeLiquidity_afterResolution_paysValue() public {
        _buy(bob, id, 0, 200e6); // pool holds fewer YES
        _warpToResolution(id);
        vm.prank(dave);
        pm.reportOutcome(id, 1); // NO wins -> pool's NO tokens are valuable
        PredictionMarket.MarketView memory v = pm.getMarket(id);
        uint256 fees = pm.pendingFees(id, alice);
        uint256 before = usdt.balanceOf(alice);
        vm.prank(alice);
        (uint256 col, uint256[] memory tok) = pm.removeLiquidity(id, 1000e6, 0);
        assertEq(col, v.pool[1]); // value = NO balance of the pool
        assertEq(tok[0], 0);
        assertEq(tok[1], 0);
        assertEq(usdt.balanceOf(alice), before + col + fees);
        // bob's YES lost -> nothing to redeem; contract keeps no more than dust
        vm.prank(bob);
        vm.expectRevert(PredictionMarket.NothingToRedeem.selector);
        pm.redeem(id);
        assertLe(usdt.balanceOf(address(pm)), 2);
    }

    // ------------------------------------------------------------------ fees

    function test_fees_splitProRataBetweenLps() public {
        vm.prank(bob);
        pm.addLiquidity(id, 1000e6, 0); // bob and alice 50/50
        _buy(carol, id, 0, 100e6); // fee 2
        _buy(carol, id, 1, 50e6); // fee 1
        assertEq(pm.pendingFees(id, alice), 1.5e6);
        assertEq(pm.pendingFees(id, bob), 1.5e6);

        uint256 before = usdt.balanceOf(bob);
        vm.prank(bob);
        uint256 claimed = pm.claimFees(id);
        assertEq(claimed, 1.5e6);
        assertEq(usdt.balanceOf(bob), before + 1.5e6);
        assertEq(pm.pendingFees(id, bob), 0);
        assertEq(pm.getMarket(id).feePool, 1.5e6);

        vm.prank(bob);
        vm.expectRevert(PredictionMarket.NothingToClaim.selector);
        pm.claimFees(id);
    }

    function test_fees_lateLpDoesNotEarnEarlierFees() public {
        _buy(carol, id, 0, 100e6); // 2 USDT to alice only
        vm.prank(bob);
        pm.addLiquidity(id, 500e6, 0);
        assertEq(pm.pendingFees(id, alice), 2e6);
        assertEq(pm.pendingFees(id, bob), 0);
        uint256 cs = _bal(carol, id, 0);
        _sell(carol, id, 0, cs);
        // later fees are shared according to current shares
        assertGt(pm.pendingFees(id, bob), 0);
        assertGt(pm.pendingFees(id, alice), 2e6);
    }

    function test_fees_claimableAfterResolutionAndWhilePaused() public {
        _buy(carol, id, 0, 100e6);
        vm.prank(admin);
        pm.pause();
        vm.prank(alice);
        assertEq(pm.claimFees(id), 2e6);
        vm.prank(admin);
        pm.unpause();
        _buy(carol, id, 0, 100e6);
        _warpToResolution(id);
        vm.prank(dave);
        pm.reportOutcome(id, 0);
        vm.prank(alice);
        assertEq(pm.claimFees(id), 2e6);
    }

    function test_fees_neverExceedPoolWithOddShares() public {
        // three LPs with awkward share counts -> accumulator rounding must never over-pay
        vm.prank(bob);
        pm.addLiquidity(id, 333_333_333, 0);
        vm.prank(carol);
        pm.addLiquidity(id, 77_777_777, 0);
        for (uint256 i; i < 25; ++i) {
            _buy(eve, id, uint8(i % 2), 1_234_567 + i * 101);
        }
        uint256 feePool = pm.getMarket(id).feePool;
        uint256 owed = pm.pendingFees(id, alice) + pm.pendingFees(id, bob) + pm.pendingFees(id, carol);
        assertLe(owed, feePool);
        assertGe(owed + 3, feePool); // at most one base unit of dust per LP
        vm.prank(alice);
        pm.claimFees(id);
        vm.prank(bob);
        pm.claimFees(id);
        vm.prank(carol);
        pm.claimFees(id);
        assertLe(pm.getMarket(id).feePool, 3);
    }

    function test_claimFees_missingMarket() public {
        vm.expectRevert(abi.encodeWithSelector(PredictionMarket.MarketNotFound.selector, 9));
        pm.claimFees(9);
    }
}
