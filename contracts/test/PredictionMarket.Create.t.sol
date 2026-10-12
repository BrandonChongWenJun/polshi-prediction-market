// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

import {BaseTest} from "./utils/BaseTest.sol";
import {PredictionMarket} from "../src/PredictionMarket.sol";
import {IPredictionMarket} from "../src/interfaces/IPredictionMarket.sol";

/// @dev ERC20 that burns 1 % on every transfer (must be rejected as collateral).
contract FeeOnTransferToken is ERC20 {
    constructor() ERC20("Fee Token", "FEE") {}

    function mint(address to, uint256 v) external {
        _mint(to, v);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) {
            uint256 fee = value / 100;
            super._update(from, address(0), fee);
            super._update(from, to, value - fee);
        } else {
            super._update(from, to, value);
        }
    }
}

contract PredictionMarketCreateTest is BaseTest {
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
    event CollateralConfigured(address indexed token, bool allowed, uint256 minLiquidity);

    function test_createBinaryMarket_uniformOdds() public {
        PredictionMarket.CreateMarketParams memory p = _params(IERC20(address(usdt)), 2, 1000e6, dave);
        uint256 balBefore = usdt.balanceOf(alice);

        vm.expectEmit(true, true, true, true, address(pm));
        emit MarketCreated(
            1, alice, dave, address(usdt), p.closeTime, p.resolutionTime, 200, p.question, p.category, p.outcomeLabels
        );
        uint256 id = _create(alice, p);

        assertEq(id, 1);
        assertEq(pm.marketCount(), 1);
        PredictionMarket.MarketView memory v = pm.getMarket(id);
        assertEq(v.creator, alice);
        assertEq(v.arbitrator, dave);
        assertEq(v.collateral, address(usdt));
        assertEq(v.numOutcomes, 2);
        assertEq(v.closeTime, p.closeTime);
        assertEq(v.resolutionTime, p.resolutionTime);
        assertEq(v.feeBps, 200);
        assertEq(v.createdAt, block.timestamp);
        assertEq(v.collateralLocked, 1000e6);
        assertEq(v.totalLpShares, 1000e6);
        assertEq(v.pool[0], 1000e6);
        assertEq(v.pool[1], 1000e6);
        assertEq(v.prices[0], 0.5e18);
        assertEq(v.prices[1], 0.5e18);
        assertEq(v.question, "Will it happen?");
        assertEq(v.category, "Test");
        assertEq(v.outcomeLabels[0], "Yes");
        assertEq(v.outcomeLabels[1], "No");
        assertEq(uint8(v.phase), uint8(PredictionMarket.Phase.Trading));
        assertFalse(v.resolved);

        assertEq(pm.lpShares(id, alice), 1000e6);
        assertEq(usdt.balanceOf(alice), balBefore - 1000e6);
        assertEq(usdt.balanceOf(address(pm)), 1000e6);
        // uniform odds: the pool keeps everything, the creator gets no outcome tokens
        assertEq(_bal(alice, id, 0), 0);
        assertEq(_bal(alice, id, 1), 0);
        _assertBacked(id);

        IPredictionMarket.MarketCore memory core = pm.getMarketCore(id);
        assertEq(core.collateral, address(usdt));
        assertEq(core.arbitrator, dave);
        assertEq(core.numOutcomes, 2);
        assertFalse(core.resolved);
    }

    function test_createWithInitialOdds_setsPricesAndReturnsTokens() public {
        PredictionMarket.CreateMarketParams memory p = _params(IERC20(address(usdt)), 2, 1000e6, dave);
        p.initialOddsBps = new uint16[](2);
        p.initialOddsBps[0] = 7000;
        p.initialOddsBps[1] = 3000;
        uint256 id = _create(alice, p);

        PredictionMarket.MarketView memory v = pm.getMarket(id);
        // b_i = F * minOdds / odds_i  -> [1000 * 0.3/0.7, 1000]
        assertEq(v.pool[1], 1000e6);
        assertEq(v.pool[0], (uint256(1000e6) * 3000) / 7000);
        assertApproxEqAbs(v.prices[0], 0.7e18, 1e12);
        assertApproxEqAbs(v.prices[1], 0.3e18, 1e12);
        // creator received the tokens the pool does not keep
        assertEq(_bal(alice, id, 0), 1000e6 - v.pool[0]);
        assertEq(_bal(alice, id, 1), 0);
        _assertBacked(id);
    }

    function test_createMultiOutcome_withOdds() public {
        PredictionMarket.CreateMarketParams memory p = _params(IERC20(address(dai)), 4, 500e18, dave);
        p.initialOddsBps = new uint16[](4);
        p.initialOddsBps[0] = 4000;
        p.initialOddsBps[1] = 3000;
        p.initialOddsBps[2] = 2000;
        p.initialOddsBps[3] = 1000;
        uint256 id = _create(bob, p);
        PredictionMarket.MarketView memory v = pm.getMarket(id);
        assertEq(v.numOutcomes, 4);
        assertApproxEqAbs(v.prices[0], 0.4e18, 1e9);
        assertApproxEqAbs(v.prices[1], 0.3e18, 1e9);
        assertApproxEqAbs(v.prices[2], 0.2e18, 1e9);
        assertApproxEqAbs(v.prices[3], 0.1e18, 1e9);
        assertApproxEqAbs(_sum(v.prices), 1e18, 10);
        _assertBacked(id);
    }

    function test_createEightOutcomes() public {
        uint256 id = _create(alice, _params(IERC20(address(weth)), 8, 1 ether, dave));
        PredictionMarket.MarketView memory v = pm.getMarket(id);
        assertEq(v.numOutcomes, 8);
        for (uint256 i; i < 8; ++i) {
            assertEq(v.prices[i], 0.125e18);
        }
    }

    function test_positionIdEncoding() public view {
        assertEq(pm.positionId(1, 0), 256);
        assertEq(pm.positionId(1, 1), 257);
        assertEq(pm.positionId(3, 7), (3 << 8) | 7);
    }

    function test_getMarketCore_nonexistent_isZero() public view {
        IPredictionMarket.MarketCore memory core = pm.getMarketCore(42);
        assertEq(core.numOutcomes, 0);
        assertEq(core.arbitrator, address(0));
    }

    // ------------------------------------------------------------------ validation reverts

    function test_revert_collateralNotAllowed() public {
        PredictionMarket.CreateMarketParams memory p = _params(IERC20(address(0xBEEF)), 2, 1000e6, dave);
        vm.expectRevert(abi.encodeWithSelector(PredictionMarket.CollateralNotAllowed.selector, address(0xBEEF)));
        _create(alice, p);
    }

    function test_revert_outcomeCount() public {
        PredictionMarket.CreateMarketParams memory p = _params(IERC20(address(usdt)), 2, 1000e6, dave);
        p.outcomeLabels = new string[](1);
        p.outcomeLabels[0] = "Only";
        vm.expectRevert(abi.encodeWithSelector(PredictionMarket.InvalidOutcomeCount.selector, 1));
        _create(alice, p);

        p.outcomeLabels = new string[](9);
        for (uint256 i; i < 9; ++i) {
            p.outcomeLabels[i] = "x";
        }
        vm.expectRevert(abi.encodeWithSelector(PredictionMarket.InvalidOutcomeCount.selector, 9));
        _create(alice, p);
    }

    function test_revert_invalidTimes() public {
        PredictionMarket.CreateMarketParams memory p = _params(IERC20(address(usdt)), 2, 1000e6, dave);
        p.closeTime = uint64(block.timestamp);
        vm.expectRevert(PredictionMarket.InvalidTimes.selector);
        _create(alice, p);

        p = _params(IERC20(address(usdt)), 2, 1000e6, dave);
        p.resolutionTime = p.closeTime - 1;
        vm.expectRevert(PredictionMarket.InvalidTimes.selector);
        _create(alice, p);

        p = _params(IERC20(address(usdt)), 2, 1000e6, dave);
        p.closeTime = uint64(block.timestamp + pm.MAX_DURATION() + 1);
        p.resolutionTime = p.closeTime;
        vm.expectRevert(PredictionMarket.InvalidTimes.selector);
        _create(alice, p);

        p = _params(IERC20(address(usdt)), 2, 1000e6, dave);
        p.resolutionTime = uint64(p.closeTime + pm.MAX_DURATION() + 1);
        vm.expectRevert(PredictionMarket.InvalidTimes.selector);
        _create(alice, p);
    }

    function test_resolutionTimeEqualToCloseTime_isAllowed() public {
        PredictionMarket.CreateMarketParams memory p = _params(IERC20(address(usdt)), 2, 1000e6, dave);
        p.resolutionTime = p.closeTime;
        uint256 id = _create(alice, p);
        assertEq(pm.getMarket(id).resolutionTime, p.closeTime);
    }

    function test_revert_zeroArbitrator() public {
        PredictionMarket.CreateMarketParams memory p = _params(IERC20(address(usdt)), 2, 1000e6, address(0));
        vm.expectRevert(PredictionMarket.InvalidArbitrator.selector);
        _create(alice, p);
    }

    function test_revert_feeTooHigh() public {
        PredictionMarket.CreateMarketParams memory p = _params(IERC20(address(usdt)), 2, 1000e6, dave);
        p.feeBps = 501;
        vm.expectRevert(abi.encodeWithSelector(PredictionMarket.FeeTooHigh.selector, 501, 500));
        _create(alice, p);
    }

    function test_revert_liquidityTooLow() public {
        PredictionMarket.CreateMarketParams memory p = _params(IERC20(address(usdt)), 2, USDT_MIN_LIQ - 1, dave);
        vm.expectRevert(
            abi.encodeWithSelector(PredictionMarket.LiquidityTooLow.selector, USDT_MIN_LIQ - 1, USDT_MIN_LIQ)
        );
        _create(alice, p);
    }

    function test_revert_invalidText() public {
        PredictionMarket.CreateMarketParams memory p = _params(IERC20(address(usdt)), 2, 1000e6, dave);
        p.question = "";
        vm.expectRevert(PredictionMarket.InvalidText.selector);
        _create(alice, p);

        p = _params(IERC20(address(usdt)), 2, 1000e6, dave);
        p.question = string(new bytes(281));
        vm.expectRevert(PredictionMarket.InvalidText.selector);
        _create(alice, p);

        p = _params(IERC20(address(usdt)), 2, 1000e6, dave);
        p.category = string(new bytes(33));
        vm.expectRevert(PredictionMarket.InvalidText.selector);
        _create(alice, p);

        p = _params(IERC20(address(usdt)), 2, 1000e6, dave);
        p.outcomeLabels[1] = "";
        vm.expectRevert(PredictionMarket.InvalidText.selector);
        _create(alice, p);

        p = _params(IERC20(address(usdt)), 2, 1000e6, dave);
        p.outcomeLabels[0] = string(new bytes(49));
        vm.expectRevert(PredictionMarket.InvalidText.selector);
        _create(alice, p);
    }

    function test_emptyCategory_isAllowed() public {
        PredictionMarket.CreateMarketParams memory p = _params(IERC20(address(usdt)), 2, 1000e6, dave);
        p.category = "";
        uint256 id = _create(alice, p);
        assertEq(pm.getMarket(id).category, "");
    }

    function test_revert_invalidOdds() public {
        PredictionMarket.CreateMarketParams memory p = _params(IERC20(address(usdt)), 2, 1000e6, dave);
        p.initialOddsBps = new uint16[](3);
        p.initialOddsBps[0] = 5000;
        p.initialOddsBps[1] = 3000;
        p.initialOddsBps[2] = 2000;
        vm.expectRevert(PredictionMarket.InvalidOdds.selector); // length mismatch
        _create(alice, p);

        p.initialOddsBps = new uint16[](2);
        p.initialOddsBps[0] = 9950;
        p.initialOddsBps[1] = 50;
        vm.expectRevert(PredictionMarket.InvalidOdds.selector); // below 1 %
        _create(alice, p);

        p.initialOddsBps[0] = 6000;
        p.initialOddsBps[1] = 3000;
        vm.expectRevert(PredictionMarket.InvalidOdds.selector); // sum != 100 %
        _create(alice, p);
    }

    function test_revert_oddsRoundPoolBalanceToZero() public {
        vm.prank(admin);
        pm.setCollateral(IERC20(address(usdt)), true, 1);
        PredictionMarket.CreateMarketParams memory p = _params(IERC20(address(usdt)), 2, 1, dave);
        p.initialOddsBps = new uint16[](2);
        p.initialOddsBps[0] = 9900;
        p.initialOddsBps[1] = 100; // b_0 = 1 * 100 / 9900 = 0
        vm.expectRevert(PredictionMarket.InvalidOdds.selector);
        _create(alice, p);
    }

    function test_revert_createWhenPaused() public {
        vm.prank(admin);
        pm.pause();
        PredictionMarket.CreateMarketParams memory p = _params(IERC20(address(usdt)), 2, 1000e6, dave);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        _create(alice, p);
    }

    function test_revert_createWithoutAllowance() public {
        address stranger = makeAddr("stranger");
        usdt.mint(stranger, 1000e6);
        PredictionMarket.CreateMarketParams memory p = _params(IERC20(address(usdt)), 2, 1000e6, dave);
        vm.expectRevert(); // MockUSDT.InsufficientAllowance bubbles through SafeERC20
        _create(stranger, p);
    }

    function test_revert_feeOnTransferCollateral() public {
        FeeOnTransferToken fot = new FeeOnTransferToken();
        vm.prank(admin);
        pm.setCollateral(IERC20(address(fot)), true, 1);
        fot.mint(alice, 1000e18);
        vm.prank(alice);
        fot.approve(address(pm), type(uint256).max);
        PredictionMarket.CreateMarketParams memory p = _params(IERC20(address(fot)), 2, 100e18, dave);
        vm.expectRevert(abi.encodeWithSelector(PredictionMarket.FeeOnTransferNotSupported.selector, 100e18, 99e18));
        _create(alice, p);
    }

    // ------------------------------------------------------------------ admin

    function test_setCollateral_onlyOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        pm.setCollateral(IERC20(address(usdt)), false, 0);
    }

    function test_setCollateral_zeroAddressReverts() public {
        vm.prank(admin);
        vm.expectRevert(PredictionMarket.InvalidCollateral.selector);
        pm.setCollateral(IERC20(address(0)), true, 0);
    }

    function test_setCollateral_disableBlocksNewMarketsOnly() public {
        uint256 id = _createBinaryUsdt();
        vm.expectEmit(true, false, false, true, address(pm));
        emit CollateralConfigured(address(usdt), false, USDT_MIN_LIQ);
        vm.prank(admin);
        pm.setCollateral(IERC20(address(usdt)), false, USDT_MIN_LIQ);

        PredictionMarket.CreateMarketParams memory p = _params(IERC20(address(usdt)), 2, 1000e6, dave);
        vm.expectRevert(abi.encodeWithSelector(PredictionMarket.CollateralNotAllowed.selector, address(usdt)));
        _create(alice, p);

        // the existing market keeps working
        uint256 shares = _buy(bob, id, 0, 10e6);
        assertGt(shares, 0);

        (address[] memory tokens, bool[] memory allowed, uint256[] memory mins) = pm.getCollaterals();
        assertEq(tokens.length, 3); // re-configuring does not duplicate the list entry
        assertEq(tokens[0], address(usdt));
        assertFalse(allowed[0]);
        assertEq(mins[0], USDT_MIN_LIQ);
        assertTrue(allowed[1]);
    }

    function test_zeroMinLiquidity_treatedAsOne() public {
        vm.prank(admin);
        pm.setCollateral(IERC20(address(usdt)), true, 0);
        PredictionMarket.CreateMarketParams memory p = _params(IERC20(address(usdt)), 2, 0, dave);
        vm.expectRevert(abi.encodeWithSelector(PredictionMarket.LiquidityTooLow.selector, 0, 1));
        _create(alice, p);
    }

    function test_pause_onlyOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob));
        vm.prank(bob);
        pm.pause();
        vm.prank(admin);
        pm.pause();
        assertTrue(pm.paused());
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob));
        vm.prank(bob);
        pm.unpause();
        vm.prank(admin);
        pm.unpause();
        assertFalse(pm.paused());
    }

    function test_ownershipTransfer_isTwoStep() public {
        vm.prank(admin);
        pm.transferOwnership(bob);
        assertEq(pm.owner(), admin);
        assertEq(pm.pendingOwner(), bob);
        vm.prank(bob);
        pm.acceptOwnership();
        assertEq(pm.owner(), bob);
    }

    function test_supportsInterface() public view {
        assertTrue(pm.supportsInterface(0xd9b67a26)); // ERC1155
        assertTrue(pm.supportsInterface(0x01ffc9a7)); // ERC165
        assertFalse(pm.supportsInterface(0xffffffff));
    }

    function test_revert_viewsOnMissingMarket() public {
        vm.expectRevert(abi.encodeWithSelector(PredictionMarket.MarketNotFound.selector, 7));
        pm.getMarket(7);
        vm.expectRevert(abi.encodeWithSelector(PredictionMarket.MarketNotFound.selector, 7));
        pm.getPrices(7);
        vm.expectRevert(abi.encodeWithSelector(PredictionMarket.MarketNotFound.selector, 7));
        pm.phase(7);
    }
}
