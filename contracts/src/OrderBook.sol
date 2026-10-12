// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC1155Receiver} from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IPredictionMarket} from "./interfaces/IPredictionMarket.sol";

/// @title OrderBook
/// @notice Bonus 1 -- secondary peer-to-peer market for outcome shares, independent of the AMM.
///         Makers post limit orders that are fully escrowed on-chain; takers fill them partially or fully;
///         makers can cancel at any time and get the unfilled escrow back. Orders can only be placed and filled
///         while the underlying market is unresolved ("prior to event resolution") and before their optional expiry.
/// @dev Prices are quoted in collateral per whole share with 4 decimals: `price / PRICE_SCALE` (e.g. 6_250 = 0.625).
///      Share amounts use the collateral's base units (1 share base unit is redeemable for at most 1 collateral
///      base unit). Rounding: a taker buying shares pays ceil(shares * price); a taker selling shares receives
///      floor(shares * price) out of the bid's escrow, which was funded with ceil(amount * price). Escrow can
///      therefore never be over-drawn, and leftover dust returns to the maker when the order completes/cancels.
///      No fees; no owner; no loops over user data.
contract OrderBook is IERC1155Receiver, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    /// @notice Price denominator: prices are in (0, PRICE_SCALE), i.e. 0.0001 .. 0.9999 collateral per share.
    uint256 public constant PRICE_SCALE = 10_000;

    enum Side {
        Buy, // maker buys shares: escrows collateral
        Sell // maker sells shares: escrows outcome tokens
    }

    enum Status {
        Open,
        Filled,
        Cancelled
    }

    struct Order {
        address maker;
        uint64 expiry; // 0 = good until the market resolves
        uint64 createdAt;
        uint16 price;
        uint8 outcome;
        Side side;
        Status status;
        uint256 marketId;
        uint256 amount; // original share amount
        uint256 remaining; // unfilled share amount (0 once filled or cancelled)
        uint256 escrow; // collateral still escrowed (buy orders only)
    }

    /// @notice The prediction market whose ERC1155 outcome tokens are traded here.
    IPredictionMarket public immutable market;
    /// @notice Number of orders ever placed; order ids are 1..orderCount.
    uint256 public orderCount;
    mapping(uint256 orderId => Order) internal _orders;
    mapping(uint256 marketId => uint256[]) internal _marketOrders;

    event OrderPlaced(
        uint256 indexed orderId,
        uint256 indexed marketId,
        address indexed maker,
        uint8 outcome,
        Side side,
        uint16 price,
        uint256 amount,
        uint64 expiry
    );
    event OrderFilled(
        uint256 indexed orderId,
        uint256 indexed marketId,
        address indexed taker,
        address maker,
        uint256 shares,
        uint256 collateral,
        uint256 remaining
    );
    event OrderCancelled(
        uint256 indexed orderId, uint256 indexed marketId, uint256 sharesRefunded, uint256 collateralRefunded
    );

    error MarketNotFound(uint256 marketId);
    error MarketResolved(uint256 marketId);
    error InvalidOutcome(uint8 outcome);
    error InvalidPrice(uint256 price);
    error InvalidExpiry(uint64 expiry);
    error ZeroAmount();
    error OrderNotFound(uint256 orderId);
    error OrderNotOpen(uint256 orderId);
    error OrderExpired(uint256 orderId, uint64 expiry);
    error NotMaker(address caller);
    error SelfFill();
    error FillExceedsRemaining(uint256 requested, uint256 remaining);
    error FillTooSmall();
    error UnexpectedTokenTransfer();
    error FeeOnTransferNotSupported(uint256 expected, uint256 received);

    /// @param market_ The {PredictionMarket} contract.
    constructor(IPredictionMarket market_) {
        market = market_;
    }

    // ------------------------------------------------------------------------------------------------
    // Maker actions
    // ------------------------------------------------------------------------------------------------

    /// @notice Places a fully-escrowed limit order.
    /// @dev Sell orders pull `amount` outcome tokens (requires `setApprovalForAll(orderBook, true)`);
    ///      buy orders pull ceil(amount * price / PRICE_SCALE) collateral (requires ERC20 approval).
    /// @param marketId Market id.
    /// @param outcome Outcome index being traded.
    /// @param side Buy (bid) or Sell (ask).
    /// @param price Collateral per share scaled by PRICE_SCALE, strictly between 0 and PRICE_SCALE.
    /// @param amount Share amount (collateral base units).
    /// @param expiry Unix time after which the order can no longer be filled (0 = no expiry).
    /// @return orderId The new order id.
    function placeOrder(uint256 marketId, uint8 outcome, Side side, uint16 price, uint256 amount, uint64 expiry)
        external
        nonReentrant
        returns (uint256 orderId)
    {
        IPredictionMarket.MarketCore memory core = market.getMarketCore(marketId);
        if (core.numOutcomes == 0) revert MarketNotFound(marketId);
        if (core.resolved) revert MarketResolved(marketId);
        if (outcome >= core.numOutcomes) revert InvalidOutcome(outcome);
        if (price == 0 || price >= PRICE_SCALE) revert InvalidPrice(price);
        if (amount == 0) revert ZeroAmount();
        if (expiry != 0 && expiry <= block.timestamp) revert InvalidExpiry(expiry);

        uint256 escrow;
        if (side == Side.Buy) {
            escrow = Math.mulDiv(amount, price, PRICE_SCALE, Math.Rounding.Ceil);
        }

        orderId = ++orderCount;
        _orders[orderId] = Order({
            maker: msg.sender,
            expiry: expiry,
            createdAt: uint64(block.timestamp),
            price: price,
            outcome: outcome,
            side: side,
            status: Status.Open,
            marketId: marketId,
            amount: amount,
            remaining: amount,
            escrow: escrow
        });
        _marketOrders[marketId].push(orderId);
        emit OrderPlaced(orderId, marketId, msg.sender, outcome, side, price, amount, expiry);

        if (side == Side.Sell) {
            market.safeTransferFrom(msg.sender, address(this), market.positionId(marketId, outcome), amount, "");
        } else {
            IERC20 token = IERC20(core.collateral);
            uint256 before = token.balanceOf(address(this));
            token.safeTransferFrom(msg.sender, address(this), escrow);
            uint256 received = token.balanceOf(address(this)) - before;
            if (received != escrow) revert FeeOnTransferNotSupported(escrow, received);
        }
    }

    /// @notice Cancels an open order and refunds its unfilled escrow to the maker. Always available.
    /// @param orderId Order id.
    function cancelOrder(uint256 orderId) external nonReentrant {
        Order storage o = _orders[orderId];
        if (o.maker == address(0)) revert OrderNotFound(orderId);
        if (msg.sender != o.maker) revert NotMaker(msg.sender);
        if (o.status != Status.Open) revert OrderNotOpen(orderId);

        uint256 shares = o.side == Side.Sell ? o.remaining : 0;
        uint256 collateral = o.escrow;
        o.status = Status.Cancelled;
        o.remaining = 0;
        o.escrow = 0;
        emit OrderCancelled(orderId, o.marketId, shares, collateral);

        if (shares != 0) {
            market.safeTransferFrom(address(this), o.maker, market.positionId(o.marketId, o.outcome), shares, "");
        }
        if (collateral != 0) {
            IERC20(market.getMarketCore(o.marketId).collateral).safeTransfer(o.maker, collateral);
        }
    }

    // ------------------------------------------------------------------------------------------------
    // Taker actions
    // ------------------------------------------------------------------------------------------------

    /// @notice Fills `shares` of an open order (partial fills allowed).
    /// @dev Sell order: taker pays ceil(shares * price) collateral to the maker and receives escrowed shares.
    ///      Buy order: taker delivers shares to the maker (requires `setApprovalForAll`) and receives
    ///      floor(shares * price) collateral from the escrow.
    /// @param orderId Order id.
    /// @param shares Share amount to fill.
    /// @return collateral Collateral paid (sell orders) or received (buy orders) by the taker.
    function fillOrder(uint256 orderId, uint256 shares) external nonReentrant returns (uint256 collateral) {
        Order storage o = _orders[orderId];
        if (o.maker == address(0)) revert OrderNotFound(orderId);
        if (o.status != Status.Open) revert OrderNotOpen(orderId);
        if (o.expiry != 0 && block.timestamp >= o.expiry) revert OrderExpired(orderId, o.expiry);
        if (msg.sender == o.maker) revert SelfFill();
        if (shares == 0) revert ZeroAmount();
        if (shares > o.remaining) revert FillExceedsRemaining(shares, o.remaining);
        IPredictionMarket.MarketCore memory core = market.getMarketCore(o.marketId);
        if (core.resolved) revert MarketResolved(o.marketId);

        IERC20 token = IERC20(core.collateral);
        uint256 id = market.positionId(o.marketId, o.outcome);
        address maker = o.maker;
        uint256 remaining = o.remaining - shares;
        o.remaining = remaining;
        if (remaining == 0) o.status = Status.Filled;

        if (o.side == Side.Sell) {
            collateral = Math.mulDiv(shares, o.price, PRICE_SCALE, Math.Rounding.Ceil);
            emit OrderFilled(orderId, o.marketId, msg.sender, maker, shares, collateral, remaining);
            token.safeTransferFrom(msg.sender, maker, collateral);
            market.safeTransferFrom(address(this), msg.sender, id, shares, "");
        } else {
            collateral = Math.mulDiv(shares, o.price, PRICE_SCALE);
            if (collateral == 0) revert FillTooSmall();
            uint256 escrowLeft = o.escrow - collateral;
            uint256 refund;
            if (remaining == 0) {
                refund = escrowLeft; // rounding dust back to the maker
                escrowLeft = 0;
            }
            o.escrow = escrowLeft;
            emit OrderFilled(orderId, o.marketId, msg.sender, maker, shares, collateral, remaining);
            market.safeTransferFrom(msg.sender, maker, id, shares, "");
            token.safeTransfer(msg.sender, collateral);
            if (refund != 0) token.safeTransfer(maker, refund);
        }
    }

    // ------------------------------------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------------------------------------

    /// @notice Returns an order by id.
    function getOrder(uint256 orderId) external view returns (Order memory) {
        return _orders[orderId];
    }

    /// @notice Number of orders ever placed on `marketId`.
    function marketOrderCount(uint256 marketId) external view returns (uint256) {
        return _marketOrders[marketId].length;
    }

    /// @notice Paginated list of orders (any status) placed on `marketId`.
    /// @param marketId Market id.
    /// @param offset Index of the first order to return.
    /// @param limit Maximum number of orders to return.
    function getMarketOrders(uint256 marketId, uint256 offset, uint256 limit)
        external
        view
        returns (uint256[] memory ids, Order[] memory orders)
    {
        uint256[] storage all = _marketOrders[marketId];
        uint256 len = all.length;
        if (offset >= len) return (new uint256[](0), new Order[](0));
        uint256 end = offset + limit > len ? len : offset + limit;
        ids = new uint256[](end - offset);
        orders = new Order[](end - offset);
        for (uint256 i = offset; i < end; ++i) {
            ids[i - offset] = all[i];
            orders[i - offset] = _orders[all[i]];
        }
    }

    // ------------------------------------------------------------------------------------------------
    // ERC1155 receiver: only accept escrow transfers this contract initiates itself
    // ------------------------------------------------------------------------------------------------

    /// @inheritdoc IERC1155Receiver
    /// @dev Rejects direct (accidental) transfers so tokens can never get stuck here unaccounted.
    function onERC1155Received(address operator, address, uint256, uint256, bytes calldata)
        external
        view
        returns (bytes4)
    {
        if (msg.sender != address(market) || operator != address(this)) revert UnexpectedTokenTransfer();
        return IERC1155Receiver.onERC1155Received.selector;
    }

    /// @inheritdoc IERC1155Receiver
    /// @dev Batch transfers are never used for escrow and are always rejected.
    function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert UnexpectedTokenTransfer();
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IERC1155Receiver).interfaceId || interfaceId == type(IERC165).interfaceId;
    }
}
