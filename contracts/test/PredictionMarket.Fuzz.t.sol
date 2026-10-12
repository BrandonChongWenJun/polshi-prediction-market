// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {BaseTest} from "./utils/BaseTest.sol";
import {PredictionMarket} from "../src/PredictionMarket.sol";

contract PredictionMarketFuzzTest is BaseTest {
    function _newMarket(uint256 nRaw, uint256 liqRaw, uint16 fee, bool sixDecimals) internal returns (uint256 id) {
        uint256 n = bound(nRaw, 2, 8);
        IERC20 token = sixDecimals ? IERC20(address(usdt)) : IERC20(address(dai));
        uint256 unit = sixDecimals ? 1e6 : 1e18;
        uint256 liq = bound(liqRaw, 10 * unit, 100_000 * unit);
        PredictionMarket.CreateMarketParams memory p = _params(token, n, liq, dave);
        p.feeBps = uint16(bound(fee, 0, 500));
        id = _create(alice, p);
    }

    /// Buying and immediately selling everything never returns more than was paid (fees + rounding favour the pool).
    function testFuzz_buySellRoundTrip_noProfit(
        uint256 nRaw,
        uint256 liqRaw,
        uint16 fee,
        bool six,
        uint256 outcomeRaw,
        uint256 amountRaw
    ) public {
        uint256 id = _newMarket(nRaw, liqRaw, fee, six);
        PredictionMarket.MarketView memory v = pm.getMarket(id);
        uint8 outcome = uint8(bound(outcomeRaw, 0, v.numOutcomes - 1));
        uint256 unit = six ? 1e6 : 1e18;
        uint256 amount = bound(amountRaw, unit / 100, 200_000 * unit);

        IERC20 token = IERC20(v.collateral);
        uint256 start = token.balanceOf(bob);
        uint256 shares = _buy(bob, id, outcome, amount);
        (uint256 quote,) = pm.calcSellReturn(id, outcome, shares);
        if (quote > 0) _sell(bob, id, outcome, shares);
        assertLe(token.balanceOf(bob), start);
        _assertBacked(id);
    }

    /// Any sequence of trades keeps every outcome token fully collateralised and the ERC20 balance covers
    /// locked collateral plus unpaid fees.
    function testFuzz_randomTradesKeepSolvency(uint256 seed, uint256 nRaw, bool six) public {
        uint256 id = _newMarket(nRaw, seed, 200, six);
        uint256 n = pm.getMarket(id).numOutcomes;
        uint256 unit = six ? 1e6 : 1e18;
        address[3] memory traders = [bob, carol, eve];
        for (uint256 k; k < 12; ++k) {
            uint256 r = uint256(keccak256(abi.encode(seed, k)));
            address t = traders[r % 3];
            uint8 o = uint8((r >> 8) % n);
            uint256 bal = _bal(t, id, o);
            if ((r >> 16) % 3 == 0 && bal > 0) {
                uint256 s = bound(r >> 32, 1, bal);
                (uint256 q,) = pm.calcSellReturn(id, o, s);
                if (q > 0) _sell(t, id, o, s);
            } else {
                _buy(t, id, o, bound(r >> 32, unit / 10, 5000 * unit));
            }
            _assertBacked(id);
        }
        PredictionMarket.MarketView memory v = pm.getMarket(id);
        assertGe(IERC20(v.collateral).balanceOf(address(pm)), v.collateralLocked + v.feePool);
        assertApproxEqAbs(_sum(v.prices), 1e18, n);
    }

    /// Adding liquidity and removing it immediately can never extract value.
    function testFuzz_addRemoveLiquidity_noValueExtraction(uint256 nRaw, uint256 seed, uint256 amountRaw) public {
        uint256 id = _newMarket(nRaw, seed, 100, true);
        uint256 n = pm.getMarket(id).numOutcomes;
        _buy(carol, id, uint8(seed % n), bound(seed >> 8, 1e6, 50_000e6)); // imbalance the pool first
        uint256 amount = bound(amountRaw, 1e6, 100_000e6);

        uint256 usdtBefore = usdt.balanceOf(bob);
        vm.prank(bob);
        uint256 shares = pm.addLiquidity(id, amount, 0);
        vm.prank(bob);
        pm.removeLiquidity(id, shares, 0);
        uint256 collateralBack = usdt.balanceOf(bob) + amount - usdtBefore; // collateral returned

        uint256 minTokens = type(uint256).max;
        for (uint256 i; i < n; ++i) {
            uint256 b = _bal(bob, id, uint8(i));
            if (b < minTokens) minTokens = b;
            // exposure to any single outcome never exceeds what was deposited
            assertLe(collateralBack + b, amount);
        }
        // collateral + mergeable complete sets <= deposit
        assertLe(collateralBack + minTokens, amount);
        _assertBacked(id);
    }

    /// Custom initial odds produce matching spot prices.
    function testFuzz_initialOdds(uint256 a, uint256 b, uint256 c) public {
        uint256 o0 = bound(a, 100, 9800);
        uint256 o1 = bound(b, 100, 9900 - o0);
        uint256 o2 = 10_000 - o0 - o1;
        vm.assume(o2 >= 100);
        c = bound(c, 10e6, 1_000_000e6);
        PredictionMarket.CreateMarketParams memory p = _params(IERC20(address(usdt)), 3, c, dave);
        p.initialOddsBps = new uint16[](3);
        p.initialOddsBps[0] = uint16(o0);
        p.initialOddsBps[1] = uint16(o1);
        p.initialOddsBps[2] = uint16(o2);
        uint256 id = _create(alice, p);
        uint256[] memory prices = pm.getPrices(id);
        // 1e14 = 0.01 % tolerance (pool balances are rounded down)
        assertApproxEqAbs(prices[0], o0 * 1e14, 1e14);
        assertApproxEqAbs(prices[1], o1 * 1e14, 1e14);
        assertApproxEqAbs(prices[2], o2 * 1e14, 1e14);
        _assertBacked(id);
    }

    /// After resolution (any outcome or invalid) total payouts never exceed the collateral held.
    function testFuzz_resolutionPayoutsNeverExceedCollateral(uint256 seed, uint256 nRaw, uint256 winnerRaw) public {
        uint256 id = _newMarket(nRaw, seed, 150, seed % 2 == 0);
        PredictionMarket.MarketView memory v = pm.getMarket(id);
        uint256 n = v.numOutcomes;
        uint256 unit = v.collateral == address(usdt) ? 1e6 : 1e18;
        address[3] memory traders = [bob, carol, eve];
        for (uint256 k; k < 6; ++k) {
            uint256 r = uint256(keccak256(abi.encode(seed, k, "t")));
            _buy(traders[k % 3], id, uint8(r % n), bound(r >> 8, unit, 2000 * unit));
        }
        vm.prank(frank);
        pm.splitPosition(id, 3 * unit + 1);

        uint8 winner = winnerRaw % (n + 1) == n ? INVALID : uint8(winnerRaw % n);
        _warpToResolution(id);
        vm.prank(dave);
        pm.reportOutcome(id, winner);

        IERC20 token = IERC20(v.collateral);
        address[5] memory everyone = [alice, bob, carol, eve, frank];
        for (uint256 i; i < everyone.length; ++i) {
            address who = everyone[i];
            uint256 lp = pm.lpShares(id, who);
            if (lp > 0) {
                vm.prank(who);
                pm.removeLiquidity(id, lp, 0);
            }
            if (pm.getUserPosition(id, who).redeemable > 0) {
                vm.prank(who);
                pm.redeem(id);
            }
        }
        PredictionMarket.MarketView memory end = pm.getMarket(id);
        assertEq(token.balanceOf(address(pm)), end.collateralLocked + end.feePool);
        // only rounding dust remains
        assertLe(end.collateralLocked, 10);
    }
}
