// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {GameUpgradeable} from "../GameUpgradeable.sol";
import {CardLogic} from "./CardLogic.sol";
import {HandProgressionLogic} from "./HandProgressionLogic.sol";

// Custom errors
error NotPlayerTurn();
error HandAlreadyStood();
error HandBusted();
error CannotHitAfterDouble();
error TooManyHands();

/**
 * @title PlayerActionsLogic
 * @notice External library for player action logic (hit, stand, double, split, etc.)
 */
library PlayerActionsLogic {
    
    /**
     * @notice Validate hit preconditions
     */
    function validateHit(
        uint8 state,
        uint8 currentHand,
        GameUpgradeable.Hand[] storage playerHands
    ) external view {
        if (state != 3) revert NotPlayerTurn(); // PlayerTurn = 3
        if (playerHands[currentHand].stood) revert HandAlreadyStood();
        if (playerHands[currentHand].busted) revert HandBusted();
        if (playerHands[currentHand].doubled) revert CannotHitAfterDouble();
    }
    
    /**
     * @notice Process stand action and determine next state
     */
    function processStand(
        uint8 currentHand,
        GameUpgradeable.Hand[] storage playerHands
    ) external view returns (uint8 nextHand, bool moveToDealerTurn) {
        nextHand = HandProgressionLogic.findNextHand(playerHands, currentHand);
        moveToDealerTurn = (nextHand == type(uint8).max);
    }
    
    /**
     * @notice Validate double down preconditions
     */
    function validateDoubleDown(
        uint8 state,
        uint8 currentHand,
        GameUpgradeable.Hand[] storage playerHands
    ) external view returns (uint256 additionalBet) {
        if (state != 3) revert NotPlayerTurn(); // PlayerTurn = 3
        require(playerHands[currentHand].cards.length >= 1 && playerHands[currentHand].cards.length <= 2, "Can only double on first hand");
        if (playerHands[currentHand].stood) revert HandAlreadyStood();
        require(!playerHands[currentHand].doubled, "Already doubled");
        additionalBet = playerHands[currentHand].bet;
    }
    
    /**
     * @notice Apply double down to hand
     */
    function applyDoubleDown(
        uint8 currentHand,
        GameUpgradeable.Hand[] storage playerHands,
        uint256 additionalBet
    ) external {
        playerHands[currentHand].bet += additionalBet;
        playerHands[currentHand].doubled = true;
    }
    
    /**
     * @notice Validate split preconditions
     */
    function validateSplit(
        uint8 state,
        uint8 currentHand,
        GameUpgradeable.Hand[] storage playerHands
    ) external view returns (uint8 card1, uint8 card2, uint256 additionalBet) {
        if (state != 3) revert NotPlayerTurn(); // PlayerTurn = 3
        if (playerHands.length >= 4) revert TooManyHands();
        require(playerHands[currentHand].cards.length == 2, "Can only split 2 cards");
        
        card1 = playerHands[currentHand].cards[0];
        card2 = playerHands[currentHand].cards[1];
        require(CardLogic.getCardRank(card1) == CardLogic.getCardRank(card2), "Cards must match");
        
        additionalBet = playerHands[currentHand].bet;
    }
    
    /**
     * @notice Execute split logic
     */
    function executeSplitLogic(
        uint8 currentHand,
        GameUpgradeable.Hand[] storage playerHands,
        uint8 card1,
        uint8 card2,
        uint256 additionalBet
    ) external {
        delete playerHands[currentHand].cards;
        playerHands[currentHand].cards.push(card1);

        GameUpgradeable.Hand memory newHand;
        newHand.cards = new uint8[](1);
        newHand.cards[0] = card2;
        newHand.bet = additionalBet;
        playerHands.push(newHand);
    }
    
    /**
     * @notice Check if insurance is offered
     */
    function shouldOfferInsurance(
        uint8[] storage dealerCards
    ) external view returns (bool) {
        return dealerCards.length > 0 && 
               CardLogic.getCardRank(dealerCards[0]) == 1; // Dealer shows Ace
    }
    
    /**
     * @notice Calculate insurance payout
     */
    function calculateInsurancePayout(
        bool hasInsurance,
        uint256 insuranceBet,
        uint8[] storage dealerCards
    ) external view returns (uint256 payout) {
        if (!hasInsurance) return 0;
        
        // Check if dealer has blackjack
        if (dealerCards.length == 2 && CardLogic.calculateScore(dealerCards) == 21) {
            return insuranceBet * 2; // Insurance pays 2:1
        }
        return 0;
    }
    
    /**
     * @notice Check if hand is busted
     */
    function isBusted(uint8[] storage cards) external pure returns (bool) {
        return CardLogic.calculateScore(cards) > 21;
    }
    
    /**
     * @notice Check if hand is blackjack
     */
    function isBlackjack(uint8[] storage cards) external view returns (bool) {
        return cards.length == 2 && CardLogic.calculateScore(cards) == 21;
    }
}
