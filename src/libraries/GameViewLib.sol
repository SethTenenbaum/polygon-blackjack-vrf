// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {GameUpgradeable} from "../GameUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {VRFRequestLogic} from "./VRFRequestLogic.sol";

/**
 * @title GameViewLib
 * @notice External library for game view/query functions
 */
library GameViewLib {
    
    uint256 constant LINK_FEE = 0.005 ether;
    
    /**
     * @notice Check if game can cover max payout
     */
    function canCoverMaxPayout(
        uint256 bet,
        address gameTokenAddress,
        address gameAddress
    ) external view returns (bool) {
        uint256 worstCase = bet * 11;
        return IERC20(gameTokenAddress).balanceOf(gameAddress) >= worstCase;
    }
    
    /**
     * @notice Check if game has enough LINK
     */
    function hasEnoughLINK(
        address linkAddress,
        address gameAddress,
        uint256 turns
    ) external view returns (bool) {
        return IERC20(linkAddress).balanceOf(gameAddress) >= LINK_FEE * turns;
    }
    
    /**
     * @notice Get recommended funding
     */
    function getRecommendedFunding(uint256 bet) external pure returns (
        uint256 tokenAmount,
        uint256 linkAmount
    ) {
        tokenAmount = bet * 11;
        linkAmount = LINK_FEE * 20;
    }
    
    /**
     * @notice Get fund status
     */
    function getFundStatus(
        uint256 bet,
        uint256 linkSpent,
        address gameTokenAddress,
        address linkAddress,
        address gameAddress
    ) external view returns (
        uint256 tokenBalance,
        uint256 linkBalance,
        uint256 linkSpentSoFar,
        bool canCoverPayout
    ) {
        tokenBalance = IERC20(gameTokenAddress).balanceOf(gameAddress);
        linkBalance = IERC20(linkAddress).balanceOf(gameAddress);
        linkSpentSoFar = linkSpent;
        
        uint256 worstCase = bet * 11;
        canCoverPayout = tokenBalance >= worstCase;
    }
    
    /**
     * @notice Get max LINK needed
     */
    function getMaxLINKNeeded(uint256 numHands) external pure returns (uint256) {
        uint256 maxPlayerHits = numHands * 10;
        uint256 maxDealerHits = 5;
        uint256 initialDeal = 1;
        return (maxPlayerHits + maxDealerHits + initialDeal) * LINK_FEE;
    }
    
    /**
     * @notice Check if game is expired
     */
    function isExpired(uint256 createdAt) external view returns (bool) {
        return block.timestamp >= createdAt + 24 hours;
    }
    
    /**
     * @notice Get time remaining
     */
    function getTimeRemaining(uint256 createdAt) external view returns (uint256) {
        uint256 expiryTime = createdAt + 24 hours;
        if (block.timestamp >= expiryTime) {
            return 0;
        }
        return expiryTime - block.timestamp;
    }
    
    /**
     * @notice Get current turn information
     */
    function getCurrentTurnInfo(
        uint8 currentHand,
        uint256 playerHandsLength,
        uint8 stateValue
    ) external pure returns (
        uint8 activeHandIndex,
        uint256 totalHands,
        bool isPlayersTurn,
        bool isDealersTurn,
        bool isWaitingForVRF
    ) {
        activeHandIndex = currentHand;
        totalHands = playerHandsLength;
        isPlayersTurn = stateValue == 2; // GameState.PlayerTurn
        isDealersTurn = stateValue == 3; // GameState.DealerTurn
        isWaitingForVRF = stateValue == 1; // GameState.Dealing
        
        return (activeHandIndex, totalHands, isPlayersTurn, isDealersTurn, isWaitingForVRF);
    }

    /**
     * @notice Get detailed hand status
     */
    function getHandStatus(
        GameUpgradeable.Hand storage hand,
        uint8 handIndex,
        uint8 currentHand,
        uint8 stateValue
    ) external view returns (
        uint8[] memory cards,
        uint256 betAmount,
        uint8 score,
        bool hasStood,
        bool hasBusted,
        bool hasDoubled,
        bool isActive
    ) {
        cards = hand.cards;
        betAmount = hand.bet;
        score = calculateScore(hand.cards);
        hasStood = hand.stood;
        hasBusted = hand.busted;
        hasDoubled = hand.doubled;
        isActive = (currentHand == handIndex && stateValue == 2); // GameState.PlayerTurn
        
        return (cards, betAmount, score, hasStood, hasBusted, hasDoubled, isActive);
    }

    /**
     * @notice Get visible dealer cards based on game state
     * @param dealerCards Full dealer cards array
     * @param gameState Current game state (3=DealerTurn, 4=Finished)
     * @return Visible cards (only first card during player turn, all cards otherwise)
     */
    function getVisibleDealerCards(
        uint8[] storage dealerCards,
        uint8 gameState
    ) external view returns (uint8[] memory) {
        // SECURITY: Only reveal dealer's hole card when appropriate
        // Show all cards during DealerTurn (4) or Finished (5)
        if (gameState == 4 || gameState == 5) {
            return dealerCards;
        }
        // During other states, only show first card if dealer has multiple cards
        if (dealerCards.length > 1) {
            uint8[] memory visibleCards = new uint8[](1);
            visibleCards[0] = dealerCards[0];
            return visibleCards;
        }
        return dealerCards;
    }
    
    /**
     * @notice Calculate score of a hand
     */
    function calculateScore(uint8[] memory cards) public pure returns (uint8) {
        uint8 score = 0;
        uint8 aces = 0;
        
        for (uint256 i = 0; i < cards.length; i++) {
            uint8 rank = getCardRank(cards[i]);
            if (rank == 1) {
                aces++;
                score += 11;
            } else if (rank > 10) {
                score += 10;
            } else {
                score += rank;
            }
        }
        
        while (score > 21 && aces > 0) {
            score -= 10;
            aces--;
        }
        
        return score;
    }

    /**
     * @notice Get card rank
     */
    function getCardRank(uint8 cardId) public pure returns (uint8) {
        require(cardId >= 1 && cardId <= 52, "Invalid card ID");
        return ((cardId - 1) % 13) + 1;
    }
}
