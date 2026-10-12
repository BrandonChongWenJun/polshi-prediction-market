// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {PredictionMarket} from "../../src/PredictionMarket.sol";
import {OrderBook} from "../../src/OrderBook.sol";
import {IPredictionMarket} from "../../src/interfaces/IPredictionMarket.sol";
import {MockUSDT} from "../../src/tokens/MockUSDT.sol";
import {WETH9} from "../../src/tokens/WETH9.sol";

contract OrderBookHandler is Test {
    PredictionMarket public pm;
    OrderBook public book;
    address[] public actors;
    uint256[] public markets;
    address public arbitrator;

    constructor(
        PredictionMarket pm_,
        OrderBook book_,
        address[] memory actors_,
        uint256[] memory markets_,
        address arb
    ) {
        pm = pm_;
        book = book_;
        actors = actors_;
        markets = markets_;
        arbitrator = arb;
    }

    function _actorAt(uint256 seed, uint256 k) internal view returns (address) {
        return actors[(seed % actors.length + k) % actors.length];
    }

    function _market(uint256 seed) internal view returns (uint256 id, PredictionMarket.MarketView memory v) {
        id = markets[seed % markets.length];
        v = pm.getMarket(id);
    }

    function placeAsk(uint256 actorSeed, uint256 marketSeed, uint256 outcomeSeed, uint16 price, uint256 amt, uint64 exp)
        external
    {
        (uint256 id, PredictionMarket.MarketView memory v) = _market(marketSeed);
        if (v.resolved) return;
        uint8 o = uint8(outcomeSeed % v.numOutcomes);
        address a = _actorAt(actorSeed, 0);
        uint256 bal = pm.balanceOf(a, pm.positionId(id, o));
        if (bal == 0) return;
        uint64 expiry = exp % 3 == 0 ? 0 : uint64(block.timestamp + 1 + (exp % 3 days));
        vm.prank(a);
        book.placeOrder(id, o, OrderBook.Side.Sell, uint16(bound(price, 1, 9999)), bound(amt, 1, bal), expiry);
    }

    function placeBid(uint256 actorSeed, uint256 marketSeed, uint256 outcomeSeed, uint16 price, uint256 amt, uint64 exp)
        external
    {
        (uint256 id, PredictionMarket.MarketView memory v) = _market(marketSeed);
        if (v.resolved) return;
        address a = _actorAt(actorSeed, 0);
        uint16 p = uint16(bound(price, 1, 9999));
        uint256 amount = _bidAmount(IERC20(v.collateral).balanceOf(a), p, amt, marketSeed % markets.length == 0);
        if (amount == 0) return;
        uint64 expiry = exp % 3 == 0 ? 0 : uint64(block.timestamp + 1 + (exp % 3 days));
        vm.prank(a);
        book.placeOrder(id, uint8(outcomeSeed % v.numOutcomes), OrderBook.Side.Buy, p, amount, expiry);
    }

    /// Bid size bounded by 1000 whole shares and by the maker's balance (escrow = amount * p / 10_000).
    function _bidAmount(uint256 cash, uint16 p, uint256 amt, bool sixDecimals) internal pure returns (uint256) {
        uint256 maxAmount = (cash * 10_000) / p;
        if (maxAmount == 0) return 0;
        uint256 unit = sixDecimals ? 1e6 : 1e18; // (a bare ternary of literals would be typed uint64)
        uint256 cap = 1000 * unit;
        if (maxAmount < cap) cap = maxAmount;
        return bound(amt, 1, cap);
    }

    function fill(uint256 orderSeed, uint256 takerSeed, uint256 amt) external {
        uint256 count = book.orderCount();
        if (count == 0) return;
        for (uint256 k; k < count; ++k) {
            uint256 oid = 1 + (orderSeed % count + k) % count;
            OrderBook.Order memory o = book.getOrder(oid);
            if (o.status != OrderBook.Status.Open) continue;
            if (o.expiry != 0 && block.timestamp >= o.expiry) continue;
            if (pm.getMarketCore(o.marketId).resolved) continue;
            uint256 shares = amt % 4 == 0 ? o.remaining : bound(amt, 1, o.remaining); // sometimes fill fully
            for (uint256 t; t < actors.length; ++t) {
                address taker = _actorAt(takerSeed, t);
                if (taker == o.maker) continue;
                if (o.side == OrderBook.Side.Buy) {
                    uint256 bal = pm.balanceOf(taker, pm.positionId(o.marketId, o.outcome));
                    if (bal == 0) continue;
                    if (shares > bal) shares = bal;
                    if ((shares * o.price) / 10_000 == 0) continue; // would be FillTooSmall
                } else {
                    IERC20 token = IERC20(pm.getMarketCore(o.marketId).collateral);
                    if (token.balanceOf(taker) < (shares * o.price + 9999) / 10_000) continue;
                }
                vm.prank(taker);
                book.fillOrder(oid, shares);
                return;
            }
        }
    }

    function cancel(uint256 orderSeed) external {
        uint256 count = book.orderCount();
        if (count == 0) return;
        for (uint256 k; k < count; ++k) {
            uint256 oid = 1 + (orderSeed % count + k) % count;
            OrderBook.Order memory o = book.getOrder(oid);
            if (o.status != OrderBook.Status.Open) continue;
            vm.prank(o.maker);
            book.cancelOrder(oid);
            return;
        }
    }

    function warp(uint256 secondsSeed) external {
        vm.warp(block.timestamp + bound(secondsSeed, 1, 1 days));
    }

    function resolve(uint256 marketSeed, uint256 outcomeSeed) external {
        (uint256 id, PredictionMarket.MarketView memory v) = _market(marketSeed);
        if (v.phase != PredictionMarket.Phase.Reporting) return;
        vm.prank(arbitrator);
        pm.reportOutcome(id, uint8(outcomeSeed % v.numOutcomes));
    }
}

