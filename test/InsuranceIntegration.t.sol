// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "./TestableGame.sol";
import "../src/GameToken.sol";
import {CardLogic} from "../src/libraries/CardLogic.sol";

// Mock VRF Coordinator for testing
contract MockVRFCoordinator {
    uint256 public requestIdCounter;
    mapping(uint256 => address) public requesters;
    
    struct RandomWordsRequest {
        bytes32 keyHash;
        uint256 subId;
        uint16 requestConfirmations;
        uint32 callbackGasLimit;
        uint32 numWords;
        bytes extraArgs;
    }
    
    function requestRandomWords(
        RandomWordsRequest calldata /* req */
    ) external returns (uint256 requestId) {
        requestId = ++requestIdCounter;
        requesters[requestId] = msg.sender;
        return requestId;
    }
}

// Mock LINK Token for testing
contract MockLinkToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    
    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }
    
    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
    
    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }
    
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/**
 * @title InsuranceIntegrationTest
 * @notice Integration tests for insurance mechanics using REAL VRF fulfillment path
 * @dev This test suite exercises the actual production code path, not mocked versions
 * 
 * WHY THIS TEST IS NEEDED:
 * - Previous unit tests used TestableGame which had different logic than production
 * - Bug in production: checked for dealerUpCardRank == 0 instead of == 1
 * - TestableGame correctly checked == 1, so tests passed but production failed
 * - This integration test uses the REAL fulfillRandomWords() path
 */
