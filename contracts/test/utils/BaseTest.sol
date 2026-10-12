// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {PredictionMarket} from "../../src/PredictionMarket.sol";
import {OrderBook} from "../../src/OrderBook.sol";
import {ReputationOracle} from "../../src/ReputationOracle.sol";
import {IPredictionMarket} from "../../src/interfaces/IPredictionMarket.sol";
import {MockUSDT} from "../../src/tokens/MockUSDT.sol";
import {MockERC20} from "../../src/tokens/MockERC20.sol";
import {WETH9} from "../../src/tokens/WETH9.sol";

/// @dev Shared fixture: tokens with 6 and 18 decimals, the market, order book and reputation oracle,
///      funded actors and helpers for creating markets and trading.
abstract contract BaseTest is Test {
    PredictionMarket internal pm;
    OrderBook internal book;
    ReputationOracle internal oracle;
    MockUSDT internal usdt; // 6 decimals, no return values (Tether-like)
    MockERC20 internal dai; // 18 decimals, standard OZ ERC20
    WETH9 internal weth; // 18 decimals

    address internal admin = makeAddr("admin");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal dave = makeAddr("dave"); // arbitrator
    address internal eve = makeAddr("eve");
    address internal frank = makeAddr("frank");
    address internal grace = makeAddr("grace");
    address internal heidi = makeAddr("heidi");

    uint64 internal constant VOTING_PERIOD = 1 days;
    uint16 internal constant QUORUM_BPS = 5000;
    uint8 internal constant INVALID = type(uint8).max;

    uint256 internal constant USDT_MIN_LIQ = 10e6;
    uint256 internal constant DAI_MIN_LIQ = 10e18;
    uint256 internal constant WETH_MIN_LIQ = 0.01 ether;

    function setUp() public virtual {
        vm.warp(1_750_000_000);
        usdt = new MockUSDT();
        dai = new MockERC20("Dai Stablecoin (Mock)", "DAI", 18, 10_000e18);
        weth = new WETH9();

        pm = new PredictionMarket(admin);
        book = new OrderBook(IPredictionMarket(address(pm)));
        oracle = new ReputationOracle(IPredictionMarket(address(pm)), VOTING_PERIOD, QUORUM_BPS, admin);

        vm.startPrank(admin);
        pm.setCollateral(IERC20(address(usdt)), true, USDT_MIN_LIQ);
        pm.setCollateral(IERC20(address(dai)), true, DAI_MIN_LIQ);
        pm.setCollateral(IERC20(address(weth)), true, WETH_MIN_LIQ);
        vm.stopPrank();

        address[9] memory actors = [admin, alice, bob, carol, dave, eve, frank, grace, heidi];
        for (uint256 i; i < actors.length; ++i) {
            _fund(actors[i]);
        }
    }

    // ------------------------------------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------------------------------------

    function _fund(address who) internal {
        usdt.mint(who, 1_000_000e6);
        dai.mint(who, 1_000_000e18);
        vm.deal(who, 2000 ether);
        vm.prank(who);
        weth.deposit{value: 1000 ether}();
        vm.startPrank(who);
        usdt.approve(address(pm), type(uint256).max);
        usdt.approve(address(book), type(uint256).max);
        dai.approve(address(pm), type(uint256).max);
        dai.approve(address(book), type(uint256).max);
        weth.approve(address(pm), type(uint256).max);
        weth.approve(address(book), type(uint256).max);
        pm.setApprovalForAll(address(book), true);
        vm.stopPrank();
    }

    function _labels(uint256 n) internal pure returns (string[] memory labels) {
        labels = new string[](n);
        if (n == 2) {
            labels[0] = "Yes";
            labels[1] = "No";
            return labels;
        }
        string[8] memory names = ["A", "B", "C", "D", "E", "F", "G", "H"];
        for (uint256 i; i < n; ++i) {
            labels[i] = names[i];
        }
    }

    function _params(IERC20 collateral, uint256 n, uint256 liquidity, address arbitrator)
        internal
        view
        returns (PredictionMarket.CreateMarketParams memory p)
    {
        p.question = "Will it happen?";
        p.category = "Test";
        p.outcomeLabels = _labels(n);
        p.closeTime = uint64(block.timestamp + 7 days);
        p.resolutionTime = uint64(block.timestamp + 8 days);
        p.arbitrator = arbitrator;
        p.collateral = collateral;
        p.initialLiquidity = liquidity;
        p.initialOddsBps = new uint16[](0);
        p.feeBps = 200;
    }

    function _create(address creator, PredictionMarket.CreateMarketParams memory p) internal returns (uint256 id) {
        vm.prank(creator);
        id = pm.createMarket(p);
    }

    /// @dev Binary USDT market, 1,000 USDT liquidity from alice, arbitrated by dave, 2 % fee.
    function _createBinaryUsdt() internal returns (uint256) {
        return _create(alice, _params(IERC20(address(usdt)), 2, 1000e6, dave));
    }

    function _buy(address who, uint256 id, uint8 outcome, uint256 amount) internal returns (uint256 shares) {
        vm.prank(who);
        shares = pm.buy(id, outcome, amount, 0);
    }

    function _sell(address who, uint256 id, uint8 outcome, uint256 shares) internal returns (uint256 out) {
        vm.prank(who);
        out = pm.sell(id, outcome, shares, 0);
    }

    function _bal(address who, uint256 id, uint8 outcome) internal view returns (uint256) {
        return pm.balanceOf(who, pm.positionId(id, outcome));
    }

    function _market(uint256 id) internal view returns (PredictionMarket.MarketView memory) {
        return pm.getMarket(id);
    }

    function _sum(uint256[] memory a) internal pure returns (uint256 s) {
        for (uint256 i; i < a.length; ++i) {
            s += a[i];
        }
    }

    /// @dev Core solvency identity before resolution: supply_i + pool_i == collateralLocked for every outcome.
    function _assertBacked(uint256 id) internal view {
        PredictionMarket.MarketView memory v = pm.getMarket(id);
        for (uint256 i; i < v.numOutcomes; ++i) {
            assertEq(v.outcomeSupply[i] + v.pool[i], v.collateralLocked, "outcome not fully backed");
        }
    }

    function _warpToResolution(uint256 id) internal {
        vm.warp(pm.getMarket(id).resolutionTime);
    }
}
