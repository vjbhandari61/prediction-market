// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {PredictionMarketFactory} from "../src/Factory.sol";

contract DeployFactory is Script {
    function run() external {
        // Read deployment config from environment
        address treasury    = vm.envAddress("TREASURY_ADDRESS");
        uint256 protocolFee = vm.envUint("PROTOCOL_FEE_BPS");

        vm.startBroadcast();

        PredictionMarketFactory factory = new PredictionMarketFactory(
            treasury,
            protocolFee
        );

        vm.stopBroadcast();

        console.log("PredictionMarketFactory deployed at:", address(factory));
        console.log("  protocolAdmin    :", factory.protocolAdmin());
        console.log("  protocolTreasury :", factory.protocolTreasury());
        console.log("  protocolFeeBps   :", factory.protocolFeeBps());
    }
}
