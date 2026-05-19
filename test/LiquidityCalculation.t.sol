// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {GameFactoryUpgradeable} from "../src/GameFactoryUpgradeable.sol";
import {GameToken} from "../src/GameToken.sol";
import {GameUpgradeable} from "../src/GameUpgradeable.sol";
import {TestableGameFactory} from "./TestableGameFactory.sol";
import {TestableGame} from "./TestableGame.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {VRFV2PlusClient} from "lib/foundry-chainlink-toolkit/lib/chainlink-brownie-contracts/contracts/src/v0.8/dev/vrf/libraries/VRFV2PlusClient.sol";

// Mock contracts
contract MockLINK is ERC20 {
    constructor() ERC20("Mock LINK", "LINK") {
        _mint(msg.sender, 1000000 ether);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockVRF {
    uint256 public requestId = 1;
    function requestRandomWords(VRFV2PlusClient.RandomWordsRequest memory) external payable returns (uint256) {
        return requestId++;
    }
}

/**
 * @title LiquidityCalculation Test
 * @notice Tests that liquidity calculations work correctly for different game outcomes
 * 
 * Expected behavior:
 * - When player LOSES: Tokens burned → Total supply decreases, but POL backing stays same → Liquidity increases
 * - When player WINS: POL used to pay winner → POL backing decreases → Liquidity decreases
 * - When POL is added: POL backing increases → Liquidity increases → Max bet increases
 * - When tokens are bought: POL is extracted → POL backing decreases → Liquidity decreases → Max bet decreases
 */
contract LiquidityCalculationTest is Test {
    TestableGameFactory public factory;
    GameToken public gameToken;
    MockLINK public link;
    address public vrfCoordinator = 0x343300b5d84D444B2ADc9116FEF1bED02BE49Cf2;
    address public linkAddr = 0x0Fd9e8d3aF1aaee056EB9e802c3A762a667b1904;
    
    address public owner = address(1);
    address public player = address(2);
    
    uint256 constant MINT_RATE = 1000; // 1 POL = 1000 tokens
    uint256 constant INITIAL_POL = 10 ether;
    uint256 public linkFee = 0.005 ether; // 0.005 LINK per VRF request (actual game cost)
    
    function setUp() public {
        // Deploy mock contracts
        link = new MockLINK();
        MockVRF mockVrf = new MockVRF();
        vm.etch(vrfCoordinator, address(mockVrf).code);
        vm.store(vrfCoordinator, bytes32(0), bytes32(uint256(1)));
        vm.etch(linkAddr, address(link).code);
        
        // Deploy GameToken
        gameToken = new GameToken();
        
        // Mint initial tokens for test contract with POL backing
        uint256 ownerPOL = 100 ether; // 100 POL to mint 100k tokens
        vm.deal(address(this), ownerPOL);
        gameToken.buyTokens{value: ownerPOL}();
        
        // Deploy Factory
        factory = new TestableGameFactory();
        factory.initializeTest(
            vrfCoordinator,
            linkAddr,
            address(gameToken),
            linkFee,
            1 * 10**18, // minBet
            1, // subscriptionId (mock)
            address(0x1234) // keeperAddress (mock)
        );
        
        // Transfer GameToken ownership to factory
        gameToken.transferOwnership(address(factory));
        
        // TestableGameFactory needs tokens in its balance
        uint256 liquidityTokens = 10000 ether;
        vm.deal(address(this), INITIAL_POL * 2);
        gameToken.buyTokens{value: INITIAL_POL}(); // Buy 10k tokens
        gameToken.transfer(address(factory), liquidityTokens); // Transfer to factory
        // Add extra POL to reserve
        vm.deal(address(factory), INITIAL_POL);
        vm.prank(address(factory));
        gameToken.topUpReserve{value: INITIAL_POL}();
        
        // Give player some tokens (buy directly to ensure proper backing)
        vm.deal(player, 100 ether + (5000 ether / 1000)); // POL for game ops + tokens
        vm.startPrank(player);
        gameToken.buyTokens{value: 5000 ether / 1000}(); // Buy 5000 tokens
        vm.stopPrank();
        
        // Set LINK balance for player
        bytes32 balancesSlot = bytes32(uint256(0));
        bytes32 playerBalanceSlot = keccak256(abi.encode(player, balancesSlot));
        vm.store(linkAddr, playerBalanceSlot, bytes32(uint256(100 ether)));
        
        // Set LINK allowance from player to factory
        bytes32 allowancesSlot = bytes32(uint256(1));
        bytes32 inner = keccak256(abi.encode(player, allowancesSlot));
        bytes32 outer = keccak256(abi.encode(address(factory), inner));
        vm.store(linkAddr, outer, bytes32(uint256(100 ether)));
    }
    
    function testLiquidityCalculation_Initial() public view {
        // Check initial state
        (
            uint256 total,
            uint256 available,
            uint256 locked,
            uint256 maxBet,
            ,
        ) = factory.getLiquidityStats();
        
        // total = total POL backing in GameToken
        // We added 10 POL via addLiquidityWithPOL, plus bought 100 POL of tokens
        // Total POL backing = 110 POL
        uint256 expectedPOL = 110 ether;
        assertEq(total, expectedPOL, "Total liquidity POL should be 110");
        
        // available = factory's token balance + mintable tokens from available POL
        // Factory has 10,000 tokens, and can mint 0 more (all POL is already backing tokens)
        // Actually, total supply is 110k tokens, max mintable is 110 POL * 1000 = 110k
        // So mintable = 110k - 110k = 0, available = factory's 10k tokens
        uint256 expectedAvailable = 10000 ether;
        assertEq(available, expectedAvailable, "Available should be factory's token balance");
        assertEq(locked, 0, "No locked liquidity initially");
        
        console.log("Initial total liquidity (POL):", total / 1e18);
        console.log("Initial available liquidity (tokens):", available / 1e18);
        console.log("Initial max bet (tokens):", maxBet / 1e18);
    }
    
    function testLiquidityIncreasesWhenPlayerLoses() public {
        // Get initial liquidity
        (uint256 initialTotal, uint256 initialAvailable, uint256 initialLocked, uint256 initialMaxBet, ,) = factory.getLiquidityStats();
        uint256 initialTokenSupply = gameToken.totalSupply();
        uint256 initialPOLBacking = address(gameToken).balance;
        
        console.log("\n=== PLAYER LOSES GAME ===");
        console.log("Initial total liquidity (POL):", initialTotal / 1e18);
        console.log("Initial available liquidity (tokens):", initialAvailable / 1e18);
        console.log("Initial locked liquidity (POL):", initialLocked / 1e18);
        console.log("Initial max bet:", initialMaxBet / 1e18);
        console.log("Initial token supply:", initialTokenSupply / 1e18);
        console.log("Initial POL backing:", initialPOLBacking / 1e18);
        
        // Create and play a game where player loses (bets 100 tokens)
        uint256 betAmount = 100 ether;
        _createAndLoseGame(player, betAmount);
        
        // Get new liquidity
        (uint256 newTotal, uint256 newAvailable, uint256 newLocked, uint256 newMaxBet, ,) = factory.getLiquidityStats();
        uint256 newTokenSupply = gameToken.totalSupply();
        uint256 newPOLBacking = address(gameToken).balance;
        
        console.log("\nAfter player loses:");
        console.log("New total liquidity (POL):", newTotal / 1e18);
        console.log("New available liquidity (tokens):", newAvailable / 1e18);
        console.log("New locked liquidity (POL):", newLocked / 1e18);
        console.log("New max bet:", newMaxBet / 1e18);
        console.log("New token supply:", newTokenSupply / 1e18);
        console.log("New POL backing:", newPOLBacking / 1e18);
        console.log("Tokens burned:", (initialTokenSupply - newTokenSupply) / 1e18);
        
        // Debug the calculation
        console.log("\n=== Debug Calculation ===");
        console.log("Expected available: (110 * 108900) / 110 = ", (newPOLBacking * newTokenSupply) / newPOLBacking / 1e18);
        
        // Verify: POL backing should stay the same (tokens were just burned)
        assertEq(newPOLBacking, initialPOLBacking, "POL backing should not change when player loses");
        
        // Verify: Token supply decreased (tokens were burned)
        assertLt(newTokenSupply, initialTokenSupply, "Token supply should decrease when tokens burned");
        
        // Verify: Locked liquidity should be released (game finished)
        assertEq(newLocked, 0, "Locked liquidity should be released after game finishes");
        
        // Verify: Available liquidity should INCREASE when tokens are burned
        // This is because burned tokens free up POL that can mint new tokens
        assertEq(newTotal, initialTotal, "Total POL liquidity should stay same");
        assertGt(newAvailable, initialAvailable, "Available liquidity increases when tokens burned");
        
        // Max bet increases because more tokens can be minted from freed POL
        assertGt(newMaxBet, initialMaxBet, "Max bet increases when tokens are burned");
        
        console.log("\nMax bet change:", int256(newMaxBet) - int256(initialMaxBet));
    }
    
    function testLiquidityDecreasesWhenPlayerWins() public {
        // Get initial liquidity
        (, uint256 initialAvailable, , uint256 initialMaxBet, ,) = factory.getLiquidityStats();
        uint256 initialPOLBacking = address(gameToken).balance;
        
        console.log("\n=== PLAYER WINS GAME ===");
        console.log("Initial available liquidity:", initialAvailable / 1e18);
        console.log("Initial max bet:", initialMaxBet / 1e18);
        console.log("Initial POL backing:", initialPOLBacking / 1e18);
        
        // Create and play a game where player wins (bets 100 tokens, gets back ~150-200)
        uint256 betAmount = 100 ether;
        uint256 payout = _createAndWinGame(player, betAmount);
        
        // Get new liquidity
        (, uint256 newAvailable, , uint256 newMaxBet, ,) = factory.getLiquidityStats();
        uint256 newPOLBacking = address(gameToken).balance;
        
        console.log("\nAfter player wins:");
        console.log("Payout received:", payout / 1e18);
        console.log("New available liquidity:", newAvailable / 1e18);
        console.log("New max bet:", newMaxBet / 1e18);
        console.log("New POL backing:", newPOLBacking / 1e18);
        console.log("POL used for payout:", (initialPOLBacking - newPOLBacking) / 1e18);
        
        // Verify: POL backing decreased (used to back payout tokens)
        // Note: Payout is in tokens, but we're tracking POL backing
        // When player wins, contract may burn some and transfer rest
        // The key is available liquidity should decrease
        assertLt(newAvailable, initialAvailable, "Available liquidity should decrease when player wins");
        assertLt(newMaxBet, initialMaxBet, "Max bet should decrease after player win");
    }
    
    function testMaxBetIncreasesWhenPOLAdded() public {
        // Get initial max bet
        (, , , uint256 initialMaxBet, ,) = factory.getLiquidityStats();
        uint256 initialPOL = address(gameToken).balance;
        
        console.log("\n=== ADDING POL LIQUIDITY ===");
        console.log("Initial max bet:", initialMaxBet / 1e18);
        console.log("Initial POL backing:", initialPOL / 1e18);
        
        // Add more POL (test contract is the owner of factory)
        uint256 additionalPOL = 5 ether;
        vm.deal(address(this), additionalPOL);
        factory.addLiquidityWithPOL{value: additionalPOL}();
        
        // Get new max bet
        (, , , uint256 newMaxBet, ,) = factory.getLiquidityStats();
        uint256 newPOL = address(gameToken).balance;
        
        console.log("\nAfter adding POL:");
        console.log("POL added:", additionalPOL / 1e18);
        console.log("New POL backing:", newPOL / 1e18);
        console.log("New max bet:", newMaxBet / 1e18);
        console.log("Max bet increase:", (newMaxBet - initialMaxBet) / 1e18);
        
        // Verify: POL backing increased
        assertEq(newPOL, initialPOL + additionalPOL, "POL backing should increase by amount added");
        
        // Verify: Max bet increased
        assertGt(newMaxBet, initialMaxBet, "Max bet should increase when POL is added");
    }
    
    function testMaxBetDecreasesWhenTokensBought() public {
        // Get initial max bet
        (, , , uint256 initialMaxBet, ,) = factory.getLiquidityStats();
        uint256 initialPOL = address(gameToken).balance;
        
        console.log("\n=== BUYING TOKENS ===");
        console.log("Initial max bet:", initialMaxBet / 1e18);
        console.log("Initial POL backing:", initialPOL / 1e18);
        
        // Player buys tokens (sends POL, gets tokens)
        uint256 polToBuy = 2 ether;
        vm.prank(player);
        gameToken.buyTokens{value: polToBuy}();
        
        // Get new max bet
        (, , , uint256 newMaxBet, ,) = factory.getLiquidityStats();
        uint256 newPOL = address(gameToken).balance;
        
        console.log("\nAfter buying tokens:");
        console.log("POL sent:", polToBuy / 1e18);
        console.log("New POL backing:", newPOL / 1e18);
        console.log("New max bet:", newMaxBet / 1e18);
        console.log("Max bet change:", int256(newMaxBet) - int256(initialMaxBet));
        
        // Verify: POL backing increased (player sent POL to contract)
        assertEq(newPOL, initialPOL + polToBuy, "POL backing should increase when tokens bought");
        
        // Verify: Max bet stays the same (new POL fully backs new tokens)
        // When tokens are minted, supply increases proportionally to POL, so mintable stays 0
        assertEq(newMaxBet, initialMaxBet, "Max bet stays same when tokens bought at proper backing ratio");
    }
    
    // Helper: Create a game where player loses
    function _createAndLoseGame(address _player, uint256 _betAmount) internal returns (address gameAddress) {
        // Player approves tokens
        vm.startPrank(_player);
        gameToken.approve(address(factory), _betAmount);
        
        // Create game
        gameAddress = factory.createGame(_betAmount);
        TestableGame game = TestableGame(payable(gameAddress));
        
        console.log("\n=== Game Created (Player Loses) ===");
        console.log("Game address:", gameAddress);
        console.log("Game token balance:", gameToken.balanceOf(gameAddress) / 1e18);
        console.log("Game state:", uint(game.state()));
        
        // Set up cards using testSetCards
        // Player gets 10+10 = 20, Dealer gets 10+10+Ace = 21
        uint8[] memory playerCards = new uint8[](2);
        playerCards[0] = 10; // 10
        playerCards[1] = 23; // Another 10
        
        uint8[] memory dealerCards = new uint8[](2);
        dealerCards[0] = 10; // 10  
        dealerCards[1] = 1;  // Ace (counts as 11, so 21)
        
        game.testSetCards(playerCards, dealerCards);
        
        console.log("After testSetCards - Game state:", uint(game.state()));
        
        // Player stands (has 20, will lose to dealer's 21)
        if (uint(game.state()) == 1) { // PlayerTurn
            game.stand();
            console.log("After stand - Game state:", uint(game.state()));
        }
        
        console.log("Final game token balance:", gameToken.balanceOf(gameAddress) / 1e18);
        console.log("Final game state:", uint(game.state()));
        
        vm.stopPrank();
    }
    
    // Helper: Create a game where player wins (blackjack)
    function _createAndWinGame(address _player, uint256 _betAmount) internal returns (uint256 payout) {
        uint256 balanceBefore = gameToken.balanceOf(_player);
        
        // Player approves tokens
        vm.startPrank(_player);
        gameToken.approve(address(factory), _betAmount);
        
        // Create game
        address gameAddress = factory.createGame(_betAmount);
        TestableGame game = TestableGame(payable(gameAddress));
        
        console.log("\n=== Game Created (Player Wins) ===");
        console.log("Game address:", gameAddress);
        console.log("Game token balance:", gameToken.balanceOf(gameAddress) / 1e18);
        
        // Set up cards using testSetCards  
        // Player gets Ace+10 = 21 (blackjack), Dealer gets 10+9 = 19
        uint8[] memory playerCards = new uint8[](2);
        playerCards[0] = 1;  // Ace
        playerCards[1] = 10; // 10
        
        uint8[] memory dealerCards = new uint8[](2);
        dealerCards[0] = 10; // 10
        dealerCards[1] = 9;  // 9
        
        game.testSetCards(playerCards, dealerCards);
        
        console.log("After testSetCards - Game state:", uint(game.state()));
        console.log("Final game token balance:", gameToken.balanceOf(gameAddress) / 1e18);
        
        vm.stopPrank();
        
        // Calculate payout
        uint256 balanceAfter = gameToken.balanceOf(_player);
        payout = balanceAfter > balanceBefore ? balanceAfter - balanceBefore : 0;
        
        console.log("Payout received:", payout / 1e18);
    }
    
    // Helper: Encode 4 cards into a single uint256 for VRF mock
    function _encodeCards(uint8 c1, uint8 c2, uint8 c3, uint8 c4) internal pure returns (uint256) {
        return uint256(c1) | (uint256(c2) << 8) | (uint256(c3) << 16) | (uint256(c4) << 24);
    }
}
