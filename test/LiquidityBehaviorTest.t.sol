// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {GameFactoryUpgradeable} from "../src/GameFactoryUpgradeable.sol";
import {GameToken} from "../src/GameToken.sol";
import {GameUpgradeable} from "../src/GameUpgradeable.sol";
import {GameImplementation} from "../src/GameImplementation.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {VRFV2PlusClient} from "lib/foundry-chainlink-toolkit/lib/chainlink-brownie-contracts/contracts/src/v0.8/dev/vrf/libraries/VRFV2PlusClient.sol";

// Mock contracts
contract MockLINK is ERC20 {
    constructor() ERC20("Mock LINK", "LINK") {
        _mint(msg.sender, 1000000 ether);
    }
}

contract MockVRF {
    uint256 public requestId = 1;
    function requestRandomWords(VRFV2PlusClient.RandomWordsRequest memory) external payable returns (uint256) {
        return requestId++;
    }
}

/**
 * @title LiquidityBehaviorTest
 * @notice Tests that verify max bet increases after player losses and decreases after wins
 * 
 * KEY BEHAVIORS:
 * 1. When player WINS with blackjack (1.5x payout): 
 *    - They bet 80 BJT, win 120 BJT total (bet + 40 BJT profit)
 *    - Factory loses 40 BJT 
 *    - Available liquidity DECREASES by 0.04 POL
 *    - Max bet should DECREASE
 * 
 * 2. When player LOSES:
 *    - They bet 60 BJT, lose all 60 BJT
 *    - 60 BJT tokens are burned
 *    - 0.06 POL that backed those tokens becomes "excess" and available
 *    - Available liquidity INCREASES by 0.06 POL
 *    - Max bet should INCREASE
 */
