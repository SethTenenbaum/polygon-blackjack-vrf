// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

// Custom errors
error NotYourGame();
error NotPlayerTurn();
error NotDealerTurn();

/**
 * @title PlayerActionValidation
 * @notice Library for validating player actions in the game
 * @dev Only contains actively used validation functions to minimize contract size
 */
library PlayerActionValidation {
    
    /**
     * @notice Validate that the caller is the player
     * @param player The address of the player
     * @param msgSender The address of the message sender (msg.sender)
     */
    function validatePlayer(address player, address msgSender) external pure {
        if (msgSender != player) revert NotYourGame();
    }
    
    /**
     * @notice Validate that the game is in PlayerTurn state
     * @param state The current game state as uint8 (3 = PlayerTurn)
     */
    function validatePlayerTurn(uint8 state) external pure {
        if (state != 3) revert NotPlayerTurn(); // GameState.PlayerTurn = 3
    }

    /**
     * @notice Validate that the game is in DealerTurn state and caller is player
     * @param player The address of the player
     * @param msgSender The address of the message sender (msg.sender)
     * @param state The current game state as uint8 (4 = DealerTurn)
     */
    function validateDealerTurn(address player, address msgSender, uint8 state) external pure {
        if (msgSender != player) revert NotYourGame();
        if (state != 4) revert NotDealerTurn(); // GameState.DealerTurn = 4
    }
}
