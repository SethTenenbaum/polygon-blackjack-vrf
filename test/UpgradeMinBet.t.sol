// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {GameFactoryUpgradeable} from "../src/GameFactoryUpgradeable.sol";
import {GameToken} from "../src/GameToken.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/**
 * @title UpgradeMinBetTest
 * @notice Tests for upgrading factory and changing minBet from 100 tokens to 1 token
 */
contract UpgradeMinBetTest is Test {
    GameFactoryUpgradeable public factory;
    GameToken public gameToken;
    
    address public owner;
    address public user;
    
    // Constants
    address constant VRF_COORDINATOR = 0x343300b5d84D444B2ADc9116FEF1bED02BE49Cf2;
    address constant LINK_ADDRESS = 0x0Fd9e8d3aF1aaee056EB9e802c3A762a667b1904;
    
    uint256 constant INITIAL_MIN_BET = 100 * 10**18; // 100 tokens
    uint256 constant NEW_MIN_BET = 1 * 10**18; // 1 token
    uint256 constant LINK_FEE = 0.001 ether;
    
    event MinBetUpdated(uint256 oldValue, uint256 newValue);
    
    function setUp() public {
        owner = address(this);
        user = makeAddr("user");
        
        // Deploy GameToken
        gameToken = new GameToken();
        
        // Deploy Factory
        GameFactoryUpgradeable factoryImpl = new GameFactoryUpgradeable();
        
        // Correct parameter order: vrfCoordinator, linkAddress, gameTokenAddress, gameImplementation, linkFee, minBet, subscriptionId, keeperAddress
        bytes memory initData = abi.encodeWithSelector(
            GameFactoryUpgradeable.initialize.selector,
            VRF_COORDINATOR,
            LINK_ADDRESS,
            address(gameToken),
            address(0x1234), // dummy game implementation
            LINK_FEE,
            INITIAL_MIN_BET,  // 100 tokens
            1, // subscriptionId (mock)
            address(0x5678) // keeperAddress (mock)
        );
        
        ERC1967Proxy proxy = new ERC1967Proxy(address(factoryImpl), initData);
        factory = GameFactoryUpgradeable(payable(address(proxy)));
        
        // Transfer GameToken ownership to factory
        gameToken.transferOwnership(address(factory));
    }
    
    /*//////////////////////////////////////////////////////////////
                            CORE TESTS
    //////////////////////////////////////////////////////////////*/
    
    function test_InitialMinBetIs100Tokens() public view {
        (,,,, uint256 minBet,) = factory.getLiquidityStats();
        assertEq(minBet, INITIAL_MIN_BET, "Initial minBet should be 100 tokens");
    }
    
    function test_UpgradeAndSetMinBetTo1Token() public {
        // Deploy new implementation (same contract, just upgrading to enable setMinBet)
        GameFactoryUpgradeable newImpl = new GameFactoryUpgradeable();
        
        // Upgrade
        factory.upgradeToAndCall(address(newImpl), "");
        
        // Set new minBet
        vm.expectEmit(false, false, false, true);
        emit MinBetUpdated(INITIAL_MIN_BET, NEW_MIN_BET);
        
        factory.setMinBet(NEW_MIN_BET);
        
        // Verify
        (,,,, uint256 minBet,) = factory.getLiquidityStats();
        assertEq(minBet, NEW_MIN_BET, "minBet should now be 1 token");
    }
    
    function test_CannotSetMinBetToZero() public {
        GameFactoryUpgradeable newImpl = new GameFactoryUpgradeable();
        factory.upgradeToAndCall(address(newImpl), "");
        
        vm.expectRevert("Min bet must be positive");
        factory.setMinBet(0);
    }
    
    function test_OnlyOwnerCanSetMinBet() public {
        GameFactoryUpgradeable newImpl = new GameFactoryUpgradeable();
        factory.upgradeToAndCall(address(newImpl), "");
        
        vm.prank(user);
        vm.expectRevert();
        factory.setMinBet(NEW_MIN_BET);
    }
    
    function test_StatePersiststhroughUpgrade() public {
        // Add liquidity (0.1 POL = 100 tokens)
        factory.addLiquidityWithPOL{value: 0.1 ether}();
        uint256 liquidityBefore = factory.totalLiquidity();
        
        address tokenBefore = address(factory.gameToken());
        
        // Upgrade
        GameFactoryUpgradeable newImpl = new GameFactoryUpgradeable();
        factory.upgradeToAndCall(address(newImpl), "");
        
        // Verify state persists
        assertEq(factory.totalLiquidity(), liquidityBefore, "Liquidity should persist");
        assertEq(address(factory.gameToken()), tokenBefore, "Token address should persist");
    }
    
    function test_GetConfigReturnsCorrectValues() public {
        GameFactoryUpgradeable newImpl = new GameFactoryUpgradeable();
        factory.upgradeToAndCall(address(newImpl), "");
        factory.setMinBet(NEW_MIN_BET);
        
        (address vrf, address link, uint256 linkFee, uint256 minBet) = factory.getConfig();
        
        assertEq(vrf, VRF_COORDINATOR, "VRF coordinator should match");
        assertEq(link, LINK_ADDRESS, "LINK address should match");
        assertEq(linkFee, LINK_FEE, "LINK fee should match");
        assertEq(minBet, NEW_MIN_BET, "minBet should be 1 token");
    }
    
    /*//////////////////////////////////////////////////////////////
                        FUZZING TESTS
    //////////////////////////////////////////////////////////////*/
    
    function testFuzz_SetMinBetToAnyPositiveValue(uint256 newMinBet) public {
        vm.assume(newMinBet > 0 && newMinBet <= 1000 * 10**18);
        
        GameFactoryUpgradeable newImpl = new GameFactoryUpgradeable();
        factory.upgradeToAndCall(address(newImpl), "");
        
        factory.setMinBet(newMinBet);
        
        (,,,, uint256 actualMinBet,) = factory.getLiquidityStats();
        assertEq(actualMinBet, newMinBet, "minBet should be set to fuzzed value");
    }
}
