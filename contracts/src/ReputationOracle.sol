// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IPredictionMarket} from "./interfaces/IPredictionMarket.sol";

/// @title ReputationOracle
/// @notice Bonus 3 -- reputation-weighted voting as an alternative resolution mode. A market opts in by naming
///         this contract as its arbitrator. Once the market's resolution time is reached, registered reporters vote
///         on the outcome (or INVALID) during a fixed voting window; each vote is weighted by the reporter's
///         reputation at the moment of voting. After the window anyone can call {finalize}:
///           * quorum reached and a unique heaviest outcome -> that outcome is reported to the market;
///             reporters who voted with the consensus gain REWARD reputation, the others lose SLASH_BPS of theirs;
///           * no quorum or a tie -> the window is extended once, by `votingPeriod` counted from the moment the
///             extension is triggered (capped just before the market's arbitration deadline); if it is still unresolved
///             the market is reported INVALID (pro-rata refund) and no reputation changes;
///           * the market's arbitration deadline passed / market already resolved -> the round is voided.
/// @dev Reporter registration is permissioned (owner) and capped at MAX_REPORTERS addresses, which bounds the
///      loop in {finalize}. Reputation is non-transferable and capped at MAX_REPUTATION.
contract ReputationOracle is Ownable2Step, ReentrancyGuardTransient {
    uint256 public constant INITIAL_REPUTATION = 100;
    uint256 public constant MAX_REPUTATION = 1000;
    uint256 public constant REWARD = 10;
    uint256 public constant SLASH_BPS = 2000; // 20 % of current reputation (rounded up)
    uint256 public constant BPS = 10_000;
    uint256 public constant MAX_REPORTERS = 50;

    enum RoundStatus {
        Pending, // accepting votes / awaiting finalize
        Resolved, // consensus outcome reported to the market
        NoConsensus, // no quorum or tie after the extension -> reported INVALID
        Voided // arbitration deadline passed or market resolved elsewhere
    }

    struct Reporter {
        bool registered;
        bool listed;
        uint64 votesCast; // votes in rounds that reached consensus
        uint64 correctVotes;
        uint256 reputation;
    }

    struct Vote {
        bool voted;
        uint8 outcome;
        uint256 weight;
    }

    struct Round {
        bool extended;
        RoundStatus status;
        uint8 result;
        uint64 extendedEnd; // end of the (single) extension, 0 until extended
        uint256 snapshotTotalReputation; // total reputation when the first vote was cast
        uint256 totalWeight;
        address[] voters;
        mapping(uint8 outcome => uint256) tally;
        mapping(address reporter => Vote) votes;
    }

    /// @notice Round snapshot for front-ends. `tally` has numOutcomes + 1 entries; the last one is INVALID.
    struct RoundView {
        uint64 votingStart;
        uint64 votingEnd;
        bool extended;
        RoundStatus status;
        uint8 result;
        uint256 snapshotTotalReputation;
        uint256 totalWeight;
        uint256 requiredWeight;
        uint256 voterCount;
        uint256[] tally;
    }

    /// @notice The prediction market this oracle reports to.
    IPredictionMarket public immutable market;
    /// @notice Length of the voting window (and of the single extension).
    uint64 public immutable votingPeriod;
    /// @notice Share of total reputation (bps) that must vote for a result to be accepted.
    uint16 public immutable quorumBps;

    mapping(address reporter => Reporter) public reporters;
    address[] internal _reporterList;
    /// @notice Sum of the reputation of currently registered reporters.
    uint256 public totalReputation;
    /// @notice Number of currently registered reporters.
    uint256 public activeReporters;
    mapping(uint256 marketId => Round) internal _rounds;

    event ReporterRegistered(address indexed reporter, uint256 reputation);
    event ReporterRemoved(address indexed reporter);
    event VoteCast(uint256 indexed marketId, address indexed reporter, uint8 outcome, uint256 weight);
    event VotingExtended(uint256 indexed marketId, uint64 newVotingEnd, bool quorumReached);
    event RoundFinalized(uint256 indexed marketId, RoundStatus status, uint8 outcome, uint256 totalWeight);
    event ReputationUpdated(address indexed reporter, uint256 oldReputation, uint256 newReputation, bool correct);

    error InvalidParameters();
    error AlreadyRegistered(address reporter);
    error NotRegistered(address reporter);
    error TooManyReporters();
    error NoReputation(address reporter);
    error MarketNotFound(uint256 marketId);
    error NotOracleMarket(uint256 marketId);
    error MarketAlreadyResolved(uint256 marketId);
    error RoundAlreadyFinalized(uint256 marketId);
    error VotingNotStarted(uint64 votingStart);
    error VotingClosed(uint64 votingEnd);
    error VotingStillOpen(uint64 votingEnd);
    error InvalidOutcome(uint8 outcome);
    error AlreadyVoted(address reporter);

    /// @param market_ Prediction market to report to.
    /// @param votingPeriod_ Voting window length; 2 * votingPeriod_ must fit inside the market's arbitration window.
    /// @param quorumBps_ Quorum as a share of total reputation, in bps (1..10_000).
    /// @param owner_ Admin that manages the reporter registry.
    constructor(IPredictionMarket market_, uint64 votingPeriod_, uint16 quorumBps_, address owner_) Ownable(owner_) {
        if (
            address(market_) == address(0) || votingPeriod_ == 0
                || 2 * uint256(votingPeriod_) >= market_.ARBITRATION_TIMEOUT() || quorumBps_ == 0 || quorumBps_ > BPS
        ) revert InvalidParameters();
        market = market_;
        votingPeriod = votingPeriod_;
        quorumBps = quorumBps_;
    }

    // ------------------------------------------------------------------------------------------------
    // Registry (owner)
    // ------------------------------------------------------------------------------------------------

    /// @notice Registers `reporter`. First-time reporters start with INITIAL_REPUTATION; re-registered reporters
    ///         keep the reputation they had (history cannot be reset).
    function registerReporter(address reporter) external onlyOwner {
        if (reporter == address(0)) revert InvalidParameters();
        Reporter storage r = reporters[reporter];
        if (r.registered) revert AlreadyRegistered(reporter);
        if (!r.listed) {
            if (_reporterList.length >= MAX_REPORTERS) revert TooManyReporters();
            r.listed = true;
            r.reputation = INITIAL_REPUTATION;
            _reporterList.push(reporter);
        }
        r.registered = true;
        activeReporters += 1;
        totalReputation += r.reputation;
        emit ReporterRegistered(reporter, r.reputation);
    }

    /// @notice De-registers `reporter`. Votes already cast still count; their reputation is frozen.
    function removeReporter(address reporter) external onlyOwner {
        Reporter storage r = reporters[reporter];
        if (!r.registered) revert NotRegistered(reporter);
        r.registered = false;
        activeReporters -= 1;
        totalReputation -= r.reputation;
        emit ReporterRemoved(reporter);
    }

    // ------------------------------------------------------------------------------------------------
    // Voting
    // ------------------------------------------------------------------------------------------------

    /// @notice Casts a reputation-weighted vote on the outcome of `marketId`.
    /// @param marketId Market that names this oracle as arbitrator.
    /// @param outcome Outcome index, or the market's INVALID_OUTCOME (255) for "invalid / cancelled".
    function vote(uint256 marketId, uint8 outcome) external nonReentrant {
        Reporter storage r = reporters[msg.sender];
        if (!r.registered) revert NotRegistered(msg.sender);
        if (r.reputation == 0) revert NoReputation(msg.sender);

        IPredictionMarket.MarketCore memory core = _oracleMarket(marketId);
        Round storage rd = _rounds[marketId];
        if (rd.status != RoundStatus.Pending) revert RoundAlreadyFinalized(marketId);
        if (core.resolved) revert MarketAlreadyResolved(marketId); // resolved via timeout, round not finalized
        if (block.timestamp < core.resolutionTime) revert VotingNotStarted(core.resolutionTime);
        uint64 end = _votingEnd(core.resolutionTime, rd);
        if (block.timestamp >= end) revert VotingClosed(end);
        if (outcome >= core.numOutcomes && outcome != market.INVALID_OUTCOME()) revert InvalidOutcome(outcome);
        if (rd.votes[msg.sender].voted) revert AlreadyVoted(msg.sender);

        if (rd.voters.length == 0) rd.snapshotTotalReputation = totalReputation;
        uint256 weight = r.reputation;
        rd.votes[msg.sender] = Vote({voted: true, outcome: outcome, weight: weight});
        rd.voters.push(msg.sender);
        rd.tally[outcome] += weight;
        rd.totalWeight += weight;
        emit VoteCast(marketId, msg.sender, outcome, weight);
    }

    /// @notice Closes the voting round of `marketId` (permissionless, after the voting window).
    /// @dev May extend the round once (no quorum / tie), report the consensus outcome, report INVALID, or void.
    /// @return status Round status after the call (Pending if the round was extended).
    function finalize(uint256 marketId) external nonReentrant returns (RoundStatus status) {
        IPredictionMarket.MarketCore memory core = _oracleMarket(marketId);
        Round storage rd = _rounds[marketId];
        if (rd.status != RoundStatus.Pending) revert RoundAlreadyFinalized(marketId);
        uint64 end = _votingEnd(core.resolutionTime, rd);
        if (block.timestamp < end) revert VotingStillOpen(end);

        uint8 invalid = market.INVALID_OUTCOME();
        uint256 deadline = uint256(core.resolutionTime) + market.ARBITRATION_TIMEOUT();

        // Liveness fallback: the market can no longer accept our report.
        if (core.resolved || block.timestamp >= deadline) {
            rd.status = RoundStatus.Voided;
            rd.result = invalid;
            emit RoundFinalized(marketId, RoundStatus.Voided, invalid, rd.totalWeight);
            if (!core.resolved) market.resolveAfterTimeout(marketId);
            return RoundStatus.Voided;
        }

        (bool quorum, bool tie, uint8 winner) = _tallyResult(rd, core.numOutcomes, invalid);
        if (!quorum || tie) {
            if (!rd.extended) {
                // A full extra period from now (even if finalize is called late), but the result must still reach
                // the market before its arbitration deadline.
                uint256 newEnd = block.timestamp + votingPeriod;
                if (newEnd >= deadline) newEnd = deadline - 1;
                rd.extended = true;
                // forge-lint: disable-next-line(unsafe-typecast)
                rd.extendedEnd = uint64(newEnd); // newEnd < deadline, which is derived from a uint64 timestamp
                emit VotingExtended(marketId, rd.extendedEnd, quorum);
                return RoundStatus.Pending;
            }
            rd.status = RoundStatus.NoConsensus;
            rd.result = invalid;
            emit RoundFinalized(marketId, RoundStatus.NoConsensus, invalid, rd.totalWeight);
            market.reportOutcome(marketId, invalid);
            return RoundStatus.NoConsensus;
        }

        rd.status = RoundStatus.Resolved;
        rd.result = winner;
        _updateReputations(rd, winner);
        emit RoundFinalized(marketId, RoundStatus.Resolved, winner, rd.totalWeight);
        market.reportOutcome(marketId, winner);
        return RoundStatus.Resolved;
    }

    // ------------------------------------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------------------------------------

    /// @notice Snapshot of the voting round of `marketId`.
    function getRound(uint256 marketId) external view returns (RoundView memory v) {
        IPredictionMarket.MarketCore memory core = market.getMarketCore(marketId);
        if (core.numOutcomes == 0) revert MarketNotFound(marketId);
        Round storage rd = _rounds[marketId];
        v.votingStart = core.resolutionTime;
        v.votingEnd = _votingEnd(core.resolutionTime, rd);
        v.extended = rd.extended;
        v.status = rd.status;
        v.result = rd.result;
        v.snapshotTotalReputation = rd.voters.length == 0 ? totalReputation : rd.snapshotTotalReputation;
        v.totalWeight = rd.totalWeight;
        v.requiredWeight = _requiredWeight(v.snapshotTotalReputation);
        v.voterCount = rd.voters.length;
        v.tally = new uint256[](uint256(core.numOutcomes) + 1);
        for (uint256 i; i < core.numOutcomes; ++i) {
            // casting to 'uint8' is safe because i < numOutcomes <= MAX_OUTCOMES (8)
            // forge-lint: disable-next-line(unsafe-typecast)
            v.tally[i] = rd.tally[uint8(i)];
        }
        v.tally[core.numOutcomes] = rd.tally[market.INVALID_OUTCOME()];
    }

    /// @notice All votes cast on `marketId`.
    function getVotes(uint256 marketId)
        external
        view
        returns (address[] memory voters, uint8[] memory outcomes, uint256[] memory weights)
    {
        Round storage rd = _rounds[marketId];
        uint256 len = rd.voters.length;
        voters = new address[](len);
        outcomes = new uint8[](len);
        weights = new uint256[](len);
        for (uint256 i; i < len; ++i) {
            address a = rd.voters[i];
            voters[i] = a;
            outcomes[i] = rd.votes[a].outcome;
            weights[i] = rd.votes[a].weight;
        }
    }

    /// @notice The vote of `reporter` on `marketId`.
    function getVote(uint256 marketId, address reporter) external view returns (Vote memory) {
        return _rounds[marketId].votes[reporter];
    }

    /// @notice Every address ever registered, with its current record.
    function getReporters() external view returns (address[] memory addrs, Reporter[] memory infos) {
        uint256 len = _reporterList.length;
        addrs = new address[](len);
        infos = new Reporter[](len);
        for (uint256 i; i < len; ++i) {
            addrs[i] = _reporterList[i];
            infos[i] = reporters[_reporterList[i]];
        }
    }

    // ------------------------------------------------------------------------------------------------
    // Internal
    // ------------------------------------------------------------------------------------------------

    function _oracleMarket(uint256 marketId) internal view returns (IPredictionMarket.MarketCore memory core) {
        core = market.getMarketCore(marketId);
        if (core.numOutcomes == 0) revert MarketNotFound(marketId);
        if (core.arbitrator != address(this)) revert NotOracleMarket(marketId);
    }

    function _votingEnd(uint64 resolutionTime, Round storage rd) internal view returns (uint64) {
        return rd.extended ? rd.extendedEnd : resolutionTime + votingPeriod;
    }

    function _requiredWeight(uint256 snapshotTotal) internal view returns (uint256) {
        return Math.mulDiv(snapshotTotal, quorumBps, BPS, Math.Rounding.Ceil);
    }

    /// @dev Scans the N outcome buckets plus the INVALID bucket (<= 9 iterations).
    function _tallyResult(Round storage rd, uint8 numOutcomes, uint8 invalid)
        internal
        view
        returns (bool quorum, bool tie, uint8 winner)
    {
        quorum = rd.totalWeight != 0 && rd.totalWeight >= _requiredWeight(rd.snapshotTotalReputation);
        uint256 best;
        for (uint256 i; i <= numOutcomes; ++i) {
            // casting to 'uint8' is safe because i < numOutcomes <= MAX_OUTCOMES (8)
            // forge-lint: disable-next-line(unsafe-typecast)
            uint8 o = i == numOutcomes ? invalid : uint8(i);
            uint256 w = rd.tally[o];
            if (w > best) {
                best = w;
                winner = o;
                tie = false;
            } else if (w == best && w != 0) {
                tie = true;
            }
        }
    }

    /// @dev Loops over the round's voters, bounded by MAX_REPORTERS.
    function _updateReputations(Round storage rd, uint8 winner) internal {
        uint256 len = rd.voters.length;
        for (uint256 i; i < len; ++i) {
            address a = rd.voters[i];
            Reporter storage r = reporters[a];
            if (!r.registered) continue; // removed reporters are frozen
            uint256 oldRep = r.reputation;
            bool correct = rd.votes[a].outcome == winner;
            uint256 newRep;
            if (correct) {
                newRep = Math.min(oldRep + REWARD, MAX_REPUTATION);
                r.correctVotes += 1;
            } else {
                // rounded up so that persistently wrong reporters eventually reach zero weight
                newRep = oldRep - Math.mulDiv(oldRep, SLASH_BPS, BPS, Math.Rounding.Ceil);
            }
            r.votesCast += 1;
            r.reputation = newRep;
            totalReputation = totalReputation - oldRep + newRep;
            emit ReputationUpdated(a, oldRep, newRep, correct);
        }
    }
}
