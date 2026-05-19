// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {GameUpgradeable} from "../GameUpgradeable.sol";
import {CardLogic} from "./CardLogic.sol";

/**
 * @title WinnerDeterminationLogic
 * @notice External library for determining winners and calculating payouts
 */
library WinnerDeterminationLogic {
    
    enum HandResult { Loss, Push, Win, Blackjack }
    
    /**
     * @notice Determine result of a single hand against dealer
     */
    function determineHandResult(
        GameUpgradeable.Hand storage playerHand,
        uint8[] storage dealerCards,
        bool dealerBusted
    ) public view returns (HandResult result, uint256 payout) {
        // Player busted = loss (check this FIRST before anything else)
        if (playerHand.busted) {
            return (HandResult.Loss, 0);
        }
        
        uint8 playerScore = CardLogic.calculateScore(playerHand.cards);
        uint8 dealerScore = CardLogic.calculateScore(dealerCards);
        
        // DEBUG: If we reach here, player didn't bust
        // So if dealer busted, player must win
        
        // Player blackjack
        bool playerBlackjack = playerHand.cards.length == 2 && playerScore == 21;
        bool dealerBlackjack = dealerCards.length == 2 && dealerScore == 21;
        
        if (playerBlackjack && !dealerBlackjack) {
            // Blackjack pays 3:2
            payout = playerHand.bet + (playerHand.bet * 3 / 2);
            return (HandResult.Blackjack, payout);
        }
        
        if (playerBlackjack && dealerBlackjack) {
            // Push on double blackjack
            payout = playerHand.bet;
            return (HandResult.Push, payout);
        }
        
        // Dealer busted and player didn't = player wins
        // BUG FIX: This should ALWAYS give payout when dealer busts and player hasn't
        if (dealerBusted) {
            // Player wins! Return bet + equal winnings
            payout = playerHand.bet * 2;
            return (HandResult.Win, payout);
        }
        
        // Compare scores
        if (playerScore > dealerScore) {
            payout = playerHand.bet * 2;
            return (HandResult.Win, payout);
        } else if (playerScore == dealerScore) {
            payout = playerHand.bet; // Push - return bet
            return (HandResult.Push, payout);
        } else {
            return (HandResult.Loss, 0);
        }
    }
    
    /**
     * @notice Calculate total payout for all hands
     */
    function calculateTotalPayout(
        GameUpgradeable.Hand[] storage playerHands,
        uint8[] storage dealerCards,
        bool dealerBusted
    ) external view returns (uint256 totalPayout) {
        totalPayout = 0;
        
        for (uint i = 0; i < playerHands.length; i++) {
            (, uint256 handPayout) = determineHandResult(
                playerHands[i],
                dealerCards,
                dealerBusted
            );
            totalPayout += handPayout;
        }
    }
    
    /**
     * @notice Check if player won overall
     */
    function didPlayerWin(
        GameUpgradeable.Hand[] storage playerHands,
        uint8[] storage dealerCards,
        bool dealerBusted
    ) external view returns (bool) {
        uint256 totalBet = 0;
        uint256 totalPayout = 0;
        
        for (uint i = 0; i < playerHands.length; i++) {
            totalBet += playerHands[i].bet;
            (, uint256 handPayout) = determineHandResult(
                playerHands[i],
                dealerCards,
                dealerBusted
            );
            totalPayout += handPayout;
        }
        
        return totalPayout > totalBet;
    }
    
    /**
     * @notice Determine game result string based on total payout vs total bet
     */
    function determineResultString(
        uint256 totalPayout,
        uint256 totalBet
    ) external pure returns (string memory) {
        if (totalPayout > totalBet) {
            return "won";
        } else if (totalPayout == totalBet) {
            return "push";
        } else {
            return "lost";
        }
    }
    
    /**
     * @notice Calculate total bet across all hands
     */
    function calculateTotalBet(
        GameUpgradeable.Hand[] storage playerHands
    ) external view returns (uint256 totalBet) {
        totalBet = playerHands[0].bet; // First hand bet
        for (uint i = 1; i < playerHands.length; i++) {
            totalBet += playerHands[i].bet;
        }
    }
}
