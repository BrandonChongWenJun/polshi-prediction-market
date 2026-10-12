// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {BaseTest} from "./utils/BaseTest.sol";
import {PredictionMarket} from "../src/PredictionMarket.sol";

contract PredictionMarketResolutionTest is BaseTest {
    event MarketResolved(uint256 indexed marketId, uint8 outcome, address indexed resolver, bool timedOut);
    event Redeemed(uint256 indexed marketId, address indexed account, uint256 payout);

    uint256 internal id;
    uint256 internal bobYes;
    uint256 internal carolNo;

    function setUp() public override {
        super.setUp();
        id = _createBinaryUsdt();
        bobYes = _buy(bob, id, 0, 200e6);
        carolNo = _buy(carol, id, 1, 100e6);
    }

    // ------------------------------------------------------------------ reporting

    function test_phases() public {
        PredictionMarket.MarketView memory v = pm.getMarket(id);
        assertEq(uint8(pm.phase(id)), uint8(PredictionMarket.Phase.Trading));
        vm.warp(v.closeTime);
        assertEq(uint8(pm.phase(id)), uint8(PredictionMarket.Phase.Closed));
        vm.warp(v.resolutionTime);
        assertEq(uint8(pm.phase(id)), uint8(PredictionMarket.Phase.Reporting));
        vm.warp(v.resolutionTime + pm.ARBITRATION_TIMEOUT());
        assertEq(uint8(pm.phase(id)), uint8(PredictionMarket.Phase.ReportingTimedOut));
    }

    function test_report_byArbitrator() public {
        _warpToResolution(id);
        vm.expectEmit(true, true, false, true, address(pm));
        emit MarketResolved(id, 0, dave, false);
        vm.prank(dave);
        pm.reportOutcome(id, 0);
        PredictionMarket.MarketView memory v = pm.getMarket(id);
        assertTrue(v.resolved);
        assertEq(v.outcome, 0);
        assertEq(v.resolvedAt, block.timestamp);
        assertEq(uint8(v.phase), uint8(PredictionMarket.Phase.Resolved));
    }

    function test_revert_report_notArbitrator() public {
        _warpToResolution(id);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(PredictionMarket.NotArbitrator.selector, bob, dave));
        pm.reportOutcome(id, 0);
    }

    function test_revert_report_tooEarly() public {
        uint64 rt = pm.getMarket(id).resolutionTime;
        vm.warp(rt - 1);
        vm.prank(dave);
        vm.expectRevert(abi.encodeWithSelector(PredictionMarket.ResolutionTooEarly.selector, rt));
        pm.reportOutcome(id, 0);
    }

    function test_revert_report_afterWindow() public {
        uint256 deadline = pm.getMarket(id).resolutionTime + pm.ARBITRATION_TIMEOUT();
        vm.warp(deadline);
        vm.prank(dave);
        vm.expectRevert(abi.encodeWithSelector(PredictionMarket.ReportingWindowClosed.selector, deadline));
        pm.reportOutcome(id, 0);
    }

    function test_revert_report_invalidIndex_twice_missing() public {
        _warpToResolution(id);
        vm.startPrank(dave);
        vm.expectRevert(abi.encodeWithSelector(PredictionMarket.InvalidOutcome.selector, 2));
        pm.reportOutcome(id, 2);
        pm.reportOutcome(id, 1);
        vm.expectRevert(abi.encodeWithSelector(PredictionMarket.MarketAlreadyResolved.selector, id));
        pm.reportOutcome(id, 0);
        vm.expectRevert(abi.encodeWithSelector(PredictionMarket.MarketNotFound.selector, 50));
        pm.reportOutcome(50, 0);
        vm.stopPrank();
    }

    function test_report_allowedWhilePaused() public {
        vm.prank(admin);
        pm.pause();
        _warpToResolution(id);
        vm.prank(dave);
        pm.reportOutcome(id, 0);
        vm.prank(bob);
        assertEq(pm.redeem(id), bobYes); // redemption is never paused
    }

    // ------------------------------------------------------------------ redemption

    function test_redeem_winnerGetsOnePerShare_loserGetsNothing() public {
        _warpToResolution(id);
        vm.prank(dave);
        pm.reportOutcome(id, 0);

        PredictionMarket.UserPosition memory pos = pm.getUserPosition(id, bob);
        assertEq(pos.redeemable, bobYes);

        uint256 before = usdt.balanceOf(bob);
        vm.expectEmit(true, true, false, true, address(pm));
        emit Redeemed(id, bob, bobYes);
        vm.prank(bob);
        uint256 paid = pm.redeem(id);
        assertEq(paid, bobYes);
        assertEq(usdt.balanceOf(bob), before + bobYes);
        assertEq(_bal(bob, id, 0), 0);

        vm.prank(bob);
        vm.expectRevert(PredictionMarket.NothingToRedeem.selector); // double redeem
        pm.redeem(id);
        vm.prank(carol);
        vm.expectRevert(PredictionMarket.NothingToRedeem.selector); // loser
        pm.redeem(id);
    }

    function test_redeem_burnsLosingTokensToo() public {
        vm.prank(bob);
        pm.splitPosition(id, 10e6);
        _warpToResolution(id);
        vm.prank(dave);
        pm.reportOutcome(id, 0);
        vm.prank(bob);
        pm.redeem(id);
        assertEq(_bal(bob, id, 0), 0);
        assertEq(_bal(bob, id, 1), 0);
    }

    function test_revert_redeem_beforeResolution() public {
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(PredictionMarket.MarketNotResolved.selector, id));
        pm.redeem(id);
    }

    function test_invalid_paysOneOverNPerShare() public {
        _warpToResolution(id);
        vm.prank(dave);
        pm.reportOutcome(id, INVALID);
        assertEq(uint8(pm.phase(id)), uint8(PredictionMarket.Phase.Invalid));

        vm.prank(bob);
        assertEq(pm.redeem(id), bobYes / 2);
        vm.prank(carol);
        assertEq(pm.redeem(id), carolNo / 2);
    }

    function test_invalid_completeSetHolderIsMadeWhole() public {
        vm.prank(eve);
        pm.splitPosition(id, 77e6);
        _warpToResolution(id);
        vm.prank(dave);
        pm.reportOutcome(id, INVALID);
        uint256 before = usdt.balanceOf(eve);
        vm.prank(eve);
        pm.redeem(id);
        assertEq(usdt.balanceOf(eve), before + 77e6);
    }

    function test_timeout_resolvesInvalid() public {
        uint256 deadline = pm.getMarket(id).resolutionTime + pm.ARBITRATION_TIMEOUT();
        vm.warp(deadline - 1);
        vm.expectRevert(abi.encodeWithSelector(PredictionMarket.ReportingWindowOpen.selector, deadline));
        pm.resolveAfterTimeout(id);

        vm.warp(deadline);
        vm.expectEmit(true, true, false, true, address(pm));
        emit MarketResolved(id, INVALID, frank, true);
        vm.prank(frank); // anyone
        pm.resolveAfterTimeout(id);
        assertEq(uint8(pm.phase(id)), uint8(PredictionMarket.Phase.Invalid));

        vm.expectRevert(abi.encodeWithSelector(PredictionMarket.MarketAlreadyResolved.selector, id));
        pm.resolveAfterTimeout(id);
        vm.prank(dave);
        vm.expectRevert(abi.encodeWithSelector(PredictionMarket.MarketAlreadyResolved.selector, id));
        pm.reportOutcome(id, 0);

        vm.prank(bob);
        assertEq(pm.redeem(id), bobYes / 2);
    }

    function test_revert_timeout_afterReport() public {
        _warpToResolution(id);
        vm.prank(dave);
        pm.reportOutcome(id, 1);
        vm.warp(block.timestamp + 30 days);
        vm.expectRevert(abi.encodeWithSelector(PredictionMarket.MarketAlreadyResolved.selector, id));
        pm.resolveAfterTimeout(id);
    }

    function test_fullLifecycle_contractEndsWithOnlyDust() public {
        vm.prank(frank);
        pm.addLiquidity(id, 321e6, 0);
        _buy(eve, id, 1, 55e6);
        _sell(bob, id, 0, bobYes / 3);
        _warpToResolution(id);
        vm.prank(dave);
        pm.reportOutcome(id, 1);

        address[5] memory everyone = [alice, bob, carol, eve, frank];
        for (uint256 i; i < everyone.length; ++i) {
            address who = everyone[i];
            uint256 lp = pm.lpShares(id, who);
            if (lp > 0) {
                vm.prank(who);
                pm.removeLiquidity(id, lp, 0);
            }
            PredictionMarket.UserPosition memory pos = pm.getUserPosition(id, who);
            if (pos.redeemable > 0) {
                vm.prank(who);
                pm.redeem(id);
            }
            if (pm.pendingFees(id, who) > 0) {
                vm.prank(who);
                pm.claimFees(id);
            }
        }
        PredictionMarket.MarketView memory v = pm.getMarket(id);
        assertEq(v.outcomeSupply[1], 0); // every winning share was redeemed
        assertEq(v.totalLpShares, 0);
        // everything was paid out except rounding dust that stays (safely) in the contract
        assertLe(usdt.balanceOf(address(pm)), 5);
        assertEq(usdt.balanceOf(address(pm)), v.collateralLocked + v.feePool);
    }

    function test_fullLifecycle_invalid_multiOutcome_weth() public {
        uint256 m = _create(alice, _params(IERC20(address(weth)), 3, 3 ether, dave));
        _buy(bob, m, 0, 1 ether);
        _buy(carol, m, 2, 0.5 ether);
        vm.prank(eve);
        pm.splitPosition(m, 0.3 ether);
        _warpToResolution(m);
        vm.prank(dave);
        pm.reportOutcome(m, INVALID);

        uint256 total;
        address[4] memory everyone = [alice, bob, carol, eve];
        for (uint256 i; i < everyone.length; ++i) {
            address who = everyone[i];
            uint256 before = weth.balanceOf(who);
            uint256 lp = pm.lpShares(m, who);
            if (lp > 0) {
                vm.prank(who);
                pm.removeLiquidity(m, lp, 0);
            }
            if (pm.getUserPosition(m, who).redeemable > 0) {
                vm.prank(who);
                pm.redeem(m);
            }
            total += weth.balanceOf(who) - before;
        }
        // 3 + 1 + 0.5 + 0.3 ETH went in; everything but dust comes back out
        assertApproxEqAbs(total, 4.8 ether, 10);
        assertLe(weth.balanceOf(address(pm)), 10);
    }
}
