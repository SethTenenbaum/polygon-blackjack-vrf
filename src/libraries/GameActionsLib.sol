// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {IGameToken} from "../interfaces/IGameToken.sol";

interface IGameFactory {
    function notifyGameFinished() external;
}

library GameActionsLib {
    event GameFinished(string outcome, uint256 payout);

    error NotYourGame();
    error NotPlayerTurn();
    error TooManyHands();
    error CannotHitAfterDouble();
    error NotInsurancePhase();
    error InsuranceTooHigh();

    // GameState enum values: NotStarted=0, Dealing=1, InsuranceOffer=2, PlayerTurn=3, DealerTurn=4, Finished=5

    /**
     * @notice Handles player surrender logic
     * @param player The player address
     * @param factory The factory address
     * @param gameToken The game token
     * @param state The current game state (as uint8)
     * @param playerHandsLength Number of player hands
     * @param firstHandCardsLength Number of cards in first hand
     * @param firstHandBet The bet amount on first hand
     * @return newState The new game state (Finished=5)
     */
    function executeSurrender(
        address player,
        address factory,
        IGameToken gameToken,
        uint8 state,
        uint256 playerHandsLength,
        uint256 firstHandCardsLength,
        uint256 firstHandBet
    ) external returns (uint8 newState) {
        if (msg.sender != player) revert NotYourGame();
        if (state != 3 && state != 2) revert NotPlayerTurn(); // PlayerTurn=3, InsuranceOffer=2
        if (playerHandsLength != 1) revert TooManyHands();
        if (firstHandCardsLength != 2) revert CannotHitAfterDouble();

        uint256 refund = firstHandBet / 2;

        if (refund > 0) {
            require(gameToken.transfer(player, refund));
        }
        
        uint256 remainingBalance = gameToken.balanceOf(address(this));
        if (remainingBalance > 0) {
            gameToken.burn(remainingBalance);
        }

        IGameFactory(factory).notifyGameFinished();
        emit GameFinished("surrendered", refund);

        return 5; // Finished
    }

    /**
     * @notice Handles skip insurance logic
     * @param player The player address
     * @param state The current game state (as uint8)
     * @param dealerHasBlackjack Whether dealer has blackjack
     * @param playerHasBlackjack Whether player has blackjack
     * @return newState The new game state
     * @return shouldDetermineWinner Whether to call determineWinner
     */
    function executeSkipInsurance(
        address player,
        uint8 state,
        bool dealerHasBlackjack,
        bool playerHasBlackjack
    ) external view returns (uint8 newState, bool shouldDetermineWinner) {
        if (msg.sender != player) revert NotYourGame();
        if (state != 2) revert NotInsurancePhase(); // InsuranceOffer=2

        if (dealerHasBlackjack || playerHasBlackjack) {
            return (5, true); // Finished=5
        } else {
            return (3, false); // PlayerTurn=3
        }
    }

    /**
     * @notice Calculates insurance payout
     * @param dealerHasBlackjack Whether dealer has blackjack
     * @param insuranceBet The insurance bet amount
     * @return insurancePayout The insurance payout amount
     */
    function calculateInsurancePayout(
        bool dealerHasBlackjack,
        uint256 insuranceBet
    ) external pure returns (uint256 insurancePayout) {
        if (dealerHasBlackjack && insuranceBet > 0) {
            return insuranceBet * 3;
        }
        return 0;
    }

    /**
     * @notice Validates and processes insurance placement
     * @param player The player address
     * @param state The current game state (as uint8)
     * @param amount The insurance amount
     * @param maxBet The maximum bet (original bet)
     * @param dealerHasBlackjack Whether dealer has blackjack
     * @param playerHasBlackjack Whether player has blackjack
     * @return newState The new game state
     * @return shouldDetermineWinner Whether to call determineWinner
     */
    function executePlaceInsurance(
        address player,
        uint8 state,
        uint256 amount,
        uint256 maxBet,
        bool dealerHasBlackjack,
        bool playerHasBlackjack
    ) external view returns (uint8 newState, bool shouldDetermineWinner) {
        if (msg.sender != player) revert NotYourGame();
        if (state != 2) revert NotInsurancePhase(); // InsuranceOffer=2
        if (amount > maxBet / 2) revert InsuranceTooHigh();

        if (dealerHasBlackjack || playerHasBlackjack) {
            return (5, true); // Finished=5
        } else {
            return (3, false); // PlayerTurn=3
        }
    }
}
