// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {GameUpgradeable} from "../src/GameUpgradeable.sol";
import {GameToken} from "../src/GameToken.sol";
import {TestableGame} from "./TestableGame.sol";
import {TestableGameFactory} from "./TestableGameFactory.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

contract MockLINK is ERC20 {
    constructor() ERC20("Mock LINK", "LINK") {
        _mint(msg.sender, 1000000 ether);
    }
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract InsuranceDoubleDownTest is Test {
    TestableGameFactory public factory;
    GameToken public gameToken;
    MockLINK public link;
    address public player = address(0x123);
    uint256 public betAmount = 1 ether;
    TestableGame public game;
    
    function setUp() public {
        // Deploy tokens
        gameToken = new GameToken();
        link = new MockLINK();
        
        // Buy tokens for liquidity
        vm.deal(address(this), 10000 ether);
        gameToken.buyTokens{value: 100 ether}(); // Gets 100k tokens
        
        // Deploy factory
        factory = new TestableGameFactory();
        
        // Initialize factory
        factory.initializeTest(
            address(0x1), // vrfCoordinator (mock)
            address(link),
            address(gameToken),
            1 ether, // linkFee
            0.1 ether, // minBet
            1, // subscriptionId
            address(0x2) // keeperAddress
        );
        
        // Transfer GameToken ownership to factory
        gameToken.transferOwnership(address(factory));
        
        // Give player tokens
        vm.deal(player, 100 ether);
        vm.prank(player);
        gameToken.buyTokens{value: 10 ether}();
        
        // Give link to player
        link.mint(player, 100 ether);
        
        // Add liquidity to factory
        uint256 liquidityTokens = gameToken.balanceOf(address(this));
        gameToken.transfer(address(factory), liquidityTokens);
        
        // Add POL reserve to back the tokens
        vm.deal(address(factory), 100 ether);
        vm.prank(address(factory));
        gameToken.topUpReserve{value: 100 ether}();
        
        vm.startPrank(player);
        gameToken.approve(address(factory), type(uint256).max);
        link.approve(address(factory), type(uint256).max);
        vm.stopPrank();
    }
    
    function testInsuranceThenDoubleDown() public {
        // Deploy a game directly for simpler testing
        game = new TestableGame();
        
        // Initialize it manually
        game.initializeTest(
            player,
            betAmount,
            address(factory),
            address(0x1), // vrfCoordinator (mock)
            address(gameToken),
            address(link)
        );
        
        // **CRITICAL FIX**: Register the game as active in the factory
        // This is why VRF was failing - the game wasn't in activeGames mapping!
        factory.testRegisterActiveGame(address(game));
        
        // Transfer tokens to game from factory
        vm.prank(address(factory));
        gameToken.transfer(address(game), betAmount * 11); // Max payout
        
        // Give LINK to the game contract for VRF requests
        link.mint(address(game), 100 ether);

        vm.startPrank(player);
        
        // Approve game to spend player's tokens for insurance and double down
        gameToken.approve(address(game), type(uint256).max);
        // ALSO approve game to spend LINK for VRF requests!
        link.approve(address(game), type(uint256).max);
        
        console.log("=== Token approval ===");
        console.log("Player address:", player);
        console.log("Game address:", address(game));
        console.log("Player token balance:", gameToken.balanceOf(player));
        console.log("Allowance for game (GameToken):", gameToken.allowance(player, address(game)));
        console.log("Allowance for game (LINK):", link.allowance(player, address(game)));
        
        // Manually set up the scenario with testSetCards
        uint8[] memory playerCards = new uint8[](2);
        playerCards[0] = 10; // 10
        playerCards[1] = 6;  // 6 - total 16
        uint8[] memory dealerUpcard = new uint8[](2);
        dealerUpcard[0] = 1;  // Ace (should trigger insurance)
        dealerUpcard[1] = 5;  // Hidden card
        
        game.testSetCards(playerCards, dealerUpcard);
        
        // Manually set state to InsuranceOffer
        game.setState(GameUpgradeable.GameState.InsuranceOffer);
        
        console.log("=== After setup ===");
        console.log("Game state:", uint(game.state()));
        uint8[] memory cards = game.getPlayerHandCards(0);
        console.log("Player hand cards count:", cards.length);
        console.log("Player card 1:", cards[0]);
        console.log("Player card 2:", cards[1]);
        uint8[] memory dealerCards = game.getDealerCards();
        console.log("Dealer cards count:", dealerCards.length);
        console.log("Dealer upcard:", dealerCards[0]);
        
        // Verify insurance is offered
        require(uint(game.state()) == uint(GameUpgradeable.GameState.InsuranceOffer), "Should offer insurance");
        
        // Place insurance (half of bet)
        uint256 insuranceAmount = betAmount / 2;
        console.log("=== Before placeInsurance ===");
        console.log("Insurance amount:", insuranceAmount);
        console.log("Allowance before insurance:", gameToken.allowance(player, address(game)));
        
        game.placeInsurance(insuranceAmount);
        
        console.log("=== After placing insurance ===");
        console.log("Allowance after insurance:", gameToken.allowance(player, address(game)));
        console.log("Game state:", uint(game.state()));
        cards = game.getPlayerHandCards(0);
        console.log("Player hand cards count:", cards.length);
        console.log("Player card 1:", cards[0]);
        console.log("Player card 2:", cards[1]);
        console.log("Hand bet amount:", game.getPlayerHandBet(0));
        
        // Should now be in PlayerTurn
        require(uint(game.state()) == uint(GameUpgradeable.GameState.PlayerTurn), "Should be in PlayerTurn");
        require(cards.length == 2, "Should have 2 cards");
        
        console.log("=== Testing ACTUAL doubleDown() function ===");
        console.log("Allowance before double down:", gameToken.allowance(player, address(game)));
        console.log("Player balance before double down:", gameToken.balanceOf(player));
        console.log("Game bet (from game.bet()):", game.bet());
        console.log("Hand bet (from playerHands[0]):", game.getPlayerHandBet(0));
        
        // Mock the VRF coordinator to return request ID
        vm.mockCall(
            address(0x1), // vrfCoordinator
            abi.encodeWithSelector(bytes4(keccak256("requestRandomWords((bytes32,uint256,uint16,uint32,uint32,bytes))"))),
            abi.encode(uint256(999)) // Return request ID 999
        );
        
        // NOW try the real doubleDown() - should work!
        game.doubleDown();
        
        console.log("=== After REAL doubleDown() call ===");
        console.log("Game state (should be Dealing):", uint(game.state()));
        console.log("New bet amount:", game.getPlayerHandBet(0));
        
        // Game should be in Dealing state, bet should be doubled
        assertEq(uint(game.state()), 1, "Should be in Dealing state");
        assertEq(game.getPlayerHandBet(0), betAmount * 2, "Bet should be doubled");
        
        // Fulfill the VRF to complete the double down
        uint256[] memory randomWords = new uint256[](1);
        randomWords[0] = 12345;
        game.testFulfill(999, randomWords);
        
        console.log("=== After VRF fulfillment ===");
        cards = game.getPlayerHandCards(0);
        console.log("Player hand cards count:", cards.length);
        
        assertEq(cards.length, 3, "Should have 3 cards after double down");
        
        console.log("========================================");
        console.log("SUCCESS! REAL doubleDown() works after insurance!");
        console.log("");
        console.log("KEY REQUIREMENTS for double down after insurance:");
        console.log("1. Game must be registered in factory.activeGames");
        console.log("2. Player must approve game contract for GameToken (bet amount)");
        console.log("3. Player must approve game contract for LINK (VRF fee)");
        console.log("");
        console.log("FRONTEND BUG IDENTIFIED:");
        console.log("When placing insurance, player approves insurance amount (bet/2)");
        console.log("But double down needs full bet amount approved!");
        console.log("Frontend should check allowance before double down and prompt if insufficient");
        console.log("========================================");
        
        vm.stopPrank();
    }
}