contract InsuranceIntegrationTest is Test {
    MockVRFCoordinator vrfCoordinator;
    MockLinkToken linkToken;
    GameToken gameToken;
    TestableGame game;
    
    address player = address(0x1234);
    uint256 betAmount = 10 ether;
    uint256 linkFee = 0.005 ether;
    
    // Implement IGameFactory interface to prevent revert when game finishes
    function notifyGameFinished() external {
        // Do nothing, just prevent revert
    }
    
    // Implement IGameFactory.requestVRFForGame to simulate factory VRF requests
    function requestVRFForGame(uint32, uint32) external view returns (uint256) {
        return vrfCoordinator.requestIdCounter() + 1;
    }
    
    function setUp() public {
        // Deploy mock contracts
        vrfCoordinator = new MockVRFCoordinator();
        linkToken = new MockLinkToken();
        gameToken = new GameToken();
        
        // Deploy testable game
        game = new TestableGame();
        game.initializeTest(
            player,
            betAmount,
            address(this), // factory
            address(vrfCoordinator),
            address(gameToken),
            address(linkToken)
        );
        
        // Fund game with tokens and LINK
        gameToken.buyTokens{value: 20 ether}();
        gameToken.transfer(address(game), 200 ether);
        linkToken.mint(address(game), 1 ether);
    }
    
    /**
     * @notice Test that insurance IS offered when dealer's first card is an Ace
     * @dev This uses the REAL VRF fulfillment path, not testSetCards()
     * 
     * NOTE: handleInitialDeal extracts 3 cards from ONE random word using bit shifting:
     * - card1 = random % 52 + 1
     * - card2 = (random >> 8) % 52 + 1
     * - card3 = (random >> 16) % 52 + 1 (dealer's up card)
     * 
     * To get dealer Ace (card ID 1), we need (random >> 16) % 52 = 0
     * Simplest: random = 0x00001404 
     * - Player card 1: 0x1404 % 52 + 1 = 20 % 52 + 1 = 21 (safe)
     * - Player card 2: (0x1404 >> 8) % 52 + 1 = 0x14 % 52 + 1 = 20 % 52 + 1 = 21 (safe) 
     * - Dealer card: (0x1404 >> 16) % 52 + 1 = 0 % 52 + 1 = 1 (Ace!)
     */
    function testInsuranceOfferedWithDealerAce() public {
        // Start game (triggers VRF request)
        game.startGame();
        
        // Get the VRF request ID
        uint256 requestId = vrfCoordinator.requestIdCounter();
        address requester = vrfCoordinator.requesters(requestId);
        assertEq(requester, address(game), "VRF request should be from game");
        
        // Create random word that will result in dealer having Ace as third card
        uint256[] memory randomWords = new uint256[](1);
        randomWords[0] = 0x00001404; // Gives dealer card 1 (Ace)
        
        // Fulfill VRF request manually (since mock doesn't auto-fulfill)
        vm.prank(address(vrfCoordinator));
        game.testFulfill(requestId, randomWords);
        
        // Verify game state is InsuranceOffer
        assertEq(
            uint8(game.state()), 
            uint8(GameUpgradeable.GameState.InsuranceOffer),
            "Game should be in InsuranceOffer state when dealer shows Ace"
        );
        
        // Verify dealer's first card is actually an Ace
        uint8[] memory dealerCards = game.getDealerCards();
        uint8 dealerFirstCard = dealerCards[0];
        uint8 rank = CardLogic.getCardRank(dealerFirstCard);
        assertEq(rank, 1, "Dealer's first card should be Ace (rank 1)");
    }
    
    /**
     * @notice Test that insurance is NOT offered when dealer's first card is NOT an Ace
     * @dev Dealer card is (random >> 16) % 52 + 1
     * To get NON-Ace (e.g. card ID 11 = Jack), we need (random >> 16) % 52 = 10
     * So bits 16-23 should be 0x0A (10 in hex)
     */
    function testInsuranceNotOfferedWithoutDealerAce() public {
        game.startGame();
        uint256 requestId = vrfCoordinator.requestIdCounter();
        
        // Create random word where dealer's card is NOT an Ace
        // 0x0A0506 = bits 16-23 are 0x0A (10), so (random >> 16) % 52 = 10, giving card ID 11 (Jack)
        uint256[] memory randomWords = new uint256[](1);
        randomWords[0] = 0x0A0506;
        
        vm.prank(address(vrfCoordinator));
        game.testFulfill(requestId, randomWords);
        
        // Should go directly to PlayerTurn, skip insurance
        assertEq(
            uint8(game.state()),
            uint8(GameUpgradeable.GameState.PlayerTurn),
            "Game should skip insurance when dealer doesn't show Ace"
        );
    }
    
    /**
     * @notice Test insurance when dealer shows Ace
     * @dev After initial deal, dealer only has 1 card (the up card)
     * The hole card is dealt later when dealer's turn starts
     */
    function testInsuranceWithDealerBlackjack() public {
        game.startGame();
        uint256 requestId = vrfCoordinator.requestIdCounter();
        
        // Dealer shows Ace (hole card not dealt yet)
        uint256[] memory randomWords = new uint256[](1);
        randomWords[0] = 0x00001404; // Gives dealer card 1 (Ace)
        
        vm.prank(address(vrfCoordinator));
        game.testFulfill(requestId, randomWords);
        
        // Should offer insurance when dealer shows Ace
        assertEq(
            uint8(game.state()),
            uint8(GameUpgradeable.GameState.InsuranceOffer),
            "Should offer insurance when dealer shows Ace"
        );
        
        // Verify dealer only has 1 card at this point (up card only)
        uint8[] memory dealerCards = game.getDealerCards();
        assertEq(dealerCards.length, 1, "Dealer should only have 1 card after initial deal");
        assertEq(CardLogic.getCardRank(dealerCards[0]), 1, "Dealer up card should be Ace");
    }
    
    /**
     * @notice Fuzz test: Try many random dealer first cards
     * @dev Only Ace (rank 1) should trigger insurance (unless player has blackjack)
     * We need to construct the random value so that (random >> 16) % 52 gives us different cards
     * Also need to ensure player doesn't get blackjack (which would end game immediately)
     */
    function testFuzzInsuranceOnlyWithAce(uint8 dealerCardOffset) public {
        // Bound to valid offset range [0, 51]
        dealerCardOffset = uint8(bound(dealerCardOffset, 0, 51));
        
        game.startGame();
        uint256 requestId = vrfCoordinator.requestIdCounter();
        
        // Construct random value where:
        // - Bits 0-7 give player card 1 (use offset 5 to avoid Ace/10-value issues)
        // - Bits 8-15 give player card 2 (use offset 7 to avoid getting 21)
        // - Bits 16+ control dealer card based on dealerCardOffset
        // Player gets cards (5%52)+1=6 and (7%52)+1=8, totaling 6+8=14 (safe)
        uint256 random = (uint256(dealerCardOffset) << 16) | 0x0705;
        
        uint256[] memory randomWords = new uint256[](1);
        randomWords[0] = random;
        
        vm.prank(address(vrfCoordinator));
        game.testFulfill(requestId, randomWords);
        
        // If player got blackjack, game ends immediately - skip this iteration
        if (uint8(game.state()) == uint8(GameUpgradeable.GameState.Finished)) {
            return; // Player blackjack, test not applicable
        }
        
        uint8 dealerCardId = (dealerCardOffset % 52) + 1; // Card IDs are 1-52
        uint8 rank = CardLogic.getCardRank(dealerCardId);
        uint8 expectedState = (rank == 1) 
            ? uint8(GameUpgradeable.GameState.InsuranceOffer)
            : uint8(GameUpgradeable.GameState.PlayerTurn);
        
        assertEq(
            uint8(game.state()),
            expectedState,
            rank == 1 
                ? "Should offer insurance when dealer shows Ace"
                : "Should NOT offer insurance when dealer doesn't show Ace"
        );
    }
    
    /**
     * @notice Test all 13 card ranks explicitly
     * @dev Only rank 1 (Ace) should trigger insurance
     * Card rank = ((cardId - 1) % 13) + 1
     * So for rank 1: cardId ∈ {1, 14, 27, 40}
     * For rank 2: cardId ∈ {2, 15, 28, 41}, etc.
     */
    function testInsuranceForAllRanks() public {
        for (uint8 rank = 1; rank <= 13; rank++) {
            // Reset for each iteration
            setUp();
            
            game.startGame();
            uint256 requestId = vrfCoordinator.requestIdCounter();
            
            // Calculate card ID with desired rank: cardId = rank (simplest choice)
            // We need (random >> 16) % 52 = cardId - 1 to get this cardId
            uint8 targetOffset = rank == 1 ? 0 : rank - 1;
            uint256 random = (uint256(targetOffset) << 16) | 0x0506;
            
            uint256[] memory randomWords = new uint256[](1);
            randomWords[0] = random;
            
            vm.prank(address(vrfCoordinator));
            game.testFulfill(requestId, randomWords);
            
            if (rank == 1) {
                assertEq(
                    uint8(game.state()),
                    uint8(GameUpgradeable.GameState.InsuranceOffer),
                    string.concat("Rank ", vm.toString(rank), " (Ace) should offer insurance")
                );
            } else {
                // Should skip insurance for all other ranks
                assertEq(
                    uint8(game.state()),
                    uint8(GameUpgradeable.GameState.PlayerTurn),
                    string.concat("Rank ", vm.toString(rank), " should NOT offer insurance")
                );
            }
        }
    }
}
