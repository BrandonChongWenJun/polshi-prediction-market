// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {PredictionMarket} from "../../src/PredictionMarket.sol";
import {ReputationOracle} from "../../src/ReputationOracle.sol";
import {IPredictionMarket} from "../../src/interfaces/IPredictionMarket.sol";
import {MockUSDT} from "../../src/tokens/MockUSDT.sol";

contract OracleHandler is Test {
    PredictionMarket public pm;
    ReputationOracle public oracle;
    address public owner;
    address[] public candidates;
    uint256[] public markets;
    IERC20 public collateral;

    constructor(
        PredictionMarket pm_,
        ReputationOracle oracle_,
        address owner_,
        address[] memory candidates_,
        IERC20 collateral_
    ) {
        pm = pm_;
        oracle = oracle_;
        owner = owner_;
        candidates = candidates_;
        collateral = collateral_;
    }

    function marketCount() external view returns (uint256) {
        return markets.length;
    }

    function candidateCount() external view returns (uint256) {
        return candidates.length;
    }

    function createVoteMarket(uint256 nSeed, uint256 timeSeed) external {
        if (markets.length >= 12) return;
        uint256 n = 2 + nSeed % 3;
        PredictionMarket.CreateMarketParams memory p;
        p.question = "Vote";
        p.outcomeLabels = new string[](n);
        for (uint256 i; i < n; ++i) {
            p.outcomeLabels[i] = "o";
        }
        p.closeTime = uint64(block.timestamp + 1 + timeSeed % 1 days);
        p.resolutionTime = p.closeTime;
        p.arbitrator = address(oracle);
        p.collateral = collateral;
        p.initialLiquidity = 100e6;
        vm.prank(owner);
        markets.push(pm.createMarket(p));
    }

    function register(uint256 seed) external {
        address a = candidates[seed % candidates.length];
        (bool registered,,,,) = oracle.reporters(a);
        if (registered) return;
        vm.prank(owner);
        oracle.registerReporter(a);
    }

    function remove(uint256 seed) external {
        address a = candidates[seed % candidates.length];
        (bool registered,,,,) = oracle.reporters(a);
        if (!registered) return;
        vm.prank(owner);
        oracle.removeReporter(a);
    }

    function vote(uint256 reporterSeed, uint256 marketSeed, uint256 outcomeSeed) external {
        if (markets.length == 0) return;
        uint256 id = markets[marketSeed % markets.length];
        IPredictionMarket.MarketCore memory core = pm.getMarketCore(id);
        ReputationOracle.RoundView memory r = oracle.getRound(id);
        if (core.resolved || r.status != ReputationOracle.RoundStatus.Pending) return;
        if (block.timestamp < r.votingStart || block.timestamp >= r.votingEnd) return;
        for (uint256 k; k < candidates.length; ++k) {
            address a = candidates[(reporterSeed % candidates.length + k) % candidates.length];
            (bool registered,,,, uint256 rep) = oracle.reporters(a);
            if (!registered || rep == 0 || oracle.getVote(id, a).voted) continue;
            uint256 pick = outcomeSeed % (uint256(core.numOutcomes) + 1);
            // bias votes towards outcome 0 so that consensus happens regularly
            if (outcomeSeed % 3 != 0) pick = 0;
            uint8 outcome = pick == core.numOutcomes ? pm.INVALID_OUTCOME() : uint8(pick);
            vm.prank(a);
            oracle.vote(id, outcome);
            return;
        }
    }

    function finalize(uint256 marketSeed) external {
        if (markets.length == 0) return;
        for (uint256 k; k < markets.length; ++k) {
            uint256 id = markets[(marketSeed % markets.length + k) % markets.length];
            ReputationOracle.RoundView memory r = oracle.getRound(id);
            if (r.status != ReputationOracle.RoundStatus.Pending || block.timestamp < r.votingEnd) continue;
            oracle.finalize(id);
            return;
        }
    }

    function warp(uint256 secondsSeed) external {
        vm.warp(block.timestamp + bound(secondsSeed, 1, 20 hours));
    }
}

