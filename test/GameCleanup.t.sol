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
 * @title GameCleanup Test Suite
 * @notice Tests for expired game cleanup and token burning
 * @dev Tests cover:
 *      - Game expiration detection
 *      - cancelExpiredGame() functionality
 *      - Token burning on cleanup
 *      - Player refunds
 *      - Permissionless cleanup (anyone can call)
 *      - Edge cases and security
 */
contract GameCleanupTest is Test {
    GameToken public gameToken;
    TestableGameFactory public factory;
    MockLINK public link;
    address public owner;
    address public player;
    address public cleaner; // Random person who cleans up expired games
    address public vrfCoordinator;
    address public linkAddr;

    uint256 constant INITIAL_LIQUIDITY = 1_000_000 * 10**18; // 1M tokens
    uint256 constant BET_AMOUNT = 100 * 10**18; // 100 tokens
    uint256 constant GAME_TIMEOUT = 24 hours;
    uint256 constant LINK_FEE = 0.005 ether; // Matches VRFRequestLogic.LINK_FEE

    event GameExpired(uint256 timestamp, address indexed player);
    event GameFinished(string result, uint256 payout);
    event TokensBurned(address indexed from, uint256 amount);

    function setUp() public {
        owner = address(this);
        player = makeAddr("player");
        cleaner = makeAddr("cleaner");
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
        
        // Mint initial tokens for owner with POL backing
        uint256 ownerPOL = 1_000_000 ether; // 1M POL to mint 1B tokens
        vm.deal(address(this), ownerPOL);
        gameToken.buyTokens{value: ownerPOL}();

        // Deploy factory (testable version)
        factory = new TestableGameFactory();
        factory.initializeTest(
            vrfCoordinator,
            linkAddr,
            address(gameToken),
            LINK_FEE,
            1 * 10**18, // minBet
            1, // subscriptionId (mock)
            address(0x1234) // keeperAddress (mock)
        );
        
        // Transfer GameToken ownership to factory
        gameToken.transferOwnership(address(factory));

        // Set LINK balance for player
        bytes32 balancesSlot = bytes32(uint256(0));
        bytes32 balanceSlot = keccak256(abi.encode(player, balancesSlot));
        vm.store(linkAddr, balanceSlot, bytes32(uint256(100 ether)));
        
        // Set LINK allowance from player to factory
        bytes32 allowancesSlot = bytes32(uint256(1));
        bytes32 inner = keccak256(abi.encode(player, allowancesSlot));
        bytes32 outer = keccak256(abi.encode(address(factory), inner));
        vm.store(linkAddr, outer, bytes32(uint256(100 ether)));

        // Add liquidity - TestableGameFactory needs tokens in its balance
        uint256 polForTokens = INITIAL_LIQUIDITY / 1000;
        vm.deal(address(this), polForTokens * 2);
        gameToken.buyTokens{value: polForTokens}(); // Buy 1M tokens
        gameToken.transfer(address(factory), INITIAL_LIQUIDITY); // Transfer to factory
        // Add extra POL to reserve
        vm.deal(address(factory), polForTokens);
        vm.prank(address(factory));
        gameToken.topUpReserve{value: polForTokens}();

        // Give player some tokens (buy them to ensure proper backing)
        vm.deal(player, (10_000 * 10**18) / 1000 + 1 ether); // POL for tokens + extra
        vm.prank(player);
        gameToken.buyTokens{value: (10_000 * 10**18) / 1000}();
    }

    // Helper function to create a game
    function createGameForPlayer(address _player) internal returns (TestableGame) {
        vm.startPrank(_player);
        gameToken.approve(address(factory), BET_AMOUNT);
        factory.createGame(BET_AMOUNT);
        vm.stopPrank();
        
        address[] memory games = factory.getPlayerGames(_player);
        return TestableGame(payable(games[games.length - 1]));
    }

    // Helper to finish a game (for testing)
    function finishGame(TestableGame game) internal {
        uint8[] memory playerCards = new uint8[](2);
        playerCards[0] = 21; // 10 of Hearts
        playerCards[1] = 31; // Ace of Hearts
        
        uint8[] memory dealerCards = new uint8[](2);
        dealerCards[0] = 20; // 10 of Diamonds
        dealerCards[1] = 25; // 7 of Diamonds
        
        vm.prank(player);
        game.testSetCards(playerCards, dealerCards);
        
        vm.prank(player);
        game.stand();
    }

    // ============================================
    // EXPIRATION DETECTION TESTS
    // ============================================

    function testGameNotExpiredInitially() public {
        TestableGame game = createGameForPlayer(player);
        
        assertFalse(game.isExpired(), "Game should not be expired initially");
        assertEq(game.getTimeRemaining(), GAME_TIMEOUT, "Should have full time remaining");
    }

    function testGameExpiresAfterTimeout() public {
        TestableGame game = createGameForPlayer(player);
        
        // Warp time forward past timeout
        vm.warp(block.timestamp + GAME_TIMEOUT + 1);
        
        assertTrue(game.isExpired(), "Game should be expired");
        assertEq(game.getTimeRemaining(), 0, "Should have 0 time remaining");
    }

    function testGameNotExpiredIfFinished() public {
        TestableGame game = createGameForPlayer(player);
        
        // Finish the game
        finishGame(game);
        
        // Warp time forward
        vm.warp(block.timestamp + GAME_TIMEOUT + 1);
        
        assertFalse(game.isExpired(), "Finished game should not be expired");
    }

    function testGetTimeRemainingDecrements() public {
        TestableGame game = createGameForPlayer(player);
        
        uint256 timeRemaining1 = game.getTimeRemaining();
        
        // Warp 1 hour
        vm.warp(block.timestamp + 1 hours);
        
        uint256 timeRemaining2 = game.getTimeRemaining();
        
        assertEq(timeRemaining1 - timeRemaining2, 1 hours, "Time should decrement");
    }

    // ============================================
    // CANCEL EXPIRED GAME TESTS
    // ============================================

    function testCancelExpiredGamePlayerLosesBet() public {
        TestableGame game = createGameForPlayer(player);
        
        uint256 playerBalanceBefore = gameToken.balanceOf(player);
        
        // Warp time forward
        vm.warp(block.timestamp + GAME_TIMEOUT + 1);
        
        // Anyone can cleanup
        vm.prank(cleaner);
        game.cancelExpiredGame();
        
        uint256 playerBalanceAfter = gameToken.balanceOf(player);
        
        // Player does NOT get refund - they lose their bet as penalty for abandoning
        assertEq(playerBalanceAfter, playerBalanceBefore, "Player should NOT get refund - bet is lost");
    }

    function testCancelExpiredGameBurnsAllTokens() public {
        // Create game with extra tokens (simulating house bet)
        TestableGame game = createGameForPlayer(player);

        
        // Game has player bet + house bet (from factory)
        uint256 gameBalance = gameToken.balanceOf(address(game));
        uint256 totalSupplyBefore = gameToken.totalSupply();
        
        // Warp time forward
        vm.warp(block.timestamp + GAME_TIMEOUT + 1);
        
        // Cleanup
        vm.prank(cleaner);
        game.cancelExpiredGame();
        
        uint256 totalSupplyAfter = gameToken.totalSupply();
        
        // ALL tokens burned (including player's bet) - no refund
        assertEq(totalSupplyAfter, totalSupplyBefore - gameBalance, "ALL tokens should burn (including player bet)");
        assertEq(gameToken.balanceOf(address(game)), 0, "Game should have 0 tokens");
    }

    function testCancelExpiredGameEmitsEvents() public {
        // Create game
        TestableGame game = createGameForPlayer(player);

        
        // Warp time forward
        vm.warp(block.timestamp + GAME_TIMEOUT + 1);
        
        // Expect events
        vm.expectEmit(true, false, false, false);
        emit GameExpired(block.timestamp, player);
        
        vm.expectEmit(false, false, false, true);
        emit GameFinished("expired - bet lost", 0); // Payout is 0, bet is lost
        
        vm.prank(cleaner);
        game.cancelExpiredGame();
    }

    function testCancelExpiredGamePermissionless() public {
        // Create game
        TestableGame game = createGameForPlayer(player);

        
        // Warp time forward
        vm.warp(block.timestamp + GAME_TIMEOUT + 1);
        
        // Different addresses can all cleanup
        address randomPerson1 = makeAddr("random1");
        
        vm.prank(randomPerson1);
        game.cancelExpiredGame();
        
        // Success - anyone can call
    }

    function testCancelExpiredGameRevertsIfNotExpired() public {
        // Create game
        TestableGame game = createGameForPlayer(player);

        
        // Try to cleanup immediately
        vm.expectRevert("Game not expired yet");
        vm.prank(cleaner);
        game.cancelExpiredGame();
    }

    function testCancelExpiredGameRevertsIfAlreadyFinished() public {
        TestableGame game = createGameForPlayer(player);
        
        // Finish the game
        finishGame(game);
        
        // Warp time forward
        vm.warp(block.timestamp + GAME_TIMEOUT + 1);
        
        // Try to cleanup
        vm.expectRevert("Game already finished");
        vm.prank(cleaner);
        game.cancelExpiredGame();
    }

    function testCancelExpiredGameUpdatesState() public {
        // Create game
        TestableGame game = createGameForPlayer(player);

        
        // Warp time forward
        vm.warp(block.timestamp + GAME_TIMEOUT + 1);
        
        // Cleanup
        vm.prank(cleaner);
        game.cancelExpiredGame();
        
        assertEq(uint256(game.state()), uint256(GameUpgradeable.GameState.Finished), "State should be Finished");
    }

    // ============================================
    // EDGE CASES
    // ============================================

    function testCancelExpiredGameWithZeroBalance() public {
        // Create game
        TestableGame game = createGameForPlayer(player);

        
        // Somehow drain the game's balance (simulate bug)
        // In real scenario, this shouldn't happen, but testing edge case
        vm.prank(address(game));
        gameToken.transfer(address(0xdead), gameToken.balanceOf(address(game)));
        
        // Warp time forward
        vm.warp(block.timestamp + GAME_TIMEOUT + 1);
        
        // Cleanup should not revert even with 0 balance
        vm.prank(cleaner);
        game.cancelExpiredGame();
    }

    function testCancelExpiredGameExactlyAtTimeout() public {
        // Create game
        TestableGame game = createGameForPlayer(player);

        
        // Warp to exactly the timeout (not past)
        vm.warp(block.timestamp + GAME_TIMEOUT);
        
        // Should be able to cleanup at exactly timeout
        vm.prank(cleaner);
        game.cancelExpiredGame();
    }

    function testCancelExpiredGameOneSecondBeforeTimeout() public {
        // Create game
        TestableGame game = createGameForPlayer(player);

        
        // Warp to 1 second before timeout
        vm.warp(block.timestamp + GAME_TIMEOUT - 1);
        
        // Should NOT be able to cleanup yet
        vm.expectRevert("Game not expired yet");
        vm.prank(cleaner);
        game.cancelExpiredGame();
    }

    function testMultipleExpiredGamesCleanup() public {
        // Create multiple games (only 3 to avoid running out of player tokens)
        address[] memory games = new address[](3);
        
        for (uint256 i = 0; i < 3; i++) {
            games[i] = address(createGameForPlayer(player));
        }
        
        // Warp time forward
        vm.warp(block.timestamp + GAME_TIMEOUT + 1);
        
        uint256 totalSupplyBefore = gameToken.totalSupply();
        
        // Cleanup all games
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(cleaner);
            TestableGame(payable(games[i])).cancelExpiredGame();
        }
        
        uint256 totalSupplyAfter = gameToken.totalSupply();
        
        // Should have burned tokens from all games
        assertLt(totalSupplyAfter, totalSupplyBefore, "Total supply should decrease");
    }

    // ============================================
    // ECONOMIC IMPACT TESTS
    // ============================================

    function testCleanupDeflationary() public {
        uint256 initialSupply = gameToken.totalSupply();
        
        // Create and expire game
        TestableGame game = createGameForPlayer(player);

        
        // Warp time forward
        vm.warp(block.timestamp + GAME_TIMEOUT + 1);
        
        // Cleanup
        vm.prank(cleaner);
        game.cancelExpiredGame();
        
        uint256 finalSupply = gameToken.totalSupply();
        
        assertLt(finalSupply, initialSupply, "Supply should decrease (deflationary)");
    }

    function testCleanupBenefitsTokenHolders() public {
        // The economic principle: burning tokens increases scarcity
        // This test demonstrates the deflationary benefit
        
        uint256 initialSupply = gameToken.totalSupply();
        
        // Create multiple games first
        TestableGame[] memory games = new TestableGame[](10);
        for (uint256 i = 0; i < 10; i++) {
            games[i] = createGameForPlayer(player);
        }
        
        // Now warp time once to expire all games
        vm.warp(block.timestamp + GAME_TIMEOUT + 1);
        
        // Cancel all expired games
        for (uint256 i = 0; i < 10; i++) {
            vm.prank(cleaner);
            games[i].cancelExpiredGame();
        }
        
        uint256 finalSupply = gameToken.totalSupply();
        uint256 burnedAmount = initialSupply - finalSupply;
        
        assertGt(burnedAmount, 0, "Tokens should be burned");
        console.log("Burned tokens:", burnedAmount / 1e18);
        console.log("Supply reduction:", (burnedAmount * 100) / initialSupply, "%");
    }    // ============================================
    // REENTRANCY TESTS
    // ============================================

    function testCancelExpiredGameReentrancyProtection() public {
        // Note: With ERC20 GameToken, reentrancy via receive() is not possible
        // The nonReentrant modifier still protects against other reentrancy vectors
        TestableGame game = createGameForPlayer(player);
        
        // Warp time forward
        vm.warp(block.timestamp + GAME_TIMEOUT + 1);
        
        // Cleanup should work without issues
        vm.prank(cleaner);
        game.cancelExpiredGame();
        
        // Verify game finished
        assertEq(uint256(game.state()), uint256(GameUpgradeable.GameState.Finished));
    }

    // ============================================
    // GAS OPTIMIZATION TESTS
    // ============================================

    function testCancelExpiredGameGasCost() public {
        // Create game
        TestableGame game = createGameForPlayer(player);

        
        // Warp time forward
        vm.warp(block.timestamp + GAME_TIMEOUT + 1);
        
        // Measure gas
        uint256 gasBefore = gasleft();
        vm.prank(cleaner);
        game.cancelExpiredGame();
        uint256 gasUsed = gasBefore - gasleft();
        
        console.log("Gas used for cleanup:", gasUsed);
        assertLt(gasUsed, 200000, "Should use reasonable gas");
    }

    // ============================================
    // INTEGRATION TESTS
    // ============================================
    
    function testCleanupRestoresFactoryLiquidity() public {
        // Note: With new burn mechanism, liquidity is NOT restored
        // Instead, tokens are burned (deflationary)
        
        (, uint256 factoryLiquidityBefore, ,) = factory.getLiquidityStatus();
        
        // Create game
        TestableGame game = createGameForPlayer(player);
        
        (, uint256 factoryLiquidityDuring, ,) = factory.getLiquidityStatus();
        assertLt(factoryLiquidityDuring, factoryLiquidityBefore, "Liquidity should decrease during game");
        
        // Warp and cleanup
        vm.warp(block.timestamp + GAME_TIMEOUT + 1);
        vm.prank(cleaner);
        game.cancelExpiredGame();
        
        (, uint256 factoryLiquidityAfter, ,) = factory.getLiquidityStatus();
        
        // With burn mechanism, liquidity does NOT fully restore
        // (tokens are burned, not returned)
        assertLt(factoryLiquidityAfter, factoryLiquidityBefore, "Tokens burned, not returned");
    }
}
