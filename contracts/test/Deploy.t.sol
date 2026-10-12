// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Deploy} from "../script/Deploy.s.sol";
import {PredictionMarket} from "../src/PredictionMarket.sol";
import {OrderBook} from "../src/OrderBook.sol";
import {ReputationOracle} from "../src/ReputationOracle.sol";

contract DeployScriptTest is Test {
    string internal constant OUT = "deployments/.deploy-test.json";

    function test_deployScript_deploysAndConfiguresEverything() public {
        address r1 = makeAddr("r1");
        address r2 = makeAddr("r2");
        string memory out = string.concat(vm.projectRoot(), "/", OUT);
        vm.setEnv("DEPLOY_OUT", out);
        vm.setEnv("REPORTERS", string.concat(vm.toString(r1), ",", vm.toString(r2)));
        vm.setEnv("PRIVATE_KEY", vm.toString(uint256(0xA11CE)));
        Deploy.Deployment memory d = new Deploy().run();
        vm.setEnv("REPORTERS", "");
        vm.setEnv("PRIVATE_KEY", "0");

        address deployer = vm.addr(0xA11CE);
        PredictionMarket pm = PredictionMarket(d.predictionMarket);
        assertEq(pm.owner(), deployer);
        (bool allowed,, uint256 minLiq) = pm.collateralConfig(IERC20(d.usdt));
        assertTrue(allowed);
        assertEq(minLiq, 10e6);
        (allowed,,) = pm.collateralConfig(IERC20(d.dai));
        assertTrue(allowed);
        (allowed,,) = pm.collateralConfig(IERC20(d.weth));
        assertTrue(allowed);
        assertEq(address(OrderBook(d.orderBook).market()), d.predictionMarket);
        ReputationOracle oracle = ReputationOracle(d.reputationOracle);
        assertEq(address(oracle.market()), d.predictionMarket);
        assertEq(oracle.votingPeriod(), 1 days);
        assertEq(oracle.quorumBps(), 5000);
        assertEq(oracle.activeReporters(), 2);
        assertEq(oracle.totalReputation(), 200);

        string memory json = vm.readFile(out);
        assertEq(vm.parseJsonAddress(json, ".PredictionMarket"), d.predictionMarket);
        assertEq(vm.parseJsonAddress(json, ".USDT"), d.usdt);
        assertEq(vm.parseJsonUint(json, ".chainId"), block.chainid);
        vm.removeFile(out);
    }
}
