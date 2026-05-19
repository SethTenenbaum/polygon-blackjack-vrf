// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

/**
 * @title VRFStatusLib
 * @notice Library for checking VRF request status and timeout
 * @dev Extracted to reduce GameImplementation size
 */
library VRFStatusLib {
    uint256 internal constant VRF_REQUEST_TIMEOUT = 2 minutes;
    
    // Custom errors
    error NotWaitingForVRF();
    error NoPendingVRFRequest();
    error VRFRequestNotTimedOut();
    
    /**
     * @param gameState Current game state (1 = Dealing)
     * @param lastRequestId Last VRF request ID  
     * @param requestTime Timestamp of last request
     * @return hasFailed True if request older than 2min timeout
     * @return timeWaiting Seconds waited for current request  
     * @return canRetry True if retry available
     */
    function getVRFRequestStatus(
        uint8 gameState,
        uint256 lastRequestId,
        uint256 requestTime
    ) internal view returns (bool hasFailed, uint256 timeWaiting, bool canRetry) {
        if (gameState != 1 || lastRequestId == 0 || requestTime == 0) {
            return (false, 0, false);
        }
        timeWaiting = block.timestamp - requestTime;
        hasFailed = timeWaiting > VRF_REQUEST_TIMEOUT;
        return (hasFailed, timeWaiting, hasFailed);
    }
    
    /**
     * @param gameState Current game state (1 = Dealing)
     * @param lastRequestId Last VRF request ID
     * @param requestTime Timestamp of last request
     * @return Seconds until timeout, 0 if timed out
     */
    function getVRFTimeRemaining(
        uint8 gameState,
        uint256 lastRequestId,
        uint256 requestTime
    ) internal view returns (uint256) {
        if (gameState != 1 || lastRequestId == 0 || requestTime == 0) return 0;
        uint256 elapsed = block.timestamp - requestTime;
        return elapsed >= VRF_REQUEST_TIMEOUT ? 0 : VRF_REQUEST_TIMEOUT - elapsed;
    }
    
    /**
     * @notice Validate that a VRF retry is allowed
     * @param gameState Current game state (1 = Dealing)
     * @param lastRequestId Last VRF request ID
     * @param requestTime Timestamp of last request
     */
    function validateRetry(
        uint8 gameState,
        uint256 lastRequestId,
        uint256 requestTime
    ) internal view {
        if (gameState != 1) revert NotWaitingForVRF(); // 1 = GameState.Dealing
        if (lastRequestId == 0) revert NoPendingVRFRequest();
        if (block.timestamp <= requestTime + VRF_REQUEST_TIMEOUT) revert VRFRequestNotTimedOut();
    }
}
