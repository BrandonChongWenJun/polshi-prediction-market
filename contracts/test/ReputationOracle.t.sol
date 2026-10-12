// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {BaseTest} from "./utils/BaseTest.sol";
import {PredictionMarket} from "../src/PredictionMarket.sol";
import {ReputationOracle} from "../src/ReputationOracle.sol";
import {IPredictionMarket} from "../src/interfaces/IPredictionMarket.sol";

contract ReputationOracleTest is BaseTest {
    event VoteCast(uint256 indexed marketId, address indexed reporter, uint8 outcome, uint256 weight);
    event VotingExtended(uint256 indexed marketId, uint64 newVotingEnd, bool quorumReached);
    event RoundFinalized(
        uint256 indexed marketId, ReputationOracle.RoundStatus status, uint8 outcome, uint256 totalWeight
    );
    event ReputationUpdated(address indexed reporter, uint256 oldReputation, uint256 newReputation, bool correct);

    uint256 internal id;
    uint256 internal bobYes;

    function setUp() public override {
        super.setUp();
        vm.startPrank(admin);
        oracle.registerReporter(eve);
        oracle.registerReporter(frank);
        oracle.registerReporter(grace);
        oracle.registerReporter(heidi);
        vm.stopPrank();
        id = _voteMarket(2);
        bobYes = _buy(bob, id, 0, 100e6);
    }

    function _voteMarket(uint256 n) internal returns (uint256) {
        return _create(alice, _params(IERC20(address(usdt)), n, 1000e6, address(oracle)));
    }

    function _vote(address who, uint256 m, uint8 outcome) internal {
        vm.prank(who);
        oracle.vote(m, outcome);
    }

    function _rep(address who) internal view returns (uint256 rep) {
        (,,,, rep) = oracle.reporters(who);
    }

    // ------------------------------------------------------------------ construction & registry

    function test_constructor_validation() public {
        IPredictionMarket m = IPredictionMarket(address(pm));
        vm.expectRevert(ReputationOracle.InvalidParameters.selector);
        new ReputationOracle(IPredictionMarket(address(0)), 1 days, 5000, admin);
        vm.expectRevert(ReputationOracle.InvalidParameters.selector);
        new ReputationOracle(m, 0, 5000, admin);
        vm.expectRevert(ReputationOracle.InvalidParameters.selector);
        new ReputationOracle(m, 3.5 days, 5000, admin); // 2 * period must be < 7-day arbitration window
        vm.expectRevert(ReputationOracle.InvalidParameters.selector);
        new ReputationOracle(m, 1 days, 0, admin);
        vm.expectRevert(ReputationOracle.InvalidParameters.selector);
        new ReputationOracle(m, 1 days, 10_001, admin);
        ReputationOracle ok = new ReputationOracle(m, 3 days, 10_000, admin);
        assertEq(ok.votingPeriod(), 3 days);
    }

    function test_registry() public view {
        assertEq(oracle.totalReputation(), 400);
        assertEq(oracle.activeReporters(), 4);
        (bool registered, bool listed, uint64 votes, uint64 correct, uint256 rep) = oracle.reporters(eve);
        assertTrue(registered);
        assertTrue(listed);
        assertEq(votes, 0);
        assertEq(correct, 0);
        assertEq(rep, 100);
        (address[] memory addrs, ReputationOracle.Reporter[] memory infos) = oracle.getReporters();
        assertEq(addrs.length, 4);
        assertEq(addrs[0], eve);
        assertEq(infos[3].reputation, 100);
    }

    function test_revert_registry() public {
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob));
        oracle.registerReporter(bob);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob));
        oracle.removeReporter(eve);
        vm.startPrank(admin);
        vm.expectRevert(abi.encodeWithSelector(ReputationOracle.AlreadyRegistered.selector, eve));
        oracle.registerReporter(eve);
        vm.expectRevert(abi.encodeWithSelector(ReputationOracle.NotRegistered.selector, bob));
        oracle.removeReporter(bob);
        vm.expectRevert(ReputationOracle.InvalidParameters.selector);
        oracle.registerReporter(address(0));
        vm.stopPrank();
    }

    function test_maxReporters() public {
        vm.startPrank(admin);
        for (uint256 i = 4; i < oracle.MAX_REPORTERS(); ++i) {
            oracle.registerReporter(address(uint160(0x1000 + i)));
        }
        vm.expectRevert(ReputationOracle.TooManyReporters.selector);
        oracle.registerReporter(address(0xBADBAD));
        // re-registering an already listed address is still possible
        oracle.removeReporter(eve);
        oracle.registerReporter(eve);
        vm.stopPrank();
        assertEq(oracle.activeReporters(), oracle.MAX_REPORTERS());
    }

    function test_removeAndReRegister_keepsReputation() public {
        // eve votes wrong once, then is removed and re-added: her history is not reset
        _warpToResolution(id);
        _vote(eve, id, 1);
        _vote(frank, id, 0);
        _vote(grace, id, 0);
        vm.warp(block.timestamp + VOTING_PERIOD);
        oracle.finalize(id);
        assertEq(_rep(eve), 80);
        assertEq(oracle.totalReputation(), 400); // 80 + 110 + 110 + 100
        vm.prank(admin);
        oracle.removeReporter(eve);
        assertEq(oracle.totalReputation(), 320);
        assertEq(oracle.activeReporters(), 3);
        vm.prank(admin);
        oracle.registerReporter(eve);
        assertEq(_rep(eve), 80);
        assertEq(oracle.totalReputation(), 400);
    }

    // ------------------------------------------------------------------ voting

    function test_consensus_resolvesMarketAndUpdatesReputation() public {
        _warpToResolution(id);
        vm.expectEmit(true, true, false, true, address(oracle));
        emit VoteCast(id, eve, 0, 100);
        _vote(eve, id, 0);
        _vote(frank, id, 0);
        _vote(grace, id, 1);

        ReputationOracle.RoundView memory r = oracle.getRound(id);
        assertEq(r.totalWeight, 300);
        assertEq(r.requiredWeight, 200);
        assertEq(r.voterCount, 3);
        assertEq(r.tally[0], 200);
        assertEq(r.tally[1], 100);
        assertEq(r.tally[2], 0); // INVALID bucket
        assertEq(r.votingStart, pm.getMarket(id).resolutionTime);
        assertEq(r.votingEnd, pm.getMarket(id).resolutionTime + VOTING_PERIOD);

        vm.expectRevert(abi.encodeWithSelector(ReputationOracle.VotingStillOpen.selector, r.votingEnd));
        oracle.finalize(id);

        vm.warp(r.votingEnd);
        vm.expectEmit(true, false, false, true, address(oracle));
        emit ReputationUpdated(grace, 100, 80, false);
        vm.expectEmit(true, false, false, true, address(oracle));
        emit RoundFinalized(id, ReputationOracle.RoundStatus.Resolved, 0, 300);
        ReputationOracle.RoundStatus st = oracle.finalize(id);
        assertEq(uint8(st), uint8(ReputationOracle.RoundStatus.Resolved));

        assertEq(_rep(eve), 110);
        assertEq(_rep(frank), 110);
        assertEq(_rep(grace), 80);
        assertEq(_rep(heidi), 100); // did not vote -> unchanged
        assertEq(oracle.totalReputation(), 400);
        (,, uint64 votes, uint64 correct,) = oracle.reporters(eve);
        assertEq(votes, 1);
        assertEq(correct, 1);

        PredictionMarket.MarketView memory v = pm.getMarket(id);
        assertTrue(v.resolved);
        assertEq(v.outcome, 0);
        vm.prank(bob);
        assertEq(pm.redeem(id), bobYes);

        vm.expectRevert(abi.encodeWithSelector(ReputationOracle.RoundAlreadyFinalized.selector, id));
        oracle.finalize(id);
        vm.expectRevert(abi.encodeWithSelector(ReputationOracle.RoundAlreadyFinalized.selector, id));
        _vote(heidi, id, 0);
    }

    function test_revert_vote_marketResolvedByTimeoutBeforeFinalize() public {
        vm.warp(pm.getMarket(id).resolutionTime + pm.ARBITRATION_TIMEOUT());
        pm.resolveAfterTimeout(id); // nobody finalized the round
        vm.expectRevert(abi.encodeWithSelector(ReputationOracle.MarketAlreadyResolved.selector, id));
        _vote(heidi, id, 0);
    }

    function test_reputationWeighting_minorityOfVotersCanWinWithMoreReputation() public {
        // round 1: eve & frank right, grace wrong, heidi abstains -> 110/110/80/100
        _warpToResolution(id);
        _vote(eve, id, 0);
        _vote(frank, id, 0);
        _vote(grace, id, 1);
        vm.warp(block.timestamp + VOTING_PERIOD);
        oracle.finalize(id); // eve/frank 200 vs grace 100 -> YES
        vm.prank(admin);
        oracle.removeReporter(frank);

        // round 2: eve (110) alone outweighs grace (80)
        uint256 m2 = _voteMarket(3);
        _warpToResolution(m2);
        _vote(eve, m2, 2);
        _vote(grace, m2, 1);
        ReputationOracle.RoundView memory r = oracle.getRound(m2);
        assertEq(r.tally[2], 110);
        assertEq(r.tally[1], 80);
        vm.warp(r.votingEnd);
        oracle.finalize(m2);
        assertEq(pm.getMarket(m2).outcome, 2);
        assertEq(_rep(eve), 120);
        assertEq(_rep(grace), 64);
    }

    function test_voteInvalid_consensusMakesMarketInvalid() public {
        _warpToResolution(id);
        _vote(eve, id, INVALID);
        _vote(frank, id, INVALID);
        _vote(grace, id, 0);
        assertEq(oracle.getRound(id).tally[2], 200);
        vm.warp(block.timestamp + VOTING_PERIOD);
        oracle.finalize(id);
        assertEq(uint8(pm.phase(id)), uint8(PredictionMarket.Phase.Invalid));
        assertEq(_rep(eve), 110);
        assertEq(_rep(grace), 80);
        vm.prank(bob);
        assertEq(pm.redeem(id), bobYes / 2);
    }

    function test_revert_vote() public {
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(ReputationOracle.NotRegistered.selector, bob));
        oracle.vote(id, 0);

        uint256 rt = pm.getMarket(id).resolutionTime;
        vm.expectRevert(abi.encodeWithSelector(ReputationOracle.VotingNotStarted.selector, uint64(rt)));
        _vote(eve, id, 0);

        vm.warp(rt);
        vm.expectRevert(abi.encodeWithSelector(ReputationOracle.MarketNotFound.selector, 99));
        _vote(eve, 99, 0);
        uint256 davesMarket = _createBinaryUsdt();
        vm.expectRevert(abi.encodeWithSelector(ReputationOracle.NotOracleMarket.selector, davesMarket));
        _vote(eve, davesMarket, 0);
        vm.expectRevert(abi.encodeWithSelector(ReputationOracle.InvalidOutcome.selector, 2));
        _vote(eve, id, 2);

        _vote(eve, id, 1);
        vm.expectRevert(abi.encodeWithSelector(ReputationOracle.AlreadyVoted.selector, eve));
        _vote(eve, id, 0);

        vm.warp(rt + VOTING_PERIOD);
        vm.expectRevert(abi.encodeWithSelector(ReputationOracle.VotingClosed.selector, uint64(rt + VOTING_PERIOD)));
        _vote(frank, id, 0);
    }

    function test_removedReporterCannotVote_butEarlierVoteCountsAndIsFrozen() public {
        _warpToResolution(id);
        _vote(eve, id, 1);
        _vote(frank, id, 0);
        _vote(grace, id, 0);
        vm.prank(admin);
        oracle.removeReporter(eve);
        vm.expectRevert(abi.encodeWithSelector(ReputationOracle.NotRegistered.selector, eve));
        _vote(eve, id, 0);
        vm.warp(block.timestamp + VOTING_PERIOD);
        oracle.finalize(id);
        assertEq(_rep(eve), 100); // frozen: not slashed while de-registered
        assertEq(oracle.totalReputation(), 320); // frank 110 + grace 110 + heidi 100
    }

    // ------------------------------------------------------------------ quorum / tie handling

    function test_noQuorum_extendsOnce_thenResolves() public {
        _warpToResolution(id);
        _vote(eve, id, 0); // 100 < 200 required
        uint64 end = oracle.getRound(id).votingEnd;
        vm.warp(end);
        vm.expectEmit(true, false, false, true, address(oracle));
        emit VotingExtended(id, end + VOTING_PERIOD, false);
        ReputationOracle.RoundStatus st = oracle.finalize(id);
        assertEq(uint8(st), uint8(ReputationOracle.RoundStatus.Pending));
        ReputationOracle.RoundView memory r = oracle.getRound(id);
        assertTrue(r.extended);
        assertEq(r.votingEnd, end + VOTING_PERIOD);

        _vote(frank, id, 0); // late voter during extension reaches quorum
        vm.expectRevert(abi.encodeWithSelector(ReputationOracle.VotingStillOpen.selector, end + VOTING_PERIOD));
        oracle.finalize(id);
        vm.warp(end + VOTING_PERIOD);
        oracle.finalize(id);
        assertEq(pm.getMarket(id).outcome, 0);
        assertEq(_rep(eve), 110);
    }

    function test_lateFinalize_extensionStillGivesAFullPeriod() public {
        uint256 rt = pm.getMarket(id).resolutionTime;
        vm.warp(rt);
        _vote(eve, id, 0); // no quorum
        vm.warp(rt + 3 days); // nobody finalized for two days
        oracle.finalize(id);
        ReputationOracle.RoundView memory r = oracle.getRound(id);
        assertTrue(r.extended);
        assertEq(r.votingEnd, rt + 3 days + VOTING_PERIOD); // counted from the extension, not from the old end
        vm.warp(rt + 3 days + 1 hours);
        _vote(frank, id, 0); // still possible during the extension
        vm.warp(r.votingEnd);
        oracle.finalize(id);
        assertEq(pm.getMarket(id).outcome, 0);
    }

    function test_extensionCappedBeforeArbitrationDeadline() public {
        uint256 rt = pm.getMarket(id).resolutionTime;
        uint256 deadline = rt + pm.ARBITRATION_TIMEOUT();
        vm.warp(deadline - 12 hours); // finalize very late, without any vote
        oracle.finalize(id);
        assertEq(oracle.getRound(id).votingEnd, deadline - 1); // capped so the report still reaches the market
        _vote(frank, id, 1);
        _vote(grace, id, 1);
        vm.warp(deadline - 1);
        oracle.finalize(id);
        assertEq(pm.getMarket(id).outcome, 1);
    }

    function test_noVotesAtAll_extendsThenInvalid() public {
        _warpToResolution(id);
        vm.warp(block.timestamp + VOTING_PERIOD);
        oracle.finalize(id); // extension
        vm.warp(block.timestamp + VOTING_PERIOD);
        vm.expectEmit(true, false, false, true, address(oracle));
        emit RoundFinalized(id, ReputationOracle.RoundStatus.NoConsensus, INVALID, 0);
        ReputationOracle.RoundStatus st = oracle.finalize(id);
        assertEq(uint8(st), uint8(ReputationOracle.RoundStatus.NoConsensus));
        assertEq(uint8(pm.phase(id)), uint8(PredictionMarket.Phase.Invalid));
    }

    function test_tie_extends_thenTieAgainIsInvalidWithoutReputationChange() public {
        _warpToResolution(id);
        _vote(eve, id, 0);
        _vote(frank, id, 1); // 100 vs 100, quorum 200 reached but tied
        vm.warp(block.timestamp + VOTING_PERIOD);
        uint64 extendedEnd = oracle.getRound(id).votingEnd + VOTING_PERIOD;
        vm.expectEmit(true, false, false, true, address(oracle));
        emit VotingExtended(id, extendedEnd, true);
        oracle.finalize(id);
        _vote(grace, id, 0);
        _vote(heidi, id, 1); // still tied 200 vs 200
        vm.warp(block.timestamp + VOTING_PERIOD);
        oracle.finalize(id);
        assertEq(uint8(pm.phase(id)), uint8(PredictionMarket.Phase.Invalid));
        assertEq(_rep(eve), 100);
        assertEq(_rep(heidi), 100);
        assertEq(uint8(oracle.getRound(id).status), uint8(ReputationOracle.RoundStatus.NoConsensus));
    }

    function test_heavierOutcomeAfterEarlierTie_wins() public {
        uint256 m3 = _voteMarket(3);
        _warpToResolution(m3);
        _vote(eve, m3, 0); // 100
        _vote(frank, m3, 1); // 100 -> outcomes 0 and 1 tie ...
        _vote(grace, m3, 2);
        _vote(heidi, m3, 2); // ... but outcome 2 is heavier (200)
        vm.warp(block.timestamp + VOTING_PERIOD);
        assertEq(uint8(oracle.finalize(m3)), uint8(ReputationOracle.RoundStatus.Resolved));
        assertEq(pm.getMarket(m3).outcome, 2);
    }

    function test_tieBrokenDuringExtension() public {
        _warpToResolution(id);
        _vote(eve, id, 0);
        _vote(frank, id, 1);
        vm.warp(block.timestamp + VOTING_PERIOD);
        oracle.finalize(id);
        _vote(grace, id, 1);
        vm.warp(block.timestamp + VOTING_PERIOD);
        oracle.finalize(id);
        assertEq(pm.getMarket(id).outcome, 1);
        assertEq(_rep(eve), 80);
        assertEq(_rep(frank), 110);
    }

    function test_quorumUsesSnapshotAtFirstVote() public {
        _warpToResolution(id);
        _vote(eve, id, 0); // snapshot = 400 -> need 200
        vm.startPrank(admin);
        for (uint256 i; i < 10; ++i) {
            oracle.registerReporter(address(uint160(0x5000 + i))); // total becomes 1400
        }
        vm.stopPrank();
        _vote(frank, id, 0);
        ReputationOracle.RoundView memory r = oracle.getRound(id);
        assertEq(r.snapshotTotalReputation, 400);
        assertEq(r.requiredWeight, 200);
        vm.warp(r.votingEnd);
        oracle.finalize(id);
        assertEq(uint8(oracle.getRound(id).status), uint8(ReputationOracle.RoundStatus.Resolved));
    }

    // ------------------------------------------------------------------ liveness / void

    function test_void_whenMarketTimedOutElsewhere() public {
        _warpToResolution(id);
        _vote(eve, id, 0);
        _vote(frank, id, 0);
        vm.warp(pm.getMarket(id).resolutionTime + pm.ARBITRATION_TIMEOUT());
        pm.resolveAfterTimeout(id);
        ReputationOracle.RoundStatus st = oracle.finalize(id);
        assertEq(uint8(st), uint8(ReputationOracle.RoundStatus.Voided));
        assertEq(_rep(eve), 100);
    }

    function test_void_finalizeAfterDeadlineResolvesMarketInvalid() public {
        _warpToResolution(id);
        _vote(eve, id, 0);
        _vote(frank, id, 0);
        vm.warp(pm.getMarket(id).resolutionTime + pm.ARBITRATION_TIMEOUT());
        oracle.finalize(id);
        assertEq(uint8(pm.phase(id)), uint8(PredictionMarket.Phase.Invalid));
        assertEq(uint8(oracle.getRound(id).status), uint8(ReputationOracle.RoundStatus.Voided));
    }

    function test_revert_finalize_badMarkets() public {
        vm.expectRevert(abi.encodeWithSelector(ReputationOracle.MarketNotFound.selector, 99));
        oracle.finalize(99);
        uint256 davesMarket = _createBinaryUsdt();
        vm.expectRevert(abi.encodeWithSelector(ReputationOracle.NotOracleMarket.selector, davesMarket));
        oracle.finalize(davesMarket);
        vm.expectRevert(abi.encodeWithSelector(ReputationOracle.MarketNotFound.selector, 99));
        oracle.getRound(99);
    }

    // ------------------------------------------------------------------ reputation dynamics

    function test_reputationCappedAtMax() public {
        for (uint256 k; k < 95; ++k) {
            uint256 m = _voteMarket(2);
            _warpToResolution(m);
            _vote(eve, m, 0);
            _vote(frank, m, 0);
            _vote(grace, m, 0);
            vm.warp(block.timestamp + VOTING_PERIOD);
            oracle.finalize(m);
        }
        assertEq(_rep(eve), oracle.MAX_REPUTATION());
    }

    function test_persistentlyWrongReporterReachesZeroAndCannotVote() public {
        uint256 k;
        while (_rep(heidi) > 0) {
            uint256 m = _voteMarket(2);
            _warpToResolution(m);
            _vote(eve, m, 0);
            _vote(frank, m, 0);
            _vote(heidi, m, 1);
            vm.warp(block.timestamp + VOTING_PERIOD);
            oracle.finalize(m);
            ++k;
        }
        assertLt(k, 30);
        uint256 m2 = _voteMarket(2);
        _warpToResolution(m2);
        vm.expectRevert(abi.encodeWithSelector(ReputationOracle.NoReputation.selector, heidi));
        _vote(heidi, m2, 0);
    }

    function test_getVotesAndGetVote() public {
        _warpToResolution(id);
        _vote(eve, id, 0);
        _vote(grace, id, INVALID);
        (address[] memory voters, uint8[] memory outcomes, uint256[] memory weights) = oracle.getVotes(id);
        assertEq(voters.length, 2);
        assertEq(voters[1], grace);
        assertEq(outcomes[1], INVALID);
        assertEq(weights[0], 100);
        ReputationOracle.Vote memory v = oracle.getVote(id, grace);
        assertTrue(v.voted);
        assertEq(v.outcome, INVALID);
        assertFalse(oracle.getVote(id, heidi).voted);
    }
}
