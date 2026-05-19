// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {GameUpgradeable} from "../GameUpgradeable.sol";
import {CardLogic} from "./CardLogic.sol";

/**
 * @title DealerLogic
 * @notice External library for dealer logic
 */
library DealerLogic {
    
    /**
     * @notice Determine if dealer should hit or stand
     */
    function shouldDealerHit(uint8[] storage dealerCards) external view returns (bool) {
        uint8 score = CardLogic.calculateScore(dealerCards);
        if (score < 17) return true;
        if (score == 17 && isSoft17(dealerCards)) return true;
        return false;
    }
    
    /**
     * @notice Check if hand is soft 17 (Ace + 6)
     */
    function isSoft17(uint8[] storage cards) internal view returns (bool) {
        uint8 score = CardLogic.calculateScore(cards);
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
    
    /**
     * @notice Check if dealer is busted
     */
    function isDealerBusted(uint8[] storage dealerCards) external pure returns (bool) {
        return CardLogic.calculateScore(dealerCards) > 21;
    }
    
    /**
     * @notice Get dealer's final score
     */
    function getDealerScore(uint8[] storage dealerCards) external pure returns (uint8) {
        return CardLogic.calculateScore(dealerCards);
    }
    
    /**
     * @notice Process dealer turn - determines if dealer hits or game ends
     */
    function processDealerTurn(uint8[] storage dealerCards) external view returns (bool shouldHit, bool isFinished) {
        uint8 dealerScore = CardLogic.calculateScore(dealerCards);
        
        // Dealer must hit on soft 17
        if (dealerScore < 17) {
            isFinished = false;
            shouldHit = true;
        } else if (dealerScore == 17 && isSoft17(dealerCards)) {
            isFinished = false;
            shouldHit = true;
        } else {
            isFinished = true;
            shouldHit = false;
        }
    }
}
