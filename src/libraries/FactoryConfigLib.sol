// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FactoryGameLib} from "./FactoryGameLib.sol";

/**
 * @title FactoryConfigLib
 * @notice External library for factory configuration and simple getters
 */
library FactoryConfigLib {
    
    event MinConcurrentPlayersUpdated(uint256 oldValue, uint256 newValue);
    event MinBetUpdated(uint256 oldValue, uint256 newValue);
    event KeeperUpdated(address indexed oldKeeper, address indexed newKeeper);
    
    /**
     * @notice Set minimum concurrent players
     */
    function setMinConcurrentPlayers(
        uint256 newValue,
        uint256 /* currentValue */
    ) external pure returns (uint256) {
        require(newValue >= 1, "Must support at least 1 player");
        require(newValue <= 100, "Unreasonably high");
        return newValue;
    }
    
    /**
     * @notice Get configuration values
     */
    function getConfig(
        address vrfCoordinator,
        address linkAddress,
        uint256 linkFee,
        uint256 minBet
    ) external pure returns (
        address,
        address,
        uint256,
        uint256
    ) {
        return (vrfCoordinator, linkAddress, linkFee, minBet);
    }
    
    /**
     * @notice Get game address at index
     */
    function getGameAtIndex(
        address[] storage allGames,
        uint256 index
    ) external view returns (address) {
        if (index >= allGames.length) {
            return address(0);
        }
        return allGames[index];
    }
    
    /**
     * @notice Get total games count
     */
    function getTotalGamesCount(
        address[] storage allGames
    ) external view returns (uint256) {
        return allGames.length;
    }
    
    /**
     * @notice Check if game is active
     */
    function isGameActive(
        mapping(address => bool) storage activeGames,
        address gameAddress
    ) external view returns (bool) {
        return activeGames[gameAddress];
    }
    
    /**
     * @notice Get player games
     */
    function getPlayerGames(
        mapping(address => address[]) storage playerGames,
        address player
    ) external view returns (address[] memory) {
        return playerGames[player];
    }
    
    /**
     * @notice Get all active games
     */
    function getAllActiveGames(
        address[] storage allGames,
        mapping(address => bool) storage activeGames
    ) external view returns (address[] memory) {
        return FactoryGameLib.filterActiveGames(allGames, activeGames);
    }
}
