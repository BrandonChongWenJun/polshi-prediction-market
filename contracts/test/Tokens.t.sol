// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {MockUSDT} from "../src/tokens/MockUSDT.sol";
import {MockERC20} from "../src/tokens/MockERC20.sol";
import {WETH9} from "../src/tokens/WETH9.sol";

contract RejectEth {
    receive() external payable {
        revert("no");
    }

    function unwrap(WETH9 w, uint256 wad) external {
        w.withdraw(wad);
    }

    function wrap(WETH9 w) external payable {
        w.deposit{value: msg.value}();
    }
}

contract TokensTest is Test {
    using SafeERC20 for IERC20;

    MockUSDT internal usdt;
    MockERC20 internal dai;
    WETH9 internal weth;
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        usdt = new MockUSDT();
        dai = new MockERC20("Dai", "DAI", 18, 10_000e18);
        weth = new WETH9();
    }

    // ------------------------------------------------------------------ MockUSDT (Tether quirks)

    function test_usdt_metadataAndFaucet() public {
        assertEq(usdt.decimals(), 6);
        assertEq(usdt.symbol(), "USDT");
        vm.prank(alice);
        usdt.faucet();
        assertEq(usdt.balanceOf(alice), 10_000e6);
        assertEq(usdt.totalSupply(), 10_000e6);
    }

    function test_usdt_transferReturnsNoData_safeErc20Works() public {
        usdt.mint(address(this), 100e6);
        // a plain IERC20 call expects a bool and reverts on USDT's empty return data ...
        (bool ok, bytes memory ret) = address(usdt).call(abi.encodeCall(IERC20.transfer, (bob, 1e6)));
        assertTrue(ok);
        assertEq(ret.length, 0);
        // ... while SafeERC20 handles it
        IERC20(address(usdt)).safeTransfer(bob, 1e6);
        assertEq(usdt.balanceOf(bob), 2e6);
    }

    function test_usdt_approveNonZeroToNonZeroReverts() public {
        vm.startPrank(alice);
        usdt.approve(bob, 5);
        vm.expectRevert(MockUSDT.ApproveFromNonZero.selector);
        usdt.approve(bob, 6);
        usdt.approve(bob, 0);
        usdt.approve(bob, 6);
        vm.stopPrank();
        assertEq(usdt.allowance(alice, bob), 6);
    }

    function test_usdt_transferFromAndInfiniteAllowance() public {
        usdt.mint(alice, 100e6);
        vm.prank(alice);
        usdt.approve(bob, 10e6);
        vm.prank(bob);
        usdt.transferFrom(alice, bob, 4e6);
        assertEq(usdt.allowance(alice, bob), 6e6);
        vm.prank(bob);
        vm.expectRevert(MockUSDT.InsufficientAllowance.selector);
        usdt.transferFrom(alice, bob, 7e6);

        vm.prank(alice);
        usdt.approve(bob, 0);
        vm.prank(alice);
        usdt.approve(bob, type(uint256).max);
        vm.prank(bob);
        usdt.transferFrom(alice, bob, 50e6);
        assertEq(usdt.allowance(alice, bob), type(uint256).max);
    }

    function test_usdt_reverts() public {
        vm.expectRevert(MockUSDT.InsufficientBalance.selector);
        usdt.transfer(bob, 1);
        usdt.mint(address(this), 1);
        vm.expectRevert(MockUSDT.ZeroAddress.selector);
        usdt.transfer(address(0), 1);
        vm.expectRevert(MockUSDT.ZeroAddress.selector);
        usdt.mint(address(0), 1);
    }

    // ------------------------------------------------------------------ MockERC20 (DAI)

    function test_dai_decimalsAndFaucet() public {
        assertEq(dai.decimals(), 18);
        assertEq(dai.faucetAmount(), 10_000e18);
        vm.prank(alice);
        dai.faucet();
        dai.mint(bob, 5);
        assertEq(dai.balanceOf(alice), 10_000e18);
        assertEq(dai.balanceOf(bob), 5);
    }

    // ------------------------------------------------------------------ WETH9

    function test_weth_depositWithdraw() public {
        vm.deal(alice, 5 ether);
        vm.prank(alice);
        weth.deposit{value: 2 ether}();
        assertEq(weth.balanceOf(alice), 2 ether);
        assertEq(weth.totalSupply(), 2 ether);
        vm.prank(alice);
        (bool ok,) = address(weth).call{value: 1 ether}(""); // receive() wraps too
        assertTrue(ok);
        assertEq(weth.balanceOf(alice), 3 ether);
        vm.prank(alice);
        weth.withdraw(1.5 ether);
        assertEq(alice.balance, 3.5 ether);
        assertEq(weth.balanceOf(alice), 1.5 ether);
        vm.prank(alice);
        vm.expectRevert(WETH9.InsufficientBalance.selector);
        weth.withdraw(2 ether);
    }

    function test_weth_transfers() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        weth.deposit{value: 1 ether}();
        vm.prank(alice);
        assertTrue(weth.transfer(bob, 0.25 ether));
        vm.prank(alice);
        weth.approve(bob, 0.5 ether);
        vm.prank(bob);
        weth.transferFrom(alice, bob, 0.5 ether);
        assertEq(weth.balanceOf(bob), 0.75 ether);
        assertEq(weth.allowance(alice, bob), 0);
        vm.prank(bob);
        vm.expectRevert(WETH9.InsufficientAllowance.selector);
        weth.transferFrom(alice, bob, 0.1 ether);
        vm.prank(bob);
        vm.expectRevert(WETH9.InsufficientBalance.selector);
        weth.transfer(alice, 1 ether);
        vm.prank(alice);
        weth.approve(bob, type(uint256).max);
        vm.prank(bob);
        weth.transferFrom(alice, bob, 0.25 ether);
        assertEq(weth.allowance(alice, bob), type(uint256).max);
    }

    function test_weth_withdrawToRejectingContractReverts() public {
        RejectEth r = new RejectEth();
        vm.deal(address(this), 1 ether);
        r.wrap{value: 1 ether}(weth);
        vm.expectRevert(WETH9.EthTransferFailed.selector);
        r.unwrap(weth, 1 ether);
    }
}
