// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "../src/TaskAuction.sol";

contract Deploy is Script {
    function run() external {
        address erc8004 = vm.envAddress("ERC8004_ADDRESS");
        address x402    = vm.envAddress("X402_ADDRESS");

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        TaskAuction auction = new TaskAuction(erc8004, x402);
        vm.stopBroadcast();

        console.log("TaskAuction:", address(auction));
        console.log("ERC8004:    ", erc8004);
        console.log("x402:       ", x402);
    }
}
