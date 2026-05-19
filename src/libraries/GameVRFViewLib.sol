// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {VRFStatusLib} from "./VRFStatusLib.sol";

/**
 * @title GameVRFViewLib
 * @notice External library for VRF status view functions
 * @dev Separated to reduce GameUpgradeable bytecode size
 */
library GameVRFViewLib {
    
    /**
     * @notice Get comprehensive VRF request status
     * @param gameState Current game state (1 = Dealing)
     * @param lastRequestId ID of last VRF request
     * @param requestTimestamp Timestamp when request was made
     * @return hasFailed True if request older than 2min timeout
     * @return timeWaiting Seconds waited for current request  
     * @return canRetry True if retry available
     */
    function getVRFRequestStatus(
        uint8 gameState,
        uint256 lastRequestId,
        uint256 requestTimestamp
    ) external view returns (bool hasFailed, uint256 timeWaiting, bool canRetry) {
        return VRFStatusLib.getVRFRequestStatus(gameState, lastRequestId, requestTimestamp);
    }
    
    /**
     * @notice Get time remaining until VRF timeout
     * @param gameState Current game state (1 = Dealing)
     * @param lastRequestId ID of last VRF request
     * @param requestTimestamp Timestamp when request was made
     * @return timeRemaining Seconds until timeout, 0 if timed out
     */
    function getVRFTimeRemaining(
        uint8 gameState,
        uint256 lastRequestId,
        uint256 requestTimestamp
    ) external view returns (uint256) {
        return VRFStatusLib.getVRFTimeRemaining(gameState, lastRequestId, requestTimestamp);
    }
}
