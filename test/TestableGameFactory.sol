// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {GameFactoryUpgradeable} from "../src/GameFactoryUpgradeable.sol";
import {TestableGame} from "./TestableGame.sol";
import {GameToken} from "../src/GameToken.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IVRFCoordinatorV2Plus} from "lib/foundry-chainlink-toolkit/lib/chainlink-brownie-contracts/contracts/src/v0.8/dev/interfaces/IVRFCoordinatorV2Plus.sol";

/**
 * @title TestableGameFactory
 * @notice GameFactory that creates TestableGame instances for testing
 * @dev DO NOT DEPLOY TO PRODUCTION - only for testing
 */
contract TestableGameFactory is GameFactoryUpgradeable {
    constructor() {}
    
    // Initialize wrapper for testing - remove initializer modifier to allow multiple calls
    function initializeTest(
        address _vrfCoordinator,
        address _linkAddress,
        address _gameTokenAddress,
        uint256 _linkFee,
        uint256 _minBet,
        uint256 _subscriptionId,
        address _keeperAddress
    ) external {
        FactoryStorage storage $ = _getFactoryStorage();
        
        $.vrfCoordinator = _vrfCoordinator;
        $.linkAddress = _linkAddress;
        $.gameTokenAddress = _gameTokenAddress;
        $.linkFee = _linkFee;
        $.minBet = _minBet;
        $.subscriptionId = _subscriptionId;
        $.keeperAddress = _keeperAddress;
        $.minConcurrentPlayers = 10;  // Default: guarantee 10 players can play
        $.vrfCallbackGasLimit = 2500000; // Set to 2.5M gas to match production config
        
        // Set s_vrfCoordinator which is outside the storage struct
        s_vrfCoordinator = IVRFCoordinatorV2Plus(_vrfCoordinator);
        
        // Manually set owner for testing
        _transferOwnership(msg.sender);
    }
    
    /**
     * @notice Create a new testable game (overrides parent)
     */
    function createGame(uint256 bet) external override returns (address gameAddress) {
        FactoryStorage storage $ = _getFactoryStorage();
        
        require(bet >= $.minBet, "Bet too small");
        
        // Get GameToken
        GameToken gameToken = GameToken(payable($.gameTokenAddress));
        
        // Transfer player bet to factory
        require(gameToken.transferFrom(msg.sender, address(this), bet), "Bet transfer failed");
        
        // Calculate required liquidity in tokens and convert to POL value for locking
        // Use constant multiplier based on blackjack rules
        uint256 requiredTokens = bet * BLACKJACK_MAX_PAYOUT_MULTIPLIER;
        // Convert tokens to POL: both have 18 decimals, so just divide by rate
        uint256 requiredPOL = requiredTokens / gameToken.TOKENS_PER_POL();
        
        // Check if we have enough POL liquidity
        uint256 availablePOL = availableLiquidity(); // Returns POL reserves
        require(availablePOL >= requiredPOL, "Insufficient factory liquidity for bet size");
        
        // Create TESTABLE game using two-step initialization
        TestableGame game = new TestableGame();
        gameAddress = address(game);
        game.initializeTest(msg.sender, bet, address(this), $.vrfCoordinator, $.gameTokenAddress, $.linkAddress);
        
        $.playerGames[msg.sender].push(gameAddress);
        $.activeGames[gameAddress] = true;
        
        // Add to allGames array for keeper enumeration
        $.gameToIndex[gameAddress] = $.allGames.length;
        $.allGames.push(gameAddress);
        
        // Reserve liquidity for this game (track POL value, not token amount)
        $.gameReservedLiquidity[gameAddress] = requiredPOL;
        $.lockedLiquidity += requiredPOL;
        
        // Transfer initial funding to game (enough for max payout in tokens)
        require(gameToken.transfer(gameAddress, requiredTokens), "Game funding failed");
        emit FundsTransferredToGame(gameAddress, requiredTokens);
        
        // Transfer LINK from player to game for startGame
        // Player must have approved factory for LINK spending
        IERC20 linkToken = IERC20($.linkAddress);
        require(linkToken.transferFrom(msg.sender, gameAddress, $.linkFee), "LINK transfer failed - player must approve factory");
        
        // Start the game (game now has LINK for VRF)
        game.startGame();
        
        emit GameCreated(msg.sender, gameAddress, bet);
    }
    
    /**
     * @notice Test helper to register a game as active
     * @dev DO NOT USE IN PRODUCTION - only for testing
     */
    function testRegisterActiveGame(address gameAddress) external {
        FactoryStorage storage $ = _getFactoryStorage();
        $.activeGames[gameAddress] = true;
    }
}
