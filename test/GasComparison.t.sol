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

/**
 * @title GasComparison
 * @notice Compares gas costs between different game actions
 */

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

contract GasComparisonTest is Test {
    TestableGameFactory public factory;
    GameToken public gameToken;
    MockLINK public link;
    address public player;
    address public vrfCoordinator = 0x343300b5d84D444B2ADc9116FEF1bED02BE49Cf2;
    address public linkAddr = 0x0Fd9e8d3aF1aaee056EB9e802c3A762a667b1904;

    uint256 public betAmount = 1 * 10**18; // 1 GameToken
    uint256 public linkFee = 0.005 ether;
    
    TestableGame public gameHit;
    TestableGame public gameDoubleDown;

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
        
        // Mint initial tokens for owner with POL backing
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
            1 * 10**18, // minBet
            1, // subscriptionId (mock)
            address(0x1234) // keeperAddress (mock)
        );
        
        // Transfer GameToken ownership to factory
        gameToken.transferOwnership(address(factory));
        
        player = address(this);

        // TestableGameFactory needs tokens in its balance
        uint256 liquidityAmount = 10000 * 10**18;
        uint256 polNeeded = liquidityAmount / 1000;
        vm.deal(address(this), polNeeded * 2);
        gameToken.buyTokens{value: polNeeded}();
        gameToken.transfer(address(factory), liquidityAmount);
        vm.deal(address(factory), polNeeded);
        vm.prank(address(factory));
        gameToken.topUpReserve{value: polNeeded}();

        // Set LINK balance for player and factory
        bytes32 balancesSlot = bytes32(uint256(0));
        bytes32 playerBalanceSlot = keccak256(abi.encode(player, balancesSlot));
        vm.store(linkAddr, playerBalanceSlot, bytes32(uint256(100 ether)));
        
        bytes32 factoryBalanceSlot = keccak256(abi.encode(address(factory), balancesSlot));
        vm.store(linkAddr, factoryBalanceSlot, bytes32(uint256(100 ether)));
        
        // Set LINK allowance from player to factory
        bytes32 allowancesSlot = bytes32(uint256(1));
        bytes32 inner = keccak256(abi.encode(player, allowancesSlot));
        bytes32 outer = keccak256(abi.encode(address(factory), inner));
        vm.store(linkAddr, outer, bytes32(uint256(100 ether)));
    }

    function testGasComparison_HitVsDoubleDown() public {
        console.log("\n=== GAS COMPARISON: HIT vs DOUBLE DOWN ===\n");
        
        // Test 1: Regular HIT
        uint256 gasHit = _testHitAction();
        console.log("Gas used for HIT:         ", gasHit);
        
        // Test 2: Double Down
        uint256 gasDoubleDown = _testDoubleDownAction();
        console.log("Gas used for DOUBLE DOWN: ", gasDoubleDown);
        
        // Calculate difference
        uint256 difference = gasDoubleDown > gasHit ? gasDoubleDown - gasHit : gasHit - gasDoubleDown;
        uint256 percentIncrease = (difference * 100) / gasHit;
        
        console.log("\n--- RESULTS ---");
        console.log("Difference:               ", difference);
        console.log("Percent increase:         ", percentIncrease, "%");
        
        // Calculate recommended multiplier
        uint256 multiplierNeeded = ((gasDoubleDown * 100) / gasHit);
        console.log("Actual multiplier needed:  1.", multiplierNeeded - 100);
        
        if (percentIncrease > 30) {
            console.log("\nRECOMMENDATION: Use 1.5x gas multiplier for doubleDown");
        } else if (percentIncrease > 15) {
            console.log("\nRECOMMENDATION: Use 1.3x gas multiplier for doubleDown");
        } else {
            console.log("\nRECOMMENDATION: Use 1.2x gas multiplier is sufficient");
        }
    }
    
    function _testHitAction() internal returns (uint256) {
        // Approve GameToken for bet
        gameToken.approve(address(factory), betAmount);
        
        // Create game
        factory.createGame(betAmount);
        address[] memory games = factory.getPlayerGames(player);
        gameHit = TestableGame(payable(games[games.length - 1]));

        // Set LINK balance and allowance for game contract
        bytes32 balancesSlot = bytes32(uint256(0));
        bytes32 gameBalanceSlot = keccak256(abi.encode(address(gameHit), balancesSlot));
        vm.store(linkAddr, gameBalanceSlot, bytes32(uint256(100 ether)));
        
        bytes32 allowancesSlot = bytes32(uint256(1));
        bytes32 inner = keccak256(abi.encode(player, allowancesSlot));
        bytes32 outer = keccak256(abi.encode(address(gameHit), inner));
        vm.store(linkAddr, outer, bytes32(uint256(100 ether)));
        
        // Fulfill initial deal
        uint256[] memory randoms = new uint256[](1);
        randoms[0] = 12345;
        gameHit.testFulfill(1, randoms);

        // Skip insurance if offered
        if (uint(gameHit.state()) == uint(GameUpgradeable.GameState.InsuranceOffer)) {
            vm.prank(player);
            gameHit.skipInsurance();
        }

        // Set LINK allowance for hit
        vm.store(linkAddr, outer, bytes32(uint256(linkFee)));

        // Record gas for HIT action
        vm.prank(player);
        uint256 gasBefore = gasleft();
        gameHit.hit();
        uint256 gasUsed = gasBefore - gasleft();
        
        return gasUsed;
    }
    
    function _testDoubleDownAction() internal returns (uint256) {
        // Approve GameToken for bet
        gameToken.approve(address(factory), betAmount);
        
        // Create game
        factory.createGame(betAmount);
        address[] memory games = factory.getPlayerGames(player);
        gameDoubleDown = TestableGame(payable(games[games.length - 1]));

        // Set LINK balance and allowance for game contract
        bytes32 balancesSlot = bytes32(uint256(0));
        bytes32 gameBalanceSlot = keccak256(abi.encode(address(gameDoubleDown), balancesSlot));
        vm.store(linkAddr, gameBalanceSlot, bytes32(uint256(100 ether)));
        
        bytes32 allowancesSlot = bytes32(uint256(1));
        bytes32 inner = keccak256(abi.encode(player, allowancesSlot));
        bytes32 outer = keccak256(abi.encode(address(gameDoubleDown), inner));
        vm.store(linkAddr, outer, bytes32(uint256(100 ether)));
        
        // Fulfill initial deal
        uint256[] memory randoms = new uint256[](1);
        randoms[0] = 67890;
        gameDoubleDown.testFulfill(1, randoms);

        // Skip insurance if offered
        if (uint(gameDoubleDown.state()) == uint(GameUpgradeable.GameState.InsuranceOffer)) {
            vm.prank(player);
            gameDoubleDown.skipInsurance();
        }

        // Set LINK allowance for double down
        vm.store(linkAddr, outer, bytes32(uint256(linkFee)));
        
        // Approve gameToken for double down bet
        vm.prank(player);
        gameToken.approve(address(gameDoubleDown), betAmount);

        // Record gas for DOUBLE DOWN action
        vm.prank(player);
        uint256 gasBefore = gasleft();
        gameDoubleDown.doubleDown();
        uint256 gasUsed = gasBefore - gasleft();
        
        return gasUsed;
    }
}
