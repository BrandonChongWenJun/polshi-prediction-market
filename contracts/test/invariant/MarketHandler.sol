// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {PredictionMarket} from "../../src/PredictionMarket.sol";

/// @dev Stateful fuzzing handler for {PredictionMarket}. Every action checks its own preconditions so that no
///      call reverts (the invariant config uses fail_on_revert = true), which guarantees the fuzzer is actually
///      exercising successful state transitions rather than bouncing off reverts.
contract MarketHandler is Test {
    PredictionMarket public pm;
    IERC20[] public tokens; // [USDT(6), DAI(18), WETH(18)]
    uint256[] public units; // one whole token in base units, per token
    address[] public actors;
    address public arbitrator;
    uint256[] public markets;

    mapping(bytes32 => uint256) public calls;

    constructor(PredictionMarket pm_, IERC20[] memory tokens_, address[] memory actors_, address arbitrator_) {
        pm = pm_;
        tokens = tokens_;
        units.push(1e6);
        units.push(1e18);
        units.push(1e18);
        actors = actors_;
        arbitrator = arbitrator_;
    }

    // ------------------------------------------------------------------ helpers

    function marketCount() external view returns (uint256) {
        return markets.length;
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    /// k-th actor after `seed` (wraps around; no overflow for any seed).
    function _actorAt(uint256 seed, uint256 k) internal view returns (address) {
        return actors[(seed % actors.length + k) % actors.length];
    }

    function _pickMarket(uint256 seed) internal view returns (uint256 id, PredictionMarket.MarketView memory v) {
        id = markets[seed % markets.length];
        v = pm.getMarket(id);
    }

    /// First actor (starting at `seed`) holding a non-zero balance of `tokenId`.
    function _holder(uint256 seed, uint256 tokenId) internal view returns (address a, uint256 bal) {
        for (uint256 k; k < actors.length; ++k) {
            a = _actorAt(seed, k);
            bal = pm.balanceOf(a, tokenId);
            if (bal != 0) return (a, bal);
        }
    }

    /// First market (starting at `seed`) in the given phase; `found` is false if there is none.
    function _findMarket(uint256 seed, PredictionMarket.Phase want, bool needLiquidity)
        internal
        view
        returns (bool found, uint256 id, PredictionMarket.MarketView memory v)
    {
        uint256 len = markets.length;
        for (uint256 k; k < len; ++k) {
            id = markets[(seed % len + k) % len];
            v = pm.getMarket(id);
            if (v.phase == want && (!needLiquidity || v.totalLpShares > 0)) return (true, id, v);
        }
    }

    function _unit(address collateral) internal view returns (uint256) {
        for (uint256 i; i < tokens.length; ++i) {
            if (address(tokens[i]) == collateral) return units[i];
        }
        return 1;
    }

    // ------------------------------------------------------------------ actions

    function createMarket(uint256 actorSeed, uint256 tokenSeed, uint256 nSeed, uint256 liqSeed, uint256 feeSeed)
        external
    {
        if (markets.length >= 16) return;
        uint256 t = tokenSeed % tokens.length;
        uint256 n = 2 + (nSeed % 4);
        PredictionMarket.CreateMarketParams memory p;
        p.question = "Invariant market";
        p.category = "Fuzz";
        p.outcomeLabels = new string[](n);
        for (uint256 i; i < n; ++i) {
            p.outcomeLabels[i] = "o";
        }
        p.closeTime = uint64(block.timestamp + 1 days + (liqSeed % 5 days));
        p.resolutionTime = uint64(p.closeTime + (feeSeed % 2 days));
        p.arbitrator = arbitrator;
        p.collateral = tokens[t];
        p.initialLiquidity = bound(liqSeed, 10 * units[t], 5000 * units[t]);
        p.feeBps = uint16(feeSeed % 501);
        if (nSeed % 3 == 0) {
            p.initialOddsBps = new uint16[](n);
            uint256 remaining = 10_000;
            for (uint256 i; i < n - 1; ++i) {
                uint256 o = 100 + (uint256(keccak256(abi.encode(nSeed, i))) % (remaining - 100 * (n - i)));
                p.initialOddsBps[i] = uint16(o);
                remaining -= o;
            }
            p.initialOddsBps[n - 1] = uint16(remaining);
        }
        vm.prank(_actor(actorSeed));
        markets.push(pm.createMarket(p));
        calls["createMarket"]++;
    }

    function buy(uint256 actorSeed, uint256 marketSeed, uint256 outcomeSeed, uint256 amountSeed) external {
        (bool found, uint256 id, PredictionMarket.MarketView memory v) =
            _findMarket(marketSeed, PredictionMarket.Phase.Trading, true);
        if (!found) return;
        uint8 o = uint8(outcomeSeed % v.numOutcomes);
        uint256 unit = _unit(v.collateral);
        uint256 amount = bound(amountSeed, unit / 100, 3000 * unit);
        (uint256 shares,) = pm.calcBuyAmount(id, o, amount);
        if (shares == 0) return;
        vm.prank(_actor(actorSeed));
        pm.buy(id, o, amount, shares);
        calls["buy"]++;
    }

    function sell(uint256 actorSeed, uint256 marketSeed, uint256 outcomeSeed, uint256 fractionSeed) external {
        (bool found, uint256 id, PredictionMarket.MarketView memory v) =
            _findMarket(marketSeed, PredictionMarket.Phase.Trading, true);
        if (!found) return;
        uint8 o = uint8(outcomeSeed % v.numOutcomes);
        (address a, uint256 bal) = _holder(actorSeed, pm.positionId(id, o));
        if (bal == 0) return;
        uint256 shares = bound(fractionSeed, 1, bal);
        (uint256 out,) = pm.calcSellReturn(id, o, shares);
        if (out == 0) return;
        vm.prank(a);
        pm.sell(id, o, shares, out);
        calls["sell"]++;
    }

    function split(uint256 actorSeed, uint256 marketSeed, uint256 amountSeed) external {
        (uint256 id, PredictionMarket.MarketView memory v) = _pickMarket(marketSeed);
        if (v.resolved) return;
        uint256 amount = bound(amountSeed, 1, 500 * _unit(v.collateral));
        vm.prank(_actor(actorSeed));
        pm.splitPosition(id, amount);
        calls["split"]++;
    }

    function merge(uint256 actorSeed, uint256 marketSeed, uint256 amountSeed) external {
        (uint256 id, PredictionMarket.MarketView memory v) = _pickMarket(marketSeed);
        address a;
        uint256 maxSets;
        for (uint256 k; k < actors.length && maxSets == 0; ++k) {
            a = _actorAt(actorSeed, k);
            maxSets = type(uint256).max;
            for (uint256 i; i < v.numOutcomes; ++i) {
                uint256 b = pm.balanceOf(a, pm.positionId(id, uint8(i)));
                if (b < maxSets) maxSets = b;
            }
        }
        if (maxSets == 0) return;
        vm.prank(a);
        pm.mergePositions(id, bound(amountSeed, 1, maxSets));
        calls["merge"]++;
    }

    function addLiquidity(uint256 actorSeed, uint256 marketSeed, uint256 amountSeed) external {
        (bool found, uint256 id, PredictionMarket.MarketView memory v) =
            _findMarket(marketSeed, PredictionMarket.Phase.Trading, false);
        if (!found) return;
        uint256 amount = bound(amountSeed, 1, 2000 * _unit(v.collateral));
        if (v.totalLpShares == 0) {
            // re-seeding an empty pool requires the collateral's minimum liquidity
            (,, uint256 minLiq) = pm.collateralConfig(IERC20(v.collateral));
            amount = bound(amountSeed, minLiq, 2000 * _unit(v.collateral));
        } else {
            uint256 weight;
            for (uint256 i; i < v.numOutcomes; ++i) {
                if (v.pool[i] > weight) weight = v.pool[i];
            }
            if ((amount * v.totalLpShares) / weight == 0) return;
        }
        vm.prank(_actor(actorSeed));
        pm.addLiquidity(id, amount, 0);
        calls["addLiquidity"]++;
    }

    function removeLiquidity(uint256 actorSeed, uint256 marketSeed, uint256 sharesSeed) external {
        (uint256 id,) = _pickMarket(marketSeed);
        address a;
        uint256 owned;
        for (uint256 k; k < actors.length && owned == 0; ++k) {
            a = _actorAt(actorSeed, k);
            owned = pm.lpShares(id, a);
        }
        if (owned == 0) return;
        uint256 shares = sharesSeed % 4 == 0 ? owned : bound(sharesSeed, 1, owned);
        vm.prank(a);
        pm.removeLiquidity(id, shares, 0);
        calls["removeLiquidity"]++;
    }

    function claimFees(uint256 actorSeed, uint256 marketSeed) external {
        (uint256 id,) = _pickMarket(marketSeed);
        address a;
        uint256 pending;
        for (uint256 k; k < actors.length && pending == 0; ++k) {
            a = _actorAt(actorSeed, k);
            pending = pm.pendingFees(id, a);
        }
        if (pending == 0) return;
        vm.prank(a);
        pm.claimFees(id);
        calls["claimFees"]++;
    }

    function transferShares(uint256 fromSeed, uint256 toSeed, uint256 marketSeed, uint256 outcomeSeed, uint256 amt)
        external
    {
        (uint256 id, PredictionMarket.MarketView memory v) = _pickMarket(marketSeed);
        uint256 tokenId = pm.positionId(id, uint8(outcomeSeed % v.numOutcomes));
        (address from, uint256 bal) = _holder(fromSeed, tokenId);
        address to = _actor(toSeed);
        if (bal == 0) return;
        vm.prank(from);
        pm.safeTransferFrom(from, to, tokenId, bound(amt, 1, bal), "");
        calls["transfer"]++;
    }

    /// Mostly short hops (keeps markets tradable), sometimes long jumps (reaches reporting / timeout phases).
    function warp(uint256 secondsSeed) external {
        uint256 dt = secondsSeed % 4 == 0 ? bound(secondsSeed, 1 days, 9 days) : bound(secondsSeed, 1, 8 hours);
        vm.warp(block.timestamp + dt);
        calls["warp"]++;
    }

    function report(uint256 marketSeed, uint256 outcomeSeed) external {
        (bool found, uint256 id, PredictionMarket.MarketView memory v) =
            _findMarket(marketSeed, PredictionMarket.Phase.Reporting, false);
        if (!found) return;
        uint256 pick = outcomeSeed % (uint256(v.numOutcomes) + 1);
        uint8 outcome = pick == v.numOutcomes ? pm.INVALID_OUTCOME() : uint8(pick);
        vm.prank(arbitrator);
        pm.reportOutcome(id, outcome);
        calls["report"]++;
    }

    function resolveTimeout(uint256 marketSeed) external {
        (bool found, uint256 id,) = _findMarket(marketSeed, PredictionMarket.Phase.ReportingTimedOut, false);
        if (!found) return;
        pm.resolveAfterTimeout(id);
        calls["timeout"]++;
    }

    function redeem(uint256 actorSeed, uint256 marketSeed) external {
        (uint256 id, PredictionMarket.MarketView memory v) = _pickMarket(marketSeed);
        if (!v.resolved) return;
        address a;
        uint256 redeemable;
        for (uint256 k; k < actors.length && redeemable == 0; ++k) {
            a = _actorAt(actorSeed, k);
            redeemable = pm.getUserPosition(id, a).redeemable;
        }
        if (redeemable == 0) return;
        vm.prank(a);
        pm.redeem(id);
        calls["redeem"]++;
    }
}
