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

error NotYourGame();
error NotDealerTurn();
error WaitingForRandomness();

contract MockLINK is ERC20 {
    constructor() ERC20("Mock LINK", "LINK") {
        _mint(msg.sender, 1000000 ether);
    }
}

contract MockVRF {
    uint256 public requestId = 1;
    
    // Match the actual VRF coordinator interface
    struct RandomWordsRequest {
        bytes32 keyHash;
        uint256 subId;
        uint16 requestConfirmations;
        uint32 callbackGasLimit;
        uint32 numWords;
        bytes extraArgs;
    }
    
    function requestRandomWords(RandomWordsRequest memory) external payable returns (uint256) {
        return requestId++;
    }
}

/**
 * @title ContinueDealerFlow Tests
 * @notice Tests for the new continueDealer() flow that prevents VRF callback gas limit errors
 * @dev After doubleDown or other actions that lead to dealer turn, the VRF callback
 *      only updates state but does NOT call playDealer(). Player must call continueDealer()
 *      in a separate transaction to execute dealer logic.
 */
contract ContinueDealerFlowTest is Test {
    TestableGameFactory public factory;
    GameToken public gameToken;
    MockLINK public link;
    address public player;
    address public vrfCoordinator = 0x343300b5d84D444B2ADc9116FEF1bED02BE49Cf2;
    address public linkAddr = 0x0Fd9e8d3aF1aaee056EB9e802c3A762a667b1904;

    uint256 public betAmount = 1 * 10**18; // 1 GameToken
    uint256 public linkFee = 0.005 ether;

    TestableGame public game;

    receive() external payable {}

    function setUp() public {
        // Deploy mock contracts
        link = new MockLINK();
        MockVRF mockVrf = new MockVRF();
        vm.etch(vrfCoordinator, address(mockVrf).code);
        vm.store(vrfCoordinator, bytes32(0), bytes32(uint256(1)));
        vm.etch(linkAddr, address(link).code);
        
        // Deploy GameToken
        gameToken = new GameToken();
        
        // Mint initial tokens
        uint256 ownerPOL = 1_000_000 ether;
        vm.deal(address(this), ownerPOL);
        gameToken.buyTokens{value: ownerPOL}();
        
        // Deploy factory
        factory = new TestableGameFactory();
        factory.initializeTest(
            vrfCoordinator,
            linkAddr,
            address(gameToken),
            linkFee,
            1 * 10**18,
            1,
            address(0x1234)
        );
        
        gameToken.transferOwnership(address(factory));
        player = address(this);

        // Fund factory
        uint256 liquidityAmount = 10000 * 10**18;
        uint256 polNeeded = liquidityAmount / 1000;
        vm.deal(address(this), polNeeded * 2);
        gameToken.buyTokens{value: polNeeded}();
        gameToken.transfer(address(factory), liquidityAmount);
        vm.deal(address(factory), polNeeded);
        vm.prank(address(factory));
        gameToken.topUpReserve{value: polNeeded}();

        // Set LINK balances
        bytes32 balancesSlot = bytes32(uint256(0));
        bytes32 playerBalanceSlot = keccak256(abi.encode(player, balancesSlot));
        vm.store(linkAddr, playerBalanceSlot, bytes32(uint256(100 ether)));
        
        bytes32 factoryBalanceSlot = keccak256(abi.encode(address(factory), balancesSlot));
        vm.store(linkAddr, factoryBalanceSlot, bytes32(uint256(100 ether)));
        
        bytes32 allowancesSlot = bytes32(uint256(1));
        bytes32 inner = keccak256(abi.encode(player, allowancesSlot));
        bytes32 outer = keccak256(abi.encode(address(factory), inner));
        vm.store(linkAddr, outer, bytes32(uint256(100 ether)));
        
        // Create game
        gameToken.approve(address(factory), betAmount);
        factory.createGame(betAmount);
        address[] memory games = factory.getPlayerGames(player);
        game = TestableGame(payable(games[0]));

        bytes32 gameBalanceSlot = keccak256(abi.encode(address(game), balancesSlot));
        vm.store(linkAddr, gameBalanceSlot, bytes32(uint256(100 ether)));
        
        bytes32 gameAllowanceInner = keccak256(abi.encode(player, allowancesSlot));
        bytes32 gameAllowanceOuter = keccak256(abi.encode(address(game), gameAllowanceInner));
        vm.store(linkAddr, gameAllowanceOuter, bytes32(uint256(100 ether)));
    }

    // ============================================================================
    // TEST: Double Down Flow with continueDealer()
    // ============================================================================

    function testDoubleDownRequiresContinueDealer() public {
        // Complete initial deal
        uint256[] memory randoms = new uint256[](1);
        randoms[0] = 12345;
        game.testFulfill(1, randoms);

        // Skip insurance if offered
        if (uint(game.state()) == uint(GameUpgradeable.GameState.InsuranceOffer)) {
            vm.prank(player);
            game.skipInsurance();
        }

        // Approve and execute double down
        bytes32 allowancesSlot = bytes32(uint256(1));
        bytes32 inner = keccak256(abi.encode(player, allowancesSlot));
        bytes32 outer = keccak256(abi.encode(address(game), inner));
        vm.store(linkAddr, outer, bytes32(uint256(linkFee)));

        vm.prank(player);
        gameToken.approve(address(game), betAmount);

        vm.prank(player);
        game.doubleDown();

        assertEq(uint(game.state()), uint(GameUpgradeable.GameState.Dealing), "Should be dealing after doubleDown");

        // Fulfill VRF for doubleDown card
        uint256[] memory ddRandoms = new uint256[](1);
        ddRandoms[0] = 99999;
        game.testFulfill(2, ddRandoms);

        // CRITICAL: After VRF callback, game should be in DealerTurn but NOT finished
        assertEq(uint(game.state()), uint(GameUpgradeable.GameState.DealerTurn), "Should be in dealer turn after doubleDown VRF");
        
        // Now player must call continueDealer() to execute dealer logic
        vm.prank(player);
        game.continueDealer();

        // After continueDealer, game should progress (either stay in DealerTurn for more cards or finish)
        assertTrue(
            uint(game.state()) == uint(GameUpgradeable.GameState.DealerTurn) ||
            uint(game.state()) == uint(GameUpgradeable.GameState.Dealing) ||
            uint(game.state()) == uint(GameUpgradeable.GameState.Finished),
            "Game should progress after continueDealer"
        );
    }

    function testContinueDealerOnlyInDealerTurn() public {
        // Try to call continueDealer before reaching dealer turn
        uint256[] memory randoms = new uint256[](1);
        randoms[0] = 12345;
        game.testFulfill(1, randoms);

        if (uint(game.state()) == uint(GameUpgradeable.GameState.InsuranceOffer)) {
            vm.prank(player);
            game.skipInsurance();
        }

        // Should be in PlayerTurn now
        assertEq(uint(game.state()), uint(GameUpgradeable.GameState.PlayerTurn));

        // Trying to call continueDealer should revert
        vm.expectRevert(NotDealerTurn.selector);
        vm.prank(player);
        game.continueDealer();
    }

    function testContinueDealerOnlyByPlayer() public {
        // Complete initial deal and get to dealer turn
        uint256[] memory randoms = new uint256[](1);
        randoms[0] = 12345;
        game.testFulfill(1, randoms);

        if (uint(game.state()) == uint(GameUpgradeable.GameState.InsuranceOffer)) {
            vm.prank(player);
            game.skipInsurance();
        }

        // Stand to get to dealer turn
        vm.prank(player);
        game.stand();

        // Fulfill VRF for dealer hole card
        randoms[0] = 88888;
        game.testFulfill(2, randoms);

        assertEq(uint(game.state()), uint(GameUpgradeable.GameState.DealerTurn));

        // Try to call continueDealer as non-player
        address attacker = address(0x999);
        vm.expectRevert(NotYourGame.selector);
        vm.prank(attacker);
        game.continueDealer();
    }

    function testContinueDealerCannotCallFromDealingState() public {
        // Complete initial deal
        uint256[] memory randoms = new uint256[](1);
        randoms[0] = 12345;
        game.testFulfill(1, randoms);

        if (uint(game.state()) == uint(GameUpgradeable.GameState.InsuranceOffer)) {
            vm.prank(player);
            game.skipInsurance();
        }

        // Stand - this will call playDealer() which requests dealer hole card and sets state to Dealing
        vm.prank(player);
        game.stand();

        // Game should be in Dealing state waiting for dealer hole card
        assertEq(uint(game.state()), uint(GameUpgradeable.GameState.Dealing), "Should be dealing dealer hole card");

        // Trying to call continueDealer while in Dealing state should revert with NotDealerTurn
        vm.expectRevert(NotDealerTurn.selector);
        vm.prank(player);
        game.continueDealer();
    }

    // ============================================================================
    // TEST: Stand Flow with continueDealer()
    // ============================================================================

    function testStandFlowWithContinueDealer() public {
        // Complete initial deal
        uint256[] memory randoms = new uint256[](1);
        randoms[0] = 12345;
        game.testFulfill(1, randoms);

        if (uint(game.state()) == uint(GameUpgradeable.GameState.InsuranceOffer)) {
            vm.prank(player);
            game.skipInsurance();
        }

        // Stand
        vm.prank(player);
        game.stand();

        assertEq(uint(game.state()), uint(GameUpgradeable.GameState.Dealing), "Should be dealing dealer hole card");

        // Fulfill VRF for dealer hole card
        randoms[0] = 77777;
        game.testFulfill(2, randoms);

        assertEq(uint(game.state()), uint(GameUpgradeable.GameState.DealerTurn), "Should be in dealer turn");

        // Call continueDealer to execute dealer logic
        vm.prank(player);
        game.continueDealer();

        // Game should progress
        assertTrue(
            uint(game.state()) == uint(GameUpgradeable.GameState.DealerTurn) ||
            uint(game.state()) == uint(GameUpgradeable.GameState.Dealing) ||
            uint(game.state()) == uint(GameUpgradeable.GameState.Finished),
            "Game should progress after continueDealer"
        );
    }

    // ============================================================================
    // TEST: Multiple continueDealer calls (dealer hitting multiple times)
    // ============================================================================

    function testMultipleContinueDealerCalls() public {
        // Complete initial deal
        uint256[] memory randoms = new uint256[](1);
        randoms[0] = 12345;
        game.testFulfill(1, randoms);

        if (uint(game.state()) == uint(GameUpgradeable.GameState.InsuranceOffer)) {
            vm.prank(player);
            game.skipInsurance();
        }

        // Stand - this will call playDealer() which requests dealer hole card
        vm.prank(player);
        game.stand();

        // After stand, state should be Dealing (waiting for dealer hole card)
        assertEq(uint(game.state()), uint(GameUpgradeable.GameState.Dealing), "Should be dealing dealer hole card");

        // Set up cards: Player has 20, Dealer starts with 12 (needs multiple hits)
        uint8[] memory playerCards = new uint8[](2);
        playerCards[0] = 10;
        playerCards[1] = 10;
        uint8[] memory dealerCards = new uint8[](2);
        dealerCards[0] = 2;
        dealerCards[1] = 10; // Dealer has 12 with this hole card
        vm.prank(player);
        game.testSetCards(playerCards, dealerCards);

        // Fulfill dealer hole card
        randoms[0] = 77777;
        game.testFulfill(2, randoms);

        assertEq(uint(game.state()), uint(GameUpgradeable.GameState.DealerTurn), "Should be in dealer turn after hole card");

        bytes32 allowancesSlot = bytes32(uint256(1));
        bytes32 inner = keccak256(abi.encode(player, allowancesSlot));
        bytes32 outer = keccak256(abi.encode(address(game), inner));

        // First continueDealer - dealer will hit (score < 17)
        vm.store(linkAddr, outer, bytes32(uint256(linkFee)));
        vm.prank(player);
        game.continueDealer();

        // Game might be dealing (dealer hits) or finished (if dealer got enough to stand)
        uint256 stateAfterFirst = uint(game.state());
        assertTrue(
            stateAfterFirst == uint(GameUpgradeable.GameState.Dealing) ||
            stateAfterFirst == uint(GameUpgradeable.GameState.Finished),
            "Should be dealing or finished after first continueDealer"
        );

        // If game finished, we're done
        if (stateAfterFirst == uint(GameUpgradeable.GameState.Finished)) {
            return;
        }

        assertEq(uint(game.state()), uint(GameUpgradeable.GameState.Dealing), "Should be dealing dealer hit");

        // Fulfill dealer hit with a low card
        randoms[0] = 2; // Dealer gets a 2
        game.testFulfill(3, randoms);

        assertEq(uint(game.state()), uint(GameUpgradeable.GameState.DealerTurn), "Should be back in dealer turn after hit");

        // Second continueDealer - dealer may need to hit again or finish
        vm.store(linkAddr, outer, bytes32(uint256(linkFee * 2))); // Extra LINK in case needed
        vm.prank(player);
        game.continueDealer();

        // Game should progress (either stay in DealerTurn, go to Dealing, or Finish)
        uint256 finalState = uint(game.state());
        assertTrue(
            finalState == uint(GameUpgradeable.GameState.DealerTurn) ||
            finalState == uint(GameUpgradeable.GameState.Dealing) ||
            finalState == uint(GameUpgradeable.GameState.Finished),
            "Game should be in a valid state after second continueDealer"
        );
    }

    // ============================================================================
    // TEST: Split then Double Down with continueDealer
    // ============================================================================

    function testSplitThenDoubleDownWithContinueDealer() public {
        // Complete initial deal with matching cards for split
        uint256[] memory randoms = new uint256[](1);
        randoms[0] = 0; // This should give matching cards
        game.testFulfill(1, randoms);

        if (uint(game.state()) == uint(GameUpgradeable.GameState.InsuranceOffer)) {
            vm.prank(player);
            game.skipInsurance();
        }

        // Approve and split
        vm.prank(player);
        gameToken.approve(address(game), betAmount);

        vm.prank(player);
        game.split();

        // Fulfill split VRF
        uint256[] memory splitRandoms = new uint256[](1);
        splitRandoms[0] = 50000;
        game.testFulfill(2, splitRandoms);

        bytes32 allowancesSlot = bytes32(uint256(1));
        bytes32 inner = keccak256(abi.encode(player, allowancesSlot));
        bytes32 outer = keccak256(abi.encode(address(game), inner));
        vm.store(linkAddr, outer, bytes32(uint256(linkFee * 2)));

        // Double down on first hand
        vm.prank(player);
        gameToken.approve(address(game), betAmount);

        vm.prank(player);
        game.doubleDown();

        // Fulfill double down VRF
        uint256[] memory ddRandoms = new uint256[](1);
        ddRandoms[0] = 99999;
        game.testFulfill(3, ddRandoms);

        // After first hand's double down, should be in PlayerTurn for second hand
        assertEq(uint(game.state()), uint(GameUpgradeable.GameState.PlayerTurn), "Should be player turn for second hand");

        // Double down on second hand
        vm.store(linkAddr, outer, bytes32(uint256(linkFee * 2)));
        vm.prank(player);
        gameToken.approve(address(game), betAmount);

        vm.prank(player);
        game.doubleDown();

        // Fulfill second double down VRF
        ddRandoms[0] = 88888;
        game.testFulfill(4, ddRandoms);

        // After second hand's double down, should be in DealerTurn
        assertEq(uint(game.state()), uint(GameUpgradeable.GameState.DealerTurn), "Should be dealer turn after all hands done");

        // Call continueDealer
        vm.prank(player);
        game.continueDealer();

        // Game should progress
        assertTrue(
            uint(game.state()) == uint(GameUpgradeable.GameState.DealerTurn) ||
            uint(game.state()) == uint(GameUpgradeable.GameState.Dealing) ||
            uint(game.state()) == uint(GameUpgradeable.GameState.Finished),
            "Game should progress after continueDealer"
        );
    }

    // ============================================================================
    // TEST: Player busts - still needs continueDealer (game will detect all busted)
    // ============================================================================

    function testPlayerBustNeedsContinueDealer() public {
        // Set up cards: Player will bust on hit
        uint8[] memory playerCards = new uint8[](2);
        playerCards[0] = 10;
        playerCards[1] = 10; // Total 20
        uint8[] memory dealerCards = new uint8[](2);
        dealerCards[0] = 2;
        dealerCards[1] = 3;
        vm.prank(player);
        game.testSetCards(playerCards, dealerCards);

        // Complete initial deal
        uint256[] memory randoms = new uint256[](1);
        randoms[0] = 12345;
        game.testFulfill(1, randoms);

        if (uint(game.state()) == uint(GameUpgradeable.GameState.InsuranceOffer)) {
            vm.prank(player);
            game.skipInsurance();
        }

        bytes32 allowancesSlot = bytes32(uint256(1));
        bytes32 inner = keccak256(abi.encode(player, allowancesSlot));
        bytes32 outer = keccak256(abi.encode(address(game), inner));
        vm.store(linkAddr, outer, bytes32(uint256(linkFee)));

        // Hit
        vm.prank(player);
        game.hit();

        // Fulfill hit with high card to bust
        randoms[0] = 10; // Player gets 10, total 30
        game.testFulfill(2, randoms);

        // After VRF callback, game should be in DealerTurn (not Finished)
        assertEq(uint(game.state()), uint(GameUpgradeable.GameState.DealerTurn), "Should be in dealer turn after player busts");
        
        // Call continueDealer to finish the game
        vm.prank(player);
        game.continueDealer();
        
        // Now game should be finished (dealer doesn't need to play when all hands busted)
        assertEq(uint(game.state()), uint(GameUpgradeable.GameState.Finished), "Game should be finished after continueDealer");
    }

    // ============================================================================
    // TEST: Dealer blackjack - no continueDealer needed
    // ============================================================================

    function testDealerBlackjackNoNeedForContinueDealer() public {
        // Set up cards: Dealer has blackjack
        uint8[] memory playerCards = new uint8[](2);
        playerCards[0] = 10;
        playerCards[1] = 9; // Total 19
        uint8[] memory dealerCards = new uint8[](2);
        dealerCards[0] = 1; // Ace
        dealerCards[1] = 10; // Blackjack
        vm.prank(player);
        game.testSetCards(playerCards, dealerCards);

        // Complete initial deal
        uint256[] memory randoms = new uint256[](1);
        randoms[0] = 12345;
        game.testFulfill(1, randoms);

        // Should offer insurance
        assertEq(uint(game.state()), uint(GameUpgradeable.GameState.InsuranceOffer));

        // Skip insurance
        vm.prank(player);
        game.skipInsurance();

        // After revealing dealer blackjack, game should finish
        assertEq(uint(game.state()), uint(GameUpgradeable.GameState.Finished), "Game should finish with dealer blackjack");
    }
}
