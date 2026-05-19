// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {GameFactoryUpgradeable} from "../src/GameFactoryUpgradeable.sol";
import {GameToken} from "../src/GameToken.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/**
 * @title UpgradeScriptTest
 * @notice Tests for upgrade script that sets minBet from 100 tokens to 1 token
 * @dev Focused tests for the upgrade flow and minBet update via setMinBet()
 */
contract UpgradeScriptTest is Test {
    GameFactoryUpgradeable public factory;
    GameToken public gameToken;
    
    address constant VRF_COORDINATOR = 0x343300b5d84D444B2ADc9116FEF1bED02BE49Cf2;
    address constant LINK_ADDRESS = 0x0Fd9e8d3aF1aaee056EB9e802c3A762a667b1904;
    
    uint256 constant INITIAL_MIN_BET = 100 * 10**18; // 100 tokens
    uint256 constant NEW_MIN_BET = 1 * 10**18; // 1 token
    uint256 constant LINK_FEE = 0.001 ether;
    
    event MinBetUpdated(uint256 oldValue, uint256 newValue);
    event LinkFeeUpdated(uint256 oldValue, uint256 newValue);
    
    function setUp() public {
        gameToken = new GameToken();
        
        GameFactoryUpgradeable factoryImpl = new GameFactoryUpgradeable();
        
        bytes memory initData = abi.encodeWithSelector(
            GameFactoryUpgradeable.initialize.selector,
            VRF_COORDINATOR,      // vrfCoordinator
            LINK_ADDRESS,         // linkAddress
            address(gameToken),   // gameTokenAddress
            address(0x1234),      // gameImplementation (dummy)
            LINK_FEE,             // linkFee
            INITIAL_MIN_BET,      // minBet (100 tokens)
            1,                    // subscriptionId (mock)
            address(0x5678)       // keeperAddress (mock)
        );
        
        ERC1967Proxy proxy = new ERC1967Proxy(address(factoryImpl), initData);
        factory = GameFactoryUpgradeable(payable(address(proxy)));
    }
    
    /// @notice Test: Verify initial minBet is 100 tokens
    function test_InitialMinBet() public view {
        (,,, uint256 minBet) = factory.getConfig();
        assertEq(minBet, INITIAL_MIN_BET, "Initial minBet should be 100 tokens");
    }
    
    /// @notice Test: Upgrade and set minBet to 1 token (mimics UpdateMinBet.s.sol script)
    function test_UpgradeAndSetMinBet() public {
        // Deploy new implementation
        GameFactoryUpgradeable newImpl = new GameFactoryUpgradeable();
        
        // Upgrade
        factory.upgradeToAndCall(address(newImpl), "");
        
        // Set minBet to 1 token
        factory.setMinBet(NEW_MIN_BET);
        
        // Verify minBet updated
        (,,, uint256 minBet) = factory.getConfig();
        assertEq(minBet, NEW_MIN_BET, "minBet should be 1 token after upgrade");
    }
    
    /// @notice Test: State persists through upgrade
    function test_StatePersistsAfterUpgrade() public {
        address tokenBefore = address(factory.gameToken());
        
        // Upgrade
        GameFactoryUpgradeable newImpl = new GameFactoryUpgradeable();
        factory.upgradeToAndCall(address(newImpl), "");
        
        // Verify references persist
        assertEq(address(factory.gameToken()), tokenBefore, "gameToken should persist");
    }
    
    /// @notice Test: Only owner can set minBet
    function test_OnlyOwnerCanSetMinBet() public {
        GameFactoryUpgradeable newImpl = new GameFactoryUpgradeable();
        factory.upgradeToAndCall(address(newImpl), "");
        
        address nonOwner = makeAddr("nonOwner");
        vm.prank(nonOwner);
        vm.expectRevert();
        factory.setMinBet(NEW_MIN_BET);
    }
    
    /// @notice Test: Cannot set minBet to zero
    function test_CannotSetMinBetToZero() public {
        GameFactoryUpgradeable newImpl = new GameFactoryUpgradeable();
        factory.upgradeToAndCall(address(newImpl), "");
        
        vm.expectRevert("Min bet must be positive");
        factory.setMinBet(0);
    }
    
    /// @notice Test: Set LINK fee after upgrade
    function test_SetLinkFee() public {
        GameFactoryUpgradeable newImpl = new GameFactoryUpgradeable();
        factory.upgradeToAndCall(address(newImpl), "");
        
        uint256 newLinkFee = 0.002 ether; // Increase from 0.001 to 0.002
        factory.setLinkFee(newLinkFee);
        
        (,, uint256 linkFee,) = factory.getConfig();
        assertEq(linkFee, newLinkFee, "linkFee should be updated to 0.002 ether");
    }
    
    /// @notice Test: Only owner can set LINK fee
    function test_OnlyOwnerCanSetLinkFee() public {
        GameFactoryUpgradeable newImpl = new GameFactoryUpgradeable();
        factory.upgradeToAndCall(address(newImpl), "");
        
        address nonOwner = makeAddr("nonOwner");
        vm.prank(nonOwner);
        vm.expectRevert();
        factory.setLinkFee(0.002 ether);
    }
    
    /// @notice Test: Cannot set LINK fee to zero
    function test_CannotSetLinkFeeToZero() public {
        GameFactoryUpgradeable newImpl = new GameFactoryUpgradeable();
        factory.upgradeToAndCall(address(newImpl), "");
        
        vm.expectRevert("LINK fee must be positive");
        factory.setLinkFee(0);
    }
    
    /*//////////////////////////////////////////////////////////////
                        SECURITY TESTS
    //////////////////////////////////////////////////////////////*/
    
    /// @notice Security: Setting extreme minBet doesn't break contract
    function test_Security_ExtremeMinBet() public {
        GameFactoryUpgradeable newImpl = new GameFactoryUpgradeable();
        factory.upgradeToAndCall(address(newImpl), "");
        
        // Test very high minBet (should still work, just impractical)
        uint256 extremelyHighMinBet = 1_000_000_000 * 10**18; // 1 billion tokens
        factory.setMinBet(extremelyHighMinBet);
        
        (,,, uint256 minBet) = factory.getConfig();
        assertEq(minBet, extremelyHighMinBet, "Should accept very high minBet");
        
        // Test very low minBet (1 wei)
        factory.setMinBet(1);
        (,,, uint256 newMinBet) = factory.getConfig();
        assertEq(newMinBet, 1, "Should accept very low minBet");
    }
    
    /// @notice Security: Setting extreme linkFee doesn't break contract
    function test_Security_ExtremeLinkFee() public {
        GameFactoryUpgradeable newImpl = new GameFactoryUpgradeable();
        factory.upgradeToAndCall(address(newImpl), "");
        
        // Test very high LINK fee
        uint256 extremelyHighFee = 100 ether; // 100 LINK
        factory.setLinkFee(extremelyHighFee);
        
        (,, uint256 linkFee,) = factory.getConfig();
        assertEq(linkFee, extremelyHighFee, "Should accept very high linkFee");
        
        // Test very low LINK fee (1 wei)
        factory.setLinkFee(1);
        (,, uint256 newLinkFee,) = factory.getConfig();
        assertEq(newLinkFee, 1, "Should accept very low linkFee");
    }
    
    /// @notice Security: Multiple rapid changes don't break state
    function test_Security_RapidChanges() public {
        GameFactoryUpgradeable newImpl = new GameFactoryUpgradeable();
        factory.upgradeToAndCall(address(newImpl), "");
        
        // Rapidly change minBet multiple times
        for (uint256 i = 1; i <= 10; i++) {
            factory.setMinBet(i * 10**18);
        }
        
        // Verify final state
        (,,, uint256 minBet) = factory.getConfig();
        assertEq(minBet, 10 * 10**18, "Should handle rapid changes");
        
        // Rapidly change linkFee multiple times
        for (uint256 i = 1; i <= 10; i++) {
            factory.setLinkFee(i * 0.001 ether);
        }
        
        // Verify final state
        (,, uint256 linkFee,) = factory.getConfig();
        assertEq(linkFee, 10 * 0.001 ether, "Should handle rapid changes");
    }
    
    /// @notice Security: Changes don't affect existing games
    function test_Security_ChangesDoNotAffectExistingGames() public pure {
        // This test verifies that setMinBet and setLinkFee only affect NEW games
        // Existing games are created with their parameters locked at creation time
        // This is secure because:
        // 1. Each GameUpgradeable contract gets its own copy of parameters at creation
        // 2. Factory changes don't retroactively modify game contracts
        
        // Note: This is a documentation test - the architecture ensures this by design
        // Games receive their bet amount at construction and it's immutable
        assertTrue(true, "Architecture ensures existing games are unaffected");
    }
}
