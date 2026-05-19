// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "../test/TestableGame.sol";
import "../src/GameToken.sol";

// Simple mock VRF coordinator for testing
contract MockVRFCoordinator {
    // Empty contract, just needs to exist for constructor
}

// Simple mock LINK token for testing
contract MockLinkToken {
    mapping(address => uint256) public balances;
    function transfer(address to, uint256 amount) external returns (bool) {
        balances[to] += amount;
        return true;
    }
    function balanceOf(address account) external view returns (uint256) {
        return balances[account];
    }
}

contract HandProgressionTest is Test {
    TestableGame public game;
    GameToken public token;
    
    address public player;
    address public factory;
    
    function setUp() public {
        player = makeAddr("player");
        factory = address(this);
        
        // Deploy GameToken
        token = new GameToken();
        
        // Fund player with POL and buy tokens (backed minting)
        vm.deal(player, 1000 ether); // 1000 POL
        vm.prank(player);
        token.buyTokens{value: 1000 ether}(); // Mints 1M tokens backed by POL
        
        // Create game (use mock VRF coordinator address for testing)
        uint256 bet = 100 * 10**18;
        
        // Deploy a simple mock contract to act as VRF coordinator
        MockVRFCoordinator mockVRF = new MockVRFCoordinator();
        MockLinkToken linkToken = new MockLinkToken();
        
        game = new TestableGame();
        game.initializeTest(player, bet, factory, address(mockVRF), address(token), address(linkToken));
        
        // Fund game with tokens (backed minting)
        vm.deal(address(this), 1100 ether); // Need POL for 11x bet
        token.buyTokens{value: 1100 ether}(); // Mints backed tokens
        token.transfer(address(game), bet * 11); // Transfer to game
        
        // Deal LINK to game (use mock LINK address)
        vm.deal(address(game), 1 ether);
    }
    
    function testHandProgressionForward() public {
        // Setup: Create 3 hands by simulating a split scenario
        game.setState(GameUpgradeable.GameState.PlayerTurn);
        
        // Manually create 3 hands (simulating splits)
        // Hand 0: not stood, not busted
        // Hand 1: not stood, not busted (current)
        // Hand 2: not stood, not busted
        
        // Add two more hands
        game.addHand(50 * 10**18);
        game.addHand(50 * 10**18);
        
        // Set current hand to 1
        game.setCurrentHand(1);
        
        // Give each hand some cards
        game.addCardToHand(0, 5); // Hand 0: 5
        game.addCardToHand(1, 6); // Hand 1: 6
        game.addCardToHand(2, 7); // Hand 2: 7
        
        // Verify initial state
        assertEq(game.currentHand(), 1, "Should start at hand 1");
        
        // Player stands on hand 1
        vm.prank(player);
        game.stand();
        
        // Should now be on hand 2 (not back to hand 0!)
        assertEq(game.currentHand(), 2, "Should progress to hand 2, not back to hand 0");
        assertEq(uint(game.state()), uint(GameUpgradeable.GameState.PlayerTurn), "Should still be player turn");
    }
    
    function testHandProgressionToDealer() public {
        // Setup: Create 2 hands
        game.setState(GameUpgradeable.GameState.PlayerTurn);
        game.addHand(50 * 10**18);
        
        // Set current hand to 1 (last hand)
        game.setCurrentHand(1);
        
        game.addCardToHand(0, 5);
        game.addCardToHand(1, 6);
        
        // Stand hand 0 first
        game.setHandStood(0, true);
        
        // Now stand on last hand (hand 1)
        vm.prank(player);
        game.stand();
        
        // Should move to dealer turn (no more hands)
        assertEq(uint(game.state()), uint(GameUpgradeable.GameState.DealerTurn), "Should move to dealer turn");
    }
    
    function testHandProgressionAfterBust() public {
        // Setup: 3 hands
        game.setState(GameUpgradeable.GameState.PlayerTurn);
        game.addHand(50 * 10**18);
        game.addHand(50 * 10**18);
        
        game.setCurrentHand(0);
        
        // Give hand 0 cards that will bust (10 + 10 + 10 = 30)
        game.addCardToHand(0, 10); // 10
        game.addCardToHand(0, 23); // King (10)
        game.addCardToHand(0, 36); // King (10)
        
        // Simulate player hitting and busting on hand 0
        game.simulatePlayerHit(49); // Queen (10) -> busts
        
        // Should progress to hand 1
        assertEq(game.currentHand(), 1, "Should progress to hand 1 after bust");
        assertEq(uint(game.state()), uint(GameUpgradeable.GameState.PlayerTurn), "Should still be player turn");
    }
    
    function testHandProgressionAfterDoubleDown() public {
        // Setup: 3 hands
        game.setState(GameUpgradeable.GameState.PlayerTurn);
        game.addHand(50 * 10**18);
        game.addHand(50 * 10**18);
        
        game.setCurrentHand(1); // Start at middle hand
        
        game.addCardToHand(0, 5);
        game.addCardToHand(1, 6);
        game.addCardToHand(1, 7); // Hand 1 has 2 cards
        game.addCardToHand(2, 8);
        
        // Mark hand 1 as doubled
        game.setHandDoubled(1, true);
        
        // Simulate getting one more card (auto-stand after double)
        game.simulatePlayerHit(10);
        
        // Should progress to hand 2
        assertEq(game.currentHand(), 2, "Should progress to hand 2 after double down");
    }
    
    function testHandProgressionSkipsStoodHands() public {
        // Setup: 4 hands
        game.setState(GameUpgradeable.GameState.PlayerTurn);
        game.addHand(50 * 10**18);
        game.addHand(50 * 10**18);
        game.addHand(50 * 10**18);
        
        game.setCurrentHand(0);
        
        // Hand 0: current
        // Hand 1: already stood
        // Hand 2: not stood
        // Hand 3: not stood
        
        game.setHandStood(1, true);
        
        game.addCardToHand(0, 5);
        game.addCardToHand(2, 7);
        game.addCardToHand(3, 8);
        
        // Stand on hand 0
        vm.prank(player);
        game.stand();
        
        // Should skip hand 1 (already stood) and go to hand 2
        assertEq(game.currentHand(), 2, "Should skip stood hand 1 and go to hand 2");
    }
    
    function testHandProgressionWithAllHandsBusted() public {
        // Setup: 2 hands, both will bust
        game.setState(GameUpgradeable.GameState.PlayerTurn);
        game.addHand(50 * 10**18);
        
        game.setCurrentHand(0);
        
        // Hand 0 busts
        game.addCardToHand(0, 10);
        game.addCardToHand(0, 23);
        game.simulatePlayerHit(36); // Busts with 30
        
        // Hand 1 busts
        game.setCurrentHand(1);
        game.addCardToHand(1, 11);
        game.addCardToHand(1, 24);
        game.simulatePlayerHit(37); // Busts with 30
        
        // Should move to dealer turn
        assertEq(uint(game.state()), uint(GameUpgradeable.GameState.DealerTurn), "Should move to dealer turn after all hands bust");
    }
    
    function testCurrentHandNeverGoesBackwards() public {
        // Critical test: Ensure currentHand never decreases
        game.setState(GameUpgradeable.GameState.PlayerTurn);
        game.addHand(50 * 10**18);
        game.addHand(50 * 10**18);
        game.addHand(50 * 10**18);
        
        // Start at hand 2 (third hand)
        game.setCurrentHand(2);
        
        game.addCardToHand(0, 5);
        game.addCardToHand(1, 6);
        game.addCardToHand(2, 7);
        game.addCardToHand(3, 8);
        
        uint8 beforeStand = game.currentHand();
        assertEq(beforeStand, 2, "Should be at hand 2");
        
        // Stand on hand 2
        vm.prank(player);
        game.stand();
        
        uint8 afterStand = game.currentHand();
        
        // Should either stay at 2 (if hand 3 exists and isn't stood)
        // or move to dealer turn (no hands after 2)
        // But should NEVER go back to 0 or 1
        if (uint(game.state()) == uint(GameUpgradeable.GameState.PlayerTurn)) {
            assertGe(afterStand, beforeStand, "Current hand should never decrease");
        } else {
            // Moved to dealer turn - this is acceptable
            assertEq(uint(game.state()), uint(GameUpgradeable.GameState.DealerTurn), "Should be dealer turn");
        }
    }
}
