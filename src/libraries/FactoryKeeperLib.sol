// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {GameUpgradeable} from "../GameUpgradeable.sol";
import {GameToken} from "../GameToken.sol";

/**
 * @title FactoryKeeperLib
 * @notice External library for Chainlink Keeper and emergency functions
 */
library FactoryKeeperLib {
    
    event ExpiredGameCancelled(address indexed gameAddress, address indexed player, uint256 refunded);
    
    /**
     * @notice Cancel expired game - callable by keeper
     * @dev Access control is handled by the calling contract (performUpkeep or cancelExpiredGameByKeeper)
     */
    function cancelExpiredGameByKeeper(
        address payable gameAddress,
        mapping(address => bool) storage activeGames,
        mapping(address => uint256) storage gameReservedLiquidity,
        uint256 lockedLiquidity,
        address gameTokenAddress,
        address /* keeperAddress */,
        address /* owner */
    ) external returns (uint256 newLockedLiquidity) {
        // Note: Access control removed - must be enforced by caller
        require(activeGames[gameAddress], "Game not active");
        
        GameUpgradeable game = GameUpgradeable(payable(gameAddress));
        
        // Verify game is actually expired
        require(block.timestamp >= game.createdAt() + 24 hours, "Game not expired yet");
        require(game.state() != GameUpgradeable.GameState.Finished, "Game already finished");
        
        address player = game.player();
        newLockedLiquidity = lockedLiquidity;
        
        // Call cancel on the game contract
        try game.cancelExpiredGame() {
            // Game already burns all tokens, so no need to transfer them back
            // Just release locked liquidity
            uint256 reservedAmount = gameReservedLiquidity[gameAddress];
            if (reservedAmount > 0) {
                newLockedLiquidity = lockedLiquidity - reservedAmount;
                gameReservedLiquidity[gameAddress] = 0;
            }
            
            // Mark as inactive
            activeGames[gameAddress] = false;
            
            emit ExpiredGameCancelled(gameAddress, player, 0);
        } catch {
            // If cancel fails, still try to recover funds
            newLockedLiquidity = forceRecoverGame(
                gameAddress,
                activeGames,
                gameReservedLiquidity,
                lockedLiquidity,
                gameTokenAddress
            );
        }
    }
    
    /**
     * @notice Force recovery from a stuck game
     * @dev Internal fallback when cancelExpiredGame() fails
     *      Maintains deflationary mechanism by burning recovered tokens
     */
    function forceRecoverGame(
        address gameAddress,
        mapping(address => bool) storage activeGames,
        mapping(address => uint256) storage gameReservedLiquidity,
        uint256 lockedLiquidity,
        address gameTokenAddress
    ) public returns (uint256 newLockedLiquidity) {
        GameToken token = GameToken(payable(gameTokenAddress));
        newLockedLiquidity = lockedLiquidity;
        
        // Check if game has tokens to recover
        uint256 gameBalance = token.balanceOf(gameAddress);
        
        if (gameBalance > 0) {
            // Record factory balance before recovery
            uint256 balanceBefore = token.balanceOf(address(this));
            
            // Try to recover tokens via emergency withdraw
            (bool success,) = gameAddress.call(
                abi.encodeWithSignature("emergencyWithdrawToFactory()")
            );
            
            if (success) {
                // Burn the recovered tokens to maintain deflationary mechanism
                uint256 balanceAfter = token.balanceOf(address(this));
                uint256 recovered = balanceAfter > balanceBefore ? balanceAfter - balanceBefore : 0;
                if (recovered > 0) {
                    token.burn(recovered);
                }
                
                // Unlock the reserved liquidity
                uint256 reservedAmount = gameReservedLiquidity[gameAddress];
                if (reservedAmount > 0) {
                    newLockedLiquidity = lockedLiquidity - reservedAmount;
                    gameReservedLiquidity[gameAddress] = 0;
                }
            }
        }
        
        // Always mark game as inactive (cleanup factory state)
        activeGames[gameAddress] = false;
    }
    
    /**
     * @notice Emergency recovery from stuck or hacked game contract
     */
    function emergencyRecoverFromGame(
        address payable gameAddress,
        mapping(address => bool) storage activeGames,
        mapping(address => uint256) storage gameReservedLiquidity,
        uint256 lockedLiquidity,
        address gameTokenAddress,
        address owner
    ) external returns (uint256 newLockedLiquidity) {
        require(msg.sender == owner, "Only owner");
        require(activeGames[gameAddress], "Not an active game");
        
        GameToken token = GameToken(payable(gameTokenAddress));
        
        // Record factory token balance before recovery
        uint256 balanceBefore = token.balanceOf(address(this));
        
        // Call emergency withdraw on the game contract
        (bool success,) = gameAddress.call(abi.encodeWithSignature("emergencyWithdrawToFactory()"));
        require(success, "Emergency recovery failed");
        
        // Burn any tokens recovered from the game
        uint256 balanceAfter = token.balanceOf(address(this));
        uint256 recovered = balanceAfter > balanceBefore ? balanceAfter - balanceBefore : 0;
        if (recovered > 0) {
            token.burn(recovered);
        }
        
        // Mark game as inactive and unlock liquidity
        activeGames[gameAddress] = false;
        uint256 reservedAmount = gameReservedLiquidity[gameAddress];
        newLockedLiquidity = lockedLiquidity;
        if (reservedAmount > 0) {
            newLockedLiquidity = lockedLiquidity - reservedAmount;
            gameReservedLiquidity[gameAddress] = 0;
        }
    }
    
    /**
     * @notice Emergency withdraw all funds (only if no active games)
     */
    function emergencyWithdraw(
        uint256 lockedLiquidity,
        address gameTokenAddress,
        address owner
    ) external {
        require(msg.sender == owner, "Only owner");
        require(lockedLiquidity == 0, "Games still active");
        
        GameToken token = GameToken(payable(gameTokenAddress));
        uint256 tokenBalance = token.balanceOf(address(this));
        
        if (tokenBalance > 0) {
            // Burn all factory tokens (emergency cleanup)
            token.burn(tokenBalance);
        }
        
        // Transfer any stray POL that might be in factory (shouldn't happen in normal flow)
        uint256 polBalance = address(this).balance;
        if (polBalance > 0) {
            payable(owner).transfer(polBalance);
        }
    }
}