/// @title Order book escrow invariants
/// @notice Under random place / fill (partial) / cancel / expiry / resolution sequences:
///         1. the book's ERC1155 balance of every outcome id equals the unfilled amount of open sell orders;
///         2. the book's collateral balance equals the escrow of open buy orders, and every open bid can still
///            pay for its remaining shares;
///         3. closed orders hold no escrow; outcome tokens and collateral are conserved between users and the book.
contract OrderBookInvariantsTest is Test {
    PredictionMarket internal pm;
    OrderBook internal book;
    OrderBookHandler internal handler;
    MockUSDT internal usdt;
    WETH9 internal weth;
    address[] internal actors;
    uint256[] internal markets;
    uint256 internal initialUsdt;
    uint256 internal initialWeth;

    function setUp() public {
        vm.warp(1_750_000_000);
        usdt = new MockUSDT();
        weth = new WETH9();
        pm = new PredictionMarket(address(this));
        book = new OrderBook(IPredictionMarket(address(pm)));
        pm.setCollateral(IERC20(address(usdt)), true, 1);
        pm.setCollateral(IERC20(address(weth)), true, 1);
        address arb = makeAddr("arb");

        // markets are created by the test contract (not an actor) so actors start with only split positions
        usdt.mint(address(this), 1e12);
        usdt.approve(address(pm), type(uint256).max);
        vm.deal(address(this), 100 ether);
        weth.deposit{value: 100 ether}();
        weth.approve(address(pm), type(uint256).max);
        markets.push(_createMarket(IERC20(address(usdt)), 2, 1000e6, arb));
        markets.push(_createMarket(IERC20(address(weth)), 3, 10 ether, arb));

        for (uint256 i; i < 4; ++i) {
            address a = makeAddr(string(abi.encodePacked("trader", vm.toString(i))));
            actors.push(a);
            usdt.mint(a, 1_000_000e6);
            vm.deal(a, 1000 ether);
            vm.startPrank(a);
            weth.deposit{value: 1000 ether}();
            usdt.approve(address(pm), type(uint256).max);
            usdt.approve(address(book), type(uint256).max);
            weth.approve(address(pm), type(uint256).max);
            weth.approve(address(book), type(uint256).max);
            pm.setApprovalForAll(address(book), true);
            pm.splitPosition(markets[0], 5000e6);
            pm.splitPosition(markets[1], 50 ether);
            vm.stopPrank();
        }
        for (uint256 i; i < actors.length; ++i) {
            initialUsdt += usdt.balanceOf(actors[i]);
            initialWeth += weth.balanceOf(actors[i]);
        }

        handler = new OrderBookHandler(pm, book, actors, markets, arb);
        targetContract(address(handler));
    }

    function _createMarket(IERC20 token, uint256 n, uint256 liq, address arb) internal returns (uint256) {
        PredictionMarket.CreateMarketParams memory p;
        p.question = "P2P";
        p.outcomeLabels = new string[](n);
        for (uint256 i; i < n; ++i) {
            p.outcomeLabels[i] = "o";
        }
        p.closeTime = uint64(block.timestamp + 2 days);
        p.resolutionTime = uint64(block.timestamp + 3 days);
        p.arbitrator = arb;
        p.collateral = token;
        p.initialLiquidity = liq;
        return pm.createMarket(p);
    }

    function invariant_escrowMatchesOpenOrders() public view {
        uint256 count = book.orderCount();
        for (uint256 k; k < markets.length; ++k) {
            PredictionMarket.MarketView memory v = pm.getMarket(markets[k]);
            for (uint256 o; o < v.numOutcomes; ++o) {
                uint256 openAsks;
                for (uint256 id = 1; id <= count; ++id) {
                    OrderBook.Order memory ord = book.getOrder(id);
                    if (
                        ord.marketId == markets[k] && ord.outcome == o && ord.side == OrderBook.Side.Sell
                            && ord.status == OrderBook.Status.Open
                    ) openAsks += ord.remaining;
                }
                assertEq(pm.balanceOf(address(book), pm.positionId(markets[k], uint8(o))), openAsks, "share escrow");
            }
        }
        uint256 usdtEscrow;
        uint256 wethEscrow;
        for (uint256 id = 1; id <= count; ++id) {
            OrderBook.Order memory ord = book.getOrder(id);
            if (ord.status != OrderBook.Status.Open) {
                assertEq(ord.remaining, 0, "closed order has remaining");
                assertEq(ord.escrow, 0, "closed order has escrow");
                continue;
            }
            assertGt(ord.remaining, 0, "open order without remaining");
            assertLe(ord.remaining, ord.amount, "remaining > amount");
            if (ord.side == OrderBook.Side.Buy) {
                assertGe(ord.escrow, (ord.remaining * ord.price) / 10_000, "bid cannot pay for remaining");
                if (pm.getMarketCore(ord.marketId).collateral == address(usdt)) usdtEscrow += ord.escrow;
                else wethEscrow += ord.escrow;
            } else {
                assertEq(ord.escrow, 0, "ask with collateral escrow");
            }
        }
        assertEq(usdt.balanceOf(address(book)), usdtEscrow, "usdt escrow");
        assertEq(weth.balanceOf(address(book)), wethEscrow, "weth escrow");
    }

    function invariant_conservation() public view {
        uint256 u = usdt.balanceOf(address(book));
        uint256 w = weth.balanceOf(address(book));
        for (uint256 i; i < actors.length; ++i) {
            u += usdt.balanceOf(actors[i]);
            w += weth.balanceOf(actors[i]);
        }
        assertEq(u, initialUsdt, "usdt created or destroyed");
        assertEq(w, initialWeth, "weth created or destroyed");
        for (uint256 k; k < markets.length; ++k) {
            PredictionMarket.MarketView memory v = pm.getMarket(markets[k]);
            for (uint256 o; o < v.numOutcomes; ++o) {
                uint256 tokenId = pm.positionId(markets[k], uint8(o));
                uint256 held = pm.balanceOf(address(book), tokenId);
                for (uint256 i; i < actors.length; ++i) {
                    held += pm.balanceOf(actors[i], tokenId);
                }
                assertEq(held, pm.totalSupply(tokenId), "outcome tokens leaked");
            }
        }
    }
}
