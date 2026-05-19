// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {GameToken} from "../src/GameToken.sol";
import {GameFactoryUpgradeable} from "../src/GameFactoryUpgradeable.sol";
import {GameUpgradeable} from "../src/GameUpgradeable.sol";
import {TestableGameFactory} from "./TestableGameFactory.sol";
import {TestableGame} from "./TestableGame.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {VRFV2PlusClient} from "lib/foundry-chainlink-toolkit/lib/chainlink-brownie-contracts/contracts/src/v0.8/dev/vrf/libraries/VRFV2PlusClient.sol";

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
 * @title Emergency Withdrawal Test Suite
 * @notice Comprehensive tests for emergency withdrawal security
 * @dev Tests cover:
 *      1. Factory emergencyWithdraw() - owner only, no active games
 *      2. Factory emergencyRecoverFromGame() - owner only, specific game recovery
 *      3. Game emergencyWithdrawToFactory() - factory only, timeout checks
 *      4. Game cancelExpiredGame() - factory only, player loses bet
 *      5. Access control verification
 *      6. Economic security (no fund theft)
 */
contract EmergencyWithdrawalTest is Test {
    GameToken public gameToken;
    TestableGameFactory public factory;
    MockLINK public link;
    address public owner;
    address public player;
    address public attacker;
    address public vrfCoordinator;
    address public linkAddr;

    uint256 constant INITIAL_LIQUIDITY = 1_000_000 * 10**18;
    uint256 constant BET_AMOUNT = 100 * 10**18;
    uint256 constant GAME_TIMEOUT = 24 hours;
    uint256 constant PLAYER_PRIORITY_PERIOD = 1 hours;
    uint256 constant LINK_FEE = 0.005 ether;

    event EmergencyWithdrawal(address indexed by, uint256 amount);
    event GameExpired(uint256 timestamp, address indexed player);
    event ExpiredGameCancelled(address indexed gameAddress, address indexed player, uint256 refunded);

    function setUp() public {
        owner = address(this);
        player = makeAddr("player");
        attacker = makeAddr("attacker");
        vrfCoordinator = 0x343300b5d84D444B2ADc9116FEF1bED02BE49Cf2;
        linkAddr = 0x0Fd9e8d3aF1aaee056EB9e802c3A762a667b1904;

        // Deploy mock contracts
        link = new MockLINK();
        MockVRF mockVrf = new MockVRF();
        vm.etch(vrfCoordinator, address(mockVrf).code);
        vm.store(vrfCoordinator, bytes32(0), bytes32(uint256(1)));
        vm.etch(linkAddr, address(link).code);

        // Deploy GameToken
        gameToken = new GameToken();
        
        // Mint initial tokens with POL backing
        uint256 ownerPOL = 1_000_000 ether;
        vm.deal(address(this), ownerPOL);
        gameToken.buyTokens{value: ownerPOL}();

        // Deploy factory
        factory = new TestableGameFactory();
        factory.initializeTest(
            vrfCoordinator,
            linkAddr,
            address(gameToken),
            LINK_FEE,
            1 * 10**18,
            1, // subscriptionId (mock)
            address(0x1234) // keeperAddress (mock)
        );
        
        // Transfer GameToken ownership to factory
        gameToken.transferOwnership(address(factory));

        // Add liquidity - TestableGameFactory needs tokens in its balance
        uint256 polForTokens = INITIAL_LIQUIDITY / 1000;
        vm.deal(address(this), polForTokens * 2);
        gameToken.buyTokens{value: polForTokens}(); // Buy 1M tokens
        gameToken.transfer(address(factory), INITIAL_LIQUIDITY); // Transfer to factory
        // Add extra POL to reserve
        vm.deal(address(factory), polForTokens);
        vm.prank(address(factory));
        gameToken.topUpReserve{value: polForTokens}();

        // Setup player tokens and LINK
        // Give player some tokens (buy them to ensure proper backing)
        vm.deal(player, (10_000 * 10**18) / 1000 + 1 ether); // POL for tokens + extra
        vm.prank(player);
        gameToken.buyTokens{value: (10_000 * 10**18) / 1000}();
        
        bytes32 balancesSlot = bytes32(uint256(0));
        bytes32 balanceSlot = keccak256(abi.encode(player, balancesSlot));
        vm.store(linkAddr, balanceSlot, bytes32(uint256(100 ether)));
        
        // Set LINK allowance from player to factory
        bytes32 allowancesSlot = bytes32(uint256(1));
        bytes32 inner = keccak256(abi.encode(player, allowancesSlot));
        bytes32 outer = keccak256(abi.encode(address(factory), inner));
        vm.store(linkAddr, outer, bytes32(uint256(100 ether)));
    }

    // ============================================
    // FACTORY: emergencyWithdraw() TESTS
    // ============================================

    function testEmergencyWithdraw_OnlyOwner() public {
        // Attacker tries to call emergencyWithdraw
        vm.prank(attacker);
        vm.expectRevert();
        factory.emergencyWithdraw();

        // Owner can call it (if no active games)
        // Since we have no active games, this should work
        factory.emergencyWithdraw();
    }

    function testEmergencyWithdraw_FailsWithActiveGames() public {
        // Create a game
        vm.startPrank(player);
        gameToken.approve(address(factory), BET_AMOUNT);
        factory.createGame(BET_AMOUNT);  // gameAddr not used in this test
        vm.stopPrank();

        // Try to emergency withdraw while game is active
        vm.expectRevert("Games still active");
        factory.emergencyWithdraw();
    }

    function testEmergencyWithdraw_SucceedsAfterGameFinishes() public {
        // Create and immediately finish a game by canceling it
        vm.startPrank(player);
        gameToken.approve(address(factory), BET_AMOUNT);
        address gameAddr = factory.createGame(BET_AMOUNT);
        vm.stopPrank();
        
        // Warp past expiration
        vm.warp(block.timestamp + GAME_TIMEOUT + 1);
        
        // Cancel the expired game through factory (marks it inactive)
        factory.cancelExpiredGameByKeeper(payable(gameAddr));

        // Now no active games, emergency withdraw should work
        factory.emergencyWithdraw();
        
        // All tokens should be burned
        uint256 factoryBalanceAfter = gameToken.balanceOf(address(factory));
        assertEq(factoryBalanceAfter, 0, "Factory should have 0 tokens after emergency withdraw");
    }

    function testEmergencyWithdraw_BurnsAllTokens() public {
        // Give factory some tokens somehow (edge case)
        // totalSupplyBefore tracked for reference but not asserted in this test
        gameToken.totalSupply();
        
        // Emergency withdraw burns all factory tokens
        factory.emergencyWithdraw();
        
        uint256 factoryBalance = gameToken.balanceOf(address(factory));
        assertEq(factoryBalance, 0, "Factory should have no tokens after emergency withdraw");
    }

    // ============================================
    // FACTORY: emergencyRecoverFromGame() TESTS
    // ============================================

    function testEmergencyRecoverFromGame_OnlyOwner() public {
        // Create a game
        vm.startPrank(player);
        gameToken.approve(address(factory), BET_AMOUNT);
        address gameAddr = factory.createGame(BET_AMOUNT);
        vm.stopPrank();

        // Attacker tries to recover from game
        vm.prank(attacker);
        vm.expectRevert();
        factory.emergencyRecoverFromGame(payable(gameAddr));
    }

    function testEmergencyRecoverFromGame_RequiresActiveGame() public {
        address fakeGame = makeAddr("fakeGame");
        
        // Try to recover from non-existent game
        vm.expectRevert("Not an active game");
        factory.emergencyRecoverFromGame(payable(fakeGame));
    }

    function testEmergencyRecoverFromGame_RecoversStuckTokens() public {
        // Create a game
        vm.startPrank(player);
        gameToken.approve(address(factory), BET_AMOUNT);
        address gameAddr = factory.createGame(BET_AMOUNT);
        vm.stopPrank();

        // Fast forward past timeout + priority period
        vm.warp(block.timestamp + GAME_TIMEOUT + PLAYER_PRIORITY_PERIOD + 1);

        uint256 lockedLiquidityBefore = factory.lockedLiquidity();
        
        // Owner recovers from stuck game
        factory.emergencyRecoverFromGame(payable(gameAddr));
        
        // Verify liquidity was unlocked
        uint256 lockedLiquidityAfter = factory.lockedLiquidity();
        assertLt(lockedLiquidityAfter, lockedLiquidityBefore, "Locked liquidity should decrease");
        
        // Game should be marked inactive
        assertFalse(factory.isGameActive(gameAddr), "Game should be inactive");
    }

    // ============================================
    // GAME: emergencyWithdrawToFactory() TESTS
    // ============================================

    function testGameEmergencyWithdraw_OnlyFactory() public {
        // Create a game
        vm.startPrank(player);
        gameToken.approve(address(factory), BET_AMOUNT);
        address gameAddr = factory.createGame(BET_AMOUNT);
        vm.stopPrank();

        TestableGame game = TestableGame(payable(gameAddr));

        // Player tries to call emergency withdraw
        vm.prank(player);
        vm.expectRevert();
        game.emergencyWithdrawToFactory();

        // Attacker tries to call emergency withdraw
        vm.prank(attacker);
        vm.expectRevert();
        game.emergencyWithdrawToFactory();

        // Only factory can call it (but need to wait for timeout + priority)
        vm.warp(block.timestamp + GAME_TIMEOUT + PLAYER_PRIORITY_PERIOD + 1);
        
        vm.prank(address(factory));
        game.emergencyWithdrawToFactory();
    }

    function testGameEmergencyWithdraw_RespectsPlayerPriority() public {
        // Create a game
        vm.startPrank(player);
        gameToken.approve(address(factory), BET_AMOUNT);
        address gameAddr = factory.createGame(BET_AMOUNT);
        vm.stopPrank();

        TestableGame game = TestableGame(payable(gameAddr));

        // Warp to just after GAME_TIMEOUT (within priority period)
        vm.warp(block.timestamp + GAME_TIMEOUT + 30 minutes);

        // Factory tries to emergency withdraw during player priority
        vm.prank(address(factory));
        vm.expectRevert("Cannot emergency withdraw - players have priority");
        game.emergencyWithdrawToFactory();

        // After priority period, it should work
        vm.warp(block.timestamp + PLAYER_PRIORITY_PERIOD);
        
        vm.prank(address(factory));
        game.emergencyWithdrawToFactory();
    }

    function testGameEmergencyWithdraw_TransfersTokensToFactory() public {
        // Create a game
        vm.startPrank(player);
        gameToken.approve(address(factory), BET_AMOUNT);
        address gameAddr = factory.createGame(BET_AMOUNT);
        vm.stopPrank();

        TestableGame game = TestableGame(payable(gameAddr));

        // Warp past timeout + priority
        vm.warp(block.timestamp + GAME_TIMEOUT + PLAYER_PRIORITY_PERIOD + 1);

        vm.prank(address(factory));
        game.emergencyWithdrawToFactory();

        uint256 gameBalanceAfter = gameToken.balanceOf(gameAddr);
        
        // Game should have transferred tokens to factory
        assertEq(gameBalanceAfter, 0, "Game should have 0 tokens after emergency withdraw");
    }

    // ============================================
    // GAME: cancelExpiredGame() TESTS
    // ============================================

    function testCancelExpiredGame_OnlyFactory() public {
        // Create a game
        vm.startPrank(player);
        gameToken.approve(address(factory), BET_AMOUNT);
        address gameAddr = factory.createGame(BET_AMOUNT);
        vm.stopPrank();

        TestableGame game = TestableGame(payable(gameAddr));

        // Warp past expiration
        vm.warp(block.timestamp + GAME_TIMEOUT + 1);

        // Player tries to cancel
        vm.prank(player);
        vm.expectRevert();
        game.cancelExpiredGame();

        // Attacker tries to cancel
        vm.prank(attacker);
        vm.expectRevert();
        game.cancelExpiredGame();

        // Only factory can cancel
        vm.prank(address(factory));
        game.cancelExpiredGame();
    }

    function testCancelExpiredGame_RequiresTimeout() public {
        // Create a game
        vm.startPrank(player);
        gameToken.approve(address(factory), BET_AMOUNT);
        address gameAddr = factory.createGame(BET_AMOUNT);
        vm.stopPrank();

        TestableGame game = TestableGame(payable(gameAddr));

        // Try to cancel before timeout
        vm.prank(address(factory));
        vm.expectRevert("Game not expired yet");
        game.cancelExpiredGame();
    }

    function testCancelExpiredGame_BurnsAllTokens() public {
        // Create a game
        vm.startPrank(player);
        gameToken.approve(address(factory), BET_AMOUNT);
        address gameAddr = factory.createGame(BET_AMOUNT);
        vm.stopPrank();

        TestableGame game = TestableGame(payable(gameAddr));
        
        uint256 gameBalanceBefore = gameToken.balanceOf(gameAddr);
        assertGt(gameBalanceBefore, 0, "Game should have tokens");

        // Warp past expiration
        vm.warp(block.timestamp + GAME_TIMEOUT + 1);

        vm.prank(address(factory));
        game.cancelExpiredGame();

        uint256 gameBalanceAfter = gameToken.balanceOf(gameAddr);
        assertEq(gameBalanceAfter, 0, "All tokens should be burned");
    }

    function testCancelExpiredGame_PlayerLosesBet() public {
        uint256 playerBalanceBefore = gameToken.balanceOf(player);

        // Create a game
        vm.startPrank(player);
        gameToken.approve(address(factory), BET_AMOUNT);
        address gameAddr = factory.createGame(BET_AMOUNT);
        vm.stopPrank();

        uint256 playerBalanceAfterBet = gameToken.balanceOf(player);
        assertEq(playerBalanceBefore - playerBalanceAfterBet, BET_AMOUNT, "Player should have paid bet");

        // Warp past expiration
        vm.warp(block.timestamp + GAME_TIMEOUT + 1);

        TestableGame game = TestableGame(payable(gameAddr));
        vm.prank(address(factory));
        game.cancelExpiredGame();

        uint256 playerBalanceFinal = gameToken.balanceOf(player);
        
        // Player should NOT get refund (penalty for abandoning game)
        assertEq(playerBalanceFinal, playerBalanceAfterBet, "Player should not get refund");
    }

    // ============================================
    // KEEPER: cancelExpiredGameByKeeper() TESTS
    // ============================================

    function testKeeperCancel_OnlyKeeperOrOwner() public {
        // Set keeper address
        address keeper = makeAddr("keeper");
        factory.setKeeperAddress(keeper);

        // Create and expire a game
        vm.startPrank(player);
        gameToken.approve(address(factory), BET_AMOUNT);
        address gameAddr = factory.createGame(BET_AMOUNT);
        vm.stopPrank();

        vm.warp(block.timestamp + GAME_TIMEOUT + 1);

        // Attacker tries to cancel
        vm.prank(attacker);
        vm.expectRevert("Only keeper or owner");
        factory.cancelExpiredGameByKeeper(payable(gameAddr));

        // Keeper can cancel
        vm.prank(keeper);
        factory.cancelExpiredGameByKeeper(payable(gameAddr));
    }

    function testKeeperCancel_UnlocksLiquidity() public {
        address keeper = makeAddr("keeper");
        factory.setKeeperAddress(keeper);

        // Create game
        vm.startPrank(player);
        gameToken.approve(address(factory), BET_AMOUNT);
        address gameAddr = factory.createGame(BET_AMOUNT);
        vm.stopPrank();

        uint256 lockedBefore = factory.lockedLiquidity();
        assertGt(lockedBefore, 0, "Should have locked liquidity");

        vm.warp(block.timestamp + GAME_TIMEOUT + 1);

        vm.prank(keeper);
        factory.cancelExpiredGameByKeeper(payable(gameAddr));

        uint256 lockedAfter = factory.lockedLiquidity();
        assertEq(lockedAfter, 0, "Liquidity should be unlocked");
    }

    // ============================================
    // ECONOMIC SECURITY TESTS
    // ============================================

    function testNoFundTheft_AttackerCannotStealViaEmergency() public {
        // Create multiple games with different players
        address player2 = makeAddr("player2");
        gameToken.transfer(player2, 10000 * 10**18);
        
        // Give player2 LINK tokens for game creation
        bytes32 balancesSlot = bytes32(uint256(0));
        bytes32 balanceSlot = keccak256(abi.encode(player2, balancesSlot));
        vm.store(linkAddr, balanceSlot, bytes32(uint256(100 ether)));
        
        // Set LINK allowance from player2 to factory
        bytes32 allowancesSlot = bytes32(uint256(1));
        bytes32 inner = keccak256(abi.encode(player2, allowancesSlot));
        bytes32 outer = keccak256(abi.encode(address(factory), inner));
        vm.store(linkAddr, outer, bytes32(uint256(100 ether)));

        vm.startPrank(player);
        gameToken.approve(address(factory), BET_AMOUNT);
        address game1 = factory.createGame(BET_AMOUNT);
        vm.stopPrank();

        vm.startPrank(player2);
        gameToken.approve(address(factory), BET_AMOUNT);
        factory.createGame(BET_AMOUNT);
        vm.stopPrank();

        uint256 attackerBalanceBefore = gameToken.balanceOf(attacker);

        // Attacker tries every emergency function
        vm.startPrank(attacker);
        
        // Try factory emergency withdraw
        vm.expectRevert();
        factory.emergencyWithdraw();

        // Try factory emergency recover
        vm.expectRevert();
        factory.emergencyRecoverFromGame(payable(game1));

        // Try game emergency withdraw
        vm.expectRevert();
        TestableGame(payable(game1)).emergencyWithdrawToFactory();

        // Try cancel expired game
        vm.expectRevert();
        TestableGame(payable(game1)).cancelExpiredGame();

        vm.stopPrank();

        uint256 attackerBalanceAfter = gameToken.balanceOf(attacker);
        
        // Attacker should have gained nothing
        assertEq(attackerBalanceAfter, attackerBalanceBefore, "Attacker should not gain any tokens");
    }

    function testPlayerCannotBypassSurrenderWithEmergency() public {
        // Create game and deal cards so player can surrender
        vm.startPrank(player);
        gameToken.approve(address(factory), BET_AMOUNT);
        address gameAddr = factory.createGame(BET_AMOUNT);
        
        TestableGame game = TestableGame(payable(gameAddr));
        
        // Deal initial cards so game is in PlayerTurn state (or InsuranceOffer)
        // Use simple random word that doesn't give dealer an Ace
        uint256[] memory randomWords = new uint256[](1);
        randomWords[0] = 0x00050A14; // Simple cards, no dealer Ace
        game.testFulfill(1, randomWords);
        
        uint256 playerBalanceAfterBet = gameToken.balanceOf(player);
        
        // Player tries to emergency withdraw their own game instead of surrendering
        vm.expectRevert();
        game.emergencyWithdrawToFactory();
        
        vm.expectRevert();
        game.cancelExpiredGame();
        
        // If player wants out, they must use surrender (50% penalty)
        game.surrender();
        
        uint256 playerBalanceFinal = gameToken.balanceOf(player);
        uint256 refund = BET_AMOUNT / 2;
        
        vm.stopPrank();
        
        assertEq(playerBalanceFinal, playerBalanceAfterBet + refund, "Player should only get surrender refund");
    }
}
