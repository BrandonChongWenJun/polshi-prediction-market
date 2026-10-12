// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC1155Receiver} from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {BaseTest} from "./utils/BaseTest.sol";
import {PredictionMarket} from "../src/PredictionMarket.sol";
import {OrderBook} from "../src/OrderBook.sol";

/// @dev Contract account that re-enters the protocol from ERC1155 receiver hooks.
contract ReentrantReceiver is IERC1155Receiver {
    using SafeERC20 for IERC20;

    PredictionMarket internal pm;
    OrderBook internal book;
    uint256 public marketId;
    uint8 public mode; // 1 = re-enter buy, 2 = sell, 3 = removeLiquidity, 4 = orderbook cancel, 5 = redeem
    uint256 public orderId;
    bool public attempted;
    bytes public reentryError;

    constructor(PredictionMarket pm_, OrderBook book_) {
        pm = pm_;
        book = book_;
    }

    function setup(uint256 marketId_, uint8 mode_, uint256 orderId_) external {
        marketId = marketId_;
        mode = mode_;
        orderId = orderId_;
    }

    function approve(IERC20 token) external {
        // USDT-style tokens return no bool, so the plain IERC20 call would fail to decode
        token.forceApprove(address(pm), type(uint256).max);
        token.forceApprove(address(book), type(uint256).max);
        pm.setApprovalForAll(address(book), true);
    }

    function doBuy(uint256 amount) external returns (uint256) {
        return pm.buy(marketId, 0, amount, 0);
    }

    function doSplit(uint256 amount) external {
        pm.splitPosition(marketId, amount);
    }

    function doAddLiquidity(uint256 amount) external {
        pm.addLiquidity(marketId, amount, 0);
    }

    function doRemoveLiquidity(uint256 shares) external {
        pm.removeLiquidity(marketId, shares, 0);
    }

    function doPlaceAsk(uint256 amount) external returns (uint256) {
        return book.placeOrder(marketId, 0, OrderBook.Side.Sell, 5000, amount, 0);
    }

    function doCancel(uint256 oid) external {
        book.cancelOrder(oid);
    }

    function _reenter() internal {
        if (mode == 0 || attempted) return;
        attempted = true;
        bytes memory data;
        if (mode == 1) data = abi.encodeCall(PredictionMarket.buy, (marketId, 0, 1e6, 0));
        else if (mode == 2) data = abi.encodeCall(PredictionMarket.sell, (marketId, 0, 1e6, 0));
        else if (mode == 3) data = abi.encodeCall(PredictionMarket.removeLiquidity, (marketId, 1e6, 0));
        else if (mode == 5) data = abi.encodeCall(PredictionMarket.redeem, (marketId));
        address target = mode == 4 ? address(book) : address(pm);
        if (mode == 4) data = abi.encodeCall(OrderBook.cancelOrder, (orderId));
        (bool ok, bytes memory ret) = target.call(data);
        require(!ok, "re-entrancy succeeded");
        reentryError = ret;
    }

    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external returns (bytes4) {
        _reenter();
        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata)
        external
        returns (bytes4)
    {
        _reenter();
        return this.onERC1155BatchReceived.selector;
    }

    function supportsInterface(bytes4 id) external pure returns (bool) {
        return id == type(IERC1155Receiver).interfaceId || id == type(IERC165).interfaceId;
    }
}

/// @dev Malicious collateral whose transfer hook tries to re-enter redeem() (ERC777-style callback).
contract HookToken is ERC20 {
    PredictionMarket internal pm;
    uint256 public marketId;
    bool public armed;
    bool public reentryBlocked;

    constructor(PredictionMarket pm_) ERC20("Hook", "HOOK") {
        pm = pm_;
    }

    function mint(address to, uint256 v) external {
        _mint(to, v);
    }

    function arm(uint256 id) external {
        marketId = id;
        armed = true;
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (armed && from == address(pm)) {
            armed = false;
            try pm.redeem(marketId) {
                reentryBlocked = false;
            } catch (bytes memory reason) {
                reentryBlocked = bytes4(reason) == ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector;
            }
        }
    }
}

