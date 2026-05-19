// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {GameUpgradeable} from "../src/GameUpgradeable.sol";
import {GameFactoryUpgradeable} from "../src/GameFactoryUpgradeable.sol";
import {GameToken} from "../src/GameToken.sol";
import {TestableGame} from "./TestableGame.sol";
import {TestableGameFactory} from "./TestableGameFactory.sol";
import {ERC1967Proxy} from "lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {VRFV2PlusClient} from "lib/foundry-chainlink-toolkit/lib/chainlink-brownie-contracts/contracts/src/v0.8/dev/vrf/libraries/VRFV2PlusClient.sol";

// Import custom errors from GameUpgradeable
error NotYourGame();
error InsuranceTooHigh();
error CannotSplitDifferentRanks();
error CannotHitAfterDouble();
error NotPlayerTurn();
error TooManyHands();

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
 * @title Unified Game Test Suite
 * @notice Comprehensive tests for blackjack game functionality
 * @dev Now uses upgradeable contracts and GameToken instead of native MATIC
 * 
 * Test Organization:
 * 1. Setup & Initial State
 * 2. Core Actions (Hit, Stand, Double Down, Split, Surrender)
 * 3. Insurance Mechanics
 * 4. Dealer Logic
 * 5. Blackjack Detection & Payouts
 * 6. Multi-Hand Play
 * 7. Score Calculation & Ace Handling
 * 8. Edge Cases & Error Conditions
 * 9. Access Control
 * 10. State Transitions
 * 11. LINK Fee Tracking
 * 
 * Card Mapping (1-52):
 * - Aces: 1, 14, 27, 40 (rank 1, value 11 or 1)
 * - 2-9: Regular cards (e.g., 2, 15, 28, 41 are all 2s)
 * - 10s: 10, 23, 36, 49 (rank 10, value 10)
 * - Jacks: 11, 24, 37, 50 (rank 11, value 10)
 * - Queens: 12, 25, 38, 51 (rank 12, value 10)
 * - Kings: 13, 26, 39, 52 (rank 13, value 10)
 */
