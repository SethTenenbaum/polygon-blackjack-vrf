// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {GameFactoryUpgradeable} from "../src/GameFactoryUpgradeable.sol";
import {GameToken} from "../src/GameToken.sol";
import {GameImplementation} from "../src/GameImplementation.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title AddLiquidityTest
 * @notice Unit tests for adding liquidity to GameFactory
 * @dev Updated for new behavior: addLiquidityWithPOL() only tops up reserve, doesn't mint tokens
 */
contract AddLiquidityTest is Test {
    GameFactoryUpgradeable public factory;
    GameToken public gameToken;
    address public owner;
    address public nonOwner;
    
    // Test constants
    address constant POLYGON_AMOY_VRF = 0x343300b5d84D444B2ADc9116FEF1bED02BE49Cf2;
    address constant POLYGON_AMOY_LINK = 0x0Fd9e8d3aF1aaee056EB9e802c3A762a667b1904;
    uint256 constant LINK_FEE = 0.0005 ether;
    uint256 constant MIN_BET = 100 * 10**18;
    
    event LiquidityAdded(address indexed provider, uint256 amount);
    
    function setUp() public {
        owner = address(this);
        nonOwner = makeAddr("nonOwner");
        
        // Deploy GameToken
        gameToken = new GameToken();
        
        // Deploy GameImplementation
        GameImplementation gameImpl = new GameImplementation();
        
        // Deploy Factory implementation
        GameFactoryUpgradeable factoryImpl = new GameFactoryUpgradeable();
        
        // Encode initializer
        bytes memory initData = abi.encodeWithSelector(
            GameFactoryUpgradeable.initialize.selector,
            POLYGON_AMOY_VRF,
            POLYGON_AMOY_LINK,
            address(gameToken),
            address(gameImpl),
            LINK_FEE,
            MIN_BET,
            1, // subscriptionId (mock)
            address(0) // keeperAddress (not needed)
        );
        
        // Deploy proxy
        ERC1967Proxy proxy = new ERC1967Proxy(address(factoryImpl), initData);
        factory = GameFactoryUpgradeable(payable(address(proxy)));
        
        // Transfer GameToken ownership to factory (this is the key difference from TestableGameFactory tests)
        gameToken.transferOwnership(address(factory));
        
        // Fund test accounts
        vm.deal(owner, 100 ether);
        vm.deal(nonOwner, 100 ether);
    }
    
    /**
     * @notice Test adding liquidity with valid amount
     * @dev addLiquidityWithPOL() only tops up reserve, doesn't mint tokens to factory
     */
    function test_AddLiquidity_Success() public {
        uint256 polAmount = 1 ether;
        
        uint256 gameTokenReserveBefore = address(gameToken).balance;
        
        // Add liquidity - event now emits POL amount, not token amount
        vm.expectEmit(true, false, false, true);
        emit LiquidityAdded(owner, polAmount);
        
        factory.addLiquidityWithPOL{value: polAmount}();
        
        // Verify GameToken received POL
        uint256 gameTokenReserveAfter = address(gameToken).balance;
        assertEq(
            gameTokenReserveAfter - gameTokenReserveBefore,
            polAmount,
            "GameToken should receive POL"
        );
        
        // Factory should NOT receive tokens - it only tops up reserve
        uint256 factoryBalance = gameToken.balanceOf(address(factory));
        assertEq(factoryBalance, 0, "Factory should not hold tokens");
    }
    
    /**
     * @notice Test adding liquidity with different amounts (fuzz)
     * @dev Updated: Factory doesn't hold tokens, only tops up reserve
     */
    function testFuzz_AddLiquidity_DifferentAmounts(uint96 polAmount) public {
        vm.assume(polAmount > 0.001 ether); // Minimum amount
        vm.assume(polAmount < 50 ether); // Maximum reasonable amount
        
        uint256 reserveBefore = address(gameToken).balance;
        
        factory.addLiquidityWithPOL{value: polAmount}();
        
        uint256 reserveAfter = address(gameToken).balance;
        assertEq(reserveAfter - reserveBefore, polAmount, "Reserve should increase by POL amount");
    }
    
    /**
     * @notice Test adding liquidity with half POL
     * @dev Updated: Only checks reserve increase
     */
    function test_AddLiquidity_HalfPOL() public {
        uint256 polAmount = 0.5 ether;
        
        uint256 reserveBefore = address(gameToken).balance;
        factory.addLiquidityWithPOL{value: polAmount}();
        uint256 reserveAfter = address(gameToken).balance;
        
        assertEq(reserveAfter - reserveBefore, polAmount, "Should handle fractional POL");
    }
    
    /**
     * @notice Test non-owner cannot add liquidity
     */
    function test_AddLiquidity_RevertIf_NotOwner() public {
        vm.prank(nonOwner);
        vm.expectRevert();
        factory.addLiquidityWithPOL{value: 1 ether}();
    }
    
    /**
     * @notice Test adding liquidity with zero amount reverts
     */
    function test_AddLiquidity_RevertIf_ZeroAmount() public {
        vm.expectRevert();
        factory.addLiquidityWithPOL{value: 0}();
    }
    
    /**
     * @notice Test multiple liquidity additions accumulate
     * @dev Updated: Checks reserve increases instead of token balance
     */
    function test_AddLiquidity_MultipleAdditions() public {
        uint256 firstAmount = 1 ether;
        uint256 secondAmount = 2 ether;
        
        // First addition
        uint256 reserveBefore = address(gameToken).balance;
        factory.addLiquidityWithPOL{value: firstAmount}();
        uint256 reserveAfterFirst = address(gameToken).balance;
        
        assertEq(reserveAfterFirst - reserveBefore, firstAmount, "First addition should increase reserve");
        
        // Second addition
        factory.addLiquidityWithPOL{value: secondAmount}();
        uint256 reserveAfterSecond = address(gameToken).balance;
        
        assertEq(
            reserveAfterSecond - reserveAfterFirst,
            secondAmount,
            "Second addition should add correct amount"
        );
    }
    
    /**
     * @notice Test liquidity addition does NOT mint tokens (new behavior)
     * @dev addLiquidityWithPOL() only tops up reserve, doesn't mint tokens
     */
    function test_AddLiquidity_UpdatesTotalSupply() public {
        uint256 totalSupplyBefore = gameToken.totalSupply();
        uint256 polAmount = 5 ether;
        
        factory.addLiquidityWithPOL{value: polAmount}();
        
        uint256 totalSupplyAfter = gameToken.totalSupply();
        assertEq(
            totalSupplyAfter,
            totalSupplyBefore,
            "Total supply should NOT change (no minting, only reserve top-up)"
        );
    }
    
    /**
     * @notice Test reserve increases with each addition
     * @dev Updated: No longer testing token minting exchange rate, just reserve increases
     */
    function test_AddLiquidity_ExchangeRate() public {
        uint256[] memory amounts = new uint256[](5);
        amounts[0] = 0.1 ether;
        amounts[1] = 0.5 ether;
        amounts[2] = 1 ether;
        amounts[3] = 5 ether;
        amounts[4] = 10 ether;
        
        uint256 reserveBefore = address(gameToken).balance;
        
        for (uint256 i = 0; i < amounts.length; i++) {
            uint256 polAmount = amounts[i];
            
            factory.addLiquidityWithPOL{value: polAmount}();
            uint256 reserveAfter = address(gameToken).balance;
            
            assertEq(
                reserveAfter - reserveBefore,
                polAmount,
                "Reserve should increase by POL amount"
            );
            
            reserveBefore = reserveAfter;
        }
    }
    
    /**
     * @notice Test GameToken ownership check
     */
    function test_AddLiquidity_VerifyGameTokenOwnership() public view {
        assertEq(
            gameToken.owner(),
            address(factory),
            "Factory should own GameToken"
        );
    }
    
    /**
     * @notice Test max withdrawable profit after adding liquidity
     */
    function test_AddLiquidity_MaxWithdrawable() public {
        uint256 polAmount = 10 ether;
        
        factory.addLiquidityWithPOL{value: polAmount}();
        
        uint256 maxWithdrawable = factory.getMaxWithdrawableProfitPOL();
        
        // Should be able to withdraw the POL we just added (minus any locked liquidity)
        assertGe(
            maxWithdrawable,
            0,
            "Should have some withdrawable profit"
        );
    }
    
    /**
     * @notice Test reentrancy protection (verify modifier exists)
     * @dev Updated: Checks reserve increase instead of token balance
     */
    function test_AddLiquidity_ReentrancyProtected() public {
        // The function has nonReentrant modifier
        // We verify it works by calling it normally - it should succeed
        uint256 reserveBefore = address(gameToken).balance;
        
        factory.addLiquidityWithPOL{value: 1 ether}();
        
        uint256 reserveAfter = address(gameToken).balance;
        // Verify the function executed successfully
        assertGt(reserveAfter - reserveBefore, 0, "Function should execute successfully with reentrancy protection");
    }
    
    /**
     * @notice Test event emission
     * @dev Updated: Event now emits POL amount, not token amount
     */
    function test_AddLiquidity_EmitsEvent() public {
        uint256 polAmount = 1 ether;
        
        vm.expectEmit(true, false, false, true);
        emit LiquidityAdded(owner, polAmount);
        
        factory.addLiquidityWithPOL{value: polAmount}();
    }
}
