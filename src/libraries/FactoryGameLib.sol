// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {GameUpgradeable} from "../GameUpgradeable.sol";

/**
 * @title FactoryGameLib
 * @notice Library for game management operations in GameFactory
 */
library FactoryGameLib {
    
    /**
     * @notice Check if a game is active
     */
    function isGameActive(address game) internal view returns (bool) {
        if (game == address(0)) return false;
        
        try GameUpgradeable(payable(game)).state() returns (GameUpgradeable.GameState state) {
            return state != GameUpgradeable.GameState.Finished;
        } catch {
            return false;
        }
    }
    
    /**
     * @notice Check if a game is expired
     */
    function isGameExpired(address game) internal view returns (bool) {
        if (game == address(0)) return false;
        
        try GameUpgradeable(payable(game)).isExpired() returns (bool expired) {
            return expired;
        } catch {
            return false;
        }
    }
    
    /**
     * @notice Get active games from a list using activeGames mapping
     */
    function filterActiveGames(
        address[] memory allGames,
        mapping(address => bool) storage activeGames
    ) internal view returns (address[] memory) {
        uint256 activeCount = 0;
        
        // Count active games
        for (uint256 i = 0; i < allGames.length; i++) {
            if (activeGames[allGames[i]]) {
                activeCount++;
            }
        }
        
        // Build active games array
        address[] memory activeGamesList = new address[](activeCount);
        uint256 index = 0;
        for (uint256 i = 0; i < allGames.length; i++) {
            if (activeGames[allGames[i]]) {
                activeGamesList[index] = allGames[i];
                index++;
            }
        }
        
        return activeGamesList;
    }
}
