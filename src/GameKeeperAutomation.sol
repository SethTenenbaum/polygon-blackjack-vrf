// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {GameFactoryUpgradeable} from "./GameFactoryUpgradeable.sol";
import {GameUpgradeable} from "./GameUpgradeable.sol";

/**
 * @title AutomationCompatibleInterface
 * @notice Interface for Chainlink Automation compatibility
 */
interface AutomationCompatibleInterface {
    function checkUpkeep(bytes calldata checkData) external returns (bool upkeepNeeded, bytes memory performData);
    function performUpkeep(bytes calldata performData) external;
}

/**
 * @title GameKeeperAutomation
 * @notice Chainlink Automation keeper for automatically recovering tokens from expired games
 * @dev Implements Chainlink Automation interface to periodically check and cleanup expired games
 * 
 * How it works:
 * 1. Chainlink nodes call checkUpkeep() to see if work is needed
 * 2. If expired games found, returns performData with game addresses
 * 3. Chainlink nodes call performUpkeep() to cancel expired games
 * 4. Tokens are automatically recovered to factory liquidity pool
 * 
 * Benefits:
 * - Automatic recovery of stuck tokens from abandoned games
 * - No manual intervention needed
 * - Keeps liquidity pool healthy
 * - Prevents tokens from being locked forever
 */
contract GameKeeperAutomation is AutomationCompatibleInterface {
    
    GameFactoryUpgradeable public immutable factory;
    
    // Configuration
    uint256 public constant MAX_GAMES_PER_UPKEEP = 10; // Process max 10 games per call
    uint256 public lastCheckBlock;
    
    // Events
    event GamesProcessed(address[] games, uint256 timestamp);
    event UpkeepPerformed(uint256 gamesProcessed, uint256 gasUsed);
    
    constructor(address payable _factory) {
        factory = GameFactoryUpgradeable(_factory);
        lastCheckBlock = block.number;
    }
    
    /**
     * @notice Checks if upkeep is needed
     * @dev Called by Chainlink nodes off-chain
     * @return upkeepNeeded true if expired games found
     * @return performData encoded array of game addresses to cleanup
     */
    function checkUpkeep(bytes calldata /* checkData */)
        external
        view
        override
        returns (bool upkeepNeeded, bytes memory performData)
    {
        address[] memory expiredGames = _findExpiredGames();
        
        upkeepNeeded = expiredGames.length > 0;
        performData = abi.encode(expiredGames);
        
        return (upkeepNeeded, performData);
    }
    
    /**
     * @notice Performs upkeep - cancels expired games
     * @dev Called by Chainlink nodes on-chain when checkUpkeep returns true
     * @param performData encoded array of game addresses to cleanup
     */
    function performUpkeep(bytes calldata performData) external override {
        uint256 gasStart = gasleft();
        
        address[] memory gamesToCleanup = abi.decode(performData, (address[]));
        
        require(gamesToCleanup.length > 0, "No games to cleanup");
        
        uint256 processed = 0;
        for (uint256 i = 0; i < gamesToCleanup.length && i < MAX_GAMES_PER_UPKEEP; i++) {
            address payable gameAddress = payable(gamesToCleanup[i]);
            
            // Verify game is actually expired before cleaning up
            if (_isGameExpired(address(gameAddress))) {
                try factory.cancelExpiredGameByKeeper(gameAddress) {
                    processed++;
                } catch {
                    // Skip games that fail to cleanup
                    continue;
                }
            }
        }
        
        uint256 gasUsed = gasStart - gasleft();
        
        emit GamesProcessed(gamesToCleanup, block.timestamp);
        emit UpkeepPerformed(processed, gasUsed);
        
        lastCheckBlock = block.number;
    }
    
    /**
     * @notice Find all expired games across all players
     * @dev Scans factory's game mappings to find expired games
     * @return expiredGames array of expired game addresses
     */
    function _findExpiredGames() internal view returns (address[] memory) {
        // Get all active games from factory
        address[] memory activeGames = factory.getAllActiveGames();
        
        // Count expired games first
        uint256 expiredCount = 0;
        for (uint256 i = 0; i < activeGames.length; i++) {
            if (_isGameExpired(activeGames[i])) {
                expiredCount++;
                if (expiredCount >= MAX_GAMES_PER_UPKEEP) {
                    break; // Limit to MAX_GAMES_PER_UPKEEP
                }
            }
        }
        
        // Collect expired games
        address[] memory expiredGames = new address[](expiredCount);
        uint256 index = 0;
        for (uint256 i = 0; i < activeGames.length && index < expiredCount; i++) {
            if (_isGameExpired(activeGames[i])) {
                expiredGames[index] = activeGames[i];
                index++;
            }
        }
        
        return expiredGames;
    }
    
    /**
     * @notice Check if a specific game is expired
     * @param gameAddress address of the game contract
     * @return true if game is expired and can be cleaned up
     */
    function _isGameExpired(address gameAddress) internal view returns (bool) {
        try GameUpgradeable(payable(gameAddress)).createdAt() returns (uint256 createdAt) {
            try GameUpgradeable(payable(gameAddress)).state() returns (GameUpgradeable.GameState state) {
                // Game is expired if:
                // 1. Created more than 24 hours ago
                // 2. Not in Finished state
                bool isExpired = block.timestamp >= createdAt + 24 hours;
                bool notFinished = state != GameUpgradeable.GameState.Finished;
                
                return isExpired && notFinished;
            } catch {
                return false;
            }
        } catch {
            return false;
        }
    }
    
    /**
     * @notice Manual check - view expired games
     * @dev Helpful for debugging and monitoring
     * @return array of expired game addresses
     */
    function getExpiredGames() external view returns (address[] memory) {
        return _findExpiredGames();
    }
    
    /**
     * @notice Get total number of active games
     * @return count of active games
     */
    function getActiveGamesCount() external view returns (uint256) {
        return factory.getAllActiveGames().length;
    }
}
