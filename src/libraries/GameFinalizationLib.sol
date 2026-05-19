// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title GameFinalizationLib
 * @notice Library for game finalization helpers
 * @dev Externalized to reduce GameUpgradeable contract size
 * @dev This library does NOT duplicate payout calculation, it just provides helper functions
 */
library GameFinalizationLib {
    
    /**
     * @notice Execute token transfers and cleanup for game end
     * @param gameToken Address of the game token
     * @param player Player address
     * @param totalPayout Amount to pay out
     * @return success True if all transfers succeeded
     */
    function executePayoutAndCleanup(
        address gameToken,
        address player,
        uint256 totalPayout
    ) external returns (bool success) {
        // Transfer payout to player
        if (totalPayout > 0) {
            (bool transferSuccess, ) = gameToken.call(
                abi.encodeWithSignature("transfer(address,uint256)", player, totalPayout)
            );
            if (!transferSuccess) return false;
        }

        // Burn remaining balance
        (bool balanceSuccess, bytes memory balanceData) = gameToken.call(
            abi.encodeWithSignature("balanceOf(address)", address(this))
        );
        if (balanceSuccess && balanceData.length >= 32) {
            uint256 remainingBalance = abi.decode(balanceData, (uint256));
            if (remainingBalance > 0) {
                (bool burnSuccess, ) = gameToken.call(
                    abi.encodeWithSignature("burn(uint256)", remainingBalance)
                );
                if (!burnSuccess) return false;
            }
        }
        
        return true;
    }
}