contract SecurityTest is BaseTest {
    uint256 internal id;
    ReentrantReceiver internal attacker;

    function setUp() public override {
        super.setUp();
        id = _createBinaryUsdt();
        attacker = new ReentrantReceiver(pm, book);
        usdt.mint(address(attacker), 10_000e6);
        attacker.approve(IERC20(address(usdt)));
    }

    function _assertGuardError() internal view {
        assertEq(bytes4(attacker.reentryError()), ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
    }

    function test_reentrancy_buyHookCannotReenterBuy() public {
        attacker.setup(id, 1, 0);
        attacker.doBuy(100e6);
        assertTrue(attacker.attempted());
        _assertGuardError();
        _assertBacked(id);
    }

    function test_reentrancy_buyHookCannotReenterSell() public {
        attacker.setup(id, 2, 0);
        attacker.doBuy(100e6);
        _assertGuardError();
    }

    function test_reentrancy_removeLiquidityHookCannotReenter() public {
        attacker.setup(id, 0, 0);
        attacker.doAddLiquidity(500e6);
        _buy(bob, id, 0, 200e6); // imbalance -> removal returns outcome tokens (hook fires)
        attacker.setup(id, 3, 0);
        attacker.doRemoveLiquidity(100e6);
        _assertGuardError();
        _assertBacked(id);
    }

    function test_reentrancy_splitHookCannotRedeemOrBuy() public {
        attacker.setup(id, 5, 0);
        attacker.doSplit(10e6);
        _assertGuardError();
    }

    function test_reentrancy_orderBookCancelHookCannotDoubleCancel() public {
        attacker.setup(id, 0, 0);
        attacker.doSplit(50e6);
        uint256 oid = attacker.doPlaceAsk(20e6);
        attacker.setup(id, 4, oid);
        attacker.doCancel(oid); // refund transfer triggers the hook, which tries to cancel again
        _assertGuardError();
        assertEq(pm.balanceOf(address(book), pm.positionId(id, 0)), 0);
        assertEq(_bal(address(attacker), id, 0), 50e6);
    }

    function test_reentrancy_collateralHookCannotDoubleRedeem() public {
        HookToken hook = new HookToken(pm);
        vm.prank(admin);
        pm.setCollateral(IERC20(address(hook)), true, 1);
        hook.mint(alice, 1000e18);
        hook.mint(bob, 1000e18);
        vm.prank(alice);
        hook.approve(address(pm), type(uint256).max);
        vm.prank(bob);
        hook.approve(address(pm), type(uint256).max);
        uint256 m = _create(alice, _params(IERC20(address(hook)), 2, 100e18, dave));
        uint256 shares = _buy(bob, m, 0, 10e18);
        _warpToResolution(m);
        vm.prank(dave);
        pm.reportOutcome(m, 0);
        hook.arm(m);
        uint256 before = hook.balanceOf(bob);
        vm.prank(bob);
        pm.redeem(m);
        assertTrue(hook.reentryBlocked());
        assertEq(hook.balanceOf(bob), before + shares); // paid exactly once
    }

    function test_donationsDoNotAffectPricesOrAccounting() public {
        uint256[] memory before = pm.getPrices(id);
        vm.prank(bob);
        usdt.transfer(address(pm), 5000e6); // direct ERC20 donation
        uint256[] memory afterP = pm.getPrices(id);
        assertEq(afterP[0], before[0]);
        assertEq(pm.getMarket(id).collateralLocked, 1000e6);
        // ERC1155 transfers to the market contract itself are rejected (it is not a receiver)
        _buy(bob, id, 0, 10e6);
        uint256 yes = pm.positionId(id, 0);
        vm.prank(bob);
        vm.expectRevert();
        pm.safeTransferFrom(bob, address(pm), yes, 1, "");
    }

    function test_arbitratorCannotReportForOtherMarkets() public {
        PredictionMarket.CreateMarketParams memory p = _params(IERC20(address(usdt)), 2, 100e6, frank);
        uint256 other = _create(alice, p);
        _warpToResolution(other);
        vm.prank(dave); // dave arbitrates `id`, not `other`
        vm.expectRevert(abi.encodeWithSelector(PredictionMarket.NotArbitrator.selector, dave, frank));
        pm.reportOutcome(other, 0);
    }

    function test_marketsAreIsolated() public {
        uint256 m2 = _create(carol, _params(IERC20(address(usdt)), 2, 500e6, frank));
        _buy(bob, id, 0, 100e6);
        _buy(bob, m2, 1, 50e6);
        _warpToResolution(m2);
        vm.prank(frank);
        pm.reportOutcome(m2, 1);
        vm.prank(bob);
        pm.redeem(m2);
        // market 1 accounting untouched by market 2's payouts
        _assertBacked(id);
        PredictionMarket.MarketView memory v1 = pm.getMarket(id);
        PredictionMarket.MarketView memory v2 = pm.getMarket(m2);
        assertEq(usdt.balanceOf(address(pm)), v1.collateralLocked + v1.feePool + v2.collateralLocked + v2.feePool);
    }
}

/// @dev Token that can switch on a transfer fee after markets exist (as USDT's `basisPointsRate` could).
contract ToggleFeeToken is ERC20 {
    bool public feeOn;

    constructor() ERC20("Toggle", "TGL") {}

    function mint(address to, uint256 v) external {
        _mint(to, v);
    }

    function setFee(bool on) external {
        feeOn = on;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (feeOn && from != address(0) && to != address(0)) {
            uint256 fee = value / 100;
            super._update(from, address(0), fee);
            super._update(from, to, value - fee);
        } else {
            super._update(from, to, value);
        }
    }
}

contract FeeToggleTest is BaseTest {
    function test_transferFeeEnabledLater_isRejectedEverywhere() public {
        ToggleFeeToken t = new ToggleFeeToken();
        vm.prank(admin);
        pm.setCollateral(IERC20(address(t)), true, 1e18);
        t.mint(alice, 1000e18);
        t.mint(bob, 1000e18);
        vm.prank(alice);
        t.approve(address(pm), type(uint256).max);
        vm.startPrank(bob);
        t.approve(address(pm), type(uint256).max);
        t.approve(address(book), type(uint256).max);
        vm.stopPrank();
        uint256 m = _create(alice, _params(IERC20(address(t)), 2, 100e18, dave));

        t.setFee(true);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(PredictionMarket.FeeOnTransferNotSupported.selector, 10e18, 9.9e18));
        pm.buy(m, 0, 10e18, 0);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(OrderBook.FeeOnTransferNotSupported.selector, 5e18, 4.95e18));
        book.placeOrder(m, 0, OrderBook.Side.Buy, 5000, 10e18, 0);
    }
}
