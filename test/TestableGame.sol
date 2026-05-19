// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {GameUpgradeable, IGameToken} from "../src/GameUpgradeable.sol";
import {CardLogic} from "../src/libraries/CardLogic.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {VRFConsumerBaseV2Plus} from "lib/foundry-chainlink-toolkit/lib/chainlink-brownie-contracts/contracts/src/v0.8/dev/vrf/VRFConsumerBaseV2Plus.sol";
import {IVRFCoordinatorV2Plus} from "lib/foundry-chainlink-toolkit/lib/chainlink-brownie-contracts/contracts/src/v0.8/dev/interfaces/IVRFCoordinatorV2Plus.sol";

// Import errors from GameUpgradeable
error OnlyFactory();
error UnknownRequest();
error GameHasExpired();
error StaleRequest();

/**
 * @title TestableGame
 * @notice Game contract with testing helpers for unit tests only
 * @dev Testing Library - excludeContract(true) tells fuzzer to ignore this
 */
contract TestableGame is GameUpgradeable {
    /// @custom:exclude-contracts true
    bool private constant IS_TEST_HELPER = true;
    
    // Override onlyFactory modifier to allow test calls
    modifier onlyFactory() override {
        // In tests, allow calls from test contract or factory
        require(msg.sender == factory || msg.sender == address(this), "Only factory");
        _;
    }
    
    // Use dummy constructor like GameImplementation
    constructor() GameUpgradeable(
        address(0xdead),  // _player - use sentinel value that won't conflict with test addresses
        1,                // _bet
        address(0xdead),  // _factory
        address(0xdead),  // _vrfCoordinator
        address(0xdead),  // _gameToken
        address(0xdead)   // _linkToken
    ) {
        // Lock with dummy value so initializeTest can check initialization state
        player = address(0xdead);
    }
    
    /**
     * @notice Initialize for testing (like initializeClone but for direct instantiation)
     */
    function initializeTest(
        address _player,
        uint256 _bet,
        address _factory,
        address /* _vrfCoordinator */,
        address _gameTokenAddress,
        address _linkTokenAddress
    ) external {
        require(player == address(0xdead), "Already initialized");
        player = _player;
        bet = _bet;
        factory = _factory;
        createdAt = block.timestamp;
        state = GameState.NotStarted;
        // Note: s_vrfCoordinator no longer used - factory handles VRF
        gameToken = IGameToken(_gameTokenAddress);
        linkToken = IERC20(_linkTokenAddress);
        
        // Clear playerHands array (constructor already pushed one hand with dummy data)
        delete playerHands;
        // Now push the real initial hand
        playerHands.push(Hand({cards: new uint8[](0), bet: _bet, stood: false, busted: false, doubled: false}));
    }

    /**
     * @notice Test helper to fulfill VRF request
     * @dev Automatically registers the request ID before fulfilling
     * @dev Silently returns if not initialized to allow fuzzing without failures
     */
    function testFulfill(uint256 _requestId, uint256[] memory randomWords) external {
        // Skip fuzz runs where game is not initialized
        if (player == address(0) || player == address(0xdead)) {
            return;
        }
        
        // If the request isn't registered, register it based on current state
        if (pendingRequests[_requestId] == RequestType.None) {
            if (state == GameState.Dealing) {
                if (isPlayerHitting()) {
                    pendingRequests[_requestId] = RequestType.PlayerHit;
                } else if (isDealerHitting()) {
                    pendingRequests[_requestId] = RequestType.DealerHit;
                } else {
                    pendingRequests[_requestId] = RequestType.InitialDeal;
                }
            } else {
                // For fuzz testing, just register as InitialDeal if state is appropriate
                pendingRequests[_requestId] = RequestType.InitialDeal;
            }
        }
        
        // Ensure we have a valid request type before fulfilling
        require(pendingRequests[_requestId] != RequestType.None, "Invalid request");
        // Call receiveRandomness - onlyFactory modifier is overridden to allow this
        this.receiveRandomness(_requestId, randomWords);
    }

    /**
     * @notice Test helper to set cards directly
     * @dev Silently returns if not initialized to allow fuzzing without failures
     */
    function testSetCards(uint8[] memory _playerCards, uint8[] memory _dealerCards) external {
        // Skip fuzz runs where game is not initialized
        if (player == address(0) || player == address(0xdead)) {
            return;
        }
        require(msg.sender == player, "Not your game");
        
        playerHands[0].cards = _playerCards;
        dealerCards = _dealerCards;
        uint8 playerScore = CardLogic.calculateScore(playerHands[0].cards);
        if (playerScore == 21) _setPlayerHasBlackjack(true);
        uint8 dealerScore = CardLogic.calculateScore(dealerCards);
        if (dealerScore == 21) _setDealerHasBlackjack(true);
        
        // Check if dealer shows an Ace (insurance opportunity)
        uint8 dealerUpCardRank = CardLogic.getCardRank(dealerCards[0]);
        bool dealerShowsAce = (dealerUpCardRank == 1);
        
        // If dealer shows Ace, offer insurance (even if dealer has blackjack)
        if (dealerShowsAce) {
            state = GameState.InsuranceOffer;
            emit CardsDealt(playerHands[0].cards, dealerCards[0]);
            return;
        }
        
        // If no insurance offer and either has blackjack, finish immediately
        if (playerHasBlackjack() || dealerHasBlackjack()) {
            state = GameState.Finished;
            determineWinner();
            return;
        }
        
        // Normal play continues
        state = GameState.PlayerTurn;
        emit CardsDealt(playerHands[0].cards, dealerCards[0]);
    }
    
    /**
     * @notice Test helper to set game state
     */
    function setState(GameState _state) external {
        state = _state;
    }
    
    /**
     * @notice Test helper to add a new hand
     */
    function addHand(uint256 _bet) external {
        Hand memory newHand = Hand(new uint8[](0), _bet, false, false, false);
        playerHands.push(newHand);
    }
    
    /**
     * @notice Test helper to set current hand
     */
    function setCurrentHand(uint8 _handIndex) external {
        currentHand = _handIndex;
    }
    
    /**
     * @notice Test helper to add card to specific hand
     */
    function addCardToHand(uint256 handIndex, uint8 cardId) external {
        playerHands[handIndex].cards.push(cardId);
    }
    
    /**
     * @notice Test helper to set hand as stood
     */
    function setHandStood(uint256 handIndex, bool _stood) external {
        playerHands[handIndex].stood = _stood;
    }
    
    /**
     * @notice Test helper to set hand as busted
     */
    function setHandBusted(uint256 handIndex, bool _busted) external {
        playerHands[handIndex].busted = _busted;
    }
    
    /**
     * @notice Test helper to set hand as doubled
     */
    function setHandDoubled(uint256 handIndex, bool _doubled) external {
        playerHands[handIndex].doubled = _doubled;
    }
    
    /**
     * @notice Test helper to simulate player hit result
     * @dev Simulates the fulfillRandomWords logic for player hit
     */
    function simulatePlayerHit(uint8 cardId) external {
        playerHands[currentHand].cards.push(cardId);
        uint8 score = CardLogic.calculateScore(playerHands[currentHand].cards);
        if (score > 21) {
            playerHands[currentHand].busted = true;
            playerHands[currentHand].stood = true;
        }
        
        if (playerHands[currentHand].busted || playerHands[currentHand].doubled) {
            playerHands[currentHand].stood = true;
            
            // Look for next hand AFTER current hand
            bool foundNext = false;
            for (uint8 i = currentHand + 1; i < playerHands.length; i++) {
                if (!playerHands[i].stood && !playerHands[i].busted) {
                    currentHand = i;
                    foundNext = true;
                    break;
                }
            }
            
            // If no next hand found, move to dealer turn
            if (!foundNext) {
                state = GameState.DealerTurn;
            }
        }
    }
}
