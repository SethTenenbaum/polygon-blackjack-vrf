// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {GameUpgradeable} from "../GameUpgradeable.sol";
import {CardLogic} from "./CardLogic.sol";
import {HandProgressionLogic} from "./HandProgressionLogic.sol";
import {DealerLogic} from "./DealerLogic.sol";
import {VRFRequestLogic} from "./VRFRequestLogic.sol";
import {WinnerDeterminationLogic} from "./WinnerDeterminationLogic.sol";
import {GameActionsLib} from "./GameActionsLib.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IGameToken} from "../interfaces/IGameToken.sol";

/**
 * @title GameLogicHandler
 * @notice External library for complex game logic to reduce bytecode size
 */
library GameLogicHandler {
    
    enum GameState { NotStarted, Dealing, InsuranceOffer, PlayerTurn, DealerTurn, Finished }
    enum RequestType { None, InitialDeal, PlayerHit, DealerHit, Split, DealerHoleCard }
    
    event DealerNeedsToHit();
    event DealerPlayed(uint8[] dealerCards);
    event GameFinished(string result, uint256 payout);
    
    /**
     * @notice Execute dealer turn logic
     * @return newState The new game state
     * @return needsVRF Whether VRF request is needed
     * @return vrfRequestId The VRF request ID (if needsVRF)
     */
    function executeDealerTurn(
        GameUpgradeable.Hand[] storage playerHands,
        uint8[] storage dealerCards,
        address player,
        address factory,
        IERC20 linkToken,
        mapping(uint256 => RequestType) storage pendingRequests,
        mapping(uint256 => uint256) storage requestTimestamps,
        uint256 linkSpent,
        uint256 createdAt
    ) external returns (
        uint8 newState,
        bool needsVRF,
        uint256 vrfRequestId,
        uint256 newLinkSpent
    ) {
        // Check if all player hands are busted
        if (HandProgressionLogic.areAllHandsBusted(playerHands)) {
            return (uint8(GameState.Finished), false, 0, linkSpent);
        }
        
        // If dealer only has 1 card (up card), request the hole card via VRF
        if (dealerCards.length == 1) {
            uint256 linkFee = VRFRequestLogic.getLinkFee();
            require(linkToken.transferFrom(player, address(this), linkFee), "LINK transfer failed");
            
            // This would need to request VRF through factory - but we can't call factory from library
            // So we need to return a flag and let the contract handle it
            return (uint8(GameState.DealerTurn), true, 0, linkSpent + linkFee);
        }
        
        // Dealer has hole card, continue with normal dealer logic
        (, bool isFinished) = DealerLogic.processDealerTurn(dealerCards);
        if (isFinished) {
            return (uint8(GameState.Finished), false, 0, linkSpent);
        } else {
            emit DealerNeedsToHit();
            return (uint8(GameState.DealerTurn), false, 0, linkSpent);
        }
    }
    
    /**
     * @notice Execute winner determination and payouts
     */
    function executeWinnerDetermination(
        GameUpgradeable.Hand[] storage playerHands,
        uint8[] storage dealerCards,
        address player,
        address factory,
        IGameToken gameToken,
        uint256 insuranceBet,
        bool dealerHasBlackjack
    ) external {
        uint8 dealerScore = CardLogic.calculateScore(dealerCards);
        bool dealerBusted = dealerScore > 21;
        
        // Calculate payouts
        uint256 totalPayout = GameActionsLib.calculateInsurancePayout(dealerHasBlackjack, insuranceBet);
        totalPayout += WinnerDeterminationLogic.calculateTotalPayout(playerHands, dealerCards, dealerBusted);

        if (totalPayout > 0) {
            require(gameToken.transfer(player, totalPayout), "Payout failed");
        }

        uint256 remainingBalance = gameToken.balanceOf(address(this));
        if (remainingBalance > 0) {
            gameToken.burn(remainingBalance);
        }

        // Notify factory
        (bool success,) = factory.call(abi.encodeWithSignature("notifyGameFinished()"));
        require(success, "Factory notification failed");
        
        emit DealerPlayed(dealerCards);
        emit GameFinished(totalPayout > 0 ? "won" : "lost", totalPayout);
    }
}
