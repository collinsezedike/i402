// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "../src/TaskAuction.sol";
import "../test/TaskAuction.t.sol";

// Deploys TaskAuction with stub ERC-8004 and x402 contracts.
// Use this for local anvil and testnet runs before real integrations are live.
contract DeployMocks is Script {
    function run() external {
        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));

        MockERC8004 registry = new MockERC8004();
        MockX402    x402     = new MockX402();
        TaskAuction auction  = new TaskAuction(address(registry), address(x402));

        vm.stopBroadcast();

        console.log("TaskAuction:  ", address(auction));
        console.log("MockERC8004:  ", address(registry));
        console.log("MockX402:     ", address(x402));
    }
}
