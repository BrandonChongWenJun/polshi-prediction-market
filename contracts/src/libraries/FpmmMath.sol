// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title FpmmMath
/// @notice Pure math for a Gnosis-style Fixed Product Market Maker (FPMM) over N outcome tokens.
/// @dev The pool holds one balance per outcome. Buying outcome `i` with `x` collateral mints `x` complete
///      sets into the pool and removes enough outcome-`i` tokens that the product of all balances does not
///      decrease. Every intermediate division rounds *up* the balance the pool keeps, so rounding always
///      favours the pool (liquidity providers) and never the trader.
///      Spot price of outcome i:  p_i = (1 / b_i) / sum_k (1 / b_k)   (prices sum to 1).
library FpmmMath {
    /// @dev Fixed-point one for prices (1e18 = probability 1.0).
    uint256 internal constant ONE = 1e18;

    /// @notice Outcome tokens received for buying `outcome` with `netInvestment` collateral (fees already removed).
    /// @dev ending = b_i * prod_{j != i} b_j / (b_j + x)  (rounded up at each step)
    ///      bought = b_i + x - ending
    ///      All balances must be non-zero (checked by the caller).
    function calcBuyAmount(uint256[] memory pool, uint256 outcome, uint256 netInvestment)
        internal
        pure
        returns (uint256)
    {
        uint256 n = pool.length;
        uint256 buyTokenBalance = pool[outcome];
        uint256 ending = buyTokenBalance;
        for (uint256 j; j < n; ++j) {
            if (j == outcome) continue;
            uint256 b = pool[j];
            ending = Math.mulDiv(ending, b, b + netInvestment, Math.Rounding.Ceil);
        }
        // ending <= buyTokenBalance because every factor b / (b + x) <= 1 and ceil(k * 1) == k.
        return buyTokenBalance + netInvestment - ending;
    }

    /// @notice Outcome tokens a seller must give the pool so that it can release `gross` complete sets.
    /// @dev ending = b_i * prod_{j != i} b_j / (b_j - gross)  (rounded up)
    ///      toSell = gross + ending - b_i
    ///      Requires gross < b_j for every j != outcome (checked by the caller / search bound).
    function sharesToSell(uint256[] memory pool, uint256 outcome, uint256 gross) internal pure returns (uint256) {
        uint256 n = pool.length;
        uint256 sellTokenBalance = pool[outcome];
        uint256 ending = sellTokenBalance;
        for (uint256 j; j < n; ++j) {
            if (j == outcome) continue;
            uint256 b = pool[j];
            ending = Math.mulDiv(ending, b, b - gross, Math.Rounding.Ceil);
        }
        return gross + ending - sellTokenBalance;
    }

    /// @notice Largest gross collateral amount the pool can release in exchange for exactly `sharesIn` tokens
    ///         of `outcome` (exact-input sell).
    /// @dev `sharesToSell` is strictly increasing in `gross`, so a binary search over
    ///      [0, min(sharesIn, min_{j != i} b_j - 1)] finds the maximum `gross` with sharesToSell(gross) <= sharesIn.
    ///      gross <= sharesIn always holds because a share can never be worth more than 1 collateral.
    ///      The loop runs at most ~log2(sharesIn) + 1 <= 257 iterations.
    function calcSellGross(uint256[] memory pool, uint256 outcome, uint256 sharesIn)
        internal
        pure
        returns (uint256 gross)
    {
        uint256 n = pool.length;
        uint256 hi = sharesIn;
        for (uint256 j; j < n; ++j) {
            if (j == outcome) continue;
            uint256 cap = pool[j] - 1; // pool balances are >= 1 (checked by the caller)
            if (cap < hi) hi = cap;
        }
        uint256 lo;
        while (lo < hi) {
            uint256 mid = lo + (hi - lo + 1) / 2;
            if (sharesToSell(pool, outcome, mid) <= sharesIn) {
                lo = mid;
            } else {
                hi = mid - 1;
            }
        }
        return lo;
    }

    /// @notice Marginal (spot) prices of every outcome, scaled by 1e18, derived from the pool balances.
    /// @dev p_i = 1 / sum_k (b_i / b_k). O(N^2) mulDivs, N <= 8. Sum of prices is 1e18 up to rounding dust.
    function prices(uint256[] memory pool) internal pure returns (uint256[] memory p) {
        uint256 n = pool.length;
        p = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            uint256 denom;
            for (uint256 k; k < n; ++k) {
                denom += Math.mulDiv(pool[i], ONE, pool[k]);
            }
            p[i] = Math.mulDiv(ONE, ONE, denom);
        }
    }
}
