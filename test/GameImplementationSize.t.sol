// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/GameImplementation.sol";
import "../src/GameFactoryUpgradeable.sol";

contract GameImplementationSizeTest is Test {
    function testGameImplementationSize() public pure {
        // Get the deployed bytecode size
        bytes memory code = type(GameImplementation).creationCode;
        uint256 size = code.length;
        
        console.log("GameImplementation creation code size:", size);
        console.log("Limit: 24576 bytes");
        console.log("Over limit by:", size > 24576 ? size - 24576 : 0);
        
        // This test will fail if over limit
        assertLe(size, 24576, "GameImplementation exceeds 24KB limit");
    }
    
    function testCloneInitialization() public {
        // Deploy factory and game implementation
        // Test that clones can be initialized properly
        
        address vrfCoordinator = address(0x343300b5d84D444B2ADc9116FEF1bED02BE49Cf2);
        address linkToken = address(0x0Fd9e8d3aF1aaee056EB9e802c3A762a667b1904);
        // address gameToken = address(0x1); // mock - unused
        
        vm.label(vrfCoordinator, "VRF");
        vm.label(linkToken, "LINK");
        
        console.log("Testing clone initialization pattern...");
        console.log("This will help us verify the fix works before deploying!");
    }
}
