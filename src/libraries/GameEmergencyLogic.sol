// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

interface IGameToken is IERC20 {
    function burn(uint256 amount) external;
}

/**
 * @title GameEmergencyLogic
 * @notice Library for emergency and game cancellation functions
 */
library GameEmergencyLogic {
    event EmergencyWithdrawal(address indexed by, uint256 amount);
    event GameExpired(uint256 timestamp, address indexed player);
    event GameFinished(string result, uint256 payout);

    struct EmergencyParams {
        address factory;
        address gameTokenAddress;
        address linkAddress;
        uint256 createdAt;
        uint256 gameTimeout;
        uint256 playerPriorityPeriod;
        uint8 state; // GameState as uint8
    }

    /**
     * @notice Emergency withdrawal - only factory can call
     * @dev Used if game is stuck, hacked, or needs manual intervention
     *      Returns all GameToken and LINK to factory
     *      Access control: Game contract enforces onlyFactory modifier
     */
    function emergencyWithdrawToFactory(EmergencyParams memory params) 
        external 
        returns (uint8 newState)
    {
        // Give players priority period to claim refund via cancelExpiredGame()
        // Factory can only recover after GAME_TIMEOUT + PLAYER_PRIORITY_PERIOD
        require(
            block.timestamp >= params.createdAt + params.gameTimeout + params.playerPriorityPeriod || 
            params.state == 5, // GameState.Finished
            "Cannot emergency withdraw - players have priority"
        );
        
        IGameToken gameToken = IGameToken(params.gameTokenAddress);
        IERC20 link = IERC20(params.linkAddress);
        
        // Transfer all GameToken
        uint256 tokenBalance = gameToken.balanceOf(address(this));
        if (tokenBalance > 0) {
            require(gameToken.transfer(params.factory, tokenBalance), "Token transfer failed");
        }
        
        // Transfer all LINK
        uint256 linkBalance = link.balanceOf(address(this));
        if (linkBalance > 0) {
            require(link.transfer(params.factory, linkBalance), "LINK transfer failed");
        }
        
        emit EmergencyWithdrawal(params.factory, tokenBalance);
        
        return params.state == 5 ? params.state : 5; // Return Finished state
    }

    /**
     * @notice Cancel an expired game - player loses their bet as penalty
     * @dev Restricted to factory/keeper to prevent griefing
     *      Player loses their bet for abandoning the game
     *      All tokens (including player's bet) are burned - deflationary mechanism
     *      Access control: Game contract should enforce onlyFactory modifier
     */
    function cancelExpiredGame(
        address gameTokenAddress,
        address linkAddress,
        address factory,
        uint256 createdAt,
        uint256 gameTimeout,
        uint8 state,
        address player
    ) 
        external 
        returns (uint8 newState)
    {
        require(block.timestamp >= createdAt + gameTimeout, "Game not expired yet");
        require(state != 5, "Game already finished"); // 5 = GameState.Finished
        
        IGameToken gameToken = IGameToken(gameTokenAddress);
        IERC20 link = IERC20(linkAddress);
        
        // Player loses their bet as penalty for abandoning game
        // Burn ALL tokens (including player's bet and factory liquidity)
        uint256 totalBalance = gameToken.balanceOf(address(this));
        if (totalBalance > 0) {
            gameToken.burn(totalBalance);
        }
        
        // Return unused LINK to factory
        uint256 linkBalance = link.balanceOf(address(this));
        if (linkBalance > 0) {
            require(link.transfer(factory, linkBalance), "LINK return failed");
        }
        
        emit GameExpired(block.timestamp, player);
        emit GameFinished("expired - bet lost", 0);
        
        return 5; // GameState.Finished
    }

    /**
     * @notice Check if game has expired
     * @return Whether the game has exceeded the timeout period
     */
    function isExpired(uint256 createdAt, uint256 gameTimeout, uint8 state) 
        external 
        view 
        returns (bool) 
    {
        return block.timestamp >= createdAt + gameTimeout && state != 5; // 5 = GameState.Finished
    }

    /**
     * @notice Get time remaining before game expires
     * @return Seconds remaining, or 0 if already expired
     */
    function getTimeRemaining(uint256 createdAt, uint256 gameTimeout, uint8 state) 
        external 
        view 
        returns (uint256) 
    {
        if (state == 5) return 0; // GameState.Finished
        uint256 expiryTime = createdAt + gameTimeout;
        if (block.timestamp >= expiryTime) return 0;
        return expiryTime - block.timestamp;
    }
}
