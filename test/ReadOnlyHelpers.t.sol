// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "forge-std/Test.sol";
import "../src/GameToken.sol";
import "../src/GameFactoryUpgradeable.sol";
import "../src/GameUpgradeable.sol";
import "./TestableGameFactory.sol";
import {ERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

contract MockLINK is ERC20 {
    constructor() ERC20("Mock LINK", "LINK") {
        _mint(msg.sender, 1000000 ether);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/**
 * @title ReadOnlyHelpers Test Suite
 * @notice Comprehensive tests for all read-only helper functions that allow
 *         checking bet feasibility and liquidity status without state changes
 */
contract ReadOnlyHelpersTest is Test {
    GameToken public token;
    TestableGameFactory public factory;
    MockLINK public linkToken;
    
    address public treasury = address(0x1);
    address public liquidityProvider = address(0x2);
    address public player = address(0x3);
    
    uint256 constant INITIAL_ETH = 1000 ether;
    uint256 constant INITIAL_LIQUIDITY = 100 ether;  // In tokens
    uint256 constant INITIAL_POL_LIQUIDITY = 0.1 ether;  // In POL (100 tokens / 1000)
    
    // Accept ETH from GameToken
    receive() external payable {}
    
    function setUp() public {
        // Deploy tokens
        token = new GameToken();
        linkToken = new MockLINK();
        
        address vrfCoordinator = address(0x999);
        
        // Deploy factory
        factory = new TestableGameFactory();
        factory.initializeTest(
            vrfCoordinator,
            address(linkToken),
            address(token),
            0.0005 ether,  // link fee
            1 ether,       // min bet
            1,             // subscriptionId (mock)
            address(0x1234) // keeperAddress (mock)
        );
        
        // Transfer GameToken ownership to factory (factory needs to own GameToken to withdraw profits)
        token.transferOwnership(address(factory));
        
        // Setup liquidity provider (test contract is owner and has initial GameToken supply)
        vm.deal(liquidityProvider, INITIAL_ETH);
        
        // TestableGameFactory needs tokens in its balance
        uint256 polNeeded = INITIAL_LIQUIDITY / 1000;
        vm.deal(address(this), polNeeded * 2);
        token.buyTokens{value: polNeeded}(); // Buy 100 tokens
        token.transfer(address(factory), INITIAL_LIQUIDITY); // Transfer to factory
        // Add extra POL to reserve
        vm.deal(address(factory), polNeeded);
        vm.prank(address(factory));
        token.topUpReserve{value: polNeeded}();
        
        // Setup player with backed tokens
        vm.deal(player, INITIAL_ETH);
        linkToken.mint(player, 100 ether);
        // Player buys tokens with POL (backed properly)
        vm.startPrank(player);
        uint256 playerTokenAmount = 100 ether;
        uint256 playerPOL = playerTokenAmount / 1000;
        token.buyTokens{value: playerPOL}();
        
        // Simulate profit: player loses tokens to factory
        // Player transfers 50 ether tokens to factory (simulating lost bet)
        token.transfer(address(factory), 50 ether);
        vm.stopPrank();
        
        // Add extra POL to GameToken to create excess (house edge/profit scenario)
        // Factory can call topUpReserve since it owns GameToken
        vm.deal(address(factory), 0.05 ether);
        vm.prank(address(factory));
        token.topUpReserve{value: 0.05 ether}();
        
        // Now factory has: 100 (initial) + 50 (from player) = 150 tokens
        // Total supply: 150 (factory) + 50 (player) = 200 tokens
        // POL backing: 0.1 + 0.1 + 0.05 = 0.25 POL
        // POL needed: 200/1000 = 0.2 POL
        // Excess: 0.25 - 0.2 = 0.05 POL
        // Available profit: 0.05 POL = 50 tokens
    }
    
    // ============================================================
    // Test canSupportBet()
    // ============================================================
    
    function testCanSupportBet_Valid() public view {
        uint256 maxBet = factory.getMaxBet();
        (,,,, uint256 minBet,) = factory.getLiquidityStats();
        
        // Use minBet which should always be valid
        assertTrue(factory.canSupportBet(minBet), "Should support min bet");
        
        // If maxBet > minBet, test midpoint
        if (maxBet > minBet) {
            uint256 midBet = (maxBet + minBet) / 2;
            assertTrue(factory.canSupportBet(midBet), "Should support bet between min and max");
        }
    }
    
    function testCanSupportBet_BelowMinimum() public view {
        (,,,, uint256 minBet,) = factory.getLiquidityStats();
        uint256 tooSmallBet = minBet - 1;
        
        assertFalse(factory.canSupportBet(tooSmallBet), "Should reject bet below minimum");
    }
    
    function testCanSupportBet_ExceedsMaximum() public view {
        uint256 maxBet = factory.getMaxBet();
        uint256 tooLargeBet = maxBet + 1 ether;
        
        assertFalse(factory.canSupportBet(tooLargeBet), "Should reject bet above maximum");
    }
    
    function testCanSupportBet_InsufficientLiquidity() public {
        // Remove some liquidity (but not enough to underback GameToken)
        // Check how much we can safely withdraw (in POL)
        uint256 availableProfitPOL = factory.getMaxWithdrawableProfitPOL();
        if (availableProfitPOL > 0) {
            // Withdraw half of available profit to reduce liquidity
            factory.withdrawProfits(availableProfitPOL / 2);
        }
        
        // Max bet should be smaller now
        uint256 maxBet = factory.getMaxBet();
        uint256 largeBet = maxBet * 2;
        
        assertFalse(factory.canSupportBet(largeBet), "Should reject when insufficient liquidity");
    }
    
    function testCanSupportBet_ExactlyAtMaximum() public view {
        uint256 maxBet = factory.getMaxBet();
        assertTrue(factory.canSupportBet(maxBet), "Should support bet exactly at maximum");
    }
    
    // ============================================================
    // Test getBetFeasibility()
    // ============================================================
    
    function testGetBetFeasibility_Valid() public view {
        (,,,, uint256 minBet,) = factory.getLiquidityStats();
        
        (bool isValid, string memory reason, uint256 requiredLiquidity, uint256 currentMaxBet) = 
            factory.getBetFeasibility(minBet);
        
        assertTrue(isValid, "Bet should be valid");
        assertEq(reason, "Bet is valid", "Reason should indicate validity");
        // requiredLiquidity is now in POL: (minBet * multiplier) / 1000
        // multiplier is constant 11
        uint256 expectedPOL = (minBet * 11) / 1000;
        assertEq(requiredLiquidity, expectedPOL, "Should calculate correct liquidity in POL");
        assertGt(currentMaxBet, 0, "Max bet should be positive");
    }
    function testGetBetFeasibility_BelowMinimum() public view {
        (,,,, uint256 minBet,) = factory.getLiquidityStats();
        uint256 tooSmallBet = minBet - 1;
        
        (bool isValid, string memory reason,,) = factory.getBetFeasibility(tooSmallBet);
        
        assertFalse(isValid, "Bet should be invalid");
        assertEq(reason, "Bet below minimum", "Should indicate bet is too small");
    }
    
    function testGetBetFeasibility_ExceedsMaximum() public view {
        uint256 maxBet = factory.getMaxBet();
        uint256 tooLargeBet = maxBet + 1 ether;
        
        (bool isValid, string memory reason,,) = factory.getBetFeasibility(tooLargeBet);
        
        assertFalse(isValid, "Bet should be invalid");
        assertEq(reason, "Bet exceeds maximum (would prevent concurrent players)", "Should indicate exceeds maximum");
    }
    
    function testGetBetFeasibility_InsufficientLiquidity() public {
        // Remove some liquidity (but not enough to underback GameToken)
        uint256 availableProfitPOL = factory.getMaxWithdrawableProfitPOL();
        if (availableProfitPOL > 0) {
            factory.withdrawProfits(availableProfitPOL / 2);
        }
        
        // Try a bet that's within max but requires more liquidity than available
        uint256 largeBet = 10 ether;
        
        (bool isValid, string memory reason,,) = factory.getBetFeasibility(largeBet);
        
        // Either exceeds max or insufficient liquidity
        assertFalse(isValid, "Bet should be invalid");
        assertTrue(
            keccak256(bytes(reason)) == keccak256(bytes("Insufficient factory liquidity")) ||
            keccak256(bytes(reason)) == keccak256(bytes("Bet exceeds maximum (would prevent concurrent players)")),
            "Should indicate liquidity or max bet issue"
        );
    }
    
    function testGetBetFeasibility_ReturnsCorrectRequiredLiquidity() public view {
        uint256 bet = 5 ether; // 5 tokens
        uint256 multiplier = 11; // constant
        
        (,, uint256 requiredLiquidity,) = factory.getBetFeasibility(bet);
        
        // Required = (5 tokens * 11) / 1000 = 0.055 POL
        uint256 expectedPOL = (bet * multiplier) / 1000;
        assertEq(requiredLiquidity, expectedPOL, "Should calculate correct required liquidity in POL");
    }
    
    function testGetBetFeasibility_ReturnsCorrectMaxBet() public view {
        uint256 expectedMaxBet = factory.getMaxBet();
        
        (,,, uint256 currentMaxBet) = factory.getBetFeasibility(1 ether);
        
        assertEq(currentMaxBet, expectedMaxBet, "Should return current max bet");
    }
    
    // ============================================================
    // Test getRequiredLiquidity()
    // ============================================================
    
    function testGetRequiredLiquidity_CalculatesCorrectly() public view {
        uint256 bet = 10 ether; // 10 tokens
        uint256 multiplier = 11; // constant
        
        uint256 required = factory.getRequiredLiquidity(bet);
        
        // Required = (10 tokens * 11) / 1000 = 0.11 POL
        uint256 expectedPOL = (bet * multiplier) / 1000;
        assertEq(required, expectedPOL, "Should calculate (bet * multiplier) / 1000 in POL");
    }
    
    function testGetRequiredLiquidity_ZeroBet() public view {
        uint256 required = factory.getRequiredLiquidity(0);
        assertEq(required, 0, "Zero bet should require zero liquidity");
    }
    
    function testGetRequiredLiquidity_LargeBet() public view {
        uint256 largeBet = 1000 ether; // 1000 tokens
        uint256 multiplier = 11; // constant
        
        uint256 required = factory.getRequiredLiquidity(largeBet);
        
        // Required = (1000 tokens * 11) / 1000 = 11 POL
        uint256 expectedPOL = (largeBet * multiplier) / 1000;
        assertEq(required, expectedPOL, "Should handle large bets");
    }
    
    // ============================================================
    // Test getRemainingCapacity()
    // ============================================================
    
    function testGetRemainingCapacity_AtStart() public view {
        uint256 bet = 1 ether;
        uint256 capacity = factory.getRemainingCapacity(bet);
        
        assertGt(capacity, 0, "Should have capacity at start");
        
        // Verify the math: capacity should be availablePOL / netLockPerGame (in POL)
        (, uint256 availablePOL,,,, ) = factory.getLiquidityStats();
        uint256 multiplier = 11; // constant
        
        // Calculate net lock per game in POL
        uint256 requiredTokens = bet * multiplier;
        uint256 requiredPOL = requiredTokens / 1000;  // Convert to POL
        uint256 betInPOL = bet / 1000;  // Convert bet to POL
        uint256 netLockPerGame = requiredPOL - betInPOL;  // Net POL locked
        
        uint256 expectedCapacity = availablePOL / netLockPerGame;
        
        assertEq(capacity, expectedCapacity, "Capacity calculation should match formula");
    }
    
    function testGetRemainingCapacity_DecreaseAfterLiquidityLock() public {
        uint256 bet = 1 ether;
        
        // Get initial capacity
        uint256 initialCapacity = factory.getRemainingCapacity(bet);
        assertGt(initialCapacity, 0, "Should have initial capacity");
        
        // Withdraw profits (redeem tokens for POL) - this DOES decrease POL capacity
        uint256 availableProfitPOL = factory.getMaxWithdrawableProfitPOL();
        require(availableProfitPOL > 0, "Must have available profit");
        uint256 withdrawAmount = availableProfitPOL / 5; // Withdraw 20%
        factory.withdrawProfits(withdrawAmount);
        
        uint256 newCapacity = factory.getRemainingCapacity(bet);
        assertLt(newCapacity, initialCapacity, "Capacity should decrease after withdrawing profits");
    }
    
    function testGetRemainingCapacity_ZeroBet() public view {
        uint256 capacity = factory.getRemainingCapacity(0);
        assertEq(capacity, 0, "Zero bet should return zero capacity");
    }
    
    function testGetRemainingCapacity_NoLiquidityLeft() public {
        // Get available profits and withdraw them all
        uint256 availableProfitPOL = factory.getMaxWithdrawableProfitPOL();
        if (availableProfitPOL > 0) {
            factory.withdrawProfits(availableProfitPOL);
            
            // After withdrawing all available profits, capacity at reasonable bet should be low
            uint256 capacity = factory.getRemainingCapacity(1 ether);
            // Note: There may still be capacity from reserves needed to back tokens
            // Capacity should be less than the initial capacity
            assertLe(capacity, 100, "Should have reduced capacity after withdrawing all available profits");
        } else {
            // If no profit available, capacity depends on existing liquidity
            uint256 capacity = factory.getRemainingCapacity(1 ether);
            // Just verify it's a reasonable number
            assertGe(capacity, 0, "Capacity should be non-negative");
        }
    }
    
    function testGetRemainingCapacity_GuaranteesAtLeast10Players() public view {
        uint256 maxBet = factory.getMaxBet();
        uint256 minPlayers = factory.minConcurrentPlayers();
        
        uint256 capacity = factory.getRemainingCapacity(maxBet);
        
        assertGe(capacity, minPlayers, "Should support at least minimum concurrent players at max bet");
    }
    
    // ============================================================
    // Test getLiquidityStats()
    // ============================================================
    
    function testGetLiquidityStats_InitialState() public view {
        (
            uint256 total,
            uint256 available,
            uint256 locked,
            uint256 maxBet,
            uint256 minBet,
            uint256 capacityAt90Percent
        ) = factory.getLiquidityStats();
        
        // Total POL = 0.1 (factory) + 0.1 (player's purchase) + 0.05 (top-up) = 0.25 POL
        assertEq(total, 0.25 ether, "Total should equal 0.25 POL");
        assertEq(available, 0.25 ether, "All POL should be available initially");
        assertEq(locked, 0, "Nothing should be locked initially");
        assertGt(maxBet, 0, "Max bet should be positive");
        assertEq(minBet, 1 ether, "Min bet should match initialized value");
        assertGt(capacityAt90Percent, 0, "Should have capacity at 90% of max");
    }
    
    function testGetLiquidityStats_AfterWithdrawing() public {
        // Get initial stats
        (uint256 initialTotal, uint256 initialAvailable,,,, ) = factory.getLiquidityStats();
        
        // Withdraw some POL (safe amount considering backing)
        uint256 availableProfitPOL = factory.getMaxWithdrawableProfitPOL();
        require(availableProfitPOL > 0, "Must have available profit");
        uint256 withdrawPOL = availableProfitPOL / 5; // Withdraw 20% of available
        factory.withdrawProfits(withdrawPOL);
        
        (
            uint256 total,
            uint256 available,
            uint256 locked,,,
        ) = factory.getLiquidityStats();
        
        // Withdrawing profits redeems tokens for POL, decreasing reserves
        assertLt(total, initialTotal, "Total POL should decrease when withdrawing profits");
        assertLt(available, initialAvailable, "Available POL should decrease");
        assertEq(locked, 0, "Nothing should be locked");
    }
    
    function testGetLiquidityStats_AfterAddingMoreLiquidity() public {
        // Get initial stats
        (uint256 initialTotal, uint256 initialAvailable,,,, ) = factory.getLiquidityStats();
        
        // Add more liquidity WITH POL backing
        uint256 additionalTokens = 50 ether;
        uint256 additionalPOL = additionalTokens / 1000;  // Convert tokens to POL
        vm.deal(address(this), additionalPOL);
        factory.addLiquidityWithPOL{value: additionalPOL}();
        
        (
            uint256 total,
            uint256 available,
            uint256 locked,,,
        ) = factory.getLiquidityStats();
        
        // Liquidity is measured in POL, not tokens
        assertEq(total, initialTotal + additionalPOL, "Total should include additional POL");
        assertEq(available, initialAvailable + additionalPOL, "Available should include additional POL");
        assertEq(locked, 0, "Nothing should be locked");
    }
    
    function testGetLiquidityStats_CapacityAt90Percent() public view {
        (,,,,, uint256 capacityAt90Percent) = factory.getLiquidityStats();
        
        uint256 maxBet = factory.getMaxBet();
        uint256 safeBet = (maxBet * 90) / 100;
        uint256 expectedCapacity = factory.getRemainingCapacity(safeBet);
        
        assertEq(capacityAt90Percent, expectedCapacity, "Should match capacity at 90% of max bet");
    }
    
    // ============================================================
    // Integration Tests
    // ============================================================
    
    function testReadOnlyHelpers_WorkTogetherForDecisionMaking() public view {
        // Scenario: A frontend wants to determine if a player's bet is feasible
        // and show them useful information
        
        uint256 desiredBet = 8 ether;
        
        // Step 1: Quick check if bet is supported
        bool canSupport = factory.canSupportBet(desiredBet);
        
        // Step 2: Get detailed feasibility info
        (bool isValid, , uint256 requiredLiquidity, uint256 currentMaxBet) = 
            factory.getBetFeasibility(desiredBet);
        
        // Step 3: Get liquidity stats for context
        (uint256 total, uint256 available, uint256 locked,,, ) = 
            factory.getLiquidityStats();
        
        // Step 4: Calculate how many more players could bet this amount
        uint256 remainingCapacity = factory.getRemainingCapacity(desiredBet);
        
        // Verify consistency
        assertEq(canSupport, isValid, "canSupportBet and getBetFeasibility should agree");
        assertEq(total, available + locked, "Total should equal available + locked");
        
        if (isValid) {
            assertGt(remainingCapacity, 0, "Valid bet should have positive capacity");
            assertLe(desiredBet, currentMaxBet, "Valid bet should be within max");
            assertLe(requiredLiquidity, available, "Valid bet should have enough liquidity");
        }
    }
    
    function testReadOnlyHelpers_DynamicMaxBetUpdates() public {
        // Get initial max bet
        uint256 initialMaxBet = factory.getMaxBet();
        (,,, uint256 maxBet1) = factory.getBetFeasibility(1 ether);
        assertEq(maxBet1, initialMaxBet, "getBetFeasibility should return current max bet");
        
        // Add more liquidity WITH POL backing
        uint256 additionalLiquidity = 100 ether;
        vm.deal(address(this), additionalLiquidity);
        factory.addLiquidityWithPOL{value: additionalLiquidity}();
        
        // Check that max bet increased
        uint256 newMaxBet = factory.getMaxBet();
        (,,, uint256 maxBet2) = factory.getBetFeasibility(1 ether);
        
        assertGt(newMaxBet, initialMaxBet, "Max bet should increase with more liquidity");
        assertEq(maxBet2, newMaxBet, "getBetFeasibility should reflect new max bet");
        
        // Verify capacity increased
        uint256 testBet = 5 ether;
        uint256 newCapacity = factory.getRemainingCapacity(testBet);
        assertGt(newCapacity, 0, "Should have capacity with new liquidity");
    }
    
    function testReadOnlyHelpers_EdgeCaseMaxBetExactly() public view {
        // Test that betting exactly the max bet is valid
        uint256 maxBet = factory.getMaxBet();
        
        assertTrue(factory.canSupportBet(maxBet), "Should support bet exactly at maximum");
        
        (bool isValid, string memory reason,,) = factory.getBetFeasibility(maxBet);
        assertTrue(isValid, "Exact max bet should be valid");
        assertEq(reason, "Bet is valid", "Should indicate validity");
        
        uint256 capacity = factory.getRemainingCapacity(maxBet);
        assertGe(capacity, factory.minConcurrentPlayers(), "Should support minimum concurrent players");
    }
    
    function testReadOnlyHelpers_EdgeCaseMinBetExactly() public view {
        // Test that betting exactly the min bet is valid
        (,,,, uint256 minBet,) = factory.getLiquidityStats();
        
        assertTrue(factory.canSupportBet(minBet), "Should support bet exactly at minimum");
        
        (bool isValid, string memory reason,,) = factory.getBetFeasibility(minBet);
        assertTrue(isValid, "Exact min bet should be valid");
        assertEq(reason, "Bet is valid", "Should indicate validity");
    }
}
