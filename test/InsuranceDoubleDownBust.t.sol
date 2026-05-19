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

/**
 * @title InsuranceDoubleDownBustTest
 * @notice Tests the specific scenario that was causing the stuck game:
 *         1. Player places insurance (dealer shows Ace)
 *         2. Player double downs
 *         3. Player BUSTS (gets card that makes score > 21)
 *         4. Game should transition to DealerTurn
 *         5. Player calls continueDealer() to finish the game
 * @dev This test verifies the ReentrancyGuardTransient fix
 */
contract InsuranceDoubleDownBustTest is Test {
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
        gameToken.buyTokens{value: 100 ether}();
        
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
    
    function testInsuranceDoubleDownBustThenContinueDealer() public {
        // Deploy a game directly
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
        
        // Register the game as active in the factory
        factory.testRegisterActiveGame(address(game));
        
        // Transfer tokens to game from factory
        vm.prank(address(factory));
        gameToken.transfer(address(game), betAmount * 11);
        
        // Give LINK to the game contract
        link.mint(address(game), 100 ether);

        vm.startPrank(player);
        
        // Approve game to spend player's tokens
        gameToken.approve(address(game), type(uint256).max);
        link.approve(address(game), type(uint256).max);
        
        // Set up scenario: player has 7, 6 (total 13)
        // Dealer shows Ace
        uint8[] memory playerCards = new uint8[](2);
        playerCards[0] = 7;  // 7
        playerCards[1] = 6;  // 6 - total 13
        uint8[] memory dealerUpcard = new uint8[](2);
        dealerUpcard[0] = 1;  // Ace (triggers insurance)
        dealerUpcard[1] = 10; // Hidden 10 (dealer will have 21)
        
        game.testSetCards(playerCards, dealerUpcard);
        game.setState(GameUpgradeable.GameState.InsuranceOffer);
        
        // Place insurance
        uint256 insuranceAmount = betAmount / 2;
        game.placeInsurance(insuranceAmount);
        
        console.log("=== After placing insurance ===");
        console.log("Game state:", uint(game.state()));
        assertEq(uint(game.state()), uint(GameUpgradeable.GameState.PlayerTurn), "Should be in PlayerTurn");
        
        // Mock VRF coordinator
        vm.mockCall(
            address(0x1),
            abi.encodeWithSelector(bytes4(keccak256("requestRandomWords((bytes32,uint256,uint16,uint32,uint32,bytes))"))),
            abi.encode(uint256(999))
        );
        
        // Double down
        game.doubleDown();
        
        console.log("=== After doubleDown ===");
        console.log("Game state:", uint(game.state()));
        assertEq(uint(game.state()), uint(GameUpgradeable.GameState.Dealing), "Should be Dealing");
        
        // Fulfill VRF with a card that busts the player
        // Random word will generate a high card (King = 52)
        uint256[] memory randomWords = new uint256[](1);
        randomWords[0] = 52; // This should give King (value 10) -> 7+6+10 = 23 BUST!
        game.testFulfill(999, randomWords);
        
        console.log("=== After VRF fulfillment (player busted) ===");
        uint8[] memory cards = game.getPlayerHandCards(0);
        console.log("Player hand cards count:", cards.length);
        console.log("Card 1:", cards[0]);
        console.log("Card 2:", cards[1]);
        console.log("Card 3:", cards[2]);
        console.log("Game state:", uint(game.state()));
        
        // After player busts with double down, should be in DealerTurn
        assertEq(uint(game.state()), uint(GameUpgradeable.GameState.DealerTurn), "Should be in DealerTurn after bust");
        assertEq(cards.length, 3, "Should have 3 cards");
        
        // THIS IS THE CRITICAL TEST: Can we call continueDealer() without reverting?
        // Before the ReentrancyGuardTransient fix, this would revert with InvalidState()
        console.log("=== Calling continueDealer() ===");
        game.continueDealer();
        
        console.log("=== After continueDealer() ===");
        console.log("Game state:", uint(game.state()));
        console.log("Final payout:", game.finalPayout());
        
        // Game should be finished now
        assertEq(uint(game.state()), uint(GameUpgradeable.GameState.Finished), "Should be Finished");
        
        // Player busted, so payout should be 0 (lost all bets)
        // Unless insurance paid out (dealer had blackjack with Ace + 10)
        uint256 finalPayout = game.finalPayout();
        console.log("Final payout:", finalPayout);
        
        // Dealer had Ace + 10 = Blackjack, so insurance pays 3:1
        // Insurance was 0.5 ETH, so payout should be 1.5 ETH
        assertEq(finalPayout, insuranceAmount * 3, "Insurance should pay 3:1 when dealer has blackjack");
        
        console.log("========================================");
        console.log("SUCCESS! continueDealer() works after insurance + double down + bust!");
        console.log("ReentrancyGuardTransient fix verified!");
        console.log("========================================");
        
        vm.stopPrank();
    }
}
