// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {GameImplementation} from "../GameImplementation.sol";

/**
 * @title FactoryInitLib
 * @notice External library for factory initialization logic
 */
library FactoryInitLib {
    
    event FactoryUpgraded(address indexed newImplementation, string newVersion);
    
    struct InitParams {
        address vrfCoordinator;
        address linkAddress;
        address gameTokenAddress;
        uint256 linkFee;
        uint256 minBet;
    }
    
    /**
     * @notice Validate initialization parameters
     */
    function validateInitParams(InitParams memory params) external pure {
        require(params.vrfCoordinator != address(0), "VRF coordinator cannot be zero address");
        require(params.linkAddress != address(0), "LINK address cannot be zero address");
        require(params.gameTokenAddress != address(0), "Game token address cannot be zero address");
        require(params.minBet > 0, "Minimum bet must be greater than 0");
    }
    
    /**
     * @notice Set initial storage values
     */
    function setInitialStorage(
        InitParams memory params,
        address gameImplementation
    ) external pure returns (
        address vrfCoordinator,
        address linkAddress,
        address gameTokenAddress,
        address gameImpl,
        uint256 linkFee,
        uint256 minBet,
        uint256 minConcurrentPlayers,
        string memory version
    ) {
        return (
            params.vrfCoordinator,
            params.linkAddress,
            params.gameTokenAddress,
            gameImplementation,
            params.linkFee,
            params.minBet,
            5,  // Default: guarantee 5 players can play
            "1.0.0"
        );
    }
}
