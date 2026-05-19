// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {GameUpgradeable} from "../GameUpgradeable.sol";
import {CardLogic} from "./CardLogic.sol";
import {GameRandomnessLogic} from "./GameRandomnessLogic.sol";
import {HandProgressionLogic} from "./HandProgressionLogic.sol";
import {VRFFulfillmentLogic} from "./VRFFulfillmentLogic.sol";

/**
 * @title VRFFulfillmentHandler
 * @notice External library to handle VRF randomness fulfillment
 * @dev Uses external functions to reduce GameUpgradeable bytecode size
 */
library VRFFulfillmentHandler {
    
    /**
     * @notice Handle PlayerHit request fulfillment
     */
    function handlePlayerHit(
        GameUpgradeable.Hand[] storage playerHands,
        uint8 currentHand,
        uint256 random
    ) external returns (uint8 newCurrentHand, bool shouldPlayDealer) {
        uint8 newCard = GameRandomnessLogic.handlePlayerHit(random, currentHand);
        playerHands[currentHand].cards.push(newCard);
        
        uint8 score = CardLogic.calculateScore(playerHands[currentHand].cards);
        if (score > 21) {
            playerHands[currentHand].busted = true;
            playerHands[currentHand].stood = true;
        }
        
        if (playerHands[currentHand].busted || playerHands[currentHand].doubled) {
            playerHands[currentHand].stood = true;
            uint8 nextHand = HandProgressionLogic.findNextHand(playerHands, currentHand);
            if (nextHand != type(uint8).max) {
                return (nextHand, false);
            } else {
                return (currentHand, true); // Move to dealer turn
            }
        }
        
        return (currentHand, false);
    }
    
    /**
     * @notice Handle Split request fulfillment
     */
    function handleSplit(
        GameUpgradeable.Hand[] storage playerHands,
        uint8 currentHand,
        uint256 random
    ) external returns (uint8 card1, uint8 card2) {
        card1 = VRFFulfillmentLogic.getCardFromRandom(random);
        card2 = VRFFulfillmentLogic.getCardFromRandom(random >> 8);
        playerHands[currentHand].cards.push(card1);
        playerHands[playerHands.length - 1].cards.push(card2);
        return (card1, card2);
    }
    
    /**
     * @notice Handle DealerHit request fulfillment
     */
    function handleDealerHit(
        uint8[] storage dealerCards,
        uint256 random
    ) external returns (uint8 newCard) {
        newCard = GameRandomnessLogic.handleDealerHit(random);
        dealerCards.push(newCard);
        return newCard;
    }
    
    /**
     * @notice Handle InitialDeal request fulfillment
     */
    function handleInitialDeal(
        GameUpgradeable.Hand[] storage playerHands,
        uint8[] storage dealerCards,
        uint256 random
    ) external returns (
        bool playerHasBlackjack,
        bool shouldOfferInsurance,
        uint8 dealerUpCard
    ) {
        (uint8 card1, uint8 card2, uint8 card3) = GameRandomnessLogic.handleInitialDeal(random);
        playerHands[0].cards.push(card1);
        playerHands[0].cards.push(card2);
        dealerCards.push(card3);
        dealerUpCard = card3;
        
        uint8 playerScore = CardLogic.calculateScore(playerHands[0].cards);
        playerHasBlackjack = (playerScore == 21);
        
        uint8 dealerUpCardRank = CardLogic.getCardRank(dealerCards[0]);
        shouldOfferInsurance = (dealerUpCardRank == 1); // Ace is rank 1
        
        return (playerHasBlackjack, shouldOfferInsurance, dealerUpCard);
    }
    
    /**
     * @notice Handle DealerHoleCard request fulfillment
     */
    function handleDealerHoleCard(
        uint8[] storage dealerCards,
        uint256 random
    ) external returns (bool dealerHasBlackjack) {
        uint8 holeCard = GameRandomnessLogic.handleDealerHit(random);
        dealerCards.push(holeCard);
        
        uint8 dealerScore = CardLogic.calculateScore(dealerCards);
        dealerHasBlackjack = (dealerScore == 21 && dealerCards.length == 2);
        
        return dealerHasBlackjack;
    }
}
