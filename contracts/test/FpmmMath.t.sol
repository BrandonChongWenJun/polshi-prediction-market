// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {FpmmMath} from "../src/libraries/FpmmMath.sol";

/// @dev Exposes the library so reverts/returns can be tested through external calls.
contract FpmmHarness {
    function buy(uint256[] memory pool, uint256 outcome, uint256 net) external pure returns (uint256) {
        return FpmmMath.calcBuyAmount(pool, outcome, net);
    }

    function toSell(uint256[] memory pool, uint256 outcome, uint256 gross) external pure returns (uint256) {
        return FpmmMath.sharesToSell(pool, outcome, gross);
    }

    function sellGross(uint256[] memory pool, uint256 outcome, uint256 shares) external pure returns (uint256) {
        return FpmmMath.calcSellGross(pool, outcome, shares);
    }

    function prices(uint256[] memory pool) external pure returns (uint256[] memory) {
        return FpmmMath.prices(pool);
    }
}

contract FpmmMathTest is Test {
    FpmmHarness internal h;

    function setUp() public {
        h = new FpmmHarness();
    }

    function _pool2(uint256 a, uint256 b) internal pure returns (uint256[] memory p) {
        p = new uint256[](2);
        p[0] = a;
        p[1] = b;
    }

    function _randomPool(uint256 seed, uint256 n, uint256 minB, uint256 maxB)
        internal
        pure
        returns (uint256[] memory p)
    {
        p = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            p[i] = bound(uint256(keccak256(abi.encode(seed, i))), minB, maxB);
        }
    }

    function _product(uint256[] memory p) internal pure returns (uint256 prod) {
        prod = 1;
        for (uint256 i; i < p.length; ++i) {
            prod *= p[i];
        }
    }

    // ------------------------------------------------------------------ unit

    function test_buy_knownValue() public view {
        // ending = ceil(100 * 100 / 110) = 91 -> bought = 100 + 10 - 91 = 19
        assertEq(h.buy(_pool2(100, 100), 0, 10), 19);
        assertEq(h.buy(_pool2(100, 100), 0, 0), 0);
    }

    function test_sell_knownValue() public view {
        // releasing 9 sets: ending = ceil(100 * 100 / 91) = 110 -> toSell = 9 + 110 - 100 = 19
        assertEq(h.toSell(_pool2(100, 100), 0, 9), 19);
        assertEq(h.toSell(_pool2(100, 100), 0, 0), 0);
        assertEq(h.sellGross(_pool2(100, 100), 0, 19), 9);
        assertEq(h.sellGross(_pool2(100, 100), 0, 18), 8);
    }

    function test_sellGross_cappedByOtherBalances() public view {
        // the pool can release at most min(other balances) - 1 sets
        assertEq(h.sellGross(_pool2(1000, 5), 0, 1e30), 4);
    }

    function test_prices_binaryAndUniform() public view {
        uint256[] memory p = h.prices(_pool2(300, 100));
        assertEq(p[0], 0.25e18); // scarce outcome is the expensive one: 100 / 400
        assertEq(p[1], 0.75e18);
        uint256[] memory u = new uint256[](4);
        for (uint256 i; i < 4; ++i) {
            u[i] = 7;
        }
        uint256[] memory pu = h.prices(u);
        for (uint256 i; i < 4; ++i) {
            assertEq(pu[i], 0.25e18);
        }
    }

    function test_revert_sharesToSell_grossTooLarge() public {
        vm.expectRevert(); // division by zero / underflow when gross >= other balance
        h.toSell(_pool2(100, 100), 0, 100);
    }

    // ------------------------------------------------------------------ fuzz

    /// Buying never decreases the product of balances (rounding favours the pool).
    function testFuzz_buyKeepsProductNonDecreasing(uint256 seed, uint256 nRaw, uint256 outcomeRaw, uint256 net)
        public
        view
    {
        uint256 n = bound(nRaw, 2, 3);
        uint256[] memory pool = _randomPool(seed, n, 1, 1e24);
        uint256 outcome = bound(outcomeRaw, 0, n - 1);
        net = bound(net, 0, 1e24);
        uint256 before = _product(pool);
        uint256 bought = h.buy(pool, outcome, net);
        for (uint256 i; i < n; ++i) {
            pool[i] += net;
        }
        pool[outcome] -= bought;
        assertGe(pool[outcome], 1);
        assertGe(_product(pool), before);
    }

    /// Same property with up to 8 outcomes (smaller balances so the product fits in 256 bits).
    function testFuzz_buyKeepsProductNonDecreasing_manyOutcomes(uint256 seed, uint256 nRaw, uint256 net) public view {
        uint256 n = bound(nRaw, 4, 8);
        uint256[] memory pool = _randomPool(seed, n, 1, 1e8);
        net = bound(net, 0, 1e8);
        uint256 outcome = seed % n;
        uint256 before = _product(pool);
        uint256 bought = h.buy(pool, outcome, net);
        for (uint256 i; i < n; ++i) {
            pool[i] += net;
        }
        pool[outcome] -= bought;
        assertGe(_product(pool), before);
    }

    /// The exact-input sell search returns the maximal gross amount that the shares can pay for.
    function testFuzz_sellGrossIsMaximal(uint256 seed, uint256 nRaw, uint256 outcomeRaw, uint256 shares) public view {
        uint256 n = bound(nRaw, 2, 8);
        uint256[] memory pool = _randomPool(seed, n, 1, 1e27);
        uint256 outcome = bound(outcomeRaw, 0, n - 1);
        shares = bound(shares, 0, 1e27);
        uint256 g = h.sellGross(pool, outcome, shares);
        assertLe(g, shares);
        assertLe(h.toSell(pool, outcome, g), shares);
        uint256 cap = type(uint256).max;
        for (uint256 j; j < n; ++j) {
            if (j != outcome && pool[j] - 1 < cap) cap = pool[j] - 1;
        }
        if (g < cap && g < shares) {
            assertGt(h.toSell(pool, outcome, g + 1), shares);
        }
    }

    /// Selling after buying never returns more collateral than was invested.
    function testFuzz_roundTripNeverProfitable(uint256 seed, uint256 nRaw, uint256 net) public view {
        uint256 n = bound(nRaw, 2, 8);
        uint256[] memory pool = _randomPool(seed, n, 1e6, 1e27);
        uint256 outcome = seed % n;
        net = bound(net, 1, 1e27);
        uint256 bought = h.buy(pool, outcome, net);
        for (uint256 i; i < n; ++i) {
            pool[i] += net;
        }
        pool[outcome] -= bought;
        uint256 back = h.sellGross(pool, outcome, bought);
        assertLe(back, net);
    }

    /// Prices are positive and sum to 1e18 up to one wei of rounding per outcome.
    function testFuzz_pricesSumToOne(uint256 seed, uint256 nRaw) public view {
        uint256 n = bound(nRaw, 2, 8);
        uint256[] memory pool = _randomPool(seed, n, 1, 1e30);
        uint256[] memory p = h.prices(pool);
        uint256 sum;
        for (uint256 i; i < n; ++i) {
            assertGt(p[i], 0);
            sum += p[i];
        }
        assertApproxEqAbs(sum, 1e18, n);
    }

    /// Buying an outcome raises its price. In a binary market the other price falls accordingly; with N > 2
    /// the *sum* of the other prices falls, but an individual long shot can tick up (FPMM property found by
    /// this fuzz test: p_i / p_k = b_k / b_i and adding x to both balances pulls that ratio towards 1).
    function testFuzz_buyRaisesPrice(uint256 seed, uint256 nRaw, uint256 net) public view {
        uint256 n = bound(nRaw, 2, 8);
        uint256[] memory pool = _randomPool(seed, n, 1e9, 1e24);
        uint256 outcome = seed % n;
        // large enough relative to the pool that the price move exceeds 1 wei of rounding
        net = bound(net, 1e15, 1e24);
        uint256[] memory before = h.prices(pool);
        uint256 bought = h.buy(pool, outcome, net);
        for (uint256 i; i < n; ++i) {
            pool[i] += net;
        }
        pool[outcome] -= bought;
        uint256[] memory afterP = h.prices(pool);
        assertGe(afterP[outcome], before[outcome]);
        if (n == 2) assertLe(afterP[1 - outcome], before[1 - outcome]);
        // relative order between the bought outcome and every other outcome moves in its favour
        for (uint256 i; i < n; ++i) {
            if (i != outcome) assertGe(afterP[outcome] * before[i], before[outcome] * afterP[i]);
        }
    }
}
