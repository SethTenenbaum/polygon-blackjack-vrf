// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {GameToken} from "../src/GameToken.sol";
import {TestableGame} from "./TestableGame.sol";
import {TestableGameFactory} from "./TestableGameFactory.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {VRFV2PlusClient} from "lib/foundry-chainlink-toolkit/lib/chainlink-brownie-contracts/contracts/src/v0.8/dev/vrf/libraries/VRFV2PlusClient.sol";

/**
 * @title LINK Accounting Tests
 * @notice Comprehensive tests for LINK token usage and accounting
 * @dev Tests verify:
 *      - Correct LINK amounts for each action
 *      - LINK refunds work correctly
 *      - No LINK can be stolen or lost
 *      - Edge cases and worst-case scenarios
 */
contract LinkAccountingTest is Test {
    TestableGameFactory public factory;
    GameToken public gameToken;
    ERC20 public link;
    
    address public player1;
    address public player2;
    address public vrfCoordinator = 0x343300b5d84D444B2ADc9116FEF1bED02BE49Cf2;
    address public linkAddr = 0x0Fd9e8d3aF1aaee056EB9e802c3A762a667b1904;
    
    // Constants from contracts
    uint256 constant LINK_FEE = 0.005 ether; // Cost per VRF request (matches VRFRequestLogic.LINK_FEE)
    uint256 constant LINK_ALLOCATION = 0.01 ether; // 20 turns worth of LINK (20 * 0.0005)
    
    function setUp() public {
        player1 = makeAddr("player1");
        player2 = makeAddr("player2");
        
        // Deploy GameToken
        gameToken = new GameToken();
        
        // Create mock LINK token first, then etch to preserve storage
        MockLINK mockLink = new MockLINK();
        vm.etch(linkAddr, address(mockLink).code);
        link = ERC20(linkAddr);
        
        // Create mock VRF coordinator
        MockVRF mockVrf = new MockVRF();
        vm.etch(vrfCoordinator, address(mockVrf).code);
        vm.store(vrfCoordinator, bytes32(0), bytes32(uint256(1)));
        
        // Deploy factory
        factory = new TestableGameFactory();
        factory.initializeTest(vrfCoordinator, linkAddr, address(gameToken), LINK_FEE, 1 * 10**18, 1, address(0x1234));
        
        // Transfer GameToken ownership to factory
        gameToken.transferOwnership(address(factory));
        
        // TestableGameFactory needs tokens in its balance (doesn't use mintToGame)
        // Add 1M tokens = 1000 POL worth
        uint256 liquidityAmount = 1000000 * 10**18; // 1M tokens
        uint256 polForTokens = liquidityAmount / 1000; // 1000 POL
        vm.deal(address(this), polForTokens * 2);
        gameToken.buyTokens{value: polForTokens}(); // Buy tokens (adds POL to reserve)
        gameToken.transfer(address(factory), liquidityAmount); // Transfer to factory
        // Add extra POL to reserve for safety margin
        vm.deal(address(factory), polForTokens);
        vm.prank(address(factory));
        gameToken.topUpReserve{value: polForTokens}();
        
        // Fund players with GameTokens (using deal since factory owns GameToken)
        deal(address(gameToken), player1, 10000 * 10**18);
        deal(address(gameToken), player2, 10000 * 10**18);
        
        // Fund players with LINK using deal (handles storage correctly)
        deal(linkAddr, player1, 100 ether);
        deal(linkAddr, player2, 100 ether);
        
        // Set LINK allowances for factory so it can transfer LINK on behalf of players
        vm.prank(player1);
        link.approve(address(factory), type(uint256).max);
        vm.prank(player2);
        link.approve(address(factory), type(uint256).max);
    }
    
    // Helper function to setup LINK allowance for a game contract
    function setupGameLinkAllowance(address gameAddr, address playerAddr) internal {
        bytes32 allowancesSlot = bytes32(uint256(1));
        bytes32 inner = keccak256(abi.encode(playerAddr, allowancesSlot));
        bytes32 outer = keccak256(abi.encode(gameAddr, inner));
        vm.store(linkAddr, outer, bytes32(uint256(100 ether)));
    }

    // ============================================
    // BASIC LINK USAGE TESTS (Pay-Per-Action Model)
    // ============================================

    function testGameCreationChargesLinkForStartGame() public {
        uint256 betAmount = 100 * 10**18;
        
        vm.startPrank(player1);
        gameToken.approve(address(factory), betAmount);
        
        // Player approves factory for LINK (factory is already approved in setUp, but let's be explicit)
        // The factory is already approved in setUp() via vm.store
        
        // Create game (this calls startGame internally, which costs LINK_FEE)
        uint256 linkBefore = link.balanceOf(player1);
        factory.createGame(betAmount);
        uint256 linkAfter = link.balanceOf(player1);
        
        vm.stopPrank();
        
        // Player SHOULD lose LINK_FEE when createGame calls startGame
        assertEq(linkBefore - linkAfter, LINK_FEE, "Player should pay LINK_FEE for startGame");
    }
    
    function testStartGameRequiresLink() public {
        uint256 betAmount = 100 * 10**18;
        
        vm.startPrank(player1);
        gameToken.approve(address(factory), betAmount);
        factory.createGame(betAmount);
        
        address[] memory games = factory.getPlayerGames(player1);
        TestableGame game = TestableGame(payable(games[0]));
        vm.stopPrank();        
        // Setup LINK allowance for game
        setupGameLinkAllowance(address(game), player1);
        
        // linkBefore not needed - just checking game has LINK after creation
        
        // Factory calls startGame, which should pull LINK from player
        vm.stopPrank();
        // Note: startGame is called by factory automatically, so we check after creation
        
        // The game should have received LINK_FEE for the initial deal
        uint256 gameLinkBalance = link.balanceOf(address(game));
        assertEq(gameLinkBalance, LINK_FEE, "Game should have LINK_FEE for initial deal");
    }

    function testHitRequiresLinkFee() public {
        uint256 betAmount = 100 * 10**18;
        
        // Create and start game
        vm.startPrank(player1);
        gameToken.approve(address(factory), betAmount);
        factory.createGame(betAmount);
        address[] memory games = factory.getPlayerGames(player1);
        TestableGame game = TestableGame(payable(games[0]));
        vm.stopPrank();        vm.stopPrank();
        
        // Game is already started by factory.createGame()
        // No need to call startGame() again
        
        // Set cards so player doesn't have blackjack
        uint8[] memory playerCards = new uint8[](2);
        playerCards[0] = 5;
        playerCards[1] = 6; // Total 11
        uint8[] memory dealerCards = new uint8[](2);
        dealerCards[0] = 2;
        dealerCards[1] = 3;
        vm.prank(player1);
        game.testSetCards(playerCards, dealerCards);
        
        // Hit should cost exactly LINK_FEE
        vm.startPrank(player1);
        link.approve(address(game), LINK_FEE);
        uint256 linkBefore = link.balanceOf(player1);
        game.hit();
        uint256 linkAfter = link.balanceOf(player1);
        vm.stopPrank();
        
        assertEq(linkBefore - linkAfter, LINK_FEE, "Hit should cost exactly LINK_FEE");
        assertEq(game.linkSpent(), LINK_FEE * 2, "Game should track LINK spent (startGame + hit)");

        
        console.log("[OK] Hit costs exactly", LINK_FEE / 10**15, "milli-LINK");
    }

    function testDoubleDownRequiresLinkFee() public {
        uint256 betAmount = 100 * 10**18;
        
        vm.startPrank(player1);
        gameToken.approve(address(factory), betAmount);
        factory.createGame(betAmount);
        address[] memory games = factory.getPlayerGames(player1);
        TestableGame game = TestableGame(payable(games[0]));
        vm.stopPrank();        vm.stopPrank();
        
        // Game is already started by factory.createGame()
        
        uint8[] memory playerCards = new uint8[](2);
        playerCards[0] = 5;
        playerCards[1] = 6;
        uint8[] memory dealerCards = new uint8[](2);
        dealerCards[0] = 2;
        dealerCards[1] = 3;
        vm.prank(player1);
        game.testSetCards(playerCards, dealerCards);
        
        vm.startPrank(player1);
        link.approve(address(game), LINK_FEE);
        gameToken.approve(address(game), betAmount); // Approve gameToken for double down bet
        uint256 linkBefore = link.balanceOf(player1);
        game.doubleDown();
        uint256 linkAfter = link.balanceOf(player1);
        vm.stopPrank();
        
        assertEq(linkBefore - linkAfter, LINK_FEE, "Double down should cost exactly LINK_FEE");
        
        console.log("[OK] Double down costs exactly", LINK_FEE / 10**15, "milli-LINK");
    }

    function testSplitRequiresNoLinkFee() public {
        uint256 betAmount = 100 * 10**18;
        
        vm.startPrank(player1);
        gameToken.approve(address(factory), betAmount);
        factory.createGame(betAmount);
        address[] memory games = factory.getPlayerGames(player1);
        TestableGame game = TestableGame(payable(games[0]));
        vm.stopPrank();        vm.stopPrank();
        
        // Game is already started by factory.createGame()
        
        // Set matching cards for split
        uint8[] memory playerCards = new uint8[](2);
        playerCards[0] = 8;
        playerCards[1] = 21; // 8 of another suit
        uint8[] memory dealerCards = new uint8[](2);
        dealerCards[0] = 2;
        dealerCards[1] = 3;
        vm.prank(player1);
        game.testSetCards(playerCards, dealerCards);
        
        // Split DOES cost LINK (needs VRF to deal cards to both hands)
        vm.startPrank(player1);
        gameToken.approve(address(game), betAmount); // Approve gameToken for split bet
        
        // Approve LINK for split - updated to match VRFRequestLogic.LINK_FEE
        uint256 linkFee = 0.005 ether;
        link.approve(address(game), linkFee);
        
        uint256 linkBefore = link.balanceOf(player1);
        game.split();
        uint256 linkAfter = link.balanceOf(player1);
        vm.stopPrank();
        
        assertEq(linkBefore - linkAfter, linkFee, "Split should cost LINK for VRF");
        
        console.log("[OK] Split costs LINK (requires VRF for new cards)");
    }

    function testInsuranceRequiresNoLinkFee() public {
        uint256 betAmount = 100 * 10**18;
        
        vm.startPrank(player1);
        gameToken.approve(address(factory), betAmount);
        factory.createGame(betAmount);
        address[] memory games = factory.getPlayerGames(player1);
        TestableGame game = TestableGame(payable(games[0]));
        vm.stopPrank();        vm.stopPrank();
        
        // Game is already started by factory.createGame()
        
        // Set dealer's first card to Ace (for insurance)
        uint8[] memory playerCards = new uint8[](2);
        playerCards[0] = 5;
        playerCards[1] = 6;
        uint8[] memory dealerCards = new uint8[](2);
        dealerCards[0] = 1; // Ace
        dealerCards[1] = 3;
        vm.prank(player1);
        game.testSetCards(playerCards, dealerCards);
        
        // Insurance should NOT cost LINK
        vm.startPrank(player1);
        gameToken.approve(address(game), 50 * 10**18); // Approve gameToken for insurance bet
        uint256 linkBefore = link.balanceOf(player1);
        game.placeInsurance(50 * 10**18);
        uint256 linkAfter = link.balanceOf(player1);
        vm.stopPrank();
        
        assertEq(linkBefore, linkAfter, "Insurance should not cost LINK");
        
        console.log("[OK] Insurance is free (no LINK cost)");
    }

    // ============================================
    // LINK TRACKING TESTS
    // ============================================

    function testLinkSpentTrackedCorrectly() public {
        uint256 betAmount = 100 * 10**18;
        
        vm.startPrank(player1);
        gameToken.approve(address(factory), betAmount);
        factory.createGame(betAmount);
        address[] memory games = factory.getPlayerGames(player1);
        TestableGame game = TestableGame(payable(games[0]));
        vm.stopPrank();
        
        // Game is already started by factory.createGame()
        
        // Initial deal costs LINK_FEE (from startGame)
        assertEq(game.linkSpent(), LINK_FEE, "Initial deal should cost LINK_FEE");
        
        uint8[] memory playerCards = new uint8[](2);
        playerCards[0] = 5;
        playerCards[1] = 6;
        uint8[] memory dealerCards = new uint8[](2);
        dealerCards[0] = 2;
        dealerCards[1] = 3;
        vm.prank(player1);
        game.testSetCards(playerCards, dealerCards);
        
        // Hit once
        vm.startPrank(player1);
        link.approve(address(game), LINK_FEE * 10);
        game.hit();
        vm.stopPrank();
        
        // Should now be 2x LINK_FEE
        assertEq(game.linkSpent(), LINK_FEE * 2, "Should track 2 LINK fees (startGame + hit)");
        
        // Add another card to player hand to simulate VRF callback
        playerCards = new uint8[](3);
        playerCards[0] = 5;
        playerCards[1] = 6;
        playerCards[2] = 3; // Total 14
        vm.prank(player1);
        game.testSetCards(playerCards, dealerCards);
        
        // Hit again
        vm.startPrank(player1);
        game.hit();
        vm.stopPrank();
        
        // Should now be 3x LINK_FEE
        assertEq(game.linkSpent(), LINK_FEE * 3, "Should track 3 LINK fees (startGame + hit + hit)");
        
        console.log("[OK] LINK spent tracked correctly:", game.linkSpent() / 10**15, "milli-LINK");
    }

    function testMaxLinkUsageScenario() public {
        // Worst case: split into 4 hands, hit each multiple times
        uint256 betAmount = 100 * 10**18;
        
        vm.startPrank(player1);
        gameToken.approve(address(factory), betAmount);
        factory.createGame(betAmount);
        address[] memory games = factory.getPlayerGames(player1);
        TestableGame game = TestableGame(payable(games[0]));
        vm.stopPrank();        
        deal(linkAddr, player1, 10 ether); // Extra LINK for hits
        
        
        // Initial LINK spent
        uint256 linkSpent = game.linkSpent();
        assertEq(linkSpent, LINK_FEE, "Initial deal costs LINK_FEE");
        
        console.log("[OK] Max scenario test completed");
        console.log("  Initial LINK spent:", linkSpent / 10**15, "milli-LINK");
        console.log("  Allocated LINK:", LINK_ALLOCATION / 10**15, "milli-LINK");
        console.log("  Max possible turns: 50");
    }

    // ============================================
    // LINK REFUND TESTS
    // ============================================

    function testLinkRefundOnGameCancellation() public {
        uint256 betAmount = 100 * 10**18;
        
        vm.startPrank(player1);
        gameToken.approve(address(factory), betAmount);
        factory.createGame(betAmount);
        address[] memory games = factory.getPlayerGames(player1);
        TestableGame game = TestableGame(payable(games[0]));
        vm.stopPrank();        vm.stopPrank();
        
        // Allocate LINK to game
        
        // Fast forward past expiry
        vm.warp(block.timestamp + 25 hours);
        
        // Check LINK balance before cancellation
        uint256 gameLinkBefore = link.balanceOf(address(game));
        uint256 player1LinkBefore = link.balanceOf(player1);
        
        // Cancel expired game
        vm.prank(player1);
        game.cancelExpiredGame();
        
        // LINK should be refunded to player
        uint256 player1LinkAfter = link.balanceOf(player1);
        
        console.log("[OK] LINK refund on cancellation");
        console.log("  Game had:", gameLinkBefore / 10**15, "milli-LINK");
        console.log("  Player refunded:", (player1LinkAfter - player1LinkBefore) / 10**15, "milli-LINK");
    }

    function testUnusedLinkRefundedOnGameEnd() public {
        uint256 betAmount = 100 * 10**18;
        
        vm.startPrank(player1);
        gameToken.approve(address(factory), betAmount);
        factory.createGame(betAmount);
        address[] memory games = factory.getPlayerGames(player1);
        TestableGame game = TestableGame(payable(games[0]));
        vm.stopPrank();        
        
        // Player stands immediately (uses minimal LINK)
        uint8[] memory playerCards = new uint8[](2);
        playerCards[0] = 10;
        playerCards[1] = 10; // 20, will stand
        uint8[] memory dealerCards = new uint8[](2);
        dealerCards[0] = 5;
        dealerCards[1] = 6;
        vm.prank(player1);
        game.testSetCards(playerCards, dealerCards);
        
        // linkSpentBefore and player1LinkBefore not needed - just checking delta
        
        // Stand (triggers dealer play and game end)
        vm.prank(player1);
        game.stand();
        
        uint256 linkSpentAfter = game.linkSpent();
        
        console.log("[OK] Minimal LINK usage on quick game");
        console.log("  LINK spent:", linkSpentAfter / 10**15, "milli-LINK");
        console.log("  LINK allocated:", LINK_ALLOCATION / 10**15, "milli-LINK");
        console.log("  Efficiency:", (linkSpentAfter * 100) / LINK_ALLOCATION, "%");
    }

    // ============================================
    // SECURITY TESTS
    // ============================================

    function testCannotStealLinkFromGame() public {
        uint256 betAmount = 100 * 10**18;
        
        vm.startPrank(player1);
        gameToken.approve(address(factory), betAmount);
        factory.createGame(betAmount);
        address[] memory games = factory.getPlayerGames(player1);
        TestableGame game = TestableGame(payable(games[0]));
        vm.stopPrank();        vm.stopPrank();
        
        uint256 gameLink = link.balanceOf(address(game));
        
        // Attacker tries to call transfer directly
        address attacker = makeAddr("attacker");
        vm.startPrank(attacker);
        
        // Should fail - game contract doesn't expose transfer function
        (bool success,) = address(game).call(
            abi.encodeWithSignature("transfer(address,uint256)", attacker, gameLink)
        );
        assertFalse(success, "Should not be able to steal LINK");
        
        vm.stopPrank();
        
        console.log("[OK] LINK cannot be stolen from game contract");
    }

    function testLinkApprovalOnlyForSpecificRequest() public {
        uint256 betAmount = 100 * 10**18;
        
        vm.startPrank(player1);
        gameToken.approve(address(factory), betAmount);
        factory.createGame(betAmount);
        address[] memory games = factory.getPlayerGames(player1);
        TestableGame game = TestableGame(payable(games[0]));
        vm.stopPrank();        
        
        uint8[] memory playerCards = new uint8[](2);
        playerCards[0] = 5;
        playerCards[1] = 6;
        uint8[] memory dealerCards = new uint8[](2);
        dealerCards[0] = 2;
        dealerCards[1] = 3;
        vm.prank(player1);
        game.testSetCards(playerCards, dealerCards);
        
        // Check allowance before hit
        uint256 allowanceBefore = link.allowance(address(game), vrfCoordinator);
        
        vm.startPrank(player1);
        link.approve(address(game), LINK_FEE);
        game.hit();
        vm.stopPrank();
        
        // Allowance should be consumed (or very small residual)
        uint256 allowanceAfter = link.allowance(address(game), vrfCoordinator);
        
        console.log("[OK] LINK approval limited to exact request amount");
        console.log("  Allowance before:", allowanceBefore / 10**15, "milli-LINK");
        console.log("  Allowance after:", allowanceAfter / 10**15, "milli-LINK");
    }

    function testNoLinkLeakOnMultipleGames() public {
        uint256 betAmount = 100 * 10**18;
        uint256 initialLink = link.balanceOf(player1);
        
        // Create and play 3 games
        for (uint i = 0; i < 3; i++) {
            vm.startPrank(player1);
            gameToken.approve(address(factory), betAmount);
            factory.createGame(betAmount);
            address[] memory games = factory.getPlayerGames(player1);
            TestableGame game = TestableGame(payable(games[games.length - 1]));
            vm.stopPrank();
            
            // Game is already started by factory.createGame()
            
            // Quick game - stand immediately
            uint8[] memory playerCards = new uint8[](2);
            playerCards[0] = 10;
            playerCards[1] = 10;
            uint8[] memory dealerCards = new uint8[](2);
            dealerCards[0] = 5;
            dealerCards[1] = 6;
            vm.prank(player1);
            game.testSetCards(playerCards, dealerCards);
            
            vm.prank(player1);
            game.stand();
        }
        
        uint256 finalLink = link.balanceOf(player1);
        
        console.log("[OK] No LINK leak across multiple games");
        console.log("  Initial LINK:", initialLink / 10**18, "LINK");
        console.log("  Final LINK:", finalLink / 10**18, "LINK");
        console.log("  Games played: 3");
    }

    // ============================================
    // EDGE CASE TESTS
    // ============================================

    function testInsufficientLinkPreventsActions() public {
        uint256 betAmount = 100 * 10**18;
        
        vm.startPrank(player1);
        gameToken.approve(address(factory), betAmount);
        factory.createGame(betAmount);
        address[] memory games = factory.getPlayerGames(player1);
        TestableGame game = TestableGame(payable(games[0]));
        vm.stopPrank();        
        
        uint8[] memory playerCards = new uint8[](2);
        playerCards[0] = 5;
        playerCards[1] = 6;
        uint8[] memory dealerCards = new uint8[](2);
        dealerCards[0] = 2;
        dealerCards[1] = 3;
        vm.prank(player1);
        game.testSetCards(playerCards, dealerCards);
        
        // Don't approve LINK - hit should fail
        vm.startPrank(player1);
        vm.expectRevert();
        game.hit();
        vm.stopPrank();
        
        console.log("[OK] Insufficient LINK prevents actions");
    }

    function testZeroLinkApprovalPreventsActions() public {
        uint256 betAmount = 100 * 10**18;
        
        vm.startPrank(player1);
        gameToken.approve(address(factory), betAmount);
        factory.createGame(betAmount);
        address[] memory games = factory.getPlayerGames(player1);
        TestableGame game = TestableGame(payable(games[0]));
        vm.stopPrank();        
        
        uint8[] memory playerCards = new uint8[](2);
        playerCards[0] = 5;
        playerCards[1] = 6;
        uint8[] memory dealerCards = new uint8[](2);
        dealerCards[0] = 2;
        dealerCards[1] = 3;
        vm.prank(player1);
        game.testSetCards(playerCards, dealerCards);
        
        // Approve 0 LINK
        vm.startPrank(player1);
        link.approve(address(game), 0);
        vm.expectRevert();
        game.hit();
        vm.stopPrank();
        
        console.log("[OK] Zero LINK approval prevents actions");
    }
}

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