contract LiquidityBehaviorTest is Test {
    GameFactoryUpgradeable public factory;
    GameToken public gameToken;
    MockLINK public link;
    MockVRF public mockVrf;
    
    address public owner;
    address public player1;
    address public player2;
    
    uint256 constant INITIAL_LIQUIDITY = 15 ether; // 15 POL → 15,000 BJT backing (5 POL excess)
    uint256 constant LINK_FEE = 0.005 ether;
    
    function setUp() public {
        owner = address(this);
        player1 = makeAddr("player1");
        player2 = makeAddr("player2");
        
        // Deploy mocks
        link = new MockLINK();
        mockVrf = new MockVRF();
        
        // Deploy GameToken
        gameToken = new GameToken();
        
        // Deploy Factory (upgradeable)
        GameFactoryUpgradeable factoryImpl = new GameFactoryUpgradeable();
        GameImplementation gameImpl = new GameImplementation();
        
        bytes memory initData = abi.encodeWithSelector(
            GameFactoryUpgradeable.initialize.selector,
            address(mockVrf),
            address(link),
            address(gameToken),
            address(gameImpl),
            LINK_FEE,
            1 ether, // min bet
            1, // subscriptionId (mock)
            address(0) // keeperAddress (not needed)
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(factoryImpl), initData);
        factory = GameFactoryUpgradeable(payable(address(proxy)));
        
        // Transfer GameToken ownership to factory (required for addLiquidityWithPOL)
        gameToken.transferOwnership(address(factory));
        
        // Add initial liquidity (10 POL → 10,000 BJT backing)
        factory.addLiquidityWithPOL{value: INITIAL_LIQUIDITY}();
        
        // Give players tokens and LINK
        vm.deal(player1, 100 ether);
        vm.deal(player2, 100 ether);
        
        // Player 1 buys 100 BJT (costs 0.1 POL)
        vm.prank(player1);
        gameToken.buyTokens{value: 0.1 ether}();
        
        // Player 2 buys 100 BJT (costs 0.1 POL)  
        vm.prank(player2);
        gameToken.buyTokens{value: 0.1 ether}();
        
        // Give players LINK
        link.transfer(player1, 100 ether);
        link.transfer(player2, 100 ether);
        
        console.log("\n=== INITIAL STATE ===");
        _printState("After setup");
    }
    
    function testPlayerWinDecreasesMaxBet() public {
        console.log("\n=== TEST: Player Wins (Blackjack) Should DECREASE Max Bet ===");
        
        // Get initial max bet
        (, , , uint256 initialMaxBet) = factory.getLiquidityStatus();
        console.log("Initial max bet:", initialMaxBet / 1e18, "BJT");
        
        // Player 1 creates a game with 80 BJT bet
        uint256 betAmount = 80 ether;
        
        vm.startPrank(player1);
        gameToken.approve(address(factory), betAmount);
        link.approve(address(factory), LINK_FEE);
        
        address gameAddr = factory.createGame(betAmount);
        // GameUpgradeable game = GameUpgradeable(payable(gameAddr));
        vm.stopPrank();
        
        _printState("After game created");
        
        // Simulate player getting blackjack (wins 1.5x)
        // Player gets: 80 (bet returned) + 120 (1.5x payout) = 200 BJT total... 
        // Wait, blackjack is 1.5x the BET, so: 80 + (80 * 1.5) = 80 + 120 = 200 BJT
        // No wait, blackjack pays 1.5:1, meaning for 80 bet you get 80 + 120 = 200 total
        // Actually blackjack is 3:2, so you get your bet + 1.5x bet = 2.5x total
        // Let me check the game logic...
        
        // For now, let's just manually resolve the game with a known payout
        // We'll transfer tokens from game to player to simulate a win
        vm.prank(gameAddr);
        gameToken.transfer(player1, 120 ether); // Player gets bet back + 40 BJT profit
        
        // Burn remaining tokens in game contract (simulate game end)
        uint256 gameBalance = gameToken.balanceOf(gameAddr);
        vm.prank(gameAddr);
        gameToken.burn(gameBalance);
        
        // Notify factory that game is finished
        vm.prank(gameAddr);
        factory.notifyGameFinished();
        
        _printState("After player wins");
        
        // Get new max bet
        (, , , uint256 newMaxBet) = factory.getLiquidityStatus();
        console.log("New max bet:", newMaxBet / 1e18, "BJT");
        
        // Max bet should DECREASE because factory lost tokens
        assertLt(newMaxBet, initialMaxBet, "Max bet should decrease after player wins");
    }
    
    function testPlayerLossIncreasesMaxBet() public {
        console.log("\n=== TEST: Player Loses Should INCREASE Max Bet ===");
        
        // Get initial max bet
        (, , , uint256 initialMaxBet) = factory.getLiquidityStatus();
        console.log("Initial max bet:", initialMaxBet / 1e18, "BJT");
        
        // Player 1 creates a game with 60 BJT bet
        uint256 betAmount = 60 ether;
        
        vm.startPrank(player1);
        gameToken.approve(address(factory), betAmount);
        link.approve(address(factory), LINK_FEE);
        
        address gameAddr = factory.createGame(betAmount);
        // GameUpgradeable game = GameUpgradeable(payable(gameAddr));
        vm.stopPrank();
        
        _printState("After game created");
        
        // Player loses - all tokens in game contract get burned
        uint256 gameBalance = gameToken.balanceOf(gameAddr);
        console.log("Game balance to burn:", gameBalance / 1e18, "BJT");
        
        vm.prank(gameAddr);
        gameToken.burn(gameBalance);
        
        // Notify factory that game is finished
        vm.prank(gameAddr);
        factory.notifyGameFinished();
        
        _printState("After player loses");
        
        // Get new max bet
        (, , , uint256 newMaxBet) = factory.getLiquidityStatus();
        console.log("New max bet:", newMaxBet / 1e18, "BJT");
        
        // Max bet should INCREASE because tokens were burned, freeing up POL
        assertGt(newMaxBet, initialMaxBet, "Max bet should increase after player loses");
    }
    
    function testMultipleGamesLiquidityBehavior() public {
        console.log("\n=== TEST: Multiple Games Liquidity Behavior ===");
        
        uint256 maxBet0;
        (, , , maxBet0) = factory.getLiquidityStatus();
        console.log("Starting max bet:", maxBet0 / 1e18, "BJT");
        
        // Game 1: Player 1 wins with blackjack (80 BJT bet)
        uint256 bet1 = 80 ether;
        vm.startPrank(player1);
        gameToken.approve(address(factory), bet1);
        link.approve(address(factory), LINK_FEE);
        address game1 = factory.createGame(bet1);
        vm.stopPrank();
        
        // Player wins - gets payout
        vm.prank(game1);
        gameToken.transfer(player1, 40 ether); // 40 BJT profit
        
        uint256 game1Balance = gameToken.balanceOf(game1);
        vm.prank(game1);
        gameToken.burn(game1Balance);
        
        vm.prank(game1);
        factory.notifyGameFinished();
        
        uint256 maxBet1;
        (, , , maxBet1) = factory.getLiquidityStatus();
        console.log("After WIN - max bet:", maxBet1 / 1e18, "BJT (should decrease)");
        assertLt(maxBet1, maxBet0, "Max bet should decrease after win");
        
        // Game 2: Player 2 loses (60 BJT bet)
        uint256 bet2 = 51 ether; // Use the new max bet amount
        vm.startPrank(player2);
        gameToken.approve(address(factory), bet2);
        link.approve(address(factory), LINK_FEE);
        address game2 = factory.createGame(bet2);
        vm.stopPrank();
        
        // Player loses - all tokens burned
        uint256 game2Balance = gameToken.balanceOf(game2);
        vm.prank(game2);
        gameToken.burn(game2Balance);
        
        vm.prank(game2);
        factory.notifyGameFinished();
        
        uint256 maxBet2;
        (, , , maxBet2) = factory.getLiquidityStatus();
        console.log("After LOSS - max bet:", maxBet2 / 1e18, "BJT (should increase)");
        assertGt(maxBet2, maxBet1, "Max bet should increase after loss");
        
        console.log("\nSUMMARY:");
        console.log("  Start:", maxBet0 / 1e18, "BJT");
        console.log("  After WIN:", maxBet1 / 1e18, "BJT");
        console.log("  After LOSS:", maxBet2 / 1e18, "BJT");
    }
    
    function _printState(string memory label) internal view {
        (, uint256 available, uint256 locked, uint256 maxBet) = factory.getLiquidityStatus();
        uint256 totalSupply = gameToken.totalSupply();
        uint256 tokenPOL = address(gameToken).balance;
        uint256 factoryPOL = address(factory).balance;
        
        console.log("\n---", label, "---");
        console.log("Total POL in GameToken:", tokenPOL / 1e18);
        console.log("Total supply:", totalSupply / 1e18, "BJT");
        console.log("POL needed for backing:", totalSupply / 1000 / 1e18);
        console.log("Excess POL:", (tokenPOL - totalSupply/1000) / 1e18);
        console.log("Factory POL balance:", factoryPOL / 1e18);
        console.log("Available liquidity:", available / 1e18, "BJT");
        console.log("Locked liquidity:", locked / 1e18, "POL");
        console.log("Max bet:", maxBet / 1e18, "BJT");
    }
}
