// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {ERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";

/**
 * @title GameToken
 * @notice ERC20 token for blackjack game with POL-backed minting
 * @dev Features:
 *      - POL-backed supply - all tokens must be minted with POL
 *      - Fixed price: 1000 tokens per 1 POL
 *      - Anyone can mint by sending POL via buyTokens()
 *      - Anyone can redeem tokens for POL at same rate
 *      - NO FEES on buy/sell - simple 1:1000 rate
 *      - NO INITIAL SUPPLY - all tokens must be minted with POL backing
 * 
 * Economics:
 * - Buy: 1 POL = 1000 tokens (unlimited, fixed rate, no fees)
 * - Sell: 1000 tokens = 1 POL (no fees)
 * - Simple and predictable
 * - 100% POL-backed at all times
 */
contract GameToken is ERC20, Ownable, ReentrancyGuard {
    // NO INITIAL SUPPLY - all tokens must be minted with POL backing
    
    // Fixed price: 1000 tokens per 1 POL
    uint256 public constant TOKENS_PER_POL = 1000;
    
    // Minimum purchase to prevent dust attacks
    uint256 public constant MIN_PURCHASE = 0.001 ether; // 0.001 POL
    
    // Events
    event TokensPurchased(address indexed buyer, uint256 polIn, uint256 tokensOut);
    event TokensRedeemed(address indexed seller, uint256 tokensIn, uint256 polOut);
    event TokensBurned(address indexed from, uint256 amount);
    event ReserveTopUp(address indexed sender, uint256 amount, uint256 newBalance);
    
    constructor() ERC20("Blackjack Token", "BJT") Ownable(msg.sender) {
        // NO initial supply - all tokens must be minted with POL backing via buyTokens()
    }
    
    /**
     * @notice Buy tokens with POL at fixed rate (1 POL = 1000 tokens)
     * @dev Mints new tokens on demand - NO FEES
     *      Maximum purchase is naturally limited by available liquidity in GameFactory
     */
    function buyTokens() external payable nonReentrant returns (uint256 tokensOut) {
        require(msg.value >= MIN_PURCHASE, "Purchase amount too small");
        
        uint256 polIn = msg.value;
        
        // Calculate tokens at fixed rate: 1 POL = 1000 tokens (no fees)
        tokensOut = (polIn * TOKENS_PER_POL * 10**18) / 1 ether;
        require(tokensOut > 0, "Insufficient output");
        
        // Mint tokens to buyer (unlimited supply)
        // POL is automatically added to address(this).balance
        _mint(msg.sender, tokensOut);
        
        emit TokensPurchased(msg.sender, polIn, tokensOut);
    }
    
    /**
     * @notice Redeem tokens for POL at fixed rate (1000 tokens = 1 POL)
     * @dev Burns tokens and returns POL from contract balance - NO FEES
     */
    function redeemTokens(uint256 tokenAmount) external nonReentrant returns (uint256 polOut) {
        require(tokenAmount > 0, "Amount must be > 0");
        require(balanceOf(msg.sender) >= tokenAmount, "Insufficient balance");
        
        // Calculate POL at fixed rate: 1000 tokens = 1 POL (no fees)
        polOut = (tokenAmount * 1 ether) / (TOKENS_PER_POL * 10**18);
        require(polOut > 0, "Insufficient output");
        // this should never happen due to previous checks, but just in case
        require(address(this).balance >= polOut, "Insufficient POL reserve");
        
        _burn(msg.sender, tokenAmount);
        emit TokensRedeemed(msg.sender, tokenAmount, polOut);
        
        payable(msg.sender).transfer(polOut);
    }
    
    /**
     * @notice Calculate how many tokens you get for given POL amount
     * @dev Fixed rate: 1 POL = 1000 tokens (no fees)
     */
    function calculateBuyReturn(uint256 polAmount) public pure returns (uint256) {
        if (polAmount == 0) return 0;
        
        // Fixed rate: 1 POL = 1000 tokens (no fees)
        return (polAmount * TOKENS_PER_POL * 10**18) / 1 ether;
    }
    
    /**
     * @notice Calculate how much POL you get for given token amount
     * @dev Fixed rate: 1000 tokens = 1 POL (no fees)
     */
    function calculateSellReturn(uint256 tokenAmount) public pure returns (uint256) {
        if (tokenAmount == 0) return 0;
        
        // Fixed rate: 1000 tokens = 1 POL (no fees)
        return (tokenAmount * 1 ether) / (TOKENS_PER_POL * 10**18);
    }
    
    /**
     * @notice Burn tokens (used by game contract for expired games)
     * @dev Only callable by token holders
     */
    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
        emit TokensBurned(msg.sender, amount);
    }
    
    /**
     * @notice Burn tokens from another address (requires approval)
     * @dev Standard ERC20 burnFrom with approval check
     */
    function burnFrom(address account, uint256 amount) external onlyOwner {
        require(account != address(0), "Invalid account");
        require(amount > 0, "Amount must be > 0");
        _burn(account, amount);
        emit TokensBurned(account, amount);
    }
    
    /**
     * @notice Mint tokens to a game contract (factory-only)
     * @dev Used by factory to provide liquidity to games
     *      These tokens are NOT backed by POL - they represent factory's risk
     *      Factory can burn excess tokens later to maintain proper backing ratio
     */
    function mintToGame(address game, uint256 amount) external onlyOwner {
        require(game != address(0), "Invalid game address");
        require(amount > 0, "Amount must be > 0");
        _mint(game, amount);
    }

    /**
     * @notice Mint tokens to any address (testing only)
     * @dev Used for testing to fund accounts
     */
    function mint(address to, uint256 amount) external onlyOwner {
        require(to != address(0), "Invalid address");
        require(amount > 0, "Amount must be > 0");
        _mint(to, amount);
    }

    /**
     * @notice Get current buy price (fixed rate)
     * @return Tokens received per 1 POL
     */
    function getCurrentPrice() external pure returns (uint256) {
        return TOKENS_PER_POL * 10**18;
    }
    
    /**
     * @notice Check reserve health ratio
     * @dev Returns basis points (10000 = 100% backed, 5000 = 50% backed)
     * @return Reserve ratio in basis points
     */
    function getReserveRatio() public view returns (uint256) {
        uint256 totalTokens = totalSupply();
        if (totalTokens == 0) return 0; // No tokens = no backing needed
        
        // Calculate POL needed: tokens / 1000 (accounting for 18 decimals on both)
        // Example: 1000e18 tokens / (1000e18) = 1e18 POL needed
        uint256 polNeeded = (totalTokens * 1 ether) / (TOKENS_PER_POL * 10**18);
        if (polNeeded == 0) polNeeded = 1; // Minimum 1 wei needed
        
        return (address(this).balance * 10000) / polNeeded;
    }
    
    /**
     * @notice Check if reserve can cover at least 100% of tokens
     * @return True if reserve is healthy (100% or better backing)
     */
    function isReserveHealthy() public view returns (bool) {
        return getReserveRatio() >= 10000; // 100% or better
    }
    
    /**
     * @notice Get comprehensive reserve status for UI display
     * @return totalSupply_ Total token supply
     * @return reserveBalance_ Current POL reserve
     * @return polNeeded POL needed for 100% backing
     * @return ratio Reserve ratio in basis points
     * @return healthy Whether reserve is healthy (≥100%)
     */
    function getReserveStatus() external view returns (
        uint256 totalSupply_,
        uint256 reserveBalance_,
        uint256 polNeeded,
        uint256 ratio,
        bool healthy
    ) {
        totalSupply_ = totalSupply();
        reserveBalance_ = address(this).balance;
        polNeeded = (totalSupply_ * 1 ether) / (TOKENS_PER_POL * 10**18);
        ratio = getReserveRatio();
        healthy = isReserveHealthy();
    }
    
    /**
     * @notice Owner can add POL to reserve to maintain backing
     * @dev Use this to top up reserve if it becomes depleted due to player winnings
     */
    function topUpReserve() external payable onlyOwner {
        require(msg.value > 0, "Must send POL");
        emit ReserveTopUp(msg.sender, msg.value, address(this).balance);
    }

    /**
     * @notice Owner can withdraw excess POL as profits
     * @dev CRITICAL: Only allows withdrawal of excess POL (not needed for backing)
     *      Factory calculates the safe amount and calls this
     * @param recipient Address to receive the POL
     * @param amount Amount of POL to withdraw
     */
    function withdrawPOL(address recipient, uint256 amount) external onlyOwner {
        require(recipient != address(0), "Invalid recipient");
        require(amount > 0, "Amount must be > 0");
        require(address(this).balance >= amount, "Insufficient balance");
        
        // Safety check: ensure withdrawal doesn't underback tokens
        uint256 remainingReserve = address(this).balance - amount;
        uint256 polNeeded = totalSupply() / TOKENS_PER_POL;
        require(remainingReserve >= polNeeded, "Would underback tokens");
        
        payable(recipient).transfer(amount);
    }
    
    /**
     * @notice Allow contract to receive POL
     */
    receive() external payable {
        // POL automatically added to address(this).balance
    }
}
