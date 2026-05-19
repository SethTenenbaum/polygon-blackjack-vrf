// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {GameImplementation} from "../GameImplementation.sol";
import {GameToken} from "../GameToken.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

/**
 * @title FactoryGameCreationLib
 * @notice Library for game creation and finalization logic
 * @dev Extracted to reduce GameFactoryUpgradeable contract size
 */
library FactoryGameCreationLib {
    
    uint256 constant BLACKJACK_MAX_PAYOUT_MULTIPLIER = 11;
    
    event GameCreated(address indexed player, address gameAddress, uint256 bet);
    event FundsTransferredToGame(address indexed gameAddress, uint256 amount);
    
    /**
     * @notice Create a new game instance
     * @return gameAddress Address of the created game
     * @return requiredPOL POL amount reserved for this game
     */
    function createGameClone(
        uint256 bet,
        address player,
        address factoryAddress,
        address vrfCoordinator,
        address gameTokenAddress,
        address linkAddress,
        uint256 /* linkFee */,
        uint256 subscriptionId,
        address gameImplementation,
        mapping(address => address[]) storage playerGames,
        mapping(address => bool) storage activeGames,
        mapping(address => uint256) storage gameToIndex,
        address[] storage allGames,
        mapping(address => uint256) storage gameReservedLiquidity
    ) internal returns (address gameAddress, uint256 requiredPOL) {
        GameToken token = GameToken(payable(gameTokenAddress));
        
        // Calculate required liquidity reserve (in POL) for worst-case payout
        uint256 maxPayoutTokens = bet * BLACKJACK_MAX_PAYOUT_MULTIPLIER;
        requiredPOL = maxPayoutTokens / token.TOKENS_PER_POL();
        
        // Create minimal proxy clone of game implementation
        gameAddress = Clones.clone(gameImplementation);
        
        // Initialize the cloned game
        GameImplementation(payable(gameAddress)).initializeClone(
            player,
            bet,
            factoryAddress,
            gameTokenAddress,
            linkAddress
        );
        
        // Track the game
        playerGames[player].push(gameAddress);
        activeGames[gameAddress] = true;
        gameToIndex[gameAddress] = allGames.length;
        allGames.push(gameAddress);
        gameReservedLiquidity[gameAddress] = requiredPOL;
        
        // Token transfers will be handled by the factory contract, not here
        // This ensures transfers happen in the factory's context, not the library's
        
        emit GameCreated(player, gameAddress, bet);
    }
    
    /**
     * @notice Handle game finish notification
     * @return newLockedLiquidity Updated locked liquidity amount
     */
    function handleGameFinished(
        address gameAddress,
        mapping(address => bool) storage activeGames,
        mapping(address => uint256) storage gameReservedLiquidity,
        uint256 lockedLiquidity
    ) external returns (uint256 newLockedLiquidity) {
        require(activeGames[gameAddress], "Not an active game");
        uint256 reservedPOL = gameReservedLiquidity[gameAddress];
        
        require(reservedPOL > 0, "No reserved liquidity for this game");
        
        // Mark game as inactive
        activeGames[gameAddress] = false;
        
        // Unlock liquidity (the POL that was reserved for this game)
        newLockedLiquidity = lockedLiquidity - reservedPOL;
        
        // Clear reservation
        gameReservedLiquidity[gameAddress] = 0;
    }
}
