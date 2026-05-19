// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./CardLogic.sol";
import "./DealerLogic.sol";
import "./HandProgressionLogic.sol";
import "./WinnerDeterminationLogic.sol";
import "./GameActionsLib.sol";

/**
 * @title GameFlowLib
 * @notice Library for dealer play result determination
 * @dev Externalized to reduce GameUpgradeable contract size
 * @dev NOTE: This library does NOT define its own Hand struct to avoid type conflicts
 */
library GameFlowLib {
    
    struct DealerPlayResult {
        uint8 newState; // 3=DealerTurn, 4=Finished, 5=Dealing
        bool needsHoleCard;
        bool isFinished;
        bool needsMoreCards;
    }
    
    /**
     * @notice Determine what should happen in dealer play without modifying state
     * @param allHandsBusted True if all player hands are busted
     * @param dealerCardsLength Number of dealer cards
     * @param dealerCards The dealer's current cards
     * @return result Struct containing new state and what actions are needed
     */
    function checkDealerPlay(
        bool allHandsBusted,
        uint256 dealerCardsLength,
        uint8[] memory dealerCards
    ) external pure returns (DealerPlayResult memory result) {
        // Optimization: If all player hands are busted, skip dealer play entirely
        if (allHandsBusted) {
            result.newState = 4; // GameState.Finished
            result.isFinished = true;
            return result;
        }
        
        // SECURITY FIX: If dealer only has 1 card (up card), request the hole card via VRF
        if (dealerCardsLength == 1) {
            result.newState = 5; // GameState.Dealing
            result.needsHoleCard = true;
            return result;
        }
        
        // Dealer has hole card, determine if dealer should hit or stand
        uint8 dealerScore = CardLogic.calculateScore(dealerCards);
        bool isSoft17 = _isSoft17(dealerCards, dealerScore);
        
        // Dealer must hit on < 17 or soft 17
        bool shouldHit = (dealerScore < 17) || (dealerScore == 17 && isSoft17);
        
        if (shouldHit) {
            result.newState = 3; // GameState.DealerTurn
            result.needsMoreCards = true;
        } else {
            result.newState = 4; // GameState.Finished
            result.isFinished = true;
        }
        
        return result;
    }
    
    /**
     * @notice Check if hand is soft 17 (Ace + 6)
     */
    function _isSoft17(uint8[] memory cards, uint8 score) private pure returns (bool) {
        if (score != 17) return false;
        
        // Check if there's an Ace counting as 11
        uint8 total = 0;
        bool hasAce = false;
        for (uint256 i = 0; i < cards.length; i++) {
            uint8 rank = CardLogic.getCardRank(cards[i]);
            if (rank == 1) {
                hasAce = true;
                total += 1; // Count ace as 1 initially
            } else if (rank > 10) {
                total += 10;
            } else {
                total += rank;
            }
        }
        
        // If we have an ace and total + 10 == 17, it's soft 17
        return hasAce && (total + 10 == 17);
    }
}
