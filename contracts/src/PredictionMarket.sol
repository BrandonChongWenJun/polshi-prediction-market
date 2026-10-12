// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {ERC1155Supply} from "@openzeppelin/contracts/token/ERC1155/extensions/ERC1155Supply.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {IPredictionMarket} from "./interfaces/IPredictionMarket.sol";
import {FpmmMath} from "./libraries/FpmmMath.sol";

/// @title PredictionMarket
/// @author SC4053 Option 4
/// @notice Singleton prediction-market engine. Each market has N (2..8) mutually exclusive outcomes,
///         an ERC20 collateral token (USDT/DAI/WETH, allow-listed by the owner), a trading close time,
///         a resolution time and an arbitrator (an EOA, multisig, or the {ReputationOracle}).
///
///         * Complete sets: 1 collateral <-> 1 token of *every* outcome (split / merge). Every outcome token in
///           existence -- held by users or virtually by the AMM pool -- is backed by exactly one unit of
///           collateral, so the contract is solvent by construction: `collateralLocked == supply_i + pool_i`
///           for every outcome i until resolution.
///         * Pricing: Gnosis-style Fixed Product Market Maker (FPMM). Prices p_i = (1/b_i)/sum(1/b_k) are the
///           market's implied probabilities and always sum to 1.
///         * Liquidity providers earn a trading fee (<= 5%), paid in collateral through a fee accumulator.
///         * Resolution: after `resolutionTime` only the arbitrator can report the winning outcome or
///           INVALID. If it does not report within ARBITRATION_TIMEOUT anyone can resolve the market as INVALID.
///           Winners redeem 1 collateral per winning share; INVALID pays 1/N per share of any outcome.
/// @dev Outcome tokens are ERC1155 ids `(marketId << 8) | outcomeIndex` with the same decimals as the market's
///      collateral. AMM balances are tracked internally (never via balanceOf) so donations cannot skew prices.
///      All value-moving functions are nonReentrant and follow checks-effects-interactions; ERC1155 receiver
///      hooks (mints/transfers) are always the last interaction.
contract PredictionMarket is IPredictionMarket, ERC1155Supply, Ownable2Step, Pausable, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    // ------------------------------------------------------------------------------------------------
    // Constants
    // ------------------------------------------------------------------------------------------------

    uint8 public constant MIN_OUTCOMES = 2;
    uint8 public constant MAX_OUTCOMES = 8;
    /// @inheritdoc IPredictionMarket
    uint8 public constant override INVALID_OUTCOME = type(uint8).max;
    uint256 public constant BPS = 10_000;
    uint16 public constant MAX_FEE_BPS = 500; // 5 %
    /// @notice Minimum initial probability per outcome when custom initial odds are supplied (1 %).
    uint256 public constant MIN_ODDS_BPS = 100;
    /// @inheritdoc IPredictionMarket
    uint256 public constant override ARBITRATION_TIMEOUT = 7 days;
    uint256 public constant MAX_DURATION = 5 * 365 days;
    uint256 public constant MAX_QUESTION_LENGTH = 280;
    uint256 public constant MAX_CATEGORY_LENGTH = 32;
    uint256 public constant MAX_LABEL_LENGTH = 48;
    /// @dev Precision of the per-LP-share fee accumulator.
    uint256 internal constant ACC_PRECISION = 1e36;

    // ------------------------------------------------------------------------------------------------
    // Types
    // ------------------------------------------------------------------------------------------------

    /// @notice Lifecycle phase of a market (derived from time + resolution state).
    enum Phase {
        Trading, // now < closeTime: AMM trading and liquidity changes allowed
        Closed, // closeTime <= now < resolutionTime: waiting for the event
        Reporting, // resolutionTime <= now < resolutionTime + ARBITRATION_TIMEOUT: arbitrator may report
        ReportingTimedOut, // arbitrator missed the window: anyone may resolve as INVALID
        Resolved, // a winning outcome was reported
        Invalid // resolved as invalid / cancelled
    }

    struct CollateralConfig {
        bool allowed;
        bool listed;
        uint256 minLiquidity; // minimum initial liquidity, in the token's base units
    }

    struct Market {
        IERC20 collateral;
        uint64 closeTime;
        uint8 numOutcomes;
        bool resolved;
        uint8 outcome; // winning outcome or INVALID_OUTCOME (meaningful only once resolved)
        address arbitrator;
        uint64 resolutionTime;
        uint16 feeBps;
        address creator;
        uint64 createdAt;
        uint64 resolvedAt;
        uint256 collateralLocked; // complete sets outstanding (backing of every outcome token)
        uint256 totalLpShares;
        uint256 accFeePerShare; // cumulative fees per LP share, scaled by ACC_PRECISION
        uint256 feePool; // fees collected and not yet paid out to LPs
        uint256 volume; // cumulative AMM volume in collateral (UI statistic)
        uint256[] pool; // AMM outcome-token balances (virtual, not ERC1155 balances)
        string question;
        string category;
        string[] outcomeLabels;
    }

    struct CreateMarketParams {
        string question;
        string category;
        string[] outcomeLabels;
        uint64 closeTime;
        uint64 resolutionTime;
        address arbitrator;
        IERC20 collateral;
        uint256 initialLiquidity;
        /// @dev Optional initial probabilities in bps (sum 10_000, each >= 1 %). Empty = uniform odds.
        uint16[] initialOddsBps;
        uint16 feeBps;
    }

    /// @notice Full market snapshot for front-ends.
    struct MarketView {
        uint256 id;
        address creator;
        address arbitrator;
        address collateral;
        uint64 createdAt;
        uint64 closeTime;
        uint64 resolutionTime;
        uint64 resolvedAt;
        uint16 feeBps;
        uint8 numOutcomes;
        bool resolved;
        uint8 outcome;
        Phase phase;
        uint256 collateralLocked;
        uint256 totalLpShares;
        uint256 feePool;
        uint256 volume;
        uint256[] pool;
        uint256[] prices;
        uint256[] outcomeSupply;
        string question;
        string category;
        string[] outcomeLabels;
    }

    /// @notice An account's position in a market, for front-ends.
    struct UserPosition {
        uint256[] balances;
        uint256 lpShares;
        uint256 pendingFees;
        uint256 redeemable;
    }

    // ------------------------------------------------------------------------------------------------
    // Storage
    // ------------------------------------------------------------------------------------------------

    /// @notice Number of markets created; market ids are 1..marketCount.
    uint256 public marketCount;
    mapping(uint256 marketId => Market) internal _markets;
    /// @notice Collateral allow-list and per-token minimum initial liquidity.
    mapping(IERC20 token => CollateralConfig) public collateralConfig;
    IERC20[] internal _collateralList;

    /// @notice Liquidity-provider shares per market (non-transferable).
    mapping(uint256 marketId => mapping(address provider => uint256)) public lpShares;
    mapping(uint256 marketId => mapping(address provider => uint256)) internal _feeCheckpoint;
    mapping(uint256 marketId => mapping(address provider => uint256)) internal _feeCredit; // scaled by ACC_PRECISION

    // ------------------------------------------------------------------------------------------------
    // Events
    // ------------------------------------------------------------------------------------------------

    event CollateralConfigured(address indexed token, bool allowed, uint256 minLiquidity);
    event MarketCreated(
        uint256 indexed marketId,
        address indexed creator,
        address indexed arbitrator,
        address collateral,
        uint64 closeTime,
        uint64 resolutionTime,
        uint16 feeBps,
        string question,
        string category,
        string[] outcomeLabels
    );
    event LiquidityAdded(
        uint256 indexed marketId,
        address indexed provider,
        uint256 collateralAmount,
        uint256 sharesMinted,
        uint256[] outcomeTokensReturned
    );
    event LiquidityRemoved(
        uint256 indexed marketId,
        address indexed provider,
        uint256 sharesBurned,
        uint256 collateralReturned,
        uint256[] outcomeTokensReturned
    );
    event FeesClaimed(uint256 indexed marketId, address indexed provider, uint256 amount);
    /// @param collateralAmount buys: collateral paid incl. fee; sells: collateral received after fee.
    event Trade(
        uint256 indexed marketId,
        address indexed trader,
        uint8 indexed outcome,
        bool isBuy,
        uint256 collateralAmount,
        uint256 shares,
        uint256 fee
    );
    /// @notice Emitted whenever AMM balances change; front-ends derive the probability chart from it.
    event PoolUpdated(uint256 indexed marketId, uint256[] balances, uint64 timestamp);
    event PositionSplit(uint256 indexed marketId, address indexed account, uint256 amount);
    event PositionsMerged(uint256 indexed marketId, address indexed account, uint256 amount);
    event MarketResolved(uint256 indexed marketId, uint8 outcome, address indexed resolver, bool timedOut);
    event Redeemed(uint256 indexed marketId, address indexed account, uint256 payout);

    // ------------------------------------------------------------------------------------------------
    // Errors
    // ------------------------------------------------------------------------------------------------

    error CollateralNotAllowed(address token);
    error InvalidCollateral();
    error InvalidOutcomeCount(uint256 count);
    error InvalidTimes();
    error InvalidArbitrator();
    error FeeTooHigh(uint256 feeBps, uint256 maxFeeBps);
    error LiquidityTooLow(uint256 provided, uint256 minimum);
    error InvalidText();
    error InvalidOdds();
    error MarketNotFound(uint256 marketId);
    error TradingClosed(uint256 marketId, uint64 closeTime);
    error MarketAlreadyResolved(uint256 marketId);
    error MarketNotResolved(uint256 marketId);
    error InvalidOutcome(uint8 outcome);
    error ZeroAmount();
    error SlippageExceeded(uint256 actual, uint256 limit);
    error NoLiquidity(uint256 marketId);
    error InsufficientLpShares(uint256 requested, uint256 available);
    error NotArbitrator(address caller, address arbitrator);
    error ResolutionTooEarly(uint64 resolutionTime);
    error ReportingWindowClosed(uint256 deadline);
    error ReportingWindowOpen(uint256 deadline);
    error NothingToRedeem();
    error NothingToClaim();
    error FeeOnTransferNotSupported(uint256 expected, uint256 received);

    // ------------------------------------------------------------------------------------------------
    // Constructor / admin
    // ------------------------------------------------------------------------------------------------

    /// @param initialOwner Admin allowed to manage the collateral allow-list and pause new risk.
    constructor(address initialOwner) ERC1155("") Ownable(initialOwner) {}

    /// @notice Allow or disallow `token` as collateral for *new* markets. Existing markets are unaffected.
    /// @param token ERC20 collateral (must not be fee-on-transfer or rebasing).
    /// @param allowed Whether new markets may use it.
    /// @param minLiquidity Minimum initial liquidity in base units (guards against dust pools).
    function setCollateral(IERC20 token, bool allowed, uint256 minLiquidity) external onlyOwner {
        if (address(token) == address(0)) revert InvalidCollateral();
        CollateralConfig storage cfg = collateralConfig[token];
        if (!cfg.listed) {
            cfg.listed = true;
            _collateralList.push(token);
        }
        cfg.allowed = allowed;
        cfg.minLiquidity = minLiquidity;
        emit CollateralConfigured(address(token), allowed, minLiquidity);
    }

    /// @notice Emergency brake: blocks market creation, trading, splitting and adding liquidity.
    /// @dev Never blocks exits: merge, remove liquidity, claim fees, reporting and redemption stay available.
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Lifts the emergency brake.
    function unpause() external onlyOwner {
        _unpause();
    }

    // ------------------------------------------------------------------------------------------------
    // Market creation
    // ------------------------------------------------------------------------------------------------

    /// @notice Opens a new prediction market and seeds its AMM with `initialLiquidity` collateral.
    /// @dev The creator becomes the first LP (shares = initialLiquidity). With non-uniform initial odds the pool
    ///      keeps fewer tokens of the likelier outcomes and the creator receives the difference as outcome tokens.
    /// @param p Market parameters (see {CreateMarketParams}).
    /// @return marketId The id of the new market.
    function createMarket(CreateMarketParams calldata p)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 marketId)
    {
        uint256 n = p.outcomeLabels.length;
        uint256[] memory pool = _validateCreate(p, n);

        marketId = ++marketCount;
        _storeMarket(_markets[marketId], p, n, pool);
        lpShares[marketId][msg.sender] = p.initialLiquidity;

        uint256[] memory returned = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            returned[i] = p.initialLiquidity - pool[i];
        }

        _emitMarketCreated(marketId, p);
        emit LiquidityAdded(marketId, msg.sender, p.initialLiquidity, p.initialLiquidity, returned);
        emit PoolUpdated(marketId, pool, uint64(block.timestamp));

        _pullCollateral(p.collateral, msg.sender, p.initialLiquidity);
        _mintOutcomeTokens(msg.sender, marketId, returned);
    }

    // ------------------------------------------------------------------------------------------------
    // Complete sets
    // ------------------------------------------------------------------------------------------------

    /// @notice Deposits `amount` collateral and mints `amount` of every outcome token (a complete set).
    /// @param marketId Market id.
    /// @param amount Collateral amount in base units.
    function splitPosition(uint256 marketId, uint256 amount) external nonReentrant whenNotPaused {
        Market storage m = _market(marketId);
        if (m.resolved) revert MarketAlreadyResolved(marketId);
        if (amount == 0) revert ZeroAmount();

        m.collateralLocked += amount;
        emit PositionSplit(marketId, msg.sender, amount);

        _pullCollateral(m.collateral, msg.sender, amount);
        _mintBatch(msg.sender, _ids(marketId, m.numOutcomes), _filled(m.numOutcomes, amount), "");
    }

    /// @notice Burns `amount` of every outcome token and returns `amount` collateral. Always available
    ///         (a complete set is worth exactly 1 collateral before and after resolution).
    /// @param marketId Market id.
    /// @param amount Number of complete sets to merge.
    function mergePositions(uint256 marketId, uint256 amount) external nonReentrant {
        Market storage m = _market(marketId);
        if (amount == 0) revert ZeroAmount();

        _burnBatch(msg.sender, _ids(marketId, m.numOutcomes), _filled(m.numOutcomes, amount));
        m.collateralLocked -= amount;
        emit PositionsMerged(marketId, msg.sender, amount);

        m.collateral.safeTransfer(msg.sender, amount);
    }

    // ------------------------------------------------------------------------------------------------
    // Trading (AMM)
    // ------------------------------------------------------------------------------------------------

    /// @notice Buys outcome shares with an exact amount of collateral.
    /// @param marketId Market id.
    /// @param outcome Outcome index to buy.
    /// @param investmentAmount Collateral paid, including the LP fee.
    /// @param minSharesOut Slippage protection: minimum outcome tokens to receive.
    /// @return sharesOut Outcome tokens received.
    function buy(uint256 marketId, uint8 outcome, uint256 investmentAmount, uint256 minSharesOut)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 sharesOut)
    {
        Market storage m = _tradableMarket(marketId, outcome);
        if (investmentAmount == 0) revert ZeroAmount();

        uint256 fee = _feeOn(investmentAmount, m.feeBps);
        uint256 net = investmentAmount - fee;
        sharesOut = FpmmMath.calcBuyAmount(m.pool, outcome, net);
        if (sharesOut == 0) revert ZeroAmount();
        if (sharesOut < minSharesOut) revert SlippageExceeded(sharesOut, minSharesOut);

        uint256 n = m.numOutcomes;
        for (uint256 i; i < n; ++i) {
            m.pool[i] += net;
        }
        m.pool[outcome] -= sharesOut;
        m.collateralLocked += net;
        m.volume += investmentAmount;
        _accrueFee(m, fee);

        emit Trade(marketId, msg.sender, outcome, true, investmentAmount, sharesOut, fee);
        emit PoolUpdated(marketId, m.pool, uint64(block.timestamp));

        _pullCollateral(m.collateral, msg.sender, investmentAmount);
        _mint(msg.sender, positionId(marketId, outcome), sharesOut, "");
    }

    /// @notice Sells an exact number of outcome shares back to the AMM.
    /// @param marketId Market id.
    /// @param outcome Outcome index to sell.
    /// @param sharesIn Outcome tokens to sell.
    /// @param minCollateralOut Slippage protection: minimum collateral to receive (after fee).
    /// @return collateralOut Collateral received.
    function sell(uint256 marketId, uint8 outcome, uint256 sharesIn, uint256 minCollateralOut)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 collateralOut)
    {
        Market storage m = _tradableMarket(marketId, outcome);
        if (sharesIn == 0) revert ZeroAmount();

        uint256 gross = FpmmMath.calcSellGross(m.pool, outcome, sharesIn);
        uint256 fee = _feeOn(gross, m.feeBps);
        collateralOut = gross - fee;
        if (collateralOut == 0) revert ZeroAmount();
        if (collateralOut < minCollateralOut) revert SlippageExceeded(collateralOut, minCollateralOut);

        // Seller's tokens go into the pool, then `gross` complete sets are merged out of it.
        _burn(msg.sender, positionId(marketId, outcome), sharesIn);
        m.pool[outcome] += sharesIn;
        uint256 n = m.numOutcomes;
        for (uint256 i; i < n; ++i) {
            m.pool[i] -= gross;
        }
        m.collateralLocked -= gross;
        m.volume += gross;
        _accrueFee(m, fee);

        emit Trade(marketId, msg.sender, outcome, false, collateralOut, sharesIn, fee);
        emit PoolUpdated(marketId, m.pool, uint64(block.timestamp));

        m.collateral.safeTransfer(msg.sender, collateralOut);
    }

    // ------------------------------------------------------------------------------------------------
    // Liquidity
    // ------------------------------------------------------------------------------------------------

    /// @notice Adds liquidity without moving prices. Tokens the pool does not need to keep the current odds are
    ///         returned to the provider as outcome tokens.
    /// @param marketId Market id.
    /// @param amount Collateral to add.
    /// @param minShares Slippage protection: minimum LP shares to mint.
    /// @return shares LP shares minted.
    function addLiquidity(uint256 marketId, uint256 amount, uint256 minShares)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 shares)
    {
        Market storage m = _market(marketId);
        if (block.timestamp >= m.closeTime) revert TradingClosed(marketId, m.closeTime);
        if (amount == 0) revert ZeroAmount();

        uint256 n = m.numOutcomes;
        uint256[] memory returned = new uint256[](n);
        uint256 total = m.totalLpShares;
        if (total == 0) {
            // Pool was fully withdrawn (all balances are zero): re-seed it with uniform odds. The same minimum as
            // for market creation applies so that a re-seeded pool is never a dust pool.
            uint256 minLiq = collateralConfig[m.collateral].minLiquidity;
            if (minLiq == 0) minLiq = 1;
            if (amount < minLiq) revert LiquidityTooLow(amount, minLiq);
            for (uint256 i; i < n; ++i) {
                m.pool[i] = amount;
            }
            shares = amount;
        } else {
            uint256 poolWeight;
            for (uint256 i; i < n; ++i) {
                if (m.pool[i] > poolWeight) poolWeight = m.pool[i];
            }
            // Rounding favours the existing LPs: the pool receives ceil(...) of each outcome and the new
            // provider receives floor(...) LP shares, so an add+remove round trip can never extract value.
            for (uint256 i; i < n; ++i) {
                uint256 added = Math.mulDiv(amount, m.pool[i], poolWeight, Math.Rounding.Ceil);
                m.pool[i] += added;
                returned[i] = amount - added;
            }
            shares = Math.mulDiv(amount, total, poolWeight);
        }
        if (shares == 0) revert ZeroAmount();
        if (shares < minShares) revert SlippageExceeded(shares, minShares);

        _checkpointFees(marketId, m, msg.sender);
        lpShares[marketId][msg.sender] += shares;
        m.totalLpShares = total + shares;
        m.collateralLocked += amount;

        emit LiquidityAdded(marketId, msg.sender, amount, shares, returned);
        emit PoolUpdated(marketId, m.pool, uint64(block.timestamp));

        _pullCollateral(m.collateral, msg.sender, amount);
        _mintOutcomeTokens(msg.sender, marketId, returned);
    }

    /// @notice Burns LP shares and withdraws the proportional slice of the pool plus accrued fees.
    /// @dev Before resolution the balanced part of the slice is merged into collateral and the remainder is
    ///      sent as outcome tokens. After resolution the slice is valued at the payout and paid in collateral.
    ///      Never paused, so LPs can always exit.
    /// @param marketId Market id.
    /// @param shares LP shares to burn.
    /// @param minCollateralOut Slippage protection on the collateral part (excluding fees).
    /// @return collateralOut Collateral returned for the pool slice (excluding fees).
    /// @return tokensOut Outcome tokens returned (all zero after resolution).
    function removeLiquidity(uint256 marketId, uint256 shares, uint256 minCollateralOut)
        external
        nonReentrant
        returns (uint256 collateralOut, uint256[] memory tokensOut)
    {
        Market storage m = _market(marketId);
        uint256 owned = lpShares[marketId][msg.sender];
        if (shares == 0) revert ZeroAmount();
        if (shares > owned) revert InsufficientLpShares(shares, owned);

        _checkpointFees(marketId, m, msg.sender);
        (collateralOut, tokensOut) = _quoteRemove(m, shares);
        if (collateralOut < minCollateralOut) revert SlippageExceeded(collateralOut, minCollateralOut);

        uint256 total = m.totalLpShares;
        uint256 n = m.numOutcomes;
        for (uint256 i; i < n; ++i) {
            m.pool[i] -= Math.mulDiv(m.pool[i], shares, total);
        }
        lpShares[marketId][msg.sender] = owned - shares;
        m.totalLpShares = total - shares;
        m.collateralLocked -= collateralOut;
        uint256 fees = _takeFees(marketId, m, msg.sender);

        emit LiquidityRemoved(marketId, msg.sender, shares, collateralOut, tokensOut);
        if (fees != 0) emit FeesClaimed(marketId, msg.sender, fees);
        emit PoolUpdated(marketId, m.pool, uint64(block.timestamp));

        uint256 payout = collateralOut + fees;
        if (payout != 0) m.collateral.safeTransfer(msg.sender, payout);
        _mintOutcomeTokens(msg.sender, marketId, tokensOut);
    }

    /// @notice Claims the caller's accrued LP trading fees for `marketId`.
    /// @param marketId Market id.
    /// @return amount Collateral paid out.
    function claimFees(uint256 marketId) external nonReentrant returns (uint256 amount) {
        Market storage m = _market(marketId);
        _checkpointFees(marketId, m, msg.sender);
        amount = _takeFees(marketId, m, msg.sender);
        if (amount == 0) revert NothingToClaim();
        emit FeesClaimed(marketId, msg.sender, amount);
        m.collateral.safeTransfer(msg.sender, amount);
    }

    // ------------------------------------------------------------------------------------------------
    // Resolution & payouts
    // ------------------------------------------------------------------------------------------------

    /// @inheritdoc IPredictionMarket
    /// @dev Only the market's arbitrator, only within [resolutionTime, resolutionTime + ARBITRATION_TIMEOUT).
    ///      `outcome` is a valid outcome index or INVALID_OUTCOME (question ambiguous / event cancelled).
    function reportOutcome(uint256 marketId, uint8 outcome) external override nonReentrant {
        Market storage m = _market(marketId);
        if (msg.sender != m.arbitrator) revert NotArbitrator(msg.sender, m.arbitrator);
        if (m.resolved) revert MarketAlreadyResolved(marketId);
        if (block.timestamp < m.resolutionTime) revert ResolutionTooEarly(m.resolutionTime);
        uint256 deadline = uint256(m.resolutionTime) + ARBITRATION_TIMEOUT;
        if (block.timestamp >= deadline) revert ReportingWindowClosed(deadline);
        if (outcome >= m.numOutcomes && outcome != INVALID_OUTCOME) revert InvalidOutcome(outcome);
        _resolve(m, marketId, outcome, false);
    }

    /// @inheritdoc IPredictionMarket
    /// @dev Permissionless liveness guarantee: funds can never be locked by an absent arbitrator.
    function resolveAfterTimeout(uint256 marketId) external override nonReentrant {
        Market storage m = _market(marketId);
        if (m.resolved) revert MarketAlreadyResolved(marketId);
        uint256 deadline = uint256(m.resolutionTime) + ARBITRATION_TIMEOUT;
        if (block.timestamp < deadline) revert ReportingWindowOpen(deadline);
        _resolve(m, marketId, INVALID_OUTCOME, true);
    }

    /// @notice Burns all of the caller's outcome tokens of a resolved market and pays out their value:
    ///         1 collateral per winning share, or 1/N per share of any outcome if the market is INVALID.
    /// @param marketId Market id.
    /// @return payout Collateral paid.
    function redeem(uint256 marketId) external nonReentrant returns (uint256 payout) {
        Market storage m = _market(marketId);
        if (!m.resolved) revert MarketNotResolved(marketId);
        uint256 n = m.numOutcomes;
        uint256[] memory ids = _ids(marketId, n);
        uint256[] memory balances = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            balances[i] = balanceOf(msg.sender, ids[i]);
        }
        payout = _payoutValue(m, balances);
        if (payout == 0) revert NothingToRedeem();

        _burnBatch(msg.sender, ids, balances);
        m.collateralLocked -= payout;
        emit Redeemed(marketId, msg.sender, payout);

        m.collateral.safeTransfer(msg.sender, payout);
    }

    // ------------------------------------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------------------------------------

    /// @inheritdoc IPredictionMarket
    function positionId(uint256 marketId, uint8 outcome) public pure override returns (uint256) {
        return (marketId << 8) | outcome;
    }

    /// @inheritdoc IPredictionMarket
    function getMarketCore(uint256 marketId) external view override returns (MarketCore memory core) {
        Market storage m = _markets[marketId];
        core = MarketCore({
            collateral: address(m.collateral),
            arbitrator: m.arbitrator,
            closeTime: m.closeTime,
            resolutionTime: m.resolutionTime,
            numOutcomes: m.numOutcomes,
            resolved: m.resolved,
            outcome: m.outcome
        });
    }

    /// @notice Full snapshot of a market (parameters, pool, prices, supplies, labels, phase).
    function getMarket(uint256 marketId) external view returns (MarketView memory v) {
        Market storage m = _market(marketId);
        uint256 n = m.numOutcomes;
        v.id = marketId;
        v.creator = m.creator;
        v.arbitrator = m.arbitrator;
        v.collateral = address(m.collateral);
        v.createdAt = m.createdAt;
        v.closeTime = m.closeTime;
        v.resolutionTime = m.resolutionTime;
        v.resolvedAt = m.resolvedAt;
        v.feeBps = m.feeBps;
        v.numOutcomes = m.numOutcomes;
        v.resolved = m.resolved;
        v.outcome = m.outcome;
        v.phase = _phase(m);
        v.collateralLocked = m.collateralLocked;
        v.totalLpShares = m.totalLpShares;
        v.feePool = m.feePool;
        v.volume = m.volume;
        v.pool = m.pool;
        v.prices = _prices(m);
        v.outcomeSupply = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            // casting to 'uint8' is safe because i < numOutcomes <= MAX_OUTCOMES (8)
            // forge-lint: disable-next-line(unsafe-typecast)
            v.outcomeSupply[i] = totalSupply(positionId(marketId, uint8(i)));
        }
        v.question = m.question;
        v.category = m.category;
        v.outcomeLabels = m.outcomeLabels;
    }

    /// @notice Current lifecycle phase of a market.
    function phase(uint256 marketId) external view returns (Phase) {
        return _phase(_market(marketId));
    }

    /// @notice Implied probabilities (1e18 = 100 %). Uniform if the pool is empty.
    function getPrices(uint256 marketId) external view returns (uint256[] memory) {
        return _prices(_market(marketId));
    }

    /// @notice AMM outcome balances.
    function getPool(uint256 marketId) external view returns (uint256[] memory) {
        return _market(marketId).pool;
    }

    /// @notice Quote for {buy}: shares received and fee charged for `investmentAmount` collateral.
    function calcBuyAmount(uint256 marketId, uint8 outcome, uint256 investmentAmount)
        external
        view
        returns (uint256 sharesOut, uint256 fee)
    {
        Market storage m = _market(marketId);
        _checkOutcome(m, outcome);
        if (m.totalLpShares == 0) revert NoLiquidity(marketId);
        fee = _feeOn(investmentAmount, m.feeBps);
        sharesOut = FpmmMath.calcBuyAmount(m.pool, outcome, investmentAmount - fee);
    }

    /// @notice Quote for {sell}: collateral received (after fee) and fee charged for selling `sharesIn`.
    function calcSellReturn(uint256 marketId, uint8 outcome, uint256 sharesIn)
        external
        view
        returns (uint256 collateralOut, uint256 fee)
    {
        Market storage m = _market(marketId);
        _checkOutcome(m, outcome);
        if (m.totalLpShares == 0) revert NoLiquidity(marketId);
        uint256 gross = FpmmMath.calcSellGross(m.pool, outcome, sharesIn);
        fee = _feeOn(gross, m.feeBps);
        collateralOut = gross - fee;
    }

    /// @notice Quote for {removeLiquidity} (excluding fees).
    function calcRemoveLiquidity(uint256 marketId, uint256 shares)
        external
        view
        returns (uint256 collateralOut, uint256[] memory tokensOut)
    {
        Market storage m = _market(marketId);
        if (shares > m.totalLpShares) revert InsufficientLpShares(shares, m.totalLpShares);
        return _quoteRemove(m, shares);
    }

    /// @notice LP fees currently claimable by `provider`.
    function pendingFees(uint256 marketId, address provider) public view returns (uint256) {
        Market storage m = _markets[marketId];
        uint256 credit = _feeCredit[marketId][provider] + lpShares[marketId][provider]
            * (m.accFeePerShare - _feeCheckpoint[marketId][provider]);
        return credit / ACC_PRECISION;
    }

    /// @notice Balances, LP shares, claimable fees and redeemable collateral of `account` in `marketId`.
    function getUserPosition(uint256 marketId, address account) external view returns (UserPosition memory pos) {
        Market storage m = _market(marketId);
        uint256 n = m.numOutcomes;
        pos.balances = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            // casting to 'uint8' is safe because i < numOutcomes <= MAX_OUTCOMES (8)
            // forge-lint: disable-next-line(unsafe-typecast)
            pos.balances[i] = balanceOf(account, positionId(marketId, uint8(i)));
        }
        pos.lpShares = lpShares[marketId][account];
        pos.pendingFees = pendingFees(marketId, account);
        if (m.resolved) pos.redeemable = _payoutValue(m, pos.balances);
    }

    /// @notice All collateral tokens ever configured, with their current configuration.
    function getCollaterals()
        external
        view
        returns (address[] memory tokens, bool[] memory allowed, uint256[] memory minLiquidity)
    {
        uint256 len = _collateralList.length;
        tokens = new address[](len);
        allowed = new bool[](len);
        minLiquidity = new uint256[](len);
        for (uint256 i; i < len; ++i) {
            IERC20 t = _collateralList[i];
            tokens[i] = address(t);
            allowed[i] = collateralConfig[t].allowed;
            minLiquidity[i] = collateralConfig[t].minLiquidity;
        }
    }

    // ------------------------------------------------------------------------------------------------
    // Internal helpers
    // ------------------------------------------------------------------------------------------------

    function _market(uint256 marketId) internal view returns (Market storage m) {
        m = _markets[marketId];
        if (m.numOutcomes == 0) revert MarketNotFound(marketId);
    }

    function _tradableMarket(uint256 marketId, uint8 outcome) internal view returns (Market storage m) {
        m = _market(marketId);
        // resolved markets always have now >= resolutionTime >= closeTime, so they are never tradable
        if (block.timestamp >= m.closeTime) revert TradingClosed(marketId, m.closeTime);
        _checkOutcome(m, outcome);
        if (m.totalLpShares == 0) revert NoLiquidity(marketId);
    }

    function _checkOutcome(Market storage m, uint8 outcome) internal view {
        if (outcome >= m.numOutcomes) revert InvalidOutcome(outcome);
    }

    function _phase(Market storage m) internal view returns (Phase) {
        if (m.resolved) return m.outcome == INVALID_OUTCOME ? Phase.Invalid : Phase.Resolved;
        if (block.timestamp < m.closeTime) return Phase.Trading;
        if (block.timestamp < m.resolutionTime) return Phase.Closed;
        if (block.timestamp < uint256(m.resolutionTime) + ARBITRATION_TIMEOUT) return Phase.Reporting;
        return Phase.ReportingTimedOut;
    }

    function _prices(Market storage m) internal view returns (uint256[] memory p) {
        uint256 n = m.numOutcomes;
        if (m.totalLpShares == 0) {
            p = new uint256[](n);
            for (uint256 i; i < n; ++i) {
                p[i] = FpmmMath.ONE / n;
            }
            return p;
        }
        return FpmmMath.prices(m.pool);
    }

    /// @dev Fee rounds up (in favour of LPs).
    function _feeOn(uint256 amount, uint16 feeBps) internal pure returns (uint256) {
        return Math.mulDiv(amount, feeBps, BPS, Math.Rounding.Ceil);
    }

    function _accrueFee(Market storage m, uint256 fee) internal {
        if (fee == 0) return;
        m.feePool += fee;
        // totalLpShares > 0 is guaranteed for tradable markets
        m.accFeePerShare += Math.mulDiv(fee, ACC_PRECISION, m.totalLpShares);
    }

    /// @dev Credits fees earned since the provider's last checkpoint, at full precision (no per-step rounding),
    ///      so the sum of all payouts can never exceed the fees collected.
    function _checkpointFees(uint256 marketId, Market storage m, address provider) internal {
        uint256 acc = m.accFeePerShare;
        uint256 last = _feeCheckpoint[marketId][provider];
        if (acc != last) {
            uint256 shares = lpShares[marketId][provider];
            if (shares != 0) _feeCredit[marketId][provider] += shares * (acc - last);
            _feeCheckpoint[marketId][provider] = acc;
        }
    }

    function _takeFees(uint256 marketId, Market storage m, address provider) internal returns (uint256 amount) {
        uint256 credit = _feeCredit[marketId][provider];
        amount = credit / ACC_PRECISION;
        if (amount != 0) {
            _feeCredit[marketId][provider] = credit - amount * ACC_PRECISION;
            m.feePool -= amount;
        }
    }

    function _quoteRemove(Market storage m, uint256 shares)
        internal
        view
        returns (uint256 collateralOut, uint256[] memory tokensOut)
    {
        uint256 n = m.numOutcomes;
        uint256 total = m.totalLpShares;
        tokensOut = new uint256[](n);
        uint256 minAmount = type(uint256).max;
        for (uint256 i; i < n; ++i) {
            uint256 a = Math.mulDiv(m.pool[i], shares, total);
            tokensOut[i] = a;
            if (a < minAmount) minAmount = a;
        }
        if (m.resolved) {
            collateralOut = _payoutValue(m, tokensOut);
            tokensOut = new uint256[](n);
        } else {
            collateralOut = minAmount; // merge the balanced part into collateral
            for (uint256 i; i < n; ++i) {
                tokensOut[i] -= minAmount;
            }
        }
    }

    /// @dev Value of an outcome-token vector in a resolved market. INVALID: every share is worth 1/N
    ///      (summed first, then rounded down once).
    function _payoutValue(Market storage m, uint256[] memory balances) internal view returns (uint256) {
        if (m.outcome == INVALID_OUTCOME) {
            uint256 sum;
            uint256 n = balances.length;
            for (uint256 i; i < n; ++i) {
                sum += balances[i];
            }
            return sum / n;
        }
        return balances[m.outcome];
    }

    function _resolve(Market storage m, uint256 marketId, uint8 outcome, bool timedOut) internal {
        m.resolved = true;
        m.outcome = outcome;
        m.resolvedAt = uint64(block.timestamp);
        emit MarketResolved(marketId, outcome, msg.sender, timedOut);
    }

    function _storeMarket(Market storage m, CreateMarketParams calldata p, uint256 n, uint256[] memory pool) internal {
        m.collateral = p.collateral;
        m.closeTime = p.closeTime;
        // casting to 'uint8' is safe because n <= MAX_OUTCOMES (8)
        // forge-lint: disable-next-line(unsafe-typecast)
        m.numOutcomes = uint8(n);
        m.arbitrator = p.arbitrator;
        m.resolutionTime = p.resolutionTime;
        m.feeBps = p.feeBps;
        m.creator = msg.sender;
        m.createdAt = uint64(block.timestamp);
        m.collateralLocked = p.initialLiquidity;
        m.totalLpShares = p.initialLiquidity;
        m.pool = pool;
        m.question = p.question;
        m.category = p.category;
        for (uint256 i; i < n; ++i) {
            m.outcomeLabels.push(p.outcomeLabels[i]);
        }
    }

    function _emitMarketCreated(uint256 marketId, CreateMarketParams calldata p) internal {
        emit MarketCreated(
            marketId,
            msg.sender,
            p.arbitrator,
            address(p.collateral),
            p.closeTime,
            p.resolutionTime,
            p.feeBps,
            p.question,
            p.category,
            p.outcomeLabels
        );
    }

    function _validateCreate(CreateMarketParams calldata p, uint256 n) internal view returns (uint256[] memory) {
        CollateralConfig storage cfg = collateralConfig[p.collateral];
        if (!cfg.allowed) revert CollateralNotAllowed(address(p.collateral));
        if (n < MIN_OUTCOMES || n > MAX_OUTCOMES) revert InvalidOutcomeCount(n);
        if (
            p.closeTime <= block.timestamp || p.closeTime > block.timestamp + MAX_DURATION
                || p.resolutionTime < p.closeTime || p.resolutionTime > uint256(p.closeTime) + MAX_DURATION
        ) revert InvalidTimes();
        if (p.arbitrator == address(0)) revert InvalidArbitrator();
        if (p.feeBps > MAX_FEE_BPS) revert FeeTooHigh(p.feeBps, MAX_FEE_BPS);
        uint256 minLiq = cfg.minLiquidity == 0 ? 1 : cfg.minLiquidity;
        if (p.initialLiquidity < minLiq) revert LiquidityTooLow(p.initialLiquidity, minLiq);
        _checkText(p.question, 1, MAX_QUESTION_LENGTH);
        _checkText(p.category, 0, MAX_CATEGORY_LENGTH);
        for (uint256 i; i < n; ++i) {
            _checkText(p.outcomeLabels[i], 1, MAX_LABEL_LENGTH);
        }
        return _initialPool(p.initialLiquidity, p.initialOddsBps, n);
    }

    function _checkText(string calldata s, uint256 minLen, uint256 maxLen) internal pure {
        uint256 len = bytes(s).length;
        if (len < minLen || len > maxLen) revert InvalidText();
    }

    /// @dev Pool balances that make the spot prices equal to `oddsBps`: b_i = funding * minOdds / odds_i.
    function _initialPool(uint256 funding, uint16[] calldata oddsBps, uint256 n)
        internal
        pure
        returns (uint256[] memory pool)
    {
        pool = new uint256[](n);
        if (oddsBps.length == 0) {
            for (uint256 i; i < n; ++i) {
                pool[i] = funding;
            }
            return pool;
        }
        if (oddsBps.length != n) revert InvalidOdds();
        uint256 sum;
        uint256 minOdds = BPS;
        for (uint256 i; i < n; ++i) {
            uint256 o = oddsBps[i];
            if (o < MIN_ODDS_BPS) revert InvalidOdds();
            sum += o;
            if (o < minOdds) minOdds = o;
        }
        if (sum != BPS) revert InvalidOdds();
        for (uint256 i; i < n; ++i) {
            pool[i] = Math.mulDiv(funding, minOdds, oddsBps[i]);
            if (pool[i] == 0) revert InvalidOdds();
        }
    }

    /// @dev Pulls collateral and rejects fee-on-transfer behaviour (the received amount must match exactly).
    function _pullCollateral(IERC20 token, address from, uint256 amount) internal {
        uint256 before = token.balanceOf(address(this));
        token.safeTransferFrom(from, address(this), amount);
        uint256 received = token.balanceOf(address(this)) - before;
        if (received != amount) revert FeeOnTransferNotSupported(amount, received);
    }

    /// @dev Mints the non-zero entries of `amounts` (indexed by outcome) to `to`.
    function _mintOutcomeTokens(address to, uint256 marketId, uint256[] memory amounts) internal {
        uint256 n = amounts.length;
        uint256 count;
        for (uint256 i; i < n; ++i) {
            if (amounts[i] != 0) ++count;
        }
        if (count == 0) return;
        uint256[] memory ids = new uint256[](count);
        uint256[] memory values = new uint256[](count);
        uint256 k;
        for (uint256 i; i < n; ++i) {
            if (amounts[i] != 0) {
                // casting to 'uint8' is safe because i < numOutcomes <= MAX_OUTCOMES (8)
                // forge-lint: disable-next-line(unsafe-typecast)
                ids[k] = positionId(marketId, uint8(i));
                values[k] = amounts[i];
                ++k;
            }
        }
        _mintBatch(to, ids, values, "");
    }

    function _ids(uint256 marketId, uint256 n) internal pure returns (uint256[] memory ids) {
        ids = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            // casting to 'uint8' is safe because i < numOutcomes <= MAX_OUTCOMES (8)
            // forge-lint: disable-next-line(unsafe-typecast)
            ids[i] = positionId(marketId, uint8(i));
        }
    }

    function _filled(uint256 n, uint256 value) internal pure returns (uint256[] memory arr) {
        arr = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            arr[i] = value;
        }
    }

    /// @inheritdoc ERC1155
    function supportsInterface(bytes4 interfaceId) public view virtual override(ERC1155, IERC165) returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}
