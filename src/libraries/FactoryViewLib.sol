// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {GameToken} from "../GameToken.sol";

/**
 * @title FactoryViewLib
 * @notice External library for factory view/calculation functions
 * 
 * ============================================================================
 * CRITICAL: LIQUIDITY MODEL - READ THIS BEFORE MAKING ANY CHANGES!!!
 * ============================================================================
 * 
 * THE FACTORY DOES NOT HOLD BJT TOKENS! IT ONLY HOLDS POL!
 * 
 * How it works:
 * 1. Players buy BJT tokens with POL (POL → GameToken contract, tokens → player)
 * 2. Factory NEVER mints BJT to itself
 * 3. Factory tracks "POL backing" - the amount of POL in GameToken that backs all existing tokens
 * 4. When player WINS: Factory pays in POL (not BJT)
 * 5. When player LOSES: Player's BJT tokens are BURNED
 * 6. Burned tokens reduce total supply, making remaining POL "excess" (not needed for backing)
 * 7. This excess POL is now available for the factory to pay out winners
 * 
 * Available Liquidity = POL in GameToken that is NOT needed to back existing tokens
 *                     = (Total POL in GameToken) - (POL needed to back all tokens)
 *                     = (Total POL in GameToken) - (Total Supply / 1000)
 * 
 * NEVER EVER:
 * - Mint BJT tokens to the factory
 * - Make factory hold BJT tokens
 * - Check factory's BJT token balance for liquidity
 * 
 * ALWAYS:
 * - Track POL in GameToken contract
 * - Calculate excess POL (total POL - backing needed)
 * - Use excess POL as available liquidity
 * ============================================================================
 */
library FactoryViewLib {
    
    uint256 internal constant BLACKJACK_MAX_PAYOUT_MULTIPLIER = 11;
    
    /**
     * @notice Get total POL in GameToken reserves
     */
    function totalLiquidity(address gameTokenAddress) public view returns (uint256) {
        GameToken token = GameToken(payable(gameTokenAddress));
        return address(token).balance;
    }
    
    /**
     * @notice Get available liquidity in POL (not locked in games)
     * @dev Available liquidity = EXCESS POL (POL not needed to back existing tokens)
     *      This excess POL can be used to pay out winners
     *      When players lose and tokens are burned, this increases automatically
     *      
     *      CRITICAL: We calculate based on POL in GameToken, NOT factory token balance!
     *      - Total POL in GameToken contract
     *      - Minus POL needed to back all tokens in circulation (totalSupply / 1000)
     *      - Minus POL locked in active games
     *      = Available POL for new games
     */
    function availableLiquidity(
        address gameTokenAddress,
        uint256 lockedLiquidity,
        address /* factoryAddress */
    ) public view returns (uint256) {
        GameToken token = GameToken(payable(gameTokenAddress));
        
        // Get total POL in GameToken contract
        uint256 totalPOL = address(token).balance;
        
        // Calculate POL needed to back all existing tokens at 1000:1 ratio
        uint256 totalSupply = token.totalSupply();
        uint256 polNeededForBacking = totalSupply / token.TOKENS_PER_POL();
        
        // Excess POL = total POL - POL needed for backing - locked in games
        uint256 totalUnavailable = polNeededForBacking + lockedLiquidity;
        
        // Available = excess POL that can be used for new games
        return totalPOL > totalUnavailable ? totalPOL - totalUnavailable : 0;
    }
    
    /**
     * @notice Calculate maximum POL that can be safely withdrawn as profit
     * @dev Factory doesn't hold tokens - we only check excess POL in reserve
     *      Excess POL = (Total POL) - (POL needed for backing) - (locked in games)
     */
    function getMaxWithdrawableProfitPOL(
        address gameTokenAddress,
        uint256 lockedLiquidity,
        address /* factoryAddress */
    ) external view returns (uint256) {
        // Simply return available liquidity - it's already the excess POL
        return availableLiquidity(gameTokenAddress, lockedLiquidity, address(0));
    }
    
    /**
     * @notice Get maximum bet size to guarantee minimum concurrent players
     * @dev Calculates max bet based on available POL (not token balance!)
     *      Logic:
     *      1. Get available POL (excess POL not needed for backing, not locked)
     *      2. Each game needs (bet × 11) in POL to cover worst-case payout
     *      3. But player contributes the bet, so factory only needs (bet × 10) in POL
     *      4. For N concurrent players: availablePOL / (N × 10) = max bet
     *      5. Convert POL to tokens: maxBetPOL × 1000 = maxBetTokens
     * 
     * @param gameTokenAddress Address of GameToken contract
     * @param lockedLiquidity POL locked in active games
     * @param minConcurrentPlayers Minimum concurrent players to support
     */
    function getMaxBet(
        address gameTokenAddress,
        uint256 lockedLiquidity,
        uint256 minConcurrentPlayers,
        address /* factoryAddress */
    ) public view returns (uint256) {
        GameToken token = GameToken(payable(gameTokenAddress));
        
        // Get available POL (excess POL not locked, not needed for backing)
        uint256 availablePOL = availableLiquidity(gameTokenAddress, lockedLiquidity, address(0));
        
        if (availablePOL == 0) return 0;
        
        // Each game needs (bet × (11-1)) = (bet × 10) in POL
        // (Player contributes the bet, factory provides 10× more)
        // For N concurrent players: availablePOL / (N × 10) = max bet in POL
        uint256 maxBetPOL = availablePOL / (minConcurrentPlayers * (BLACKJACK_MAX_PAYOUT_MULTIPLIER - 1));
        
        // Convert POL to tokens (1 POL = 1000 tokens)
        uint256 maxBetTokens = maxBetPOL * token.TOKENS_PER_POL();
        
        return maxBetTokens;
    }
}