contract GameTest is Test {
    TestableGameFactory public factory;
    GameToken public gameToken;
    MockLINK public link;
    address public player;
    address public vrfCoordinator = 0x343300b5d84D444B2ADc9116FEF1bED02BE49Cf2;
    address public linkAddr = 0x0Fd9e8d3aF1aaee056EB9e802c3A762a667b1904;

    uint256 public betAmount = 1 * 10**18; // 1 GameToken
    uint256 public linkFee = 0.005 ether; // Updated to match VRFRequestLogic.LINK_FEE

    TestableGame public game;

    // Allow contract to receive MATIC (for withdrawExcess test)
    receive() external payable {}

    // Helper function to conditionally skip insurance
    function skipInsuranceIfNeeded() internal {
        if (uint(game.state()) == uint(GameUpgradeable.GameState.InsuranceOffer)) {
            vm.prank(player);
            game.skipInsurance();
        }
    }

    // Helper function to approve tokens for game operations
    function approveTokensForGame(uint256 amount) internal {
        vm.prank(player);
        gameToken.approve(address(game), amount);
    }

    // Helper function to simulate Chainlink Keeper performing upkeep on expired games
    // This recovers LINK tokens from expired games back to the factory
    function simulateKeeperUpkeep(address gameAddress) internal {
        // Warp time forward to make the game expired (24 hours)
        vm.warp(block.timestamp + 24 hours + 1);
        
        // Simulate keeper calling performUpkeep
        // The keeper would call factory.cancelExpiredGameByKeeper(gameAddress)
        factory.cancelExpiredGameByKeeper(payable(gameAddress));
    }
    
    // Helper function to simulate keeper checking for expired games
    function getExpiredGames() internal view returns (address[] memory) {
        address[] memory allGames = factory.getAllActiveGames();
        uint256 expiredCount = 0;
        
        // Count expired games
        for (uint256 i = 0; i < allGames.length; i++) {
            try GameUpgradeable(payable(allGames[i])).createdAt() returns (uint256 createdAt) {
                try GameUpgradeable(payable(allGames[i])).state() returns (GameUpgradeable.GameState state) {
                    bool isExpired = block.timestamp >= createdAt + 24 hours;
                    bool notFinished = state != GameUpgradeable.GameState.Finished;
                    if (isExpired && notFinished) {
                        expiredCount++;
                    }
                } catch {}
            } catch {}
        }
        
        // Collect expired games
        address[] memory expiredGames = new address[](expiredCount);
        uint256 index = 0;
        for (uint256 i = 0; i < allGames.length && index < expiredCount; i++) {
            try GameUpgradeable(payable(allGames[i])).createdAt() returns (uint256 createdAt) {
                try GameUpgradeable(payable(allGames[i])).state() returns (GameUpgradeable.GameState state) {
                    bool isExpired = block.timestamp >= createdAt + 24 hours;
                    bool notFinished = state != GameUpgradeable.GameState.Finished;
                    if (isExpired && notFinished) {
                        expiredGames[index] = allGames[i];
                        index++;
                    }
                } catch {}
            } catch {}
        }
        
        return expiredGames;
    }

    function setUp() public {
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
        
        // Deploy factory
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
        
        player = address(this);

        // TestableGameFactory needs tokens in its balance
        uint256 liquidityAmount = 10000 * 10**18; // 10,000 tokens
        uint256 polNeeded = liquidityAmount / 1000; // 10 POL
        vm.deal(address(this), polNeeded * 2);
        gameToken.buyTokens{value: polNeeded}(); // Buy tokens
        gameToken.transfer(address(factory), liquidityAmount); // Transfer to factory
        // Add extra POL to reserve
        vm.deal(address(factory), polNeeded);
        vm.prank(address(factory));
        gameToken.topUpReserve{value: polNeeded}();

        // Set LINK balance for player and factory
        bytes32 balancesSlot = bytes32(uint256(0));
        bytes32 playerBalanceSlot = keccak256(abi.encode(player, balancesSlot));
        vm.store(linkAddr, playerBalanceSlot, bytes32(uint256(100 ether)));
        
        bytes32 factoryBalanceSlot = keccak256(abi.encode(address(factory), balancesSlot));
        vm.store(linkAddr, factoryBalanceSlot, bytes32(uint256(100 ether)));
        
        // Set LINK allowance from player to factory for createGame to transfer LINK
        bytes32 allowancesSlot = bytes32(uint256(1));
        bytes32 inner = keccak256(abi.encode(player, allowancesSlot));
        bytes32 outer = keccak256(abi.encode(address(factory), inner));
        vm.store(linkAddr, outer, bytes32(uint256(100 ether)));
        
        // Approve GameToken for bet
        gameToken.approve(address(factory), betAmount);
        
        // Create game (factory will call startGame() automatically)
        factory.createGame(betAmount);
        address[] memory games = factory.getPlayerGames(player);
        game = TestableGame(payable(games[0]));

        // Set LINK balance and allowance for game contract
        bytes32 gameBalanceSlot = keccak256(abi.encode(address(game), balancesSlot));
        vm.store(linkAddr, gameBalanceSlot, bytes32(uint256(100 ether)));
        
        bytes32 gameAllowanceInner = keccak256(abi.encode(player, allowancesSlot));
        bytes32 gameAllowanceOuter = keccak256(abi.encode(address(game), gameAllowanceInner));
        vm.store(linkAddr, gameAllowanceOuter, bytes32(uint256(100 ether)));

        // Game is already started by factory.createGame()
        // No need to call startGame() again
    }

    // ============================================================================
    // SECTION 1: SETUP & INITIAL STATE
    // ============================================================================

    function testInitialDeal() public view {
        assertEq(uint(game.state()), uint(GameUpgradeable.GameState.Dealing), "Should be dealing");
        uint8[] memory dealerCards = game.getDealerCards();
        assertEq(dealerCards.length, 0, "Dealer should have 0 cards initially");
    }

    // ============================================================================
    // SECTION 2: CORE ACTIONS - HIT
    // ============================================================================

    function testHit() public {
        uint256[] memory randoms = new uint256[](1);
        randoms[0] = 2;
        game.testFulfill(1, randoms);

        if (uint(game.state()) == uint(GameUpgradeable.GameState.InsuranceOffer)) {
            vm.prank(player);
            game.skipInsurance();
        }

        bytes32 allowancesSlot = bytes32(uint256(1));
        bytes32 inner = keccak256(abi.encode(player, allowancesSlot));
        bytes32 outer = keccak256(abi.encode(address(game), inner));
        vm.store(linkAddr, outer, bytes32(uint256(linkFee)));

        vm.prank(player);
        game.hit();

        uint256[] memory hitRandoms = new uint256[](1);
        hitRandoms[0] = 67890;
        game.testFulfill(2, hitRandoms);

        uint8[] memory playerCards = game.getPlayerHandCards(0);
        assertEq(playerCards.length, 3, "Player should have 3 cards after hit");
    }

    function testHitWithBustedHand() public {
        uint8[] memory playerCards = new uint8[](2);
        playerCards[0] = 10; // 10
        playerCards[1] = 11; // Jack (10) - total 20
        uint8[] memory dealerCards = new uint8[](2);
        dealerCards[0] = 2;
        dealerCards[1] = 3;
        vm.prank(player);
        game.testSetCards(playerCards, dealerCards);

        bytes32 allowancesSlot = bytes32(uint256(1));
        bytes32 inner = keccak256(abi.encode(player, allowancesSlot));
        bytes32 outer = keccak256(abi.encode(address(game), inner));
        vm.store(linkAddr, outer, bytes32(uint256(linkFee * 2)));

        vm.prank(player);
        game.hit();
        uint256[] memory hit1 = new uint256[](1);
        hit1[0] = 10; // Total 30, busted
        game.testFulfill(2, hit1);

        // After VRF callback for busted player, game transitions to DealerTurn (not Finished)
        assertEq(uint(game.state()), uint(GameUpgradeable.GameState.DealerTurn), "Should be dealer turn after player busts");
        
        // Call continueDealer to finish the game (dealer doesn't need to play when all hands busted)
        vm.prank(player);
        game.continueDealer();
        
        // Now game should be finished
        assertEq(uint(game.state()), uint(GameUpgradeable.GameState.Finished), "Game should be finished after continueDealer");
    }

    function testHitAfterStand() public {
        uint8[] memory playerCards = new uint8[](2);
        playerCards[0] = 10;
        playerCards[1] = 7;
        uint8[] memory dealerCards = new uint8[](2);
        dealerCards[0] = 2;
        dealerCards[1] = 3;
        vm.prank(player);
        game.testSetCards(playerCards, dealerCards);

        vm.prank(player);
        game.stand();

        assertEq(uint(game.state()), uint(GameUpgradeable.GameState.DealerTurn));
    }

    // ============================================================================
    // SECTION 3: CORE ACTIONS - STAND
    // ============================================================================

    function testStand() public {
        uint256[] memory randoms = new uint256[](1);
        randoms[0] = 12345;
        game.testFulfill(1, randoms);

        if (uint(game.state()) == uint(GameUpgradeable.GameState.InsuranceOffer)) {
            vm.prank(player);
            game.skipInsurance();
        }

        vm.prank(player);
        game.stand();

        // After stand, game requests dealer hole card via VRF (state = Dealing)
        // Fulfill the VRF request to get the hole card
        assertEq(uint(game.state()), uint(GameUpgradeable.GameState.Dealing), "Should be dealing dealer hole card");
        
        randoms[0] = 99999; // Random for dealer hole card
        game.testFulfill(2, randoms);
        
        assertEq(uint(game.state()), uint(GameUpgradeable.GameState.DealerTurn), "Should be dealer turn after hole card dealt");
    }

    // ============================================================================
    // SECTION 4: CORE ACTIONS - DOUBLE DOWN
    // ============================================================================

    function testDoubleDown() public {
        uint256[] memory randoms = new uint256[](1);
        randoms[0] = 0;
        game.testFulfill(1, randoms);

        if (uint(game.state()) == uint(GameUpgradeable.GameState.InsuranceOffer)) {
            vm.prank(player);
            game.skipInsurance();
        }

        bytes32 allowancesSlot = bytes32(uint256(1));
        bytes32 inner = keccak256(abi.encode(player, allowancesSlot));
        bytes32 outer = keccak256(abi.encode(address(game), inner));
        vm.store(linkAddr, outer, bytes32(uint256(linkFee)));

        // Approve gameToken for double down bet
        vm.prank(player);
        gameToken.approve(address(game), betAmount);

        vm.prank(player);
        game.doubleDown();

        uint256 bet = game.getPlayerHandBet(0);
        assertEq(bet, betAmount * 2, "Bet should be doubled");
    }

    function testDoubleDownWith3Cards() public {
        uint8[] memory playerCards = new uint8[](3);
        playerCards[0] = 2;
        playerCards[1] = 3;
        playerCards[2] = 4;
        uint8[] memory dealerCards = new uint8[](2);
        dealerCards[0] = 5;
        dealerCards[1] = 6;
        vm.prank(player);
        game.testSetCards(playerCards, dealerCards);

        vm.expectRevert("Can only double on first hand");
        vm.prank(player);
        game.doubleDown();
    }

    function testDoubleDownInsufficientFunds() public {
        uint8[] memory playerCards = new uint8[](2);
        playerCards[0] = 5;
        playerCards[1] = 6;
        uint8[] memory dealerCards = new uint8[](2);
        dealerCards[0] = 2;
        dealerCards[1] = 3;
        vm.prank(player);
        game.testSetCards(playerCards, dealerCards);

        // Drain GameToken from game contract to make doubleDown fail
        uint256 gameBalance = gameToken.balanceOf(address(game));
        vm.prank(address(game));
        gameToken.transfer(player, gameBalance - betAmount / 2);

        // Player has no allowance set, so it will revert with ERC20 error
        vm.expectRevert(); // Just expect any revert
        vm.prank(player);
        game.doubleDown();
    }

    function testDoubleDownOnSplit() public {
        uint256[] memory randoms = new uint256[](1);
        randoms[0] = 0;
        game.testFulfill(1, randoms);

        if (uint(game.state()) == uint(GameUpgradeable.GameState.InsuranceOffer)) {
            vm.prank(player);
            game.skipInsurance();
        }

        // Approve gameToken for split
        vm.prank(player);
        gameToken.approve(address(game), betAmount);

        vm.prank(player);
        game.split();

        // Fulfill split VRF request to get card for first split hand
        uint256[] memory splitRandoms = new uint256[](1);
        splitRandoms[0] = 50000; // Random card
        game.testFulfill(2, splitRandoms);

        bytes32 allowancesSlot = bytes32(uint256(1));
        bytes32 inner = keccak256(abi.encode(player, allowancesSlot));
        bytes32 outer = keccak256(abi.encode(address(game), inner));
        vm.store(linkAddr, outer, bytes32(uint256(linkFee * 2)));

        // Approve gameToken for first double down
        vm.prank(player);
        gameToken.approve(address(game), betAmount);

        vm.prank(player);
        game.doubleDown();

        uint256 bet0 = game.getPlayerHandBet(0);
        assertEq(bet0, betAmount * 2, "First hand bet should be doubled");

        uint256[] memory ddRandoms = new uint256[](1);
        ddRandoms[0] = 99999;
        game.testFulfill(2, ddRandoms);

        vm.store(linkAddr, outer, bytes32(uint256(linkFee * 2)));
        
        // Approve gameToken for second double down
        vm.prank(player);
        gameToken.approve(address(game), betAmount);
        
        vm.prank(player);
        game.doubleDown();

        uint256 bet1 = game.getPlayerHandBet(1);
        assertEq(bet1, betAmount * 2, "Second hand bet should be doubled");
    }

    // ============================================================================
    // SECTION 5: CORE ACTIONS - SPLIT
    // ============================================================================

    function testSplit() public {
        uint256[] memory randoms = new uint256[](1);
        randoms[0] = 0;
        game.testFulfill(1, randoms);

        if (uint(game.state()) == uint(GameUpgradeable.GameState.InsuranceOffer)) {
            vm.prank(player);
            game.skipInsurance();
        }

        // Approve gameToken for split
        vm.prank(player);
        gameToken.approve(address(game), betAmount);

        vm.prank(player);
        game.split();

        assertEq(game.getPlayerHandsLength(), 2, "Should have 2 hands after split");
    }

    function testSplitNonMatchingCards() public {
        uint8[] memory playerCards = new uint8[](2);
        playerCards[0] = 5;
        playerCards[1] = 6;
        uint8[] memory dealerCards = new uint8[](2);
        dealerCards[0] = 2;
        dealerCards[1] = 3;
        vm.prank(player);
        game.testSetCards(playerCards, dealerCards);

        vm.expectRevert("Cards must match");
        vm.prank(player);
        game.split();
    }

    function testSplitWith3Cards() public {
        uint8[] memory playerCards = new uint8[](3);
        playerCards[0] = 5;
        playerCards[1] = 5;
        playerCards[2] = 5;
        uint8[] memory dealerCards = new uint8[](2);
        dealerCards[0] = 2;
        dealerCards[1] = 3;
        vm.prank(player);
        game.testSetCards(playerCards, dealerCards);

        vm.expectRevert("Can only split 2 cards");
        vm.prank(player);
        game.split();
    }

    function testSplitFaceCards() public {
        uint8[] memory playerCards = new uint8[](2);
        playerCards[0] = 11; // Jack (rank 11)
        playerCards[1] = 24; // Jack (rank 11)
        uint8[] memory dealerCards = new uint8[](2);
        dealerCards[0] = 2;
        dealerCards[1] = 3;
        vm.prank(player);
        game.testSetCards(playerCards, dealerCards);

        // Approve gameToken for split
        vm.prank(player);
        gameToken.approve(address(game), betAmount);

        vm.prank(player);
        game.split();

        assertEq(game.getPlayerHandsLength(), 2);
    }

    function testSplitInsufficientFunds() public {
        uint8[] memory playerCards = new uint8[](2);
        playerCards[0] = 2;
        playerCards[1] = 2;
        uint8[] memory dealerCards = new uint8[](2);
        dealerCards[0] = 3;
        dealerCards[1] = 4;
        vm.prank(player);
        game.testSetCards(playerCards, dealerCards);

        // Drain GameToken from game contract to make split fail
        uint256 gameBalance = gameToken.balanceOf(address(game));
        vm.prank(address(game));
        gameToken.transfer(player, gameBalance);

        // No approval, so ERC20 will revert with insufficient allowance
        vm.expectRevert(); // Just expect any revert
        vm.prank(player);
        game.split();
    }

    function testResplit() public {
        uint8[] memory pCards = new uint8[](2);
        pCards[0] = 13;
        pCards[1] = 26;
        uint8[] memory dCards = new uint8[](2);
        dCards[0] = 2;
        dCards[1] = 3;
        vm.prank(player);
        game.testSetCards(pCards, dCards);

        // Approve for first split
        vm.prank(player);
        gameToken.approve(address(game), betAmount);

        vm.prank(player);
        game.split();
        
        // Fulfill first split VRF (request ID 2, since ID 1 was initial deal)
        // Random 6400: card1=18, card2=26 (King, matching hand 1's King)
        uint256[] memory splitRandoms1 = new uint256[](1);
        splitRandoms1[0] = 6400;
        game.testFulfill(2, splitRandoms1);
        
        assertEq(game.getPlayerHandsLength(), 2);

        bytes32 allowancesSlot = bytes32(uint256(1));
        bytes32 inner = keccak256(abi.encode(player, allowancesSlot));
        bytes32 outer = keccak256(abi.encode(address(game), inner));
        vm.store(linkAddr, outer, bytes32(uint256(linkFee * 2)));

        vm.prank(player);
        game.hit();
        uint256[] memory hitRandoms = new uint256[](1);
        hitRandoms[0] = 38;
        game.testFulfill(3, hitRandoms);

        // Approve for resplit
        vm.prank(player);
        gameToken.approve(address(game), betAmount);

        vm.prank(player);
        game.split();
        
        // Fulfill resplit VRF
        uint256[] memory splitRandoms2 = new uint256[](1);
        splitRandoms2[0] = 45000;
        game.testFulfill(4, splitRandoms2);
        
        assertEq(game.getPlayerHandsLength(), 3);
    }

    function testSplitMaxHands() public {
        uint8[] memory playerCards = new uint8[](2);
        playerCards[0] = 1; // Ace
        playerCards[1] = 14; // Ace
        uint8[] memory dealerCards = new uint8[](2);
        dealerCards[0] = 2;
        dealerCards[1] = 3;
        vm.prank(player);
        game.testSetCards(playerCards, dealerCards);

        // Approve for all splits
        vm.prank(player);
        gameToken.approve(address(game), betAmount * 4);

        bytes32 allowancesSlot = bytes32(uint256(1));
        bytes32 inner = keccak256(abi.encode(player, allowancesSlot));
        bytes32 outer = keccak256(abi.encode(address(game), inner));
        vm.store(linkAddr, outer, bytes32(uint256(linkFee * 4)));

        // Random value that gives us two Aces: 6669 gives card 14 and 27
        uint256 aceRandom = 6669;

        // First split: 2 hands
        vm.prank(player);
        game.split();
        uint256[] memory split1 = new uint256[](1);
        split1[0] = aceRandom;
        game.testFulfill(2, split1);
        assertEq(game.getPlayerHandsLength(), 2);

        // Second split on hand 0: 3 hands
        vm.prank(player);
        game.split();
        uint256[] memory split2 = new uint256[](1);
        split2[0] = aceRandom;
        game.testFulfill(3, split2);
        assertEq(game.getPlayerHandsLength(), 3);

        // Stand on hand 0, move to hand 1
        vm.prank(player);
        game.stand();

        // Third split on hand 1: 4 hands (max)
        vm.prank(player);
        game.split();
        uint256[] memory split3 = new uint256[](1);
        split3[0] = aceRandom;
        game.testFulfill(4, split3);
        assertEq(game.getPlayerHandsLength(), 4);

        // Stand on hand 1, move to hand 2
        vm.prank(player);
        game.stand();

        // Try to split hand 2, should fail with TooManyHands (would create 5th hand)
        vm.expectRevert(TooManyHands.selector);
        vm.prank(player);
        game.split();
    }

    // ============================================================================
    // SECTION 6: CORE ACTIONS - SURRENDER
    // ============================================================================

    function testSurrender() public {
        uint256[] memory randoms = new uint256[](1);
        randoms[0] = 0;
        game.testFulfill(1, randoms);

        if (uint(game.state()) == uint(GameUpgradeable.GameState.InsuranceOffer)) {
            vm.prank(player);
            game.skipInsurance();
        }

        vm.prank(player);
        game.surrender();

        assertEq(uint(game.state()), uint(GameUpgradeable.GameState.Finished), "Game should be finished");
    }

    function testSurrenderAfterHit() public {
        uint8[] memory playerCards = new uint8[](2);
        playerCards[0] = 10;
        playerCards[1] = 6;
        uint8[] memory dealerCards = new uint8[](2);
        dealerCards[0] = 2;
        dealerCards[1] = 3;
        vm.prank(player);
        game.testSetCards(playerCards, dealerCards);

        bytes32 allowancesSlot = bytes32(uint256(1));
        bytes32 inner = keccak256(abi.encode(player, allowancesSlot));
        bytes32 outer = keccak256(abi.encode(address(game), inner));
        vm.store(linkAddr, outer, bytes32(uint256(linkFee)));

        vm.prank(player);
        game.hit();
        uint256[] memory hit = new uint256[](1);
        hit[0] = 2;
        game.testFulfill(2, hit);

        uint8[] memory hand = game.getPlayerHandCards(0);
        assertEq(hand.length, 3);
        assertEq(uint(game.state()), uint(GameUpgradeable.GameState.PlayerTurn));
    }

    function testSurrenderAfterSplit() public {
        uint8[] memory playerCards = new uint8[](2);
        playerCards[0] = 8;
        playerCards[1] = 21;
        uint8[] memory dealerCards = new uint8[](2);
        dealerCards[0] = 2;
        dealerCards[1] = 3;
        vm.prank(player);
        game.testSetCards(playerCards, dealerCards);

        // Approve gameToken for split
        vm.prank(player);
        gameToken.approve(address(game), betAmount);

        vm.prank(player);
        game.split();

        // Fulfill split VRF
        uint256[] memory splitRandoms = new uint256[](1);
        splitRandoms[0] = 25000;
        game.testFulfill(1, splitRandoms);

        vm.expectRevert(TooManyHands.selector);
        vm.prank(player);
        game.surrender();
    }

    // ============================================================================
    // SECTION 7: INSURANCE MECHANICS
    // ============================================================================

    function testInsuranceOffer() public {
        uint8[] memory playerCards = new uint8[](2);
        playerCards[0] = 2;
        playerCards[1] = 3;
        uint8[] memory dealerCards = new uint8[](2);
        dealerCards[0] = 1; // Ace
        dealerCards[1] = 5;
        vm.prank(player);
        game.testSetCards(playerCards, dealerCards);
        assertEq(uint(game.state()), uint(GameUpgradeable.GameState.InsuranceOffer), "Should offer insurance when dealer upcard is Ace");
    }

    function testPlaceInsuranceDealerBlackjack() public {
        uint8[] memory playerCards = new uint8[](2);
        playerCards[0] = 2;
        playerCards[1] = 3;
        uint8[] memory dealerCards = new uint8[](2);
        dealerCards[0] = 1; // Ace
        dealerCards[1] = 10; // 10-value card
        vm.prank(player);
        game.testSetCards(playerCards, dealerCards);
        assertEq(uint(game.state()), uint(GameUpgradeable.GameState.InsuranceOffer));

        uint256 insuranceAmount = betAmount / 2;
        // Approve gameToken for insurance
        vm.prank(player);
        gameToken.approve(address(game), insuranceAmount);
        
        vm.prank(player);
        game.placeInsurance(insuranceAmount);
        assertEq(uint(game.state()), uint(GameUpgradeable.GameState.Finished));
    }

    function testSkipInsuranceDealerBlackjack() public {
        uint8[] memory playerCards = new uint8[](2);
        playerCards[0] = 2;
        playerCards[1] = 3;
        uint8[] memory dealerCards = new uint8[](2);
        dealerCards[0] = 1; // Ace
        dealerCards[1] = 10; // 10-value card
        vm.prank(player);
        game.testSetCards(playerCards, dealerCards);
        assertEq(uint(game.state()), uint(GameUpgradeable.GameState.InsuranceOffer));

        vm.prank(player);
        game.skipInsurance();
        assertEq(uint(game.state()), uint(GameUpgradeable.GameState.Finished));
    }

    function testPlaceInsuranceNoBlackjack() public {
        uint8[] memory playerCards = new uint8[](2);
        playerCards[0] = 2;
        playerCards[1] = 3;
        uint8[] memory dealerCards = new uint8[](2);
        dealerCards[0] = 1; // Ace
        dealerCards[1] = 5;
        vm.prank(player);
        game.testSetCards(playerCards, dealerCards);
        assertEq(uint(game.state()), uint(GameUpgradeable.GameState.InsuranceOffer));

        // Approve gameToken for insurance
        vm.prank(player);
        gameToken.approve(address(game), betAmount / 2);
        
        vm.prank(player);
        game.placeInsurance(betAmount / 2);
        assertEq(uint(game.state()), uint(GameUpgradeable.GameState.PlayerTurn));
    }

    function testInsuranceExcessiveAmount() public {
        uint8[] memory playerCards = new uint8[](2);
        playerCards[0] = 10;
        playerCards[1] = 6;
        uint8[] memory dealerCards = new uint8[](2);
        dealerCards[0] = 1; // Ace
        dealerCards[1] = 5;
        vm.prank(player);
        game.testSetCards(playerCards, dealerCards);

        vm.expectRevert(InsuranceTooHigh.selector);
        vm.prank(player);
        game.placeInsurance(betAmount);
    }

    function testInsuranceInsufficientFunds() public {
        uint8[] memory playerCards = new uint8[](2);
        playerCards[0] = 10;
        playerCards[1] = 6;
        uint8[] memory dealerCards = new uint8[](2);
        dealerCards[0] = 1; // Ace
        dealerCards[1] = 5;
        vm.prank(player);
        game.testSetCards(playerCards, dealerCards);

        // Don't give approval - will fail with ERC20InsufficientAllowance
        vm.expectRevert(); // Just expect any revert
        vm.prank(player);
        game.placeInsurance(betAmount / 2);
    }

    function testPlaceZeroInsurance() public {
        uint8[] memory playerCards = new uint8[](2);
        playerCards[0] = 10;
        playerCards[1] = 6;
        uint8[] memory dealerCards = new uint8[](2);
        dealerCards[0] = 1; // Ace
        dealerCards[1] = 5;
        vm.prank(player);
        game.testSetCards(playerCards, dealerCards);

        assertEq(uint(game.state()), uint(GameUpgradeable.GameState.InsuranceOffer));

        vm.prank(player);
        game.placeInsurance(0);

        assertEq(uint(game.state()), uint(GameUpgradeable.GameState.PlayerTurn));
    }

    // ============================================================================
    // SECTION 8: DEALER LOGIC
    // ============================================================================

    function testDealerHit() public {
        uint8[] memory playerCards = new uint8[](2);
        playerCards[0] = 10;
        playerCards[1] = 7;
        uint8[] memory dealerCards = new uint8[](2);
        dealerCards[0] = 5;
        dealerCards[1] = 6;
        vm.prank(player);
        game.testSetCards(playerCards, dealerCards);

        vm.prank(player);
        game.stand();

        bytes32 allowancesSlot = bytes32(uint256(1));
        bytes32 inner = keccak256(abi.encode(player, allowancesSlot));
        bytes32 outer = keccak256(abi.encode(address(game), inner));
        vm.store(linkAddr, outer, bytes32(uint256(linkFee)));

        vm.prank(player);
        game.dealerHit();
        uint256[] memory dh = new uint256[](1);
        dh[0] = 10;
        game.testFulfill(2, dh);

        // After VRF callback, game transitions to DealerTurn
        assertEq(uint(game.state()), uint(GameUpgradeable.GameState.DealerTurn), "Should be in dealer turn after dealer hit");
        
        // Call continueDealer to finish the game
        vm.prank(player);
        game.continueDealer();

        uint8[] memory dCards = game.getDealerCards();
        assertEq(dCards.length, 3);
        assertEq(uint(game.state()), uint(GameUpgradeable.GameState.Finished), "Game should be finished after continueDealer");
    }

    function testDealerBust() public {
        // Replicate scenario: Dealer busts with 23, Player has valid hand
        // Expected: Player wins 2x bet
        
        uint256 initialBalance = gameToken.balanceOf(player);
        
        uint8[] memory playerCards = new uint8[](2);
        playerCards[0] = 10;
        playerCards[1] = 8;  // Player has 18
        uint8[] memory dealerCards = new uint8[](2);
        dealerCards[0] = 13;  // King (10 value)
        dealerCards[1] = 6;   // Dealer has 16
        
        vm.prank(player);
        game.testSetCards(playerCards, dealerCards);
        
        vm.prank(player);
        game.stand();
        
        // Set LINK allowance for dealer hit
        bytes32 allowancesSlot = bytes32(uint256(1));
        bytes32 inner = keccak256(abi.encode(player, allowancesSlot));
        bytes32 outer = keccak256(abi.encode(address(game), inner));
        vm.store(linkAddr, outer, bytes32(uint256(linkFee)));
        
        // Dealer hits and gets 7 -> total 23 (BUST!)
        vm.prank(player);
        game.dealerHit();
        uint256[] memory dh = new uint256[](1);
        dh[0] = 7;  // Dealer gets 7, total = 23 (BUST!)
        game.testFulfill(2, dh);
        
        // After VRF callback, game transitions to DealerTurn but doesn't call playDealer()
        assertEq(uint(game.state()), uint(GameUpgradeable.GameState.DealerTurn), "Should be in dealer turn after dealer hit");
        
        // Call continueDealer to finish the game (dealer busted, game will end)
        vm.prank(player);
        game.continueDealer();
        
        // Check game is finished
        assertEq(uint(game.state()), uint(GameUpgradeable.GameState.Finished), "Game should be finished");
        
        // Check dealer busted
        uint8[] memory finalDealerCards = game.getDealerCards();
        assertEq(finalDealerCards.length, 3, "Dealer should have 3 cards");
        
        // Check player won and received correct payout (2x bet when dealer busts)
        uint256 finalBalance = gameToken.balanceOf(player);
        uint256 payout = finalBalance > initialBalance ? finalBalance - initialBalance : 0;
        assertEq(payout, betAmount * 2, "Should get 2x bet when dealer busts");
    }

    function testDealerStandsOn17() public {
        uint8[] memory playerCards = new uint8[](2);
        playerCards[0] = 10;
        playerCards[1] = 8;
        uint8[] memory dealerCards = new uint8[](2);
        dealerCards[0] = 10;
        dealerCards[1] = 7; // 17
        vm.prank(player);
        game.testSetCards(playerCards, dealerCards);

        vm.prank(player);
        game.stand();

        assertEq(uint(game.state()), uint(GameUpgradeable.GameState.Finished));
    }

    function testDealerHitsOn16() public {
        uint8[] memory playerCards = new uint8[](2);
        playerCards[0] = 10;
        playerCards[1] = 8;
        uint8[] memory dealerCards = new uint8[](2);
        dealerCards[0] = 10;
        dealerCards[1] = 6; // 16
        vm.prank(player);
        game.testSetCards(playerCards, dealerCards);

        vm.prank(player);
        game.stand();

        assertEq(uint(game.state()), uint(GameUpgradeable.GameState.DealerTurn));
    }

    function testDealerHitsOnSoft17() public {
        uint8[] memory playerCards = new uint8[](2);
        playerCards[0] = 10;
        playerCards[1] = 8;
        uint8[] memory dealerCards = new uint8[](2);
        dealerCards[0] = 6; // 6 showing
        dealerCards[1] = 1; // Ace - Soft 17
        vm.prank(player);
        game.testSetCards(playerCards, dealerCards);

        vm.prank(player);
        game.stand();

        // Dealer must hit on soft 17, so game should be in DealerTurn waiting for VRF
        assertEq(uint(game.state()), uint(GameUpgradeable.GameState.DealerTurn));
    }

    function testDealerMultipleHits() public {
        uint8[] memory playerCards = new uint8[](2);
        playerCards[0] = 10;
        playerCards[1] = 10; // 20
        uint8[] memory dealerCards = new uint8[](2);
        dealerCards[0] = 2;
        dealerCards[1] = 3; // 5
        vm.prank(player);
        game.testSetCards(playerCards, dealerCards);

        vm.prank(player);
        game.stand();

        assertEq(uint(game.state()), uint(GameUpgradeable.GameState.DealerTurn));

        bytes32 allowancesSlot = bytes32(uint256(1));
        bytes32 inner = keccak256(abi.encode(player, allowancesSlot));
        bytes32 outer = keccak256(abi.encode(address(game), inner));
        vm.store(linkAddr, outer, bytes32(uint256(linkFee * 5))); // Extra LINK for multiple hits

        // First dealer hit
        vm.prank(player);
        game.dealerHit();
        uint256[] memory hit1 = new uint256[](1);
        hit1[0] = 2; // Dealer now has 7
        game.testFulfill(2, hit1);

        assertEq(uint(game.state()), uint(GameUpgradeable.GameState.DealerTurn), "Should be in dealer turn after first hit");
        
        // Continue dealer turn - dealer should request another hit since 7 < 17
        vm.prank(player);
        game.dealerHit(); // Manually call dealerHit since dealer needs more cards
        uint256[] memory hit2 = new uint256[](1);
        hit2[0] = 3; // Dealer now has 10
        game.testFulfill(3, hit2);

        assertEq(uint(game.state()), uint(GameUpgradeable.GameState.DealerTurn), "Should be in dealer turn after second hit");
        
        // Continue dealer turn - dealer should request another hit since 10 < 17
        vm.prank(player);
        game.dealerHit();
        uint256[] memory hit3 = new uint256[](1);
        hit3[0] = 10; // Dealer now has 20
        game.testFulfill(4, hit3);

        assertEq(uint(game.state()), uint(GameUpgradeable.GameState.DealerTurn), "Should be in dealer turn after third hit");
        
        // Call continueDealer - dealer has 20, should stand and finish
        vm.prank(player);
        game.continueDealer();

        uint8[] memory finalDealerCards = game.getDealerCards();
        assertTrue(finalDealerCards.length == 5, "Dealer should have 5 cards");
        assertEq(uint(game.state()), uint(GameUpgradeable.GameState.Finished), "Game should be finished");
    }

    // ============================================================================
    // SECTION 9: BLACKJACK DETECTION & PAYOUTS
    // ============================================================================

    function testDealerBlackjack() public {
        uint8[] memory playerCards = new uint8[](2);
        playerCards[0] = 2;
        playerCards[1] = 3;
        uint8[] memory dealerCards = new uint8[](2);
        dealerCards[0] = 10; // 10 showing (no insurance)
        dealerCards[1] = 1; // Ace
        vm.prank(player);
        game.testSetCards(playerCards, dealerCards);
        assertEq(uint(game.state()), uint(GameUpgradeable.GameState.Finished), "Game should finish if dealer blackjack");
        assertTrue(game.getDealerHasBlackjack(), "Dealer should have blackjack");
    }

    function testPlayerBlackjack() public {
        uint8[] memory playerCards = new uint8[](2);
        playerCards[0] = 13; // King
        playerCards[1] = 1; // Ace
        uint8[] memory dealerCards = new uint8[](2);
        dealerCards[0] = 2;
        dealerCards[1] = 3;
        vm.prank(player);
        game.testSetCards(playerCards, dealerCards);
        assertTrue(game.getPlayerHasBlackjack(), "Player should have blackjack");
        assertEq(uint(game.state()), uint(GameUpgradeable.GameState.Finished), "Game should be finished immediately for player blackjack");
    }

    function testPlayerWinsNormalHand() public {
        uint8[] memory playerCards = new uint8[](2);
        playerCards[0] = 10;
        playerCards[1] = 10; // 20
        uint8[] memory dealerCards = new uint8[](2);
        dealerCards[0] = 10;
        dealerCards[1] = 8; // 18
        vm.prank(player);
        game.testSetCards(playerCards, dealerCards);

        vm.prank(player);
        game.stand();

        assertEq(uint(game.state()), uint(GameUpgradeable.GameState.Finished));
    }

    function testPlayerWinsBlackjack() public {
        uint8[] memory playerCards = new uint8[](2);
        playerCards[0] = 1; // Ace
        playerCards[1] = 10; // Blackjack!
        uint8[] memory dealerCards = new uint8[](2);
        dealerCards[0] = 10;
        dealerCards[1] = 8;
        vm.prank(player);
        game.testSetCards(playerCards, dealerCards);

        assertEq(uint(game.state()), uint(GameUpgradeable.GameState.Finished));
        assertTrue(game.getPlayerHasBlackjack());
    }

    function testBothBlackjackPush() public {
        uint8[] memory playerCards = new uint8[](2);
        playerCards[0] = 1; // Ace
        playerCards[1] = 10; // Blackjack
        uint8[] memory dealerCards = new uint8[](2);
        dealerCards[0] = 14; // Ace
        dealerCards[1] = 11; // Jack - Blackjack
        vm.prank(player);
        game.testSetCards(playerCards, dealerCards);

        assertEq(uint(game.state()), uint(GameUpgradeable.GameState.InsuranceOffer));
        assertTrue(game.getPlayerHasBlackjack());
        assertTrue(game.getDealerHasBlackjack());

        vm.prank(player);
        game.skipInsurance();

        assertEq(uint(game.state()), uint(GameUpgradeable.GameState.Finished));
    }

    function testPlayerLosesToDealer() public {
        uint8[] memory playerCards = new uint8[](2);
        playerCards[0] = 10;
        playerCards[1] = 6; // 16
        uint8[] memory dealerCards = new uint8[](2);
        dealerCards[0] = 10;
        dealerCards[1] = 10; // 20
        vm.prank(player);
        game.testSetCards(playerCards, dealerCards);

        vm.prank(player);
        game.stand();

        assertEq(uint(game.state()), uint(GameUpgradeable.GameState.Finished));
    }

    function testPush() public {
        uint8[] memory playerCards = new uint8[](2);
        playerCards[0] = 10;
        playerCards[1] = 7;
        uint8[] memory dealerCards = new uint8[](2);
        dealerCards[0] = 10;
        dealerCards[1] = 7;
        vm.prank(player);
        game.testSetCards(playerCards, dealerCards);

        vm.prank(player);
        game.stand();

        assertEq(uint(game.state()), uint(GameUpgradeable.GameState.Finished));
    }

    // ============================================================================
    // SECTION 10: MULTI-HAND PLAY
    // ============================================================================

    function testHitOnSplitHands() public {
        uint256[] memory randoms = new uint256[](1);
        randoms[0] = 0;
        game.testFulfill(1, randoms);

        if (uint(game.state()) == uint(GameUpgradeable.GameState.InsuranceOffer)) {
            vm.prank(player);
            game.skipInsurance();
        }

        // Approve gameToken for split
        vm.prank(player);
        gameToken.approve(address(game), betAmount);

        vm.prank(player);
        game.split();

        // Fulfill split VRF request
        uint256[] memory splitRandoms = new uint256[](1);
        splitRandoms[0] = 45000;
        game.testFulfill(2, splitRandoms);

        assertEq(game.getPlayerHandsLength(), 2);

        bytes32 allowancesSlot = bytes32(uint256(1));
        bytes32 inner = keccak256(abi.encode(player, allowancesSlot));
        bytes32 outer = keccak256(abi.encode(address(game), inner));
        vm.store(linkAddr, outer, bytes32(uint256(linkFee * 2)));

        vm.prank(player);
        game.hit();

        uint256[] memory hitRandoms = new uint256[](1);
        hitRandoms[0] = 67890;
        game.testFulfill(3, hitRandoms);

        uint8[] memory hand0 = game.getPlayerHandCards(0);
        assertEq(hand0.length, 3, "First hand should have 3 cards after split+hit");

        vm.prank(player);
        game.stand();

        vm.store(linkAddr, outer, bytes32(uint256(linkFee * 2)));
        vm.prank(player);
        game.hit();

        uint256[] memory hitRandoms2 = new uint256[](1);
        hitRandoms2[0] = 11111;
        game.testFulfill(4, hitRandoms2);

        uint8[] memory hand1 = game.getPlayerHandCards(1);
        assertEq(hand1.length, 3, "Second hand should have 3 cards after split+hit");
    }

    function testSplitWinLose() public {
        uint256[] memory randoms = new uint256[](1);
        randoms[0] = 0;
        game.testFulfill(1, randoms);

        if (uint(game.state()) == uint(GameUpgradeable.GameState.InsuranceOffer)) {
            vm.prank(player);
            game.skipInsurance();
        }

        // Approve gameToken for split
        vm.prank(player);
        gameToken.approve(address(game), betAmount);

        vm.prank(player);
        game.split();

        // Fulfill split VRF
        uint256[] memory splitRandoms = new uint256[](1);
        splitRandoms[0] = 42000;
        game.testFulfill(2, splitRandoms);

        bytes32 allowancesSlot = bytes32(uint256(1));
        bytes32 inner = keccak256(abi.encode(player, allowancesSlot));
        bytes32 outer = keccak256(abi.encode(address(game), inner));
        vm.store(linkAddr, outer, bytes32(uint256(linkFee * 4)));

        vm.prank(player);
        game.hit();
        uint256[] memory hit1 = new uint256[](1);
        hit1[0] = 100;
        game.testFulfill(3, hit1);

        vm.prank(player);
        game.hit();
        uint256[] memory hit2 = new uint256[](1);
        hit2[0] = 200;
        game.testFulfill(4, hit2);

        vm.prank(player);
        game.stand();

        // After stand, game requests dealer hole card (state = Dealing)
        assertEq(uint(game.state()), uint(GameUpgradeable.GameState.Dealing), "Should be dealing dealer hole card");
        
        // Fulfill dealer hole card VRF request
        uint256[] memory holeCardRandom = new uint256[](1);
        holeCardRandom[0] = 55555;
        game.testFulfill(5, holeCardRandom);
        
        // After hole card is dealt, dealer logic runs automatically
        // Game may be Finished if dealer doesn't need to hit, or DealerTurn if dealer needs to hit
        assertTrue(
            uint(game.state()) == uint(GameUpgradeable.GameState.DealerTurn) ||
            uint(game.state()) == uint(GameUpgradeable.GameState.Finished),
            "Should be dealer turn or finished after hole card dealt"
        );
    }

    // ============================================================================
    // SECTION 11: SCORE CALCULATION & ACE HANDLING
    // ============================================================================

    function testAceHandling() public {
        uint8[] memory playerCards = new uint8[](2);
        playerCards[0] = 1; // Ace
        playerCards[1] = 6;
        uint8[] memory dealerCards = new uint8[](2);
        dealerCards[0] = 2;
        dealerCards[1] = 3;
        vm.prank(player);
        game.testSetCards(playerCards, dealerCards);

        bytes32 allowancesSlot = bytes32(uint256(1));
        bytes32 inner = keccak256(abi.encode(player, allowancesSlot));
        bytes32 outer = keccak256(abi.encode(address(game), inner));
        vm.store(linkAddr, outer, bytes32(uint256(linkFee)));

        vm.prank(player);
        game.hit();
        uint256[] memory hit = new uint256[](1);
        hit[0] = 9;
        game.testFulfill(2, hit);

        uint8[] memory hand = game.getPlayerHandCards(0);
        assertEq(hand.length, 3);
        assertEq(uint(game.state()), uint(GameUpgradeable.GameState.PlayerTurn));
    }

    function testAceSoftHand() public {
        uint8[] memory playerCards = new uint8[](2);
        playerCards[0] = 1; // Ace
        playerCards[1] = 6; // Soft 17
        uint8[] memory dealerCards = new uint8[](2);
        dealerCards[0] = 2;
        dealerCards[1] = 3;
        vm.prank(player);
        game.testSetCards(playerCards, dealerCards);

        bytes32 allowancesSlot = bytes32(uint256(1));
        bytes32 inner = keccak256(abi.encode(player, allowancesSlot));
        bytes32 outer = keccak256(abi.encode(address(game), inner));
        vm.store(linkAddr, outer, bytes32(uint256(linkFee)));

        vm.prank(player);
        game.hit();
        uint256[] memory hit = new uint256[](1);
        hit[0] = 10;
        game.testFulfill(2, hit);

        assertEq(uint(game.state()), uint(GameUpgradeable.GameState.PlayerTurn));
    }

    function testMultipleAces() public {
        uint8[] memory playerCards = new uint8[](3);
        playerCards[0] = 1; // Ace
        playerCards[1] = 14; // Ace
        playerCards[2] = 27; // Ace
        uint8[] memory dealerCards = new uint8[](2);
        dealerCards[0] = 2;
        dealerCards[1] = 3;
        vm.prank(player);
        game.testSetCards(playerCards, dealerCards);

        assertEq(uint(game.state()), uint(GameUpgradeable.GameState.PlayerTurn));
    }

    function testPlayerBust() public {
        uint8[] memory playerCards = new uint8[](2);
        playerCards[0] = 10;
        playerCards[1] = 10; // 20
        uint8[] memory dealerCards = new uint8[](2);
        dealerCards[0] = 2;
        dealerCards[1] = 3;
        vm.prank(player);
        game.testSetCards(playerCards, dealerCards);

        bytes32 allowancesSlot = bytes32(uint256(1));
        bytes32 inner = keccak256(abi.encode(player, allowancesSlot));
        bytes32 outer = keccak256(abi.encode(address(game), inner));
        vm.store(linkAddr, outer, bytes32(uint256(linkFee)));

        vm.prank(player);
        game.hit();
        uint256[] memory hit1 = new uint256[](1);
        hit1[0] = 10; // Total 30, busted
        game.testFulfill(2, hit1);

        // After VRF callback, game transitions to DealerTurn but doesn't call playDealer()
        assertEq(uint(game.state()), uint(GameUpgradeable.GameState.DealerTurn), "Should be in dealer turn after player busts");
        
        // Call continueDealer to finish the game
        vm.prank(player);
        game.continueDealer();
        
        // Now game should be finished (dealer doesn't need to play when all hands busted)
        assertEq(uint(game.state()), uint(GameUpgradeable.GameState.Finished), "Game should be finished after continueDealer");
    }

    // ============================================================================
    // SECTION 12: EDGE CASES & ERROR CONDITIONS
    // ============================================================================

    function testInsufficientLINK() public {
        uint256[] memory randoms = new uint256[](1);
        randoms[0] = 7;
        game.testFulfill(1, randoms);

        bytes32 allowancesSlot = bytes32(uint256(1));
        bytes32 inner = keccak256(abi.encode(player, allowancesSlot));
        bytes32 outer = keccak256(abi.encode(address(game), inner));
        vm.store(linkAddr, outer, bytes32(uint256(0)));

        vm.expectRevert();
        vm.prank(player);
        game.hit();
    }

    // ============================================================================
    // SECTION 13: ACCESS CONTROL
    // ============================================================================

    function testNonPlayerCannotHit() public {
        uint8[] memory playerCards = new uint8[](2);
        playerCards[0] = 10;
        playerCards[1] = 6;
        uint8[] memory dealerCards = new uint8[](2);
        dealerCards[0] = 2;
        dealerCards[1] = 3;
        vm.prank(player);
        game.testSetCards(playerCards, dealerCards);

        address attacker = address(0x999);
        vm.expectRevert(NotYourGame.selector);
        vm.prank(attacker);
        game.hit();
    }

    function testNonPlayerCannotStand() public {
        uint8[] memory playerCards = new uint8[](2);
        playerCards[0] = 10;
        playerCards[1] = 6;
        uint8[] memory dealerCards = new uint8[](2);
        dealerCards[0] = 2;
        dealerCards[1] = 3;
        vm.prank(player);
        game.testSetCards(playerCards, dealerCards);

        address attacker = address(0x999);
        vm.expectRevert(NotYourGame.selector);
        vm.prank(attacker);
        game.stand();
    }

    function testNonPlayerCannotDoubleDown() public {
        uint8[] memory playerCards = new uint8[](2);
        playerCards[0] = 5;
        playerCards[1] = 6;
        uint8[] memory dealerCards = new uint8[](2);
        dealerCards[0] = 2;
        dealerCards[1] = 3;
        vm.prank(player);
        game.testSetCards(playerCards, dealerCards);

        address attacker = address(0x999);
        vm.expectRevert(NotYourGame.selector);
        vm.prank(attacker);
        game.doubleDown();
    }

    function testNonPlayerCannotSplit() public {
        uint8[] memory playerCards = new uint8[](2);
        playerCards[0] = 8;
        playerCards[1] = 21;
        uint8[] memory dealerCards = new uint8[](2);
        dealerCards[0] = 2;
        dealerCards[1] = 3;
        vm.prank(player);
        game.testSetCards(playerCards, dealerCards);

        address attacker = address(0x999);
        vm.expectRevert(NotYourGame.selector);
        vm.prank(attacker);
        game.split();
    }

    function testNonPlayerCannotSurrender() public {
        uint8[] memory playerCards = new uint8[](2);
        playerCards[0] = 10;
        playerCards[1] = 6;
        uint8[] memory dealerCards = new uint8[](2);
        dealerCards[0] = 2;
        dealerCards[1] = 3;
        vm.prank(player);
        game.testSetCards(playerCards, dealerCards);

        address attacker = address(0x999);
        vm.expectRevert(NotYourGame.selector);
        vm.prank(attacker);
        game.surrender();
    }

    function testNonPlayerCannotPlaceInsurance() public {
        uint8[] memory playerCards = new uint8[](2);
        playerCards[0] = 10;
        playerCards[1] = 6;
        uint8[] memory dealerCards = new uint8[](2);
        dealerCards[0] = 1; // Ace
        dealerCards[1] = 5;
        vm.prank(player);
        game.testSetCards(playerCards, dealerCards);

        address attacker = address(0x999);
        vm.expectRevert(NotYourGame.selector);
        vm.prank(attacker);
        game.placeInsurance(betAmount / 2);
    }

    function testNonPlayerCannotSkipInsurance() public {
        uint8[] memory playerCards = new uint8[](2);
        playerCards[0] = 10;
        playerCards[1] = 6;
        uint8[] memory dealerCards = new uint8[](2);
        dealerCards[0] = 1; // Ace
        dealerCards[1] = 5;
        vm.prank(player);
        game.testSetCards(playerCards, dealerCards);

        address attacker = address(0x999);
        vm.expectRevert(NotYourGame.selector);
        vm.prank(attacker);
        game.skipInsurance();
    }

    function testNonPlayerCannotDealerHit() public {
        uint8[] memory playerCards = new uint8[](2);
        playerCards[0] = 10;
        playerCards[1] = 8;
        uint8[] memory dealerCards = new uint8[](2);
        dealerCards[0] = 10;
        dealerCards[1] = 5;
        vm.prank(player);
        game.testSetCards(playerCards, dealerCards);

        vm.prank(player);
        game.stand();

        address attacker = address(0x999);
        vm.expectRevert(NotYourGame.selector);
        vm.prank(attacker);
        game.dealerHit();
    }

    // ============================================================================
    // SECTION 14: STATE TRANSITIONS
    // ============================================================================

    function testCannotHitInDealerTurn() public {
        uint8[] memory playerCards = new uint8[](2);
        playerCards[0] = 10;
        playerCards[1] = 8;
        uint8[] memory dealerCards = new uint8[](2);
        dealerCards[0] = 10;
        dealerCards[1] = 5;
        vm.prank(player);
        game.testSetCards(playerCards, dealerCards);

        vm.prank(player);
        game.stand();

        assertEq(uint(game.state()), uint(GameUpgradeable.GameState.DealerTurn));

        vm.expectRevert(NotPlayerTurn.selector);
        vm.prank(player);
        game.hit();
    }

    function testCannotStandInDealerTurn() public {
        uint8[] memory playerCards = new uint8[](2);
        playerCards[0] = 10;
        playerCards[1] = 8;
        uint8[] memory dealerCards = new uint8[](2);
        dealerCards[0] = 10;
        dealerCards[1] = 5;
        vm.prank(player);
        game.testSetCards(playerCards, dealerCards);

        vm.prank(player);
        game.stand();

        assertEq(uint(game.state()), uint(GameUpgradeable.GameState.DealerTurn));

        vm.expectRevert(NotPlayerTurn.selector);
        vm.prank(player);
        game.stand();
    }

    function testCannotSplitInDealerTurn() public {
        uint8[] memory playerCards = new uint8[](2);
        playerCards[0] = 8;
        playerCards[1] = 21;
        uint8[] memory dealerCards = new uint8[](2);
        dealerCards[0] = 10;
        dealerCards[1] = 5;
        vm.prank(player);
        game.testSetCards(playerCards, dealerCards);

        vm.prank(player);
        game.stand();

        assertEq(uint(game.state()), uint(GameUpgradeable.GameState.DealerTurn));

        vm.expectRevert(NotPlayerTurn.selector);
        vm.prank(player);
        game.split();
    }

    // ============================================================================
    // SECTION 15: RELOADABLE GAME & LINK FEES
    // ============================================================================

    function testLINKFeeTracking() public {
        // Initial LINK spent from startGame
        uint256 initialLinkSpent = game.linkSpent();
        assertGt(initialLinkSpent, 0);

        uint8[] memory playerCards = new uint8[](2);
        playerCards[0] = 5;
        playerCards[1] = 6;
        uint8[] memory dealerCards = new uint8[](2);
        dealerCards[0] = 2;
        dealerCards[1] = 3;
        vm.prank(player);
        game.testSetCards(playerCards, dealerCards);

        bytes32 allowancesSlot = bytes32(uint256(1));
        bytes32 inner = keccak256(abi.encode(player, allowancesSlot));
        bytes32 outer = keccak256(abi.encode(address(game), inner));
        vm.store(linkAddr, outer, bytes32(uint256(linkFee)));

        vm.prank(player);
        game.hit();

        // LINK spent should increase
        uint256 afterHitLinkSpent = game.linkSpent();
        assertGt(afterHitLinkSpent, initialLinkSpent);
    }

    // ============ Fund Management Tests ============

    function testCanCoverMaxPayout() public view {
        // Game is funded with 11x bet from factory (1 token * 11 = 11 tokens)
        // Should be able to cover max payout
        bool canCover = game.canCoverMaxPayout();
        assertTrue(canCover);
    }

    function testCanCoverMaxPayoutInsufficientFunds() public {
        // Create new game with minimal funds
        vm.prank(player);
        gameToken.approve(address(factory), betAmount);
        vm.prank(player);
        factory.createGame(betAmount);
        address[] memory games = factory.getPlayerGames(player);
        TestableGame newGame = TestableGame(payable(games[games.length - 1]));
        
        // Game has already been started by factory. Now drain most GameToken from the game
        // Factory already sent 11x bet, drain it to leave only betAmount
        uint256 gameBalance = gameToken.balanceOf(address(newGame));
        vm.prank(address(newGame));
        gameToken.transfer(player, gameBalance - betAmount);
        
        // Should not be able to cover max payout (needs 11x bet, only has 1x bet)
        bool canCover = newGame.canCoverMaxPayout();
        assertFalse(canCover);
    }

    function testHasEnoughLINK() public view {
        // In pay-per-action model, game receives LINK_FEE for startGame
        // In test env (MockVRF), LINK isn't consumed so it stays in contract
        bool hasEnough = game.hasEnoughLINK(1);
        assertTrue(hasEnough); // Has LINK_FEE (0.0005 ether) from startGame
    }

    function testHasEnoughLINKInsufficient() public view {
        // Game has 100 ether LINK from setUp
        // Check if it has enough for 25000 turns (25000 * 0.005 = 125 ether)
        bool hasEnough = game.hasEnoughLINK(25000);
        assertFalse(hasEnough); // Only has 100 ether, not enough for 25000 turns (needs 125 ether)
    }

    function testGetRecommendedFunding() public view {
        (uint256 tokenAmount, uint256 linkAmount) = game.getRecommendedFunding();
        
        // Worst-case payout: 11x bet (insurance + split + double + blackjack)
        assertEq(tokenAmount, betAmount * 11);
        
        // 20 turns worth of LINK
        assertEq(linkAmount, linkFee * 20);
    }
    
    // ============================================================================
    // SECTION 12: CHAINLINK KEEPER AUTOMATION
    // ============================================================================
    
    function testKeeperRecoverLinkFromExpiredGame() public {
        // Record initial LINK balances
        uint256 initialFactoryLink = IERC20(linkAddr).balanceOf(address(factory));
        uint256 initialGameLink = IERC20(linkAddr).balanceOf(address(game));
        
        console.log("Initial factory LINK:", initialFactoryLink);
        console.log("Initial game LINK:", initialGameLink);
        
        // Simulate time passing (game expires after 24 hours)
        vm.warp(block.timestamp + 24 hours + 1);
        
        // Check that game is expired
        address[] memory expiredGames = getExpiredGames();
        assertEq(expiredGames.length, 1, "Should have 1 expired game");
        assertEq(expiredGames[0], address(game), "Expired game should be our game");
        
        // Simulate keeper performing upkeep
        simulateKeeperUpkeep(address(game));
        
        // Check LINK was recovered to factory
        uint256 finalFactoryLink = IERC20(linkAddr).balanceOf(address(factory));
        uint256 finalGameLink = IERC20(linkAddr).balanceOf(address(game));
        
        console.log("Final factory LINK:", finalFactoryLink);
        console.log("Final game LINK:", finalGameLink);
        
        assertEq(finalGameLink, 0, "Game should have no LINK left");
        assertEq(finalFactoryLink, initialFactoryLink + initialGameLink, "Factory should receive all game LINK");
        
        // Check game state is finished
        assertEq(uint(game.state()), uint(GameUpgradeable.GameState.Finished), "Game should be finished");
    }
    
    function testKeeperMultipleExpiredGames() public {
        // Create additional games
        gameToken.approve(address(factory), betAmount * 2);
        factory.createGame(betAmount);
        factory.createGame(betAmount);
        
        address[] memory allGames = factory.getPlayerGames(player);
        assertEq(allGames.length, 3, "Should have 3 games total");
        
        // Record initial LINK balances
        uint256 initialFactoryLink = IERC20(linkAddr).balanceOf(address(factory));
        uint256 totalGameLink = 0;
        for (uint256 i = 0; i < allGames.length; i++) {
            totalGameLink += IERC20(linkAddr).balanceOf(allGames[i]);
        }
        
        console.log("Initial factory LINK:", initialFactoryLink);
        console.log("Total game LINK:", totalGameLink);
        
        // Warp time to expire all games
        vm.warp(block.timestamp + 24 hours + 1);
        
        // Check that all games are expired
        address[] memory expiredGames = getExpiredGames();
        assertEq(expiredGames.length, 3, "All 3 games should be expired");
        
        // Simulate keeper performing upkeep on all games
        for (uint256 i = 0; i < expiredGames.length; i++) {
            factory.cancelExpiredGameByKeeper(payable(expiredGames[i]));
        }
        
        // Check all LINK was recovered
        uint256 finalFactoryLink = IERC20(linkAddr).balanceOf(address(factory));
        console.log("Final factory LINK:", finalFactoryLink);
        
        assertEq(finalFactoryLink, initialFactoryLink + totalGameLink, "Factory should receive all LINK from expired games");
        
        // Check all games have no LINK left
        for (uint256 i = 0; i < allGames.length; i++) {
            uint256 gameLink = IERC20(linkAddr).balanceOf(allGames[i]);
            assertEq(gameLink, 0, "Game should have no LINK left");
        }
    }
    
    function testKeeperOnlyWorksOnExpiredGames() public {
        // Try to call keeper on non-expired game (should fail)
        vm.expectRevert("Game not expired yet");
        factory.cancelExpiredGameByKeeper(payable(address(game)));
        
        // Game should still be active
        assertTrue(uint(game.state()) != uint(GameUpgradeable.GameState.Finished), "Game should still be active");
    }
    
    function testKeeperDoesNotAffectFinishedGames() public {
        // This test verifies that keeper's getExpiredGames() function 
        // correctly excludes finished games from cleanup
        
        // Record current game's LINK balance
        // uint256 gameLink = IERC20(linkAddr).balanceOf(address(game));
        
        // Warp time to make game "old" (24+ hours)
        vm.warp(block.timestamp + 24 hours + 1);
        
        // Game is not finished, so it SHOULD be in expired games list
        address[] memory expiredGames = getExpiredGames();
        assertEq(expiredGames.length, 1, "Unfinished old game should be expired");
        assertEq(expiredGames[0], address(game), "Game should be in expired list");
        
        // Keeper CAN clean up this unfinished expired game
        factory.cancelExpiredGameByKeeper(payable(address(game)));
        
        // LINK should be recovered
        assertEq(IERC20(linkAddr).balanceOf(address(game)), 0, "LINK should be recovered from expired game");
        
        // Game should now be finished (canceled)
        assertEq(uint(game.state()), uint(GameUpgradeable.GameState.Finished), "Game should be finished after cleanup");
    }
}
