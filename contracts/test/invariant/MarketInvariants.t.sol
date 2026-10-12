// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {PredictionMarket} from "../../src/PredictionMarket.sol";
import {MockUSDT} from "../../src/tokens/MockUSDT.sol";
import {MockERC20} from "../../src/tokens/MockERC20.sol";
import {WETH9} from "../../src/tokens/WETH9.sol";
import {MarketHandler} from "./MarketHandler.sol";

/// @title Core accounting invariants of the prediction market
/// @notice Proves, under random sequences of create / buy / sell / split / merge / add & remove liquidity /
///         claim / transfer / time travel / report / timeout / redeem across USDT (6 dp), DAI and WETH markets:
///         1. Conservation: each token's balance held by the contract == sum(collateralLocked + feePool).
///         2. Full backing before resolution: supply_i + pool_i == collateralLocked for every outcome i.
///         3. Solvency after resolution: collateralLocked covers the value of every outstanding share.
///         4. LP fees owed never exceed the fee pool; LP shares sum to totalLpShares.
///         5. Prices sum to 1 (up to N wei); liquid pools never have an empty outcome balance.
contract MarketInvariantsTest is Test {
    PredictionMarket internal pm;
    MarketHandler internal handler;
    IERC20[] internal tokens;
    address[] internal actors;

    function setUp() public {
        vm.warp(1_750_000_000);
        MockUSDT usdt = new MockUSDT();
        MockERC20 dai = new MockERC20("Dai", "DAI", 18, 0);
        WETH9 weth = new WETH9();
        pm = new PredictionMarket(address(this));
        pm.setCollateral(IERC20(address(usdt)), true, 10e6);
        pm.setCollateral(IERC20(address(dai)), true, 10e18);
        pm.setCollateral(IERC20(address(weth)), true, 0.01 ether);
        tokens.push(IERC20(address(usdt)));
        tokens.push(IERC20(address(dai)));
        tokens.push(IERC20(address(weth)));

        for (uint256 i; i < 5; ++i) {
            address a = makeAddr(string(abi.encodePacked("actor", vm.toString(i))));
            actors.push(a);
            usdt.mint(a, 1e15); // 1e9 USDT
            dai.mint(a, 1e27);
            vm.deal(a, 1e9 ether);
            vm.startPrank(a);
            weth.deposit{value: 1e9 ether}();
            usdt.approve(address(pm), type(uint256).max);
            dai.approve(address(pm), type(uint256).max);
            weth.approve(address(pm), type(uint256).max);
            vm.stopPrank();
        }

        handler = new MarketHandler(pm, tokens, actors, makeAddr("arbitrator"));
        // three markets to start with: USDT binary, DAI 3-outcome with odds, WETH 4-outcome
        handler.createMarket(0, 0, 0, 1000e6, 200);
        handler.createMarket(1, 1, 4, 500e18, 100);
        handler.createMarket(2, 2, 2, 20e18, 50);

        bytes4[] memory selectors = new bytes4[](15);
        selectors[0] = MarketHandler.createMarket.selector;
        selectors[1] = MarketHandler.buy.selector;
        selectors[2] = MarketHandler.buy.selector; // weight trading more heavily
        selectors[3] = MarketHandler.sell.selector;
        selectors[4] = MarketHandler.sell.selector;
        selectors[5] = MarketHandler.split.selector;
        selectors[6] = MarketHandler.merge.selector;
        selectors[7] = MarketHandler.addLiquidity.selector;
        selectors[8] = MarketHandler.removeLiquidity.selector;
        selectors[9] = MarketHandler.claimFees.selector;
        selectors[10] = MarketHandler.transferShares.selector;
        selectors[11] = MarketHandler.warp.selector;
        selectors[12] = MarketHandler.report.selector;
        selectors[13] = MarketHandler.redeem.selector;
        selectors[14] = MarketHandler.resolveTimeout.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// 1. Collateral conservation per token (exact: no donations happen in the handler).
    function invariant_collateralConservation() public view {
        uint256 n = handler.marketCount();
        for (uint256 t; t < tokens.length; ++t) {
            uint256 expected;
            for (uint256 k; k < n; ++k) {
                PredictionMarket.MarketView memory v = pm.getMarket(handler.markets(k));
                if (v.collateral == address(tokens[t])) expected += v.collateralLocked + v.feePool;
            }
            assertEq(tokens[t].balanceOf(address(pm)), expected, "collateral not conserved");
        }
    }

    /// 2 + 3. Every outstanding outcome token is backed; resolved markets can pay every claim.
    function invariant_solvency() public view {
        uint256 n = handler.marketCount();
        for (uint256 k; k < n; ++k) {
            PredictionMarket.MarketView memory v = pm.getMarket(handler.markets(k));
            if (!v.resolved) {
                for (uint256 i; i < v.numOutcomes; ++i) {
                    assertEq(v.outcomeSupply[i] + v.pool[i], v.collateralLocked, "outcome not fully backed");
                }
            } else if (v.outcome == pm.INVALID_OUTCOME()) {
                uint256 total;
                for (uint256 i; i < v.numOutcomes; ++i) {
                    total += v.outcomeSupply[i] + v.pool[i];
                }
                assertGe(v.collateralLocked * v.numOutcomes, total, "invalid market insolvent");
            } else {
                assertEq(
                    v.outcomeSupply[v.outcome] + v.pool[v.outcome], v.collateralLocked, "winning shares not backed"
                );
            }
        }
    }

    /// 4. LP accounting: pending fees are covered and LP shares add up.
    function invariant_lpAccounting() public view {
        uint256 n = handler.marketCount();
        for (uint256 k; k < n; ++k) {
            uint256 id = handler.markets(k);
            PredictionMarket.MarketView memory v = pm.getMarket(id);
            uint256 owed;
            uint256 shares;
            for (uint256 a; a < actors.length; ++a) {
                owed += pm.pendingFees(id, actors[a]);
                shares += pm.lpShares(id, actors[a]);
            }
            assertLe(owed, v.feePool, "fees owed exceed fee pool");
            assertEq(shares, v.totalLpShares, "LP shares do not sum to total");
        }
    }

    /// 5. Price sanity and pool shape.
    function invariant_pricesAndPool() public view {
        uint256 n = handler.marketCount();
        for (uint256 k; k < n; ++k) {
            PredictionMarket.MarketView memory v = pm.getMarket(handler.markets(k));
            uint256 sum;
            for (uint256 i; i < v.numOutcomes; ++i) {
                sum += v.prices[i];
                if (v.totalLpShares > 0) assertGt(v.pool[i], 0, "liquid pool has an empty outcome");
                else assertEq(v.pool[i], 0, "pool without LPs holds tokens");
            }
            assertApproxEqAbs(sum, 1e18, v.numOutcomes, "prices do not sum to 1");
        }
    }
}
