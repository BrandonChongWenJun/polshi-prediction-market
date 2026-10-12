// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC1155Errors} from "@openzeppelin/contracts/interfaces/IERC6093.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

import {BaseTest} from "./utils/BaseTest.sol";
import {PredictionMarket} from "../src/PredictionMarket.sol";

contract PredictionMarketTradingTest is BaseTest {
    event Trade(
        uint256 indexed marketId,
        address indexed trader,
        uint8 indexed outcome,
        bool isBuy,
        uint256 collateralAmount,
        uint256 shares,
        uint256 fee
    );

    uint256 internal id;

    function setUp() public override {
        super.setUp();
        id = _createBinaryUsdt(); // pool [1000, 1000] USDT, fee 2 %
    }

    // ------------------------------------------------------------------ complete sets

    function test_splitAndMerge() public {
        vm.prank(bob);
        pm.splitPosition(id, 50e6);
        assertEq(_bal(bob, id, 0), 50e6);
        assertEq(_bal(bob, id, 1), 50e6);
        assertEq(pm.getMarket(id).collateralLocked, 1050e6);
        _assertBacked(id);

        uint256 before = usdt.balanceOf(bob);
        vm.prank(bob);
        pm.mergePositions(id, 20e6);
        assertEq(_bal(bob, id, 0), 30e6);
        assertEq(_bal(bob, id, 1), 30e6);
        assertEq(usdt.balanceOf(bob), before + 20e6);
        assertEq(pm.getMarket(id).collateralLocked, 1030e6);
        _assertBacked(id);
    }

    function test_revert_splitMergeZero() public {
        vm.startPrank(bob);
        vm.expectRevert(PredictionMarket.ZeroAmount.selector);
        pm.splitPosition(id, 0);
        vm.expectRevert(PredictionMarket.ZeroAmount.selector);
        pm.mergePositions(id, 0);
        vm.stopPrank();
    }

    function test_revert_mergeWithoutFullSet() public {
        _buy(bob, id, 0, 10e6); // only YES tokens
        uint256 yes = _bal(bob, id, 0);
        uint256 noId = pm.positionId(id, 1); // computed before the prank (external calls consume it)
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC1155Errors.ERC1155InsufficientBalance.selector, bob, 0, yes, noId));
        pm.mergePositions(id, yes);
    }

    function test_revert_splitMissingMarket() public {
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(PredictionMarket.MarketNotFound.selector, 99));
        pm.splitPosition(99, 1e6);
    }

    function test_splitAllowedAfterClose_blockedAfterResolution() public {
        vm.warp(pm.getMarket(id).closeTime);
        vm.prank(bob);
        pm.splitPosition(id, 5e6); // P2P market makers can still mint sets after the AMM closes
        _warpToResolution(id);
        vm.prank(dave);
        pm.reportOutcome(id, 0);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(PredictionMarket.MarketAlreadyResolved.selector, id));
        pm.splitPosition(id, 5e6);
        // merging a full set is still worth exactly 1 after resolution
        uint256 before = usdt.balanceOf(bob);
        vm.prank(bob);
        pm.mergePositions(id, 5e6);
        assertEq(usdt.balanceOf(bob), before + 5e6);
    }

    // ------------------------------------------------------------------ buy

    function test_buy_knownValues() public {
        // fee = 2 USDT, net = 98 USDT; ending = ceil(1000e6 * 1000e6 / 1098e6) = 910_746_813
        uint256 expected = 1000e6 + 98e6 - 910_746_813;
        (uint256 quote, uint256 fee) = pm.calcBuyAmount(id, 0, 100e6);
        assertEq(quote, expected);
        assertEq(fee, 2e6);

        vm.expectEmit(true, true, true, true, address(pm));
        emit Trade(id, bob, 0, true, 100e6, expected, 2e6);
        uint256 shares = _buy(bob, id, 0, 100e6);
        assertEq(shares, expected);
        assertEq(_bal(bob, id, 0), expected);

        PredictionMarket.MarketView memory v = pm.getMarket(id);
        assertEq(v.pool[0], 910_746_813);
        assertEq(v.pool[1], 1098e6);
        assertEq(v.collateralLocked, 1098e6);
        assertEq(v.feePool, 2e6);
        assertEq(v.volume, 100e6);
        assertGt(v.prices[0], 0.5e18); // YES became more likely
        assertApproxEqAbs(v.prices[0] + v.prices[1], 1e18, 2);
        assertEq(usdt.balanceOf(address(pm)), 1100e6);
        _assertBacked(id);
    }

    function test_buy_averagePriceBetweenOldAndNewSpot() public {
        uint256 p0 = pm.getPrices(id)[0];
        uint256 shares = _buy(bob, id, 0, 200e6);
        uint256 p1 = pm.getPrices(id)[0];
        uint256 avgNet = (196e6 * 1e18) / shares; // average price excluding the fee
        assertGt(avgNet, p0);
        assertLt(avgNet, p1);
    }

    function test_buy_largeTradeNeverDrainsPool() public {
        _buy(bob, id, 0, 900_000e6);
        PredictionMarket.MarketView memory v = pm.getMarket(id);
        assertGt(v.pool[0], 0);
        assertGt(v.prices[0], 0.99e18);
        _assertBacked(id);
    }

    function test_revert_buy_slippage() public {
        (uint256 quote,) = pm.calcBuyAmount(id, 0, 100e6);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(PredictionMarket.SlippageExceeded.selector, quote, quote + 1));
        pm.buy(id, 0, 100e6, quote + 1);
    }

    function test_revert_buy_frontRunTriggersSlippage() public {
        (uint256 quote,) = pm.calcBuyAmount(id, 0, 100e6);
        _buy(carol, id, 0, 300e6); // front-runner moves the price
        vm.prank(bob);
        vm.expectRevert();
        pm.buy(id, 0, 100e6, (quote * 99) / 100);
    }

    function test_revert_buy_zero_invalidOutcome_missing() public {
        vm.startPrank(bob);
        vm.expectRevert(PredictionMarket.ZeroAmount.selector);
        pm.buy(id, 0, 0, 0);
        vm.expectRevert(abi.encodeWithSelector(PredictionMarket.InvalidOutcome.selector, 2));
        pm.buy(id, 2, 10e6, 0);
        vm.expectRevert(abi.encodeWithSelector(PredictionMarket.MarketNotFound.selector, 5));
        pm.buy(5, 0, 10e6, 0);
        vm.stopPrank();
    }

    function test_revert_buy_dustRoundsToZero() public {
        // 1 base unit: fee rounds up to 1, nothing left to invest
        vm.prank(bob);
        vm.expectRevert(PredictionMarket.ZeroAmount.selector);
        pm.buy(id, 0, 1, 0);
    }

    function test_revert_buy_afterClose() public {
        uint64 closeTime = pm.getMarket(id).closeTime;
        vm.warp(closeTime);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(PredictionMarket.TradingClosed.selector, id, closeTime));
        pm.buy(id, 0, 10e6, 0);
        assertEq(uint8(pm.phase(id)), uint8(PredictionMarket.Phase.Closed));
    }

    function test_revert_buy_whenPaused() public {
        vm.prank(admin);
        pm.pause();
        vm.prank(bob);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        pm.buy(id, 0, 10e6, 0);
        vm.prank(bob);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        pm.splitPosition(id, 10e6);
    }

    function test_buy_zeroFeeMarket() public {
        PredictionMarket.CreateMarketParams memory p = _params(IERC20(address(usdt)), 2, 1000e6, dave);
        p.feeBps = 0;
        uint256 m2 = _create(alice, p);
        (uint256 shares, uint256 fee) = pm.calcBuyAmount(m2, 1, 100e6);
        assertEq(fee, 0);
        assertEq(_buy(bob, m2, 1, 100e6), shares);
        assertEq(pm.getMarket(m2).feePool, 0);
    }

    // ------------------------------------------------------------------ sell

    function test_sell_exactInput_matchesQuote() public {
        uint256 shares = _buy(bob, id, 0, 100e6);
        (uint256 quote, uint256 fee) = pm.calcSellReturn(id, 0, shares / 2);
        uint256 before = usdt.balanceOf(bob);

        vm.expectEmit(true, true, true, true, address(pm));
        emit Trade(id, bob, 0, false, quote, shares / 2, fee);
        uint256 out = _sell(bob, id, 0, shares / 2);

        assertEq(out, quote);
        assertEq(usdt.balanceOf(bob), before + out);
        assertEq(_bal(bob, id, 0), shares - shares / 2);
        assertGt(fee, 0);
        _assertBacked(id);
    }

    function test_sell_roundTripLosesOnlyFeesAndRounding() public {
        uint256 shares = _buy(bob, id, 0, 100e6);
        uint256 out = _sell(bob, id, 0, shares);
        assertLt(out, 100e6);
        // 2 % in + 2 % out ~= 3.96 USDT; allow a couple of base units of rounding
        assertApproxEqAbs(100e6 - out, 3.96e6, 0.05e6);
        // pool returns (almost) to its initial state
        PredictionMarket.MarketView memory v = pm.getMarket(id);
        assertApproxEqAbs(v.prices[0], 0.5e18, 1e12);
        _assertBacked(id);
    }

    function test_sell_leavesNoProfitForSmallTrades() public {
        for (uint256 i = 1; i < 50; ++i) {
            uint256 s = _buy(carol, id, 1, i * 3 + 7);
            if (s == 0) continue;
            vm.prank(carol);
            try pm.sell(id, 1, s, 0) returns (uint256 out) {
                assertLe(out, i * 3 + 7);
            } catch {}
        }
        _assertBacked(id);
    }

    function test_revert_sell_slippage() public {
        uint256 shares = _buy(bob, id, 0, 100e6);
        (uint256 quote,) = pm.calcSellReturn(id, 0, shares);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(PredictionMarket.SlippageExceeded.selector, quote, quote + 1));
        pm.sell(id, 0, shares, quote + 1);
    }

    function test_revert_sell_insufficientBalance() public {
        uint256 shares = _buy(bob, id, 0, 100e6);
        uint256 yesId = pm.positionId(id, 0);
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(IERC1155Errors.ERC1155InsufficientBalance.selector, bob, shares, shares + 1, yesId)
        );
        pm.sell(id, 0, shares + 1, 0);
    }

    function test_revert_sell_zeroAndDust() public {
        vm.startPrank(bob);
        vm.expectRevert(PredictionMarket.ZeroAmount.selector);
        pm.sell(id, 0, 0, 0);
        pm.splitPosition(id, 10);
        vm.expectRevert(PredictionMarket.ZeroAmount.selector); // 1 share -> 0 collateral after fee rounding
        pm.sell(id, 0, 1, 0);
        vm.stopPrank();
    }

    function test_revert_sell_afterClose() public {
        uint256 shares = _buy(bob, id, 0, 100e6);
        vm.warp(pm.getMarket(id).closeTime + 1);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(PredictionMarket.TradingClosed.selector, id, pm.getMarket(id).closeTime));
        pm.sell(id, 0, shares, 0);
    }

    function test_revert_sell_whenPaused() public {
        uint256 shares = _buy(bob, id, 0, 100e6);
        vm.prank(admin);
        pm.pause();
        vm.prank(bob);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        pm.sell(id, 0, shares, 0);
    }

    function test_sell_sharesFromSplitAreSellable() public {
        vm.prank(bob);
        pm.splitPosition(id, 100e6);
        uint256 outYes = _sell(bob, id, 0, 100e6);
        // selling 100 YES into a balanced pool yields < 50 because of price impact
        assertLt(outYes, 50e6);
        assertGt(outYes, 40e6);
        _assertBacked(id);
    }

    // ------------------------------------------------------------------ multi-outcome & decimals

    function test_multiOutcome_buyMovesOnlyUpTheBoughtOutcome() public {
        uint256 m4 = _create(alice, _params(IERC20(address(dai)), 4, 1000e18, dave));
        uint256[] memory before = pm.getPrices(m4);
        _buy(bob, m4, 2, 250e18);
        uint256[] memory afterP = pm.getPrices(m4);
        assertGt(afterP[2], before[2]);
        assertLt(afterP[0], before[0]);
        assertLt(afterP[1], before[1]);
        assertLt(afterP[3], before[3]);
        assertApproxEqAbs(_sum(afterP), 1e18, 4);
        uint256 s = _bal(bob, m4, 2);
        _sell(bob, m4, 2, s / 3);
        _assertBacked(m4);
    }

    function test_decimals_sameEconomicsFor6And18Decimals() public {
        uint256 mDai = _create(alice, _params(IERC20(address(dai)), 2, 1000e18, dave));
        uint256 sUsdt = _buy(bob, id, 0, 100e6);
        uint256 sDai = _buy(bob, mDai, 0, 100e18);
        // identical trade in whole units gives identical shares (up to the 6-decimal rounding)
        assertApproxEqAbs(sDai / 1e12, sUsdt, 1);
        uint256[] memory pU = pm.getPrices(id);
        uint256[] memory pD = pm.getPrices(mDai);
        assertApproxEqAbs(pU[0], pD[0], 1e9);
    }

    function test_quotes_revertOnBadInputs() public {
        vm.expectRevert(abi.encodeWithSelector(PredictionMarket.InvalidOutcome.selector, 3));
        pm.calcBuyAmount(id, 3, 1e6);
        vm.expectRevert(abi.encodeWithSelector(PredictionMarket.InvalidOutcome.selector, 3));
        pm.calcSellReturn(id, 3, 1e6);
        vm.expectRevert(abi.encodeWithSelector(PredictionMarket.MarketNotFound.selector, 77));
        pm.calcBuyAmount(77, 0, 1e6);
    }

    function test_userPositionView() public {
        uint256 shares = _buy(bob, id, 1, 40e6);
        PredictionMarket.UserPosition memory pos = pm.getUserPosition(id, bob);
        assertEq(pos.balances.length, 2);
        assertEq(pos.balances[1], shares);
        assertEq(pos.lpShares, 0);
        assertEq(pos.redeemable, 0);
        PredictionMarket.UserPosition memory lp = pm.getUserPosition(id, alice);
        assertEq(lp.lpShares, 1000e6);
        assertApproxEqAbs(lp.pendingFees, 0.8e6, 1);
    }

    function test_erc1155TransfersKeepBacking() public {
        uint256 shares = _buy(bob, id, 0, 100e6);
        uint256 yesId = pm.positionId(id, 0);
        vm.prank(bob);
        pm.safeTransferFrom(bob, carol, yesId, shares, "");
        assertEq(_bal(carol, id, 0), shares);
        _assertBacked(id);
        // carol can sell tokens she received peer-to-peer
        assertGt(_sell(carol, id, 0, shares), 0);
    }
}
