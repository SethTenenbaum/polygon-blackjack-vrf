// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

/**
 * @title CardLogic
 * @notice Library for blackjack card calculations
 */
library CardLogic {
    
    /**
     * @notice Calculate the score of a hand
     * @param cards Array of card IDs
     * @return score Best score for the hand (accounting for aces)
     */
    function calculateScore(uint8[] memory cards) public pure returns (uint8) {
        uint8 score = 0;
        uint8 aces = 0;
        
        for (uint256 i = 0; i < cards.length; i++) {
            uint8 value = getCardValue(cards[i]);
            score += value;
            if (value == 11) {
                aces++;
            }
        }
        
        // Adjust for aces
        while (score > 21 && aces > 0) {
            score -= 10;
            aces--;
        }
        
        return score;
    }
    
    /**
     * @notice Get the blackjack value of a card
     * @param cardId Card ID (1-52)
     * @return value Card value (1-11)
     * Card system: 1,14,27,40 = Ace, 2-10 = numbered cards, 11-13 = Jack/Queen/King
     */
    function getCardValue(uint8 cardId) public pure returns (uint8) {
        uint8 rank = getCardRank(cardId);
        if (rank == 1) return 11;   // Ace
        if (rank >= 11) return 10;  // Face cards (J, Q, K)
        return rank;                // 2-10
    }
    
    /**
     * @notice Get the rank of a card
     * @param cardId Card ID (1-52)
     * @return rank Card rank (1-13: A,2-10,J,Q,K)
     */
    function getCardRank(uint8 cardId) public pure returns (uint8) {
        require(cardId >= 1 && cardId <= 52, "Invalid card ID");
        return ((cardId - 1) % 13) + 1;
    }
    
    /**
     * @notice Check if a hand is blackjack (21 with 2 cards)
     * @param cards Array of card IDs
     * @return True if blackjack
     */
    function isBlackjack(uint8[] memory cards) external pure returns (bool) {
        return cards.length == 2 && calculateScore(cards) == 21;
    }
    
    /**
     * @notice Check if a hand is busted
     * @param cards Array of card IDs
     * @return True if busted
     */
    function isBusted(uint8[] memory cards) external pure returns (bool) {
        return calculateScore(cards) > 21;
    }
}
