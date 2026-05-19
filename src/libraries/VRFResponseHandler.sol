// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {CardLogic} from "./CardLogic.sol";
import {GameRandomnessLogic} from "./GameRandomnessLogic.sol";
import {HandProgressionLogic} from "./HandProgressionLogic.sol";
import {VRFFulfillmentLogic} from "./VRFFulfillmentLogic.sol";

/**
 * @title VRFResponseHandler
 * @notice Library to reduce GameUpgradeable bytecode by handling VRF response logic
 * @dev Using a library with `using for` to avoid delegate call overhead
 */
library VRFResponseHandler {
    /**
     * @notice Process initial deal randomness
     * @dev Returns values to update in the calling contract
     */
    function processInitialDeal(
        uint256 random
    ) internal pure returns (
        uint8 card1,
        uint8 card2, 
        uint8 card3,
        bool playerHasBlackjack,
        bool shouldOfferInsurance
    ) {
        (card1, card2, card3) = GameRandomnessLogic.handleInitialDeal(random);
        
        // Check player score with 2 cards
        uint8[] memory playerCards = new uint8[](2);
        playerCards[0] = card1;
        playerCards[1] = card2;
        uint8 playerScore = CardLogic.calculateScore(playerCards);
        playerHasBlackjack = (playerScore == 21);
        
        uint8 dealerUpCardRank = CardLogic.getCardRank(card3);
        shouldOfferInsurance = (dealerUpCardRank == 1); // Ace
        
        return (card1, card2, card3, playerHasBlackjack, shouldOfferInsurance);
    }
    
    /**
     * @notice Process player hit randomness
     * @dev Calculates new card and checks for bust
     */
    function processPlayerHit(
        uint256 random,
        uint8 currentHand,
        uint8[] memory currentHandCards
    ) internal pure returns (
        uint8 newCard,
        bool busted
    ) {
        newCard = GameRandomnessLogic.handlePlayerHit(random, currentHand);
        
        // Create new array with the new card to check score
        uint8[] memory updatedCards = new uint8[](currentHandCards.length + 1);
        for (uint i = 0; i < currentHandCards.length; i++) {
            updatedCards[i] = currentHandCards[i];
        }
        updatedCards[currentHandCards.length] = newCard;
        
        uint8 score = CardLogic.calculateScore(updatedCards);
        busted = (score > 21);
        
        return (newCard, busted);
    }
    
    /**
     * @notice Process dealer hit randomness  
     */
    function processDealerHit(
        uint256 random
    ) internal pure returns (uint8 newCard) {
        return GameRandomnessLogic.handleDealerHit(random);
    }
    
    /**
     * @notice Process split randomness
     * @dev Returns two cards, one for each split hand
     */
    function processSplit(
        uint256 random
    ) internal pure returns (uint8 card1, uint8 card2) {
        card1 = VRFFulfillmentLogic.getCardFromRandom(random);
        card2 = VRFFulfillmentLogic.getCardFromRandom(random >> 8);
        return (card1, card2);
    }
    
    /**
     * @notice Process dealer hole card and check for blackjack
     */
    function processDealerHoleCard(
        uint256 random,
        uint8 dealerUpCard
    ) internal pure returns (
        uint8 holeCard,
        bool dealerHasBlackjack
    ) {
        holeCard = GameRandomnessLogic.handleDealerHit(random);
        
        // Check for dealer blackjack with 2 cards
        uint8[] memory dealerCards = new uint8[](2);
        dealerCards[0] = dealerUpCard;
        dealerCards[1] = holeCard;
        uint8 dealerScore = CardLogic.calculateScore(dealerCards);
        dealerHasBlackjack = (dealerScore == 21);
        
        return (holeCard, dealerHasBlackjack);
    }
}
