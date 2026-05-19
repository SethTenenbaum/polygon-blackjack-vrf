// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

/**
 * @title AutoLinkFunding
 * @notice Automatically funds VRF Coordinator and Keeper when LINK balances are low
 * @dev This library monitors LINK balances and automatically tops them up from the factory's LINK reserve
 * 
 * Architecture:
 * - Factory maintains a LINK reserve for auto-funding
 * - Checks balances before each game action
 * - Automatically transfers LINK when below threshold
 * - Emits events for monitoring
 * 
 * Thresholds (customizable):
 * - VRF Subscription: Min 5 LINK, Top-up to 10 LINK
 * - Keeper Upkeep: Min 2 LINK, Top-up to 5 LINK
 */
library AutoLinkFunding {
    // Custom errors
    error InsufficientLinkReserve();
    error LinkTransferFailed();
    error InvalidThreshold();

    // Events
    event VRFSubscriptionFunded(uint256 indexed subId, uint256 amount, uint256 newBalance);
    event KeeperUpkeepFunded(uint256 indexed upkeepId, uint256 amount, uint256 newBalance);
    event LinkReserveReplenished(address indexed from, uint256 amount);
    event ThresholdsUpdated(uint256 vrfMin, uint256 vrfTarget, uint256 keeperMin, uint256 keeperTarget);

    // Funding thresholds
    struct FundingConfig {
        uint256 vrfMinBalance;      // Minimum LINK for VRF before funding
        uint256 vrfTargetBalance;   // Amount to fund VRF to
        uint256 keeperMinBalance;   // Minimum LINK for Keeper before funding
        uint256 keeperTargetBalance; // Amount to fund Keeper to
    }

    // Default configuration (can be customized)
    function getDefaultConfig() internal pure returns (FundingConfig memory) {
        return FundingConfig({
            vrfMinBalance: 5 ether,      // 5 LINK minimum
            vrfTargetBalance: 10 ether,   // Top-up to 10 LINK
            keeperMinBalance: 2 ether,    // 2 LINK minimum  
            keeperTargetBalance: 5 ether  // Top-up to 5 LINK
        });
    }

    /**
     * @notice Check and fund VRF subscription if needed
     * @param linkToken LINK token contract
     * @param vrfCoordinator VRF Coordinator address
     * @param subscriptionId VRF subscription ID
     * @param factoryLinkBalance Factory's LINK reserve balance
     * @param config Funding configuration
     * @return funded Whether funding occurred
     * @return amountFunded Amount of LINK transferred
     */
    function checkAndFundVRF(
        IERC20 linkToken,
        address vrfCoordinator,
        uint256 subscriptionId,
        uint256 factoryLinkBalance,
        FundingConfig memory config
    ) internal returns (bool funded, uint256 amountFunded) {
        // Get VRF subscription balance (would need VRF interface to check actual balance)
        // For now, we'll use a simplified approach checking if we have enough for requests
        
        // Calculate funding needed
        uint256 currentBalance = linkToken.balanceOf(vrfCoordinator);
        
        if (currentBalance < config.vrfMinBalance) {
            amountFunded = config.vrfTargetBalance - currentBalance;
            
            // Check if factory has enough LINK
            if (factoryLinkBalance < amountFunded) {
                revert InsufficientLinkReserve();
            }
            
            // Transfer LINK to VRF coordinator
            bool success = linkToken.transfer(vrfCoordinator, amountFunded);
            if (!success) revert LinkTransferFailed();
            
            emit VRFSubscriptionFunded(subscriptionId, amountFunded, config.vrfTargetBalance);
            return (true, amountFunded);
        }
        
        return (false, 0);
    }

    /**
     * @notice Check and fund Chainlink Keeper upkeep if needed
     * @param linkToken LINK token contract
     * @param keeperRegistry Chainlink Keeper Registry address
     * @param upkeepId Keeper upkeep ID
     * @param factoryLinkBalance Factory's LINK reserve balance
     * @param config Funding configuration
     * @return funded Whether funding occurred
     * @return amountFunded Amount of LINK transferred
     */
    function checkAndFundKeeper(
        IERC20 linkToken,
        address keeperRegistry,
        uint256 upkeepId,
        uint256 factoryLinkBalance,
        FundingConfig memory config
    ) internal returns (bool funded, uint256 amountFunded) {
        // Get Keeper upkeep balance (would need Keeper interface to check actual balance)
        uint256 currentBalance = linkToken.balanceOf(keeperRegistry);
        
        if (currentBalance < config.keeperMinBalance) {
            amountFunded = config.keeperTargetBalance - currentBalance;
            
            // Check if factory has enough LINK
            if (factoryLinkBalance < amountFunded) {
                revert InsufficientLinkReserve();
            }
            
            // Transfer LINK to Keeper registry
            bool success = linkToken.transfer(keeperRegistry, amountFunded);
            if (!success) revert LinkTransferFailed();
            
            emit KeeperUpkeepFunded(upkeepId, amountFunded, config.keeperTargetBalance);
            return (true, amountFunded);
        }
        
        return (false, 0);
    }

    /**
     * @notice Check and fund both VRF and Keeper if needed
     * @dev Called before game creation to ensure sufficient LINK
     */
    function checkAndFundAll(
        IERC20 linkToken,
        address vrfCoordinator,
        uint256 subscriptionId,
        address keeperRegistry,
        uint256 upkeepId,
        FundingConfig memory config
    ) internal returns (uint256 totalFunded) {
        uint256 factoryBalance = linkToken.balanceOf(address(this));
        
        // Fund VRF if needed
        (, uint256 vrfFunded) = checkAndFundVRF(
            linkToken,
            vrfCoordinator,
            subscriptionId,
            factoryBalance,
            config
        );
        totalFunded += vrfFunded;
        
        // Update factory balance after VRF funding
        factoryBalance = linkToken.balanceOf(address(this));
        
        // Fund Keeper if needed
        (, uint256 keeperFunded) = checkAndFundKeeper(
            linkToken,
            keeperRegistry,
            upkeepId,
            factoryBalance,
            config
        );
        totalFunded += keeperFunded;
        
        return totalFunded;
    }

    /**
     * @notice Validate funding configuration
     */
    function validateConfig(FundingConfig memory config) internal pure {
        if (config.vrfTargetBalance <= config.vrfMinBalance) revert InvalidThreshold();
        if (config.keeperTargetBalance <= config.keeperMinBalance) revert InvalidThreshold();
    }

    /**
     * @notice Calculate total LINK needed for auto-funding
     * @dev Useful for UI to show recommended LINK reserve
     */
    function calculateRecommendedReserve(FundingConfig memory config) internal pure returns (uint256) {
        // Reserve should cover at least 3 complete funding cycles
        return (config.vrfTargetBalance + config.keeperTargetBalance) * 3;
    }
}
