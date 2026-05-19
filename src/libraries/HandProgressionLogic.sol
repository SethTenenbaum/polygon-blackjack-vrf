// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {GameUpgradeable} from "../GameUpgradeable.sol";
import {CardLogic} from "./CardLogic.sol";

/**
 * @title HandProgressionLogic
 * @notice External library for hand progression and turn management
 */
library HandProgressionLogic {
    
    /**
     * @notice Find next active hand after current hand
     * @return nextHand Index of next hand to play, or type(uint8).max if all done
     */
    function findNextHand(
        GameUpgradeable.Hand[] storage playerHands,
        uint8 currentHand
    ) public view returns (uint8 nextHand) {
        // Start from the hand AFTER current
        for (uint8 i = currentHand + 1; i < playerHands.length; i++) {
            if (!playerHands[i].stood && !playerHands[i].busted) {
                return i;
            }
        }
        
        // No more hands to play
        return type(uint8).max;
    }
    
    /**
     * @notice Check if all hands are busted
     * @return allBusted True if all player hands are busted
     */
    function areAllHandsBusted(
        GameUpgradeable.Hand[] storage playerHands
    ) external view returns (bool allBusted) {
        allBusted = true;
        for (uint i = 0; i < playerHands.length; i++) {
            if (!playerHands[i].busted) {
                allBusted = false;
                break;
            }
        }
    }
    
    /**
     * @notice Check if all hands are finished
     */
    function areAllHandsFinished(
        GameUpgradeable.Hand[] storage playerHands
    ) external view returns (bool) {
        for (uint i = 0; i < playerHands.length; i++) {
            if (!playerHands[i].stood && !playerHands[i].busted) {
                return false;
            }
        }
        return true;
    }
    
    /**
     * @notice Move to next hand or dealer turn
     * @return shouldMoveToDealerTurn Whether to move to dealer turn
     * @return nextHandIndex Index of next hand if not moving to dealer
     */
    function progressToNextHand(
        GameUpgradeable.Hand[] storage playerHands,
        uint8 currentHand
    ) external view returns (bool shouldMoveToDealerTurn, uint8 nextHandIndex) {
        nextHandIndex = findNextHand(playerHands, currentHand);
        
        if (nextHandIndex == type(uint8).max) {
            // All hands finished, move to dealer turn
            shouldMoveToDealerTurn = true;
        } else {
            shouldMoveToDealerTurn = false;
        }
    }
    
    /**
     * @notice Check if hand should auto-advance (after bust or double down)
     */
    function shouldAutoAdvance(
        GameUpgradeable.Hand storage hand
    ) external view returns (bool) {
        // Auto-advance if busted or doubled (doubled hands get exactly one card then stand)
        return hand.busted || hand.doubled;
    }
}
