// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Script, console} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {PredictionMarket} from "../src/PredictionMarket.sol";
import {OrderBook} from "../src/OrderBook.sol";
import {ReputationOracle} from "../src/ReputationOracle.sol";
import {IPredictionMarket} from "../src/interfaces/IPredictionMarket.sol";
import {MockUSDT} from "../src/tokens/MockUSDT.sol";
import {MockERC20} from "../src/tokens/MockERC20.sol";
import {WETH9} from "../src/tokens/WETH9.sol";

/// @title Deploy
/// @notice Deploys the whole system (collateral tokens, PredictionMarket, OrderBook, ReputationOracle) and writes
///         `deployments/<chainId>.json` for the front-end.
///
/// Local (anvil):
///   forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8554 --private-key $ANVIL_KEY0 --broadcast
/// Public testnet (e.g. Sepolia):
///   forge script script/Deploy.s.sol --rpc-url $SEPOLIA_RPC_URL --private-key $PRIVATE_KEY --broadcast
///   (or export PRIVATE_KEY and omit --private-key; `--account <keystore>` also works)
///
/// Optional environment variables:
///   PRIVATE_KEY     broadcaster key (otherwise the --private-key / --account CLI signer is used)
///   OWNER           final admin of the market and oracle (2-step transfer; must call acceptOwnership)
///   USDT_ADDRESS    use an existing USDT-like token instead of deploying MockUSDT (6 decimals)
///   DAI_ADDRESS     use an existing 18-decimal stablecoin instead of deploying the mock DAI
///   WETH_ADDRESS    use the canonical WETH (Sepolia: 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14)
///   REPORTERS       comma-separated addresses registered as reputation-oracle reporters
///   VOTING_PERIOD   oracle voting window in seconds (default 1 day)
///   QUORUM_BPS      oracle quorum in bps of total reputation (default 5000)
///   DEPLOY_OUT      output file (default deployments/<chainId>.json; must stay inside deployments/, see
///                   fs_permissions in foundry.toml)
contract Deploy is Script {
    struct Deployment {
        address predictionMarket;
        address orderBook;
        address reputationOracle;
        address usdt;
        address dai;
        address weth;
        address owner;
        uint256 startBlock;
    }

    function run() external returns (Deployment memory d) {
        uint256 pk = vm.envOr("PRIVATE_KEY", uint256(0));
        if (pk != 0) vm.startBroadcast(pk);
        else vm.startBroadcast();
        (VmSafe.CallerMode mode, address deployer,) = vm.readCallers();
        require(mode == VmSafe.CallerMode.RecurrentBroadcast, "broadcast not active");

        d.startBlock = block.number;
        d.owner = vm.envOr("OWNER", deployer);
        uint64 votingPeriod = uint64(vm.envOr("VOTING_PERIOD", uint256(1 days)));
        uint16 quorumBps = uint16(vm.envOr("QUORUM_BPS", uint256(5000)));

        d.usdt = vm.envOr("USDT_ADDRESS", address(0));
        if (d.usdt == address(0)) d.usdt = address(new MockUSDT());
        d.dai = vm.envOr("DAI_ADDRESS", address(0));
        if (d.dai == address(0)) d.dai = address(new MockERC20("Dai Stablecoin (Mock)", "DAI", 18, 10_000e18));
        d.weth = vm.envOr("WETH_ADDRESS", address(0));
        if (d.weth == address(0)) d.weth = address(new WETH9());

        PredictionMarket pm = new PredictionMarket(deployer);
        pm.setCollateral(IERC20(d.usdt), true, 10e6); // min 10 USDT initial liquidity
        pm.setCollateral(IERC20(d.dai), true, 10e18); // min 10 DAI
        pm.setCollateral(IERC20(d.weth), true, 0.005 ether); // min 0.005 WETH
        OrderBook book = new OrderBook(IPredictionMarket(address(pm)));
        ReputationOracle oracle =
            new ReputationOracle(IPredictionMarket(address(pm)), votingPeriod, quorumBps, deployer);

        address[] memory reporters = vm.envOr("REPORTERS", ",", new address[](0));
        for (uint256 i; i < reporters.length; ++i) {
            oracle.registerReporter(reporters[i]);
        }
        if (d.owner != deployer) {
            pm.transferOwnership(d.owner);
            oracle.transferOwnership(d.owner);
        }
        vm.stopBroadcast();

        d.predictionMarket = address(pm);
        d.orderBook = address(book);
        d.reputationOracle = address(oracle);
        _write(d);
    }

    function _write(Deployment memory d) internal {
        string memory key = "deployment";
        vm.serializeUint(key, "chainId", block.chainid);
        vm.serializeUint(key, "startBlock", d.startBlock);
        vm.serializeAddress(key, "owner", d.owner);
        vm.serializeAddress(key, "PredictionMarket", d.predictionMarket);
        vm.serializeAddress(key, "OrderBook", d.orderBook);
        vm.serializeAddress(key, "ReputationOracle", d.reputationOracle);
        vm.serializeAddress(key, "USDT", d.usdt);
        vm.serializeAddress(key, "DAI", d.dai);
        string memory json = vm.serializeAddress(key, "WETH", d.weth);
        string memory path = vm.envOr(
            "DEPLOY_OUT", string.concat(vm.projectRoot(), "/deployments/", vm.toString(block.chainid), ".json")
        );
        vm.writeJson(json, path);

        console.log("PredictionMarket ", d.predictionMarket);
        console.log("OrderBook        ", d.orderBook);
        console.log("ReputationOracle ", d.reputationOracle);
        console.log("USDT (6 dp)      ", d.usdt);
        console.log("DAI  (18 dp)     ", d.dai);
        console.log("WETH (18 dp)     ", d.weth);
        console.log("written to       ", path);
    }
}
