// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/**
 * @title VRFFulfillmentLogic
 * @notice Library for processing VRF responses
 */
library VRFFulfillmentLogic {
    
    /**
     * @notice Extract a card (1-52) from random number
     */
    function getCardFromRandom(uint256 random) internal pure returns (uint8) {
        return uint8((random % 52) + 1);
    }
}

