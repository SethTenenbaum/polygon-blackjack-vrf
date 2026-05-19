// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {CardLogic} from "./CardLogic.sol";
import {GameRandomnessLogic} from "./GameRandomnessLogic.sol";
import {HandProgressionLogic} from "./HandProgressionLogic.sol";
import {VRFFulfillmentLogic} from "./VRFFulfillmentLogic.sol";

/**
 * @title RandomnessFulfillmentLib
 * @notice Library to handle VRF randomness fulfillment logic - INLINE functions only
 * @dev Extracted from GameUpgradeable to reduce contract size
 * @dev All functions are internal view/pure to avoid delegatecall issues
 */
library RandomnessFulfillmentLib {
    
    /**
     * @notice Handle randomness fulfillment for initial deal
     * @param random The random number
     * @param playerHand The player's hand to update
     * @param dealerCards The dealer's cards array
     * @param _flags Current flags state
     * @return newState The new game state
     * @return updatedFlags The updated flags
     * @return shouldDetermineWinner Whether to determine winner immediately
     */
    function handleInitialDealFulfillment(
        uint256 random,
        Hand storage playerHand,
        uint8[] storage dealerCards,
        uint256 _flags
    ) external returns (
        GameState newState,
        uint256 updatedFlags,
        bool shouldDetermineWinner
    ) {
        (uint8 card1, uint8 card2, uint8 card3) = GameRandomnessLogic.handleInitialDeal(random);
        playerHand.cards.push(card1);
        playerHand.cards.push(card2);
        dealerCards.push(card3);
        
        uint8 playerScore = CardLogic.calculateScore(playerHand.cards);
        if (playerScore == 21) {
            // Set player has blackjack flag (bit 3)
            updatedFlags = _flags | 8;
            return (GameState.Finished, updatedFlags, true);
        }
        
        uint8 dealerUpCardRank = CardLogic.getCardRank(dealerCards[0]);
        if (dealerUpCardRank == 1) {  // Ace is rank 1
            newState = GameState.InsuranceOffer;
        } else {
            newState = GameState.PlayerTurn;
        }
        
        emit CardsDealt(playerHand.cards, dealerCards[0]);
        return (newState, _flags, false);
    }
    
    /**
     * @notice Handle randomness fulfillment for player hit
     * @param random The random number
     * @param currentHand Current hand index
     * @param playerHands Array of player hands
     * @param _flags Current flags state
     * @return newState The new game state
     * @return updatedCurrentHand The updated current hand index
     * @return updatedFlags The updated flags
     * @return shouldPlayDealer Whether to play dealer after this
     */
    function handlePlayerHitFulfillment(
        uint256 random,
        uint8 currentHand,
        Hand[] storage playerHands,
        uint256 _flags
    ) external returns (
        GameState newState,
        uint8 updatedCurrentHand,
        uint256 updatedFlags,
        bool shouldPlayDealer
    ) {
        uint8 newCard = GameRandomnessLogic.handlePlayerHit(random, currentHand);
        playerHands[currentHand].cards.push(newCard);
        
        // Clear isPlayerHitting flag (bit 0)
        updatedFlags = _flags & ~uint256(1);
        newState = GameState.PlayerTurn;
        
        uint8 score = CardLogic.calculateScore(playerHands[currentHand].cards);
        if (score > 21) {
            playerHands[currentHand].busted = true;
            playerHands[currentHand].stood = true;
        }
        
        emit PlayerHit(newCard);
        
        if (playerHands[currentHand].busted || playerHands[currentHand].doubled) {
            playerHands[currentHand].stood = true;
            uint8 nextHand = HandProgressionLogic.findNextHand(playerHands, currentHand);
            if (nextHand != type(uint8).max) {
                updatedCurrentHand = nextHand;
                shouldPlayDealer = false;
            } else {
                newState = GameState.DealerTurn;
                updatedCurrentHand = currentHand;
                shouldPlayDealer = true;
            }
        } else {
            updatedCurrentHand = currentHand;
            shouldPlayDealer = false;
        }
        
        return (newState, updatedCurrentHand, updatedFlags, shouldPlayDealer);
    }
    
    /**
     * @notice Handle randomness fulfillment for split
     * @param random The random number
     * @param currentHand Current hand index
     * @param playerHands Array of player hands
     * @param _flags Current flags state
     * @return updatedFlags The updated flags
     */
    function handleSplitFulfillment(
        uint256 random,
        uint8 currentHand,
        Hand[] storage playerHands,
        uint256 _flags
    ) external returns (uint256 updatedFlags) {
        uint8 card1 = VRFFulfillmentLogic.getCardFromRandom(random);
        uint8 card2 = VRFFulfillmentLogic.getCardFromRandom(random >> 8);
        playerHands[currentHand].cards.push(card1);
        playerHands[playerHands.length - 1].cards.push(card2);
        
        // Clear isPlayerHitting flag (bit 0)
        updatedFlags = _flags & ~uint256(1);
        
        emit PlayerHit(card1);
        emit PlayerHit(card2);
        
        return updatedFlags;
    }
    
    /**
     * @notice Handle randomness fulfillment for dealer hit
     * @param random The random number
     * @param dealerCards The dealer's cards array
     * @param _flags Current flags state
     * @return updatedFlags The updated flags
     */
    function handleDealerHitFulfillment(
        uint256 random,
        uint8[] storage dealerCards,
        uint256 _flags
    ) external returns (uint256 updatedFlags) {
        uint8 newCard = GameRandomnessLogic.handleDealerHit(random);
        dealerCards.push(newCard);
        
        // Clear isDealerHitting flag (bit 1)
        updatedFlags = _flags & ~uint256(2);
        
        return updatedFlags;
    }
    
    /**
     * @notice Handle randomness fulfillment for dealer hole card
     * @param random The random number
     * @param dealerCards The dealer's cards array
     * @param _flags Current flags state
     * @return updatedFlags The updated flags
     */
    function handleDealerHoleCardFulfillment(
        uint256 random,
        uint8[] storage dealerCards,
        uint256 _flags
    ) external returns (uint256 updatedFlags) {
        uint8 holeCard = GameRandomnessLogic.handleDealerHit(random);
        dealerCards.push(holeCard);
        
        // Clear isDealerHitting flag (bit 1)
        updatedFlags = _flags & ~uint256(2);
        
        // Check for dealer blackjack
        uint8 dealerScore = CardLogic.calculateScore(dealerCards);
        if (dealerScore == 21 && dealerCards.length == 2) {
            // Set dealerHasBlackjack flag (bit 2)
            updatedFlags = updatedFlags | 4;
        }
        
        return updatedFlags;
    }
}
