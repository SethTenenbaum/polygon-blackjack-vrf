// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {IGameToken} from "../interfaces/IGameToken.sol";

/**
 * @title SurrenderLogic
 * @notice Library for handling player surrender logic
 */
library SurrenderLogic {
    /**
     * @notice Execute surrender logic
     * @return refund The amount refunded to player (half the bet)
     */
    function executeSurrender(
        address player,
        address gameTokenAddress,
        address factory,
        uint256 bet
    ) external returns (uint256 refund) {
        IGameToken gameToken = IGameToken(gameTokenAddress);
        
        refund = bet / 2;

        if (refund > 0) {
            require(gameToken.transfer(player, refund), "Refund failed");
        }
        
        uint256 remainingBalance = gameToken.balanceOf(address(this));
        if (remainingBalance > 0) {
            gameToken.burn(remainingBalance);
        }

        // Notify factory
        (bool success, ) = factory.call(abi.encodeWithSignature("notifyGameFinished()"));
        require(success, "Factory notification failed");
        
        return refund;
    }
}