/// @title Reputation oracle invariants
/// @notice 1. totalReputation == sum of registered reporters' reputation; activeReporters matches the registry.
///         2. reputation never exceeds MAX_REPUTATION.
///         3. each round's tally equals the sum of its votes' weights.
///         4. finalized rounds agree with the market: Resolved -> market resolved to the round result;
///            NoConsensus / Voided -> market INVALID.
contract OracleInvariantsTest is Test {
    PredictionMarket internal pm;
    ReputationOracle internal oracle;
    OracleHandler internal handler;

    function setUp() public {
        vm.warp(1_750_000_000);
        address owner = makeAddr("owner");
        MockUSDT usdt = new MockUSDT();
        pm = new PredictionMarket(owner);
        oracle = new ReputationOracle(IPredictionMarket(address(pm)), 1 days, 5000, owner);
        vm.startPrank(owner);
        pm.setCollateral(IERC20(address(usdt)), true, 1);
        usdt.mint(owner, 1e15);
        usdt.approve(address(pm), type(uint256).max);
        vm.stopPrank();

        address[] memory candidates = new address[](6);
        for (uint256 i; i < 6; ++i) {
            candidates[i] = makeAddr(string(abi.encodePacked("reporter", vm.toString(i))));
            if (i < 4) {
                vm.prank(owner);
                oracle.registerReporter(candidates[i]);
            }
        }
        handler = new OracleHandler(pm, oracle, owner, candidates, IERC20(address(usdt)));
        handler.createVoteMarket(0, 1);
        handler.createVoteMarket(1, 5000);
        targetContract(address(handler));
    }

    function invariant_reputationAccounting() public view {
        (address[] memory addrs, ReputationOracle.Reporter[] memory infos) = oracle.getReporters();
        uint256 total;
        uint256 active;
        for (uint256 i; i < addrs.length; ++i) {
            assertLe(infos[i].reputation, oracle.MAX_REPUTATION(), "reputation above cap");
            assertLe(infos[i].correctVotes, infos[i].votesCast, "more correct votes than votes");
            if (infos[i].registered) {
                total += infos[i].reputation;
                active += 1;
            }
        }
        assertEq(total, oracle.totalReputation(), "totalReputation drift");
        assertEq(active, oracle.activeReporters(), "active reporter count drift");
        assertLe(addrs.length, oracle.MAX_REPORTERS(), "registry above cap");
    }

    function invariant_roundsConsistentWithMarkets() public view {
        uint256 n = handler.marketCount();
        for (uint256 k; k < n; ++k) {
            uint256 id = handler.markets(k);
            ReputationOracle.RoundView memory r = oracle.getRound(id);
            (, uint8[] memory outcomes, uint256[] memory weights) = oracle.getVotes(id);
            uint256 sumWeights;
            for (uint256 i; i < weights.length; ++i) {
                sumWeights += weights[i];
                outcomes[i]; // silence unused warning
            }
            uint256 sumTally;
            for (uint256 i; i < r.tally.length; ++i) {
                sumTally += r.tally[i];
            }
            assertEq(sumWeights, r.totalWeight, "weights != totalWeight");
            assertEq(sumTally, r.totalWeight, "tally != totalWeight");

            IPredictionMarket.MarketCore memory core = pm.getMarketCore(id);
            if (r.status == ReputationOracle.RoundStatus.Resolved) {
                assertTrue(core.resolved, "resolved round, unresolved market");
                assertEq(core.outcome, r.result, "market outcome differs from round result");
                assertGe(r.totalWeight, r.requiredWeight, "resolved without quorum");
            } else if (r.status != ReputationOracle.RoundStatus.Pending) {
                assertTrue(core.resolved, "closed round, unresolved market");
                assertEq(core.outcome, pm.INVALID_OUTCOME(), "no-consensus round must be invalid");
            }
        }
    }
}
