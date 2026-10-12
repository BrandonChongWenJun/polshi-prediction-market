// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC1155Errors} from "@openzeppelin/contracts/interfaces/IERC6093.sol";
import {IERC1155Receiver} from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";

import {BaseTest} from "./utils/BaseTest.sol";
import {OrderBook} from "../src/OrderBook.sol";
import {PredictionMarket} from "../src/PredictionMarket.sol";

contract OrderBookTest is BaseTest {
    event OrderPlaced(
        uint256 indexed orderId,
        uint256 indexed marketId,
        address indexed maker,
        uint8 outcome,
        OrderBook.Side side,
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

    uint256 internal id;
    uint256 internal yesId;

    function setUp() public override {
        super.setUp();
        id = _createBinaryUsdt();
        yesId = pm.positionId(id, 0);
        _buy(bob, id, 0, 300e6); // bob holds YES shares
        vm.prank(carol);
        pm.splitPosition(id, 200e6); // carol holds 200 YES + 200 NO
    }

    function _ask(address maker, uint16 price, uint256 amount) internal returns (uint256 oid) {
        vm.prank(maker);
        oid = book.placeOrder(id, 0, OrderBook.Side.Sell, price, amount, 0);
    }

    function _bid(address maker, uint16 price, uint256 amount) internal returns (uint256 oid) {
        vm.prank(maker);
        oid = book.placeOrder(id, 0, OrderBook.Side.Buy, price, amount, 0);
    }

    // ------------------------------------------------------------------ sell orders (asks)

    function test_ask_placeEscrowsShares() public {
        uint256 bobYes = _bal(bob, id, 0);
        vm.expectEmit(true, true, true, true, address(book));
        emit OrderPlaced(1, id, bob, 0, OrderBook.Side.Sell, 6000, 100e6, 0);
        uint256 oid = _ask(bob, 6000, 100e6);
        assertEq(oid, 1);
        assertEq(_bal(bob, id, 0), bobYes - 100e6);
        assertEq(pm.balanceOf(address(book), yesId), 100e6);
        OrderBook.Order memory o = book.getOrder(oid);
        assertEq(o.maker, bob);
        assertEq(o.marketId, id);
        assertEq(o.price, 6000);
        assertEq(o.amount, 100e6);
        assertEq(o.remaining, 100e6);
        assertEq(o.escrow, 0);
        assertEq(uint8(o.status), uint8(OrderBook.Status.Open));
        assertEq(book.marketOrderCount(id), 1);
    }

    function test_ask_partialAndFullFill() public {
        uint256 oid = _ask(bob, 6000, 100e6);
        uint256 bobUsdt = usdt.balanceOf(bob);
        uint256 eveUsdt = usdt.balanceOf(eve);

        vm.expectEmit(true, true, true, true, address(book));
        emit OrderFilled(oid, id, eve, bob, 40e6, 24e6, 60e6);
        vm.prank(eve);
        uint256 paid = book.fillOrder(oid, 40e6);
        assertEq(paid, 24e6);
        assertEq(usdt.balanceOf(eve), eveUsdt - 24e6);
        assertEq(usdt.balanceOf(bob), bobUsdt + 24e6);
        assertEq(_bal(eve, id, 0), 40e6);
        assertEq(book.getOrder(oid).remaining, 60e6);

        vm.prank(frank);
        book.fillOrder(oid, 60e6);
        OrderBook.Order memory o = book.getOrder(oid);
        assertEq(o.remaining, 0);
        assertEq(uint8(o.status), uint8(OrderBook.Status.Filled));
        assertEq(pm.balanceOf(address(book), yesId), 0);
        assertEq(usdt.balanceOf(bob), bobUsdt + 60e6);
    }

    function test_ask_takerPaysRoundedUp() public {
        uint256 oid = _ask(bob, 3333, 10e6);
        vm.prank(eve);
        uint256 paid = book.fillOrder(oid, 1); // 1 * 0.3333 -> rounds up to 1 base unit
        assertEq(paid, 1);
    }

    function test_ask_cancelRefundsRemaining() public {
        uint256 oid = _ask(bob, 6000, 100e6);
        vm.prank(eve);
        book.fillOrder(oid, 30e6);
        uint256 before = _bal(bob, id, 0);
        vm.expectEmit(true, true, false, true, address(book));
        emit OrderCancelled(oid, id, 70e6, 0);
        vm.prank(bob);
        book.cancelOrder(oid);
        assertEq(_bal(bob, id, 0), before + 70e6);
        OrderBook.Order memory o = book.getOrder(oid);
        assertEq(uint8(o.status), uint8(OrderBook.Status.Cancelled));
        assertEq(o.remaining, 0);
        assertEq(pm.balanceOf(address(book), yesId), 0);
    }

    // ------------------------------------------------------------------ buy orders (bids)

    function test_bid_placeEscrowsCollateral() public {
        uint256 before = usdt.balanceOf(eve);
        uint256 oid = _bid(eve, 4500, 100e6);
        assertEq(usdt.balanceOf(eve), before - 45e6);
        assertEq(usdt.balanceOf(address(book)), 45e6);
        assertEq(book.getOrder(oid).escrow, 45e6);
    }

    function test_bid_partialFillsAndDustRefund() public {
        // escrow = ceil(10_000_001 * 0.3333) = ceil(3_333_000.33) = 3_333_001
        uint256 oid = _bid(eve, 3333, 10_000_001);
        assertEq(book.getOrder(oid).escrow, 3_333_001);
        uint256 eveUsdt = usdt.balanceOf(eve);
        uint256 carolUsdt = usdt.balanceOf(carol);

        vm.prank(carol);
        uint256 got1 = book.fillOrder(oid, 3_000_000); // floor(999_900) = 999_900
        assertEq(got1, 999_900);
        assertEq(_bal(eve, id, 0), 3_000_000);
        vm.prank(carol);
        uint256 got2 = book.fillOrder(oid, 7_000_001); // floor(2_333_100.33) = 2_333_100
        assertEq(got2, 2_333_100);
        assertEq(usdt.balanceOf(carol), carolUsdt + got1 + got2);
        // leftover rounding dust (3_333_001 - 3_333_000) is returned to the maker when the order completes
        assertEq(usdt.balanceOf(eve), eveUsdt + 1);
        assertEq(usdt.balanceOf(address(book)), 0);
        assertEq(_bal(eve, id, 0), 10_000_001);
        assertEq(uint8(book.getOrder(oid).status), uint8(OrderBook.Status.Filled));
        assertEq(book.getOrder(oid).escrow, 0);
    }

    function test_bid_cancelRefundsEscrow() public {
        uint256 oid = _bid(eve, 5000, 100e6);
        vm.prank(carol);
        book.fillOrder(oid, 20e6);
        uint256 before = usdt.balanceOf(eve);
        vm.prank(eve);
        book.cancelOrder(oid);
        assertEq(usdt.balanceOf(eve), before + 40e6);
        assertEq(usdt.balanceOf(address(book)), 0);
    }

    function test_revert_bid_fillTooSmall() public {
        uint256 oid = _bid(eve, 1, 100e6); // 0.0001 per share
        vm.prank(carol);
        vm.expectRevert(OrderBook.FillTooSmall.selector);
        book.fillOrder(oid, 9999); // floor(0.9999) = 0
    }

    function test_revert_bid_takerWithoutShares() public {
        uint256 oid = _bid(eve, 5000, 100e6);
        vm.prank(frank); // frank holds no YES
        vm.expectRevert(
            abi.encodeWithSelector(IERC1155Errors.ERC1155InsufficientBalance.selector, frank, 0, 10e6, yesId)
        );
        book.fillOrder(oid, 10e6);
    }

    function test_revert_bid_takerWithoutApproval() public {
        uint256 oid = _bid(eve, 5000, 100e6);
        vm.prank(carol);
        pm.setApprovalForAll(address(book), false);
        vm.prank(carol);
        vm.expectRevert(
            abi.encodeWithSelector(IERC1155Errors.ERC1155MissingApprovalForAll.selector, address(book), carol)
        );
        book.fillOrder(oid, 10e6);
    }

    // ------------------------------------------------------------------ validation

    function test_revert_place() public {
        vm.startPrank(bob);
        vm.expectRevert(abi.encodeWithSelector(OrderBook.MarketNotFound.selector, 99));
        book.placeOrder(99, 0, OrderBook.Side.Sell, 5000, 1e6, 0);
        vm.expectRevert(abi.encodeWithSelector(OrderBook.InvalidOutcome.selector, 2));
        book.placeOrder(id, 2, OrderBook.Side.Sell, 5000, 1e6, 0);
        vm.expectRevert(abi.encodeWithSelector(OrderBook.InvalidPrice.selector, 0));
        book.placeOrder(id, 0, OrderBook.Side.Sell, 0, 1e6, 0);
        vm.expectRevert(abi.encodeWithSelector(OrderBook.InvalidPrice.selector, 10_000));
        book.placeOrder(id, 0, OrderBook.Side.Buy, 10_000, 1e6, 0);
        vm.expectRevert(OrderBook.ZeroAmount.selector);
        book.placeOrder(id, 0, OrderBook.Side.Sell, 5000, 0, 0);
        vm.expectRevert(abi.encodeWithSelector(OrderBook.InvalidExpiry.selector, uint64(block.timestamp)));
        book.placeOrder(id, 0, OrderBook.Side.Sell, 5000, 1e6, uint64(block.timestamp));
        vm.stopPrank();
    }

    function test_revert_place_askWithoutShares() public {
        vm.prank(frank);
        vm.expectRevert(
            abi.encodeWithSelector(IERC1155Errors.ERC1155InsufficientBalance.selector, frank, 0, 1e6, yesId)
        );
        book.placeOrder(id, 0, OrderBook.Side.Sell, 5000, 1e6, 0);
    }

    function test_revert_fill() public {
        uint256 oid = _ask(bob, 6000, 100e6);
        vm.expectRevert(abi.encodeWithSelector(OrderBook.OrderNotFound.selector, 77));
        book.fillOrder(77, 1);
        vm.prank(bob);
        vm.expectRevert(OrderBook.SelfFill.selector);
        book.fillOrder(oid, 1);
        vm.prank(eve);
        vm.expectRevert(OrderBook.ZeroAmount.selector);
        book.fillOrder(oid, 0);
        vm.prank(eve);
        vm.expectRevert(abi.encodeWithSelector(OrderBook.FillExceedsRemaining.selector, 100e6 + 1, 100e6));
        book.fillOrder(oid, 100e6 + 1);
        vm.prank(bob);
        book.cancelOrder(oid);
        vm.prank(eve);
        vm.expectRevert(abi.encodeWithSelector(OrderBook.OrderNotOpen.selector, oid));
        book.fillOrder(oid, 1);
    }

    function test_revert_cancel() public {
        uint256 oid = _ask(bob, 6000, 100e6);
        vm.expectRevert(abi.encodeWithSelector(OrderBook.OrderNotFound.selector, 5));
        book.cancelOrder(5);
        vm.prank(eve);
        vm.expectRevert(abi.encodeWithSelector(OrderBook.NotMaker.selector, eve));
        book.cancelOrder(oid);
        vm.prank(eve);
        book.fillOrder(oid, 100e6);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(OrderBook.OrderNotOpen.selector, oid));
        book.cancelOrder(oid);
    }

    function test_expiry() public {
        uint64 expiry = uint64(block.timestamp + 1 hours);
        vm.prank(bob);
        uint256 oid = book.placeOrder(id, 0, OrderBook.Side.Sell, 5000, 10e6, expiry);
        vm.prank(eve);
        book.fillOrder(oid, 1e6);
        vm.warp(expiry);
        vm.prank(eve);
        vm.expectRevert(abi.encodeWithSelector(OrderBook.OrderExpired.selector, oid, expiry));
        book.fillOrder(oid, 1e6);
        // expired orders can still be cancelled to recover the escrow
        vm.prank(bob);
        book.cancelOrder(oid);
        assertEq(pm.balanceOf(address(book), yesId), 0);
    }

    function test_tradingAfterAmmCloseButBeforeResolution_thenBlocked() public {
        uint256 oid = _ask(bob, 7000, 50e6);
        vm.warp(pm.getMarket(id).closeTime + 1); // AMM closed, P2P still open
        vm.prank(eve);
        book.fillOrder(oid, 10e6);
        vm.prank(carol);
        uint256 oid2 = book.placeOrder(id, 1, OrderBook.Side.Sell, 2000, 10e6, 0);

        _warpToResolution(id);
        vm.prank(dave);
        pm.reportOutcome(id, 0);

        vm.prank(eve);
        vm.expectRevert(abi.encodeWithSelector(OrderBook.MarketResolved.selector, id));
        book.fillOrder(oid, 10e6);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(OrderBook.MarketResolved.selector, id));
        book.placeOrder(id, 0, OrderBook.Side.Sell, 5000, 1e6, 0);

        // makers recover their escrow after resolution and can redeem
        vm.prank(bob);
        book.cancelOrder(oid);
        vm.prank(carol);
        book.cancelOrder(oid2);
        vm.prank(bob);
        assertGt(pm.redeem(id), 0);
    }

    function test_getMarketOrders_pagination() public {
        _ask(bob, 6000, 1e6);
        _ask(bob, 6100, 1e6);
        _bid(eve, 4000, 1e6);
        (uint256[] memory ids, OrderBook.Order[] memory orders) = book.getMarketOrders(id, 0, 10);
        assertEq(ids.length, 3);
        assertEq(orders[2].maker, eve);
        (ids, orders) = book.getMarketOrders(id, 1, 1);
        assertEq(ids.length, 1);
        assertEq(ids[0], 2);
        assertEq(orders[0].price, 6100);
        (ids,) = book.getMarketOrders(id, 3, 5);
        assertEq(ids.length, 0);
        (ids,) = book.getMarketOrders(id, 2, 5);
        assertEq(ids.length, 1);
    }

    function test_rejectsDirectErc1155Transfers() public {
        vm.prank(bob);
        vm.expectRevert(OrderBook.UnexpectedTokenTransfer.selector);
        pm.safeTransferFrom(bob, address(book), yesId, 1e6, "");

        uint256[] memory ids = new uint256[](1);
        ids[0] = yesId;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1e6;
        vm.prank(bob);
        vm.expectRevert(OrderBook.UnexpectedTokenTransfer.selector);
        pm.safeBatchTransferFrom(bob, address(book), ids, amounts, "");
    }

    function test_supportsInterface() public view {
        assertTrue(book.supportsInterface(type(IERC1155Receiver).interfaceId));
        assertTrue(book.supportsInterface(0x01ffc9a7));
        assertFalse(book.supportsInterface(0xdeadbeef));
    }

    function test_multiCollateral_wethMarketOrders() public {
        uint256 m = _create(alice, _params(IERC20(address(weth)), 3, 2 ether, dave));
        vm.prank(bob);
        pm.splitPosition(m, 1 ether);
        vm.prank(bob);
        uint256 oid = book.placeOrder(m, 2, OrderBook.Side.Sell, 2500, 0.4 ether, 0);
        uint256 before = weth.balanceOf(eve);
        vm.prank(eve);
        book.fillOrder(oid, 0.4 ether);
        assertEq(weth.balanceOf(eve), before - 0.1 ether);
        assertEq(_bal(eve, m, 2), 0.4 ether);
    }

    // ------------------------------------------------------------------ fuzz

    /// Filling a bid in arbitrary chunks never over-draws the escrow; the maker ends with all shares and
    /// exactly (escrow - paid) refunded.
    function testFuzz_bidChunksNeverOverdrawEscrow(uint16 priceRaw, uint256 amountRaw, uint256 seed) public {
        uint16 price = uint16(bound(priceRaw, 1, 9999));
        uint256 amount = bound(amountRaw, 1e4, 150e6);
        uint256 oid = _bid(eve, price, amount);
        uint256 escrow = book.getOrder(oid).escrow;
        uint256 eveBefore = usdt.balanceOf(eve);
        uint256 paid;
        for (uint256 k; k < 6 && book.getOrder(oid).remaining > 0; ++k) {
            uint256 rem = book.getOrder(oid).remaining;
            uint256 chunk = k == 5 ? rem : bound(uint256(keccak256(abi.encode(seed, k))), 1, rem);
            if ((chunk * price) / 10_000 == 0) chunk = rem; // avoid FillTooSmall
            if ((chunk * price) / 10_000 == 0) return;
            vm.prank(carol);
            paid += book.fillOrder(oid, chunk);
        }
        if (book.getOrder(oid).remaining == 0) {
            assertLe(paid, escrow);
            assertEq(usdt.balanceOf(eve), eveBefore + (escrow - paid));
            assertEq(usdt.balanceOf(address(book)), 0);
        } else {
            assertEq(usdt.balanceOf(address(book)), book.getOrder(oid).escrow);
        }
    }

    /// Ask fills: the maker always receives at least price * shares.
    function testFuzz_askMakerNeverUnderpaid(uint16 priceRaw, uint256 amountRaw, uint256 fillRaw) public {
        uint16 price = uint16(bound(priceRaw, 1, 9999));
        uint256 amount = bound(amountRaw, 1, 150e6);
        uint256 fill = bound(fillRaw, 1, amount);
        uint256 oid = _ask(carol, price, amount);
        uint256 before = usdt.balanceOf(carol);
        vm.prank(eve);
        uint256 paid = book.fillOrder(oid, fill);
        assertEq(usdt.balanceOf(carol), before + paid);
        assertGe(paid * 10_000, fill * price);
        assertLt(paid * 10_000, fill * price + 10_000);
    }
}
