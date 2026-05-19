// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

/**
 * @title InsuranceLogic
 * @notice Library for handling insurance operations in blackjack games
 */
library InsuranceLogic {
    /**
     * @notice Validate insurance bet amount
     * @param amount Insurance bet amount
     * @param bet Original bet amount
     * @param maxAllowed Maximum allowed insurance (typically bet/2)
     */
    function validateInsuranceAmount(uint256 amount, uint256 bet, uint256 maxAllowed) internal pure {
        require(amount > 0, "Insurance amount must be positive");
        require(amount <= maxAllowed, "Insurance exceeds maximum");
        require(amount <= bet / 2, "Insurance too high");
    }
    
    /**
     * @notice Determine next game state after insurance decision
     * @param dealerHasBlackjack Whether dealer has blackjack
     * @param playerHasBlackjack Whether player has blackjack
     * @return nextState The next game state (3=PlayerTurn or 5=Finished)
     * @return shouldDetermineWinner Whether to call determineWinner
     */
    function processInsuranceDecision(
        bool dealerHasBlackjack,
        bool playerHasBlackjack
    ) internal pure returns (uint8 nextState, bool shouldDetermineWinner) {
        if (dealerHasBlackjack || playerHasBlackjack) {
            return (5, true); // GameState.Finished = 5
        } else {
            return (3, false); // GameState.PlayerTurn = 3
        }
    }
}
