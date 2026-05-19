// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20; // Minimum 0.8.20 for transient storage

import {GameUpgradeable} from "./GameUpgradeable.sol";
import {GameImplementation} from "./GameImplementation.sol";
import {GameToken} from "./GameToken.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {FactoryGameCreationLib} from "./libraries/FactoryGameCreationLib.sol";
import {FactoryViewLib} from "./libraries/FactoryViewLib.sol";
import {FactoryKeeperLib} from "./libraries/FactoryKeeperLib.sol";
import {FactoryConfigLib} from "./libraries/FactoryConfigLib.sol";
import {FactoryInitLib} from "./libraries/FactoryInitLib.sol";
import {VRFRequestLogic} from "./libraries/VRFRequestLogic.sol";
import {VRFV2PlusClient} from "lib/foundry-chainlink-toolkit/lib/chainlink-brownie-contracts/contracts/src/v0.8/dev/vrf/libraries/VRFV2PlusClient.sol";
import {IVRFCoordinatorV2Plus} from "lib/foundry-chainlink-toolkit/lib/chainlink-brownie-contracts/contracts/src/v0.8/dev/interfaces/IVRFCoordinatorV2Plus.sol";

/**
 * @title GameFactoryUpgradeable
 * @notice UUPS Upgradeable factory for creating and managing blackjack games
 * @dev Uses OpenZeppelin's UUPS pattern with ERC-7201 namespaced storage
 *      Uses GameToken (custom ERC20)
 *      
 * Game contracts are NOT upgradeable (ephemeral, per-game)
 * UPGRADE PROCESS:
 * 1. Deploy new implementation
 * 2. Call upgradeToAndCall() on proxy
 * 3. Only owner can upgrade
 */
contract GameFactoryUpgradeable is 
    Initializable, 
    UUPSUpgradeable, 
    OwnableUpgradeable, 
    ReentrancyGuard 
{
    // VRF Coordinator (manually stored, not inherited from VRFConsumerBaseV2Plus)
    IVRFCoordinatorV2Plus internal s_vrfCoordinator;
    /// @custom:storage-location erc7201:blackjack.factory.storage
    struct FactoryStorage {
        address vrfCoordinator;
        address linkAddress;
        address gameTokenAddress;  // GameToken (ERC20) for betting
        address gameImplementation;  // Master game implementation for clones
        uint256 linkFee;
        uint256 minBet;
        uint256 lockedLiquidity;     // POL value locked in active games (not token amount)
        mapping(address => address[]) playerGames;
        mapping(address => bool) activeGames;
        mapping(address => uint256) gameReservedLiquidity;  // POL value reserved per game (not token amount)
        string version;
        
        // For Chainlink Automation enumeration
        address[] allGames;  // Array of all game addresses ever created
        mapping(address => uint256) gameToIndex;  // Game address => index in allGames
        
        // Concurrency guarantees
        uint256 minConcurrentPlayers;  // Minimum number of players that must be able to play (default: 5)
        
        // Chainlink VRF subscription ID
        uint256 subscriptionId;
        
        // Chainlink Keeper address
        address keeperAddress;
        
        // VRF request routing: requestId => game address
        mapping(uint256 => address) vrfRequestToGame;
        
        // VRF callback gas limit (configurable for upgrades)
        uint32 vrfCallbackGasLimit;
        
        // Storage gap for future upgrades
        uint256[44] __gap;  // Decreased by 5 after adding gameImplementation, subscriptionId, keeperAddress, vrfRequestToGame, and vrfCallbackGasLimit
    }
    
    // Blackjack maximum payout multiplier (FIXED by game rules)
    // Worst case: Insurance (2:1) + Split + Double + Blackjack (1.5:1) = 11x
    uint256 internal constant BLACKJACK_MAX_PAYOUT_MULTIPLIER = 11;

    // Standard ERC-7201 namespaced storage location
    // Simplified to: bytes32(uint256(keccak256("blackjack.factory.storage")) - 1)
    bytes32 private constant FACTORY_STORAGE_LOCATION = 
        0x2ab489362577e610d6c162e0971e91941ae096a79cb7e919bae03df3d243279b;

    function _getFactoryStorage() internal pure returns (FactoryStorage storage $) {
        assembly {
            // Return pointer `$` point to our special, hardcoded location.
            $.slot := FACTORY_STORAGE_LOCATION
        }
    }

    event GameCreated(address indexed player, address gameAddress, uint256 bet);
    event LiquidityAdded(address indexed provider, uint256 amount);
    event LiquidityWithdrawn(address indexed provider, uint256 amount);
    event GameFinalized(address indexed gameAddress, uint256 returned);
    event FundsTransferredToGame(address indexed gameAddress, uint256 amount);
    event FactoryUpgraded(address indexed newImplementation, string newVersion);
    event MinConcurrentPlayersUpdated(uint256 oldValue, uint256 newValue);
    event MinBetUpdated(uint256 oldValue, uint256 newValue);
    event LinkFeeUpdated(uint256 oldValue, uint256 newValue);
    event VRFRequested(uint256 indexed requestId, address indexed gameAddress);
    event VRFFulfilled(uint256 indexed requestId, address indexed gameAddress);
    event SubscriptionIdUpdated(uint256 newSubscriptionId);
    event VRFCoordinatorUpdated(address newVrfCoordinator);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        // Lock implementation contract
        _disableInitializers();
    }

    /**
     * @notice Initialize the upgradeable factory contract
     * @param _vrfCoordinator Chainlink VRF Coordinator address
     * @param _linkAddress LINK token address
     * @param _gameTokenAddress GameToken (ERC20) address for betting
     * @param _gameImplementation Address of deployed GameImplementation
     * @param _linkFee LINK fee per VRF request
     * @param _minBet Minimum bet amount (in GameToken)
     * @param _subscriptionId Chainlink VRF subscription ID
     * @param _keeperAddress Chainlink Keeper address (can be address(0) if not using automation)
     */
    function initialize(
        address _vrfCoordinator,
        address _linkAddress,
        address _gameTokenAddress,
        address _gameImplementation,
        uint256 _linkFee,
        uint256 _minBet,
        uint256 _subscriptionId,
        address _keeperAddress
    ) public initializer {
        // Validate parameters
        FactoryInitLib.InitParams memory params = FactoryInitLib.InitParams({
            vrfCoordinator: _vrfCoordinator,
            linkAddress: _linkAddress,
            gameTokenAddress: _gameTokenAddress,
            linkFee: _linkFee,
            minBet: _minBet
        });
        FactoryInitLib.validateInitParams(params);
        require(_gameImplementation != address(0), "Game implementation cannot be zero address");
        
        __Ownable_init(msg.sender);

        // Initialize VRF Consumer with the VRF coordinator
        // Note: We can't call __VRFConsumerBaseV2Plus_init because it doesn't exist in upgradeable pattern
        // Instead, we set s_vrfCoordinator directly in storage
        s_vrfCoordinator = IVRFCoordinatorV2Plus(_vrfCoordinator);

        FactoryStorage storage $ = _getFactoryStorage();
        
        // Set storage values
        (
            $.vrfCoordinator,
            $.linkAddress,
            $.gameTokenAddress,
            $.gameImplementation,
            $.linkFee,
            $.minBet,
            $.minConcurrentPlayers,
            $.version
        ) = FactoryInitLib.setInitialStorage(params, _gameImplementation);
        
        // Set subscription ID and keeper address
        $.subscriptionId = _subscriptionId;
        $.keeperAddress = _keeperAddress;
        
        // Set default VRF callback gas limit
        // CRITICAL: Set HIGH gas limit for safety - Chainlink only charges for gas ACTUALLY USED!
        // Factory receives VRF -> forwards to game -> game processes randomness + library calls
        // Maximum allowed by Chainlink is 2.5M, we use 2M for safety margin
        // This covers ALL possible code paths (hit/stand/split/dealer/initial deal)
        // You are ONLY charged for actual gas consumed, not the limit!
        $.vrfCallbackGasLimit = 2000000; // Default: 2M gas (safe for all scenarios)
        
        // Approve factory to spend its own tokens (needed for library external calls)
        // Libraries use external functions which require approval even for self-transfers
        GameToken(payable(_gameTokenAddress)).approve(address(this), type(uint256).max);
    }

    /**
     * @notice Reinitialize for version 2
     * @dev Only callable during upgrade, adds new features
     */
    function initializeV2() public reinitializer(2) onlyProxy {
        FactoryStorage storage $ = _getFactoryStorage();
        $.version = "2.0.0";
    }

    /**
     * @notice Required by UUPS - only owner can upgrade
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {
        FactoryStorage storage $ = _getFactoryStorage();
        emit FactoryUpgraded(newImplementation, $.version);
    }

    modifier onlyActiveGame() {
        FactoryStorage storage $ = _getFactoryStorage();
        require($.activeGames[msg.sender], "Not an active game");
        _;
    }

    /**
     * @notice Get total liquidity (factory's token balance, must be POL-backed)
     * @dev Factory liquidity = tokens the factory owns and can transfer to games
     *      These tokens must be backed by POL in GameToken for winners to redeem
     *      Use addLiquidityWithPOL() to ensure proper backing
     */
    /**
     * @notice Get total liquidity in POL (from GameToken reserves)
     * @dev Liquidity is measured in POL reserves, not token balances
     *      This represents the total POL available to back all tokens
     */
    function totalLiquidity() public view returns (uint256) {
        FactoryStorage storage $ = _getFactoryStorage();
        return FactoryViewLib.totalLiquidity($.gameTokenAddress);
    }

    /**
     * @notice Get available liquidity in POL (not locked in games)
     * @dev Available = total POL reserves - POL locked in active games
     *      Locked liquidity is tracked in POL value, not token amount
     */
    function availableLiquidity() public view returns (uint256) {
        FactoryStorage storage $ = _getFactoryStorage();
        return FactoryViewLib.availableLiquidity($.gameTokenAddress, $.lockedLiquidity, address(this));
    }

    /**
     * @notice Add liquidity by providing POL (increases backing reserve)
     * @dev CRITICAL: Factory does NOT receive tokens! This just adds POL to GameToken reserve.
     *      The POL increases the "excess" available for backing new games.
     *      
     *      How it works:
     *      1. Owner sends POL to this function
     *      2. POL is forwarded to GameToken contract (increases reserve)
     *      3. NO tokens are minted - this is pure POL reserve increase
     *      4. More POL = higher max bet size for players
     *      
     *      When to use: After players lose and tokens are burned, there's no excess POL.
     *                   Use this to add more POL backing so players can bet again.
     */
    function addLiquidityWithPOL() external payable onlyOwner nonReentrant {
        FactoryStorage storage $ = _getFactoryStorage();
        require(msg.value > 0, "Must send POL");
        
        GameToken token = GameToken(payable($.gameTokenAddress));
        
        // Send POL to GameToken reserve WITHOUT minting tokens
        // This increases the backing ratio and creates "excess POL" for new games
        token.topUpReserve{value: msg.value}();
            
        emit LiquidityAdded(msg.sender, msg.value);
    }

    /**
     * @notice [DEPRECATED - Factory no longer holds tokens]
     * @dev Factory doesn't need to replenish tokens because it doesn't hold any.
     *      When players lose, tokens are burned and POL becomes "excess".
     *      This excess POL automatically increases max bet size.
     *      Use addLiquidityWithPOL() to add more POL if needed.
     */
    function replenishBankrollFromExcess() external view onlyOwner returns (uint256) {
        revert("Factory no longer holds tokens - use addLiquidityWithPOL() to add POL backing");
    }

    /**
     * @notice Calculate maximum POL that can be safely withdrawn as profit
     * @return maxWithdrawable Maximum POL that can be withdrawn without underbacking GameToken
     * @dev This considers:
     *      1. Factory tokens not locked in games
     *      2. Excess POL in GameToken reserve beyond what's needed to back all tokens
     *      Leaving more POL in the reserve allows players to make larger bets
     */
    function getMaxWithdrawableProfitPOL() public view returns (uint256 maxWithdrawable) {
        FactoryStorage storage $ = _getFactoryStorage();
        return FactoryViewLib.getMaxWithdrawableProfitPOL(
            $.gameTokenAddress,
            $.lockedLiquidity,
            address(this)
        );
    }

    /**
     * @notice Withdraw POL profits from excess reserves
     * @param polAmount Amount of POL to withdraw (use getMaxWithdrawableProfitPOL() to check max)
     * @dev CRITICAL: Factory doesn't hold tokens, so we withdraw directly from GameToken reserve
     *      Only excess POL can be withdrawn (POL not needed for backing existing tokens)
     *      TIP: Withdraw less than max to leave more POL for larger player bets
     *      
     *      How it works:
     *      1. Calculate excess POL in GameToken (total POL - backing needed - locked)
     *      2. Transfer excess POL from GameToken to owner
     *      3. No tokens are involved - pure POL transfer
     */
    function withdrawProfits(uint256 polAmount) external onlyOwner nonReentrant {
        FactoryStorage storage $ = _getFactoryStorage();
        uint256 maxWithdrawable = getMaxWithdrawableProfitPOL();
        
        require(polAmount > 0, "Must withdraw some POL");
        require(polAmount <= maxWithdrawable, "Exceeds maximum withdrawable profit");
        
        GameToken token = GameToken(payable($.gameTokenAddress));
        
        // Verify reserve will stay healthy
        uint256 currentReserve = address(token).balance;
        uint256 remainingReserve = currentReserve - polAmount;
        uint256 currentTotalSupply = token.totalSupply();
        uint256 polNeeded = currentTotalSupply / token.TOKENS_PER_POL();
        
        require(remainingReserve >= polNeeded, "Withdrawal would leave GameToken underbacked");
        
        // Withdraw POL directly from GameToken reserve (owner-only function)
        token.withdrawPOL(owner(), polAmount);
        
        emit LiquidityWithdrawn(owner(), polAmount);
    }

    /**
     * @notice Create a new game with liquidity from POL reserves (NOT factory token balance!)
     * @param bet Bet amount in GameToken (BJT)
     * @dev CRITICAL LIQUIDITY MODEL:
     *      1. Player sends their bet in BJT tokens to game
     *      2. Factory MINTS additional tokens to game (backed by POL in GameToken contract)
     *      3. If player wins: game pays out from its token balance
     *      4. If player loses: game BURNS all remaining tokens
     *      5. Burned tokens reduce supply, making POL "excess" and available for new games
     *      
     *      Factory NEVER holds BJT tokens - only GameToken contract holds POL backing!
     *      Max bet is calculated from available POL backing (not factory token balance)
     */
    function createGame(uint256 bet) external virtual nonReentrant returns (address) {
        FactoryStorage storage $ = _getFactoryStorage();
        require(bet >= $.minBet, "Bet too small");
        require(bet <= getMaxBet(), "Bet exceeds maximum");
        
        // Calculate POL needed to back worst-case payout
        GameToken token = GameToken(payable($.gameTokenAddress));
        uint256 maxPayoutTokens = bet * BLACKJACK_MAX_PAYOUT_MULTIPLIER;
        uint256 requiredPOL = maxPayoutTokens / token.TOKENS_PER_POL();
        
        // Verify POL backing is available
        uint256 totalPOL = address(token).balance;
        uint256 totalSupply = token.totalSupply();
        uint256 polNeededForBacking = totalSupply / token.TOKENS_PER_POL();
        uint256 excessPOL = totalPOL > polNeededForBacking ? totalPOL - polNeededForBacking : 0;
        require(excessPOL >= requiredPOL, "Insufficient POL backing for this bet");
        
        // Create minimal proxy clone
        address gameAddress = Clones.clone($.gameImplementation);
        
        // Initialize the cloned game
        GameImplementation(payable(gameAddress)).initializeClone(
            msg.sender,
            bet,
            address(this),
            $.gameTokenAddress,
            $.linkAddress
        );
        
        // Track the game
        $.playerGames[msg.sender].push(gameAddress);
        $.activeGames[gameAddress] = true;
        $.gameToIndex[gameAddress] = $.allGames.length;
        $.allGames.push(gameAddress);
        $.gameReservedLiquidity[gameAddress] = requiredPOL;
        
        // Transfer player's bet from player to game
        require(token.transferFrom(msg.sender, gameAddress, bet), "Player bet transfer failed");
        
        // Mint additional tokens to game (backed by POL in GameToken contract)
        // These will be either paid out to player if they win, or burned if they lose
        uint256 factoryContribution = maxPayoutTokens - bet;
        if (factoryContribution > 0) {
            token.mintToGame(gameAddress, factoryContribution);
        }
        
        // Player pays LINK fee
        require(IERC20($.linkAddress).transferFrom(msg.sender, gameAddress, $.linkFee), "LINK transfer failed");
        
        // Start the game
        GameImplementation(payable(gameAddress)).startGame();
        
        $.lockedLiquidity += requiredPOL;
        
        emit GameCreated(msg.sender, gameAddress, bet);
        emit FundsTransferredToGame(gameAddress, maxPayoutTokens);
        
        return gameAddress;
    }

    /**
     * @notice Called by game contract when it finishes naturally (not via expiration)
     * @dev Unlocks reserved liquidity so it can be used for new games or withdrawn as profit
     */
    function notifyGameFinished() external onlyActiveGame nonReentrant {
        FactoryStorage storage $ = _getFactoryStorage();
        $.lockedLiquidity = FactoryGameCreationLib.handleGameFinished(
            msg.sender,
            $.activeGames,
            $.gameReservedLiquidity,
            $.lockedLiquidity
        );
        
        emit GameFinalized(msg.sender, 0);
    }

    /**
     * @notice Set the keeper address
     * @param _keeperAddress New keeper address
     * @dev Only callable by owner
     */
    function setKeeperAddress(address _keeperAddress) external onlyOwner {
        FactoryStorage storage $ = _getFactoryStorage();
        $.keeperAddress = _keeperAddress;
    }
    
    /**
     * @notice Get the keeper address
     * @return Current keeper address
     */
    function keeperAddress() external view returns (address) {
        FactoryStorage storage $ = _getFactoryStorage();
        return $.keeperAddress;
    }
    
    /**
     * @notice Get the VRF subscription ID
     * @return Current VRF subscription ID
     */
    function subscriptionId() external view returns (uint256) {
        FactoryStorage storage $ = _getFactoryStorage();
        return $.subscriptionId;
    }

    /**
     * @notice Set the VRF callback gas limit
     * @param _gasLimit The gas limit for VRF callbacks
     * @dev Only owner can update. Use this to adjust if callbacks are failing due to gas limits
     */
    function setVRFCallbackGasLimit(uint32 _gasLimit) external onlyOwner {
        require(_gasLimit >= 100000, "Gas limit too low");
        require(_gasLimit <= 2500000, "Gas limit too high");
        FactoryStorage storage $ = _getFactoryStorage();
        $.vrfCallbackGasLimit = _gasLimit;
    }
    
    /**
     * @notice Get the VRF callback gas limit
     * @return Current VRF callback gas limit
     */
    function vrfCallbackGasLimit() external view returns (uint32) {
        FactoryStorage storage $ = _getFactoryStorage();
        return $.vrfCallbackGasLimit;
    }

    function getPlayerGames(address player) external view returns (address[] memory) {
        FactoryStorage storage $ = _getFactoryStorage();
        return FactoryConfigLib.getPlayerGames($.playerGames, player);
    }

    /**
     * @notice Get factory liquidity status
     * @return total Total POL liquidity (from GameToken reserves)
     * @return available Available POL liquidity for new games
     * @return locked POL liquidity locked in active games
     * @return maxBet Current maximum bet per player (in tokens)
     */
    function getLiquidityStatus() external view returns (
        uint256 total,
        uint256 available,
        uint256 locked,
        uint256 maxBet
    ) {
        FactoryStorage storage $ = _getFactoryStorage();
        return (
            FactoryViewLib.totalLiquidity($.gameTokenAddress),
            FactoryViewLib.availableLiquidity($.gameTokenAddress, $.lockedLiquidity, address(this)),
            $.lockedLiquidity,
            FactoryViewLib.getMaxBet($.gameTokenAddress, $.lockedLiquidity, $.minConcurrentPlayers, address(this))
        );
    }

    /**
     * @notice Get maximum bet size to guarantee minimum concurrent players
     * @dev Formula accounts for the fact that player bets ADD to liquidity:
     *      For N players betting B each:
     *      - Total added: N × B (in tokens)
     *      - Total locked: N × B × 11 (in POL value) - 11x is fixed by blackjack rules
     *      - Constraint: initialLiquidity (POL) ≥ N×B×(11-1) (in POL)
     *      - Therefore: maxBet = (availableLiquidity_POL × TOKENS_PER_POL) / (N × 10)
     *      
     *      Example with 100 POL, 5 players, 11x multiplier:
     *      - maxBet = (100 POL × 1000) / (5 × 10) = 2,000 tokens per player
     *      - 5 players bet 2,000 tokens each = 10 POL added
     *      - Total POL = 110
     *      - Total locked = 5 × 2 POL × 11 = 110 POL ✓ exactly fits
     */
    function getMaxBet() public view returns (uint256) {
        FactoryStorage storage $ = _getFactoryStorage();
        return FactoryViewLib.getMaxBet(
            $.gameTokenAddress,
            $.lockedLiquidity,
            $.minConcurrentPlayers,
            address(this)
        );
    }

    /**
     * @notice Check if factory can support a bet of given size
     * @param bet The bet amount to check (in tokens)
     * @return Whether the bet is within acceptable limits
     */
    function canSupportBet(uint256 bet) public view returns (bool) {
        FactoryStorage storage $ = _getFactoryStorage();
        if (bet < $.minBet) return false;
        uint256 maxBet = getMaxBet();
        return bet <= maxBet;
    }

    /**
     * @notice Get detailed information about bet feasibility
     * @param bet The bet amount to check (in tokens)
     * @return isValid Whether bet is valid and can be accepted
     * @return reason Human-readable reason if bet is invalid
     * @return requiredLiquidity Amount of POL liquidity needed for this bet
     * @return currentMaxBet Current maximum bet allowed (in tokens)
     */
    function getBetFeasibility(uint256 bet) public view returns (
        bool isValid,
        string memory reason,
        uint256 requiredLiquidity,
        uint256 currentMaxBet
    ) {
        FactoryStorage storage $ = _getFactoryStorage();
        GameToken token = GameToken(payable($.gameTokenAddress));
        
        currentMaxBet = getMaxBet();
        requiredLiquidity = (bet * BLACKJACK_MAX_PAYOUT_MULTIPLIER) / token.TOKENS_PER_POL();
        uint256 available = availableLiquidity();
        
        if (bet < $.minBet) {
            return (false, "Bet below minimum", requiredLiquidity, currentMaxBet);
        }
        
        if (bet > currentMaxBet) {
            return (false, "Bet exceeds maximum", requiredLiquidity, currentMaxBet);
        }
        
        if (available < requiredLiquidity) {
            return (false, "Insufficient liquidity", requiredLiquidity, currentMaxBet);
        }
        
        return (true, "Bet is valid", requiredLiquidity, currentMaxBet);
    }

    /**
     * @notice Get the amount of POL liquidity required for a given bet
     * @param bet The bet amount (in tokens)
     * @return Amount of POL liquidity that would be reserved
     */
    function getRequiredLiquidity(uint256 bet) public view returns (uint256) {
        FactoryStorage storage $ = _getFactoryStorage();
        GameToken token = GameToken(payable($.gameTokenAddress));
        return (bet * BLACKJACK_MAX_PAYOUT_MULTIPLIER) / token.TOKENS_PER_POL();
    }

    /**
     * @notice Calculate how many more games can be created at a given bet size
     * @param bet The bet amount per game (in tokens)
     * @return Number of additional games that can be created
     */
    function getRemainingCapacity(uint256 bet) public view returns (uint256) {
        if (bet == 0) return 0;
        FactoryStorage storage $ = _getFactoryStorage();
        GameToken token = GameToken(payable($.gameTokenAddress));
        uint256 availablePOL = availableLiquidity();
        // Each game locks (bet × 10) in POL value (player contributes 1×, factory 10×)
        uint256 requiredPOLPerGame = (bet * (BLACKJACK_MAX_PAYOUT_MULTIPLIER - 1)) / token.TOKENS_PER_POL();
        return requiredPOLPerGame > 0 ? availablePOL / requiredPOLPerGame : 0;
    }

    /**
     * @notice Get comprehensive liquidity statistics
     * @return total Total POL liquidity in factory (from GameToken reserves)
     * @return available Available POL liquidity for new games
     * @return locked POL liquidity locked in active games
     * @return maxBet Current maximum bet per player (in tokens)
     * @return minBet Minimum bet required (in tokens)
     * @return capacityAt90Percent How many games at 90% of max bet
     */
    function getLiquidityStats() public view returns (
        uint256 total,
        uint256 available,
        uint256 locked,
        uint256 maxBet,
        uint256 minBet,
        uint256 capacityAt90Percent
    ) {
        FactoryStorage storage $ = _getFactoryStorage();
        
        total = FactoryViewLib.totalLiquidity($.gameTokenAddress);
        available = FactoryViewLib.availableLiquidity($.gameTokenAddress, $.lockedLiquidity, address(this));
        locked = $.lockedLiquidity;
        maxBet = getMaxBet();
        minBet = $.minBet;
        
        // Calculate capacity at 90% of max bet
        if (maxBet > 0) {
            uint256 betAt90 = (maxBet * 90) / 100;
            if (betAt90 > 0) {
                GameToken token = GameToken(payable($.gameTokenAddress));
                uint256 requiredPerGame = (betAt90 * (BLACKJACK_MAX_PAYOUT_MULTIPLIER - 1)) / token.TOKENS_PER_POL();
                capacityAt90Percent = available / requiredPerGame;
            }
        }
    }

    /**
     * @notice Get contract version
     */
    function setMinConcurrentPlayers(uint256 _minConcurrentPlayers) external onlyOwner {
        FactoryStorage storage $ = _getFactoryStorage();
        uint256 oldValue = $.minConcurrentPlayers;
        $.minConcurrentPlayers = FactoryConfigLib.setMinConcurrentPlayers(
            _minConcurrentPlayers,
            oldValue
        );
        emit MinConcurrentPlayersUpdated(oldValue, _minConcurrentPlayers);
    }

    /**
     * @notice Set minimum bet amount (owner only)
     * @param _minBet New minimum bet in GameToken wei (e.g., 1e18 = 1 token)
     */
    function setMinBet(uint256 _minBet) external onlyOwner {
        require(_minBet > 0, "Min bet must be positive");
        FactoryStorage storage $ = _getFactoryStorage();
        uint256 oldValue = $.minBet;
        $.minBet = _minBet;
        emit MinBetUpdated(oldValue, _minBet);
    }

    /**
     * @notice Set LINK fee for VRF requests (owner only)
     * @param _linkFee New LINK fee in wei (e.g., 1e17 = 0.1 LINK)
     * @dev Update this if Polygon Amoy changes VRF costs
     */
    function setLinkFee(uint256 _linkFee) external onlyOwner {
        require(_linkFee > 0, "LINK fee must be positive");
        FactoryStorage storage $ = _getFactoryStorage();
        uint256 oldValue = $.linkFee;
        $.linkFee = _linkFee;
        emit LinkFeeUpdated(oldValue, _linkFee);
    }

    /**
     * @notice Set VRF subscription ID (owner only)
     * @param _subscriptionId New VRF subscription ID
     * @dev Update this if the Chainlink VRF subscription changes
     */
    function setSubscriptionId(uint256 _subscriptionId) external onlyOwner {
        FactoryStorage storage $ = _getFactoryStorage();
        $.subscriptionId = _subscriptionId;
        
        emit SubscriptionIdUpdated(_subscriptionId);
    }

    /**
     * @notice Set the VRF Coordinator address
     * @dev Only callable by owner. Needed after upgrades if VRF coordinator wasn't preserved.
     */
    function setVRFCoordinator(address _vrfCoordinator) external onlyOwner {
        require(_vrfCoordinator != address(0), "VRF coordinator cannot be zero address");
        s_vrfCoordinator = IVRFCoordinatorV2Plus(_vrfCoordinator);
        
        FactoryStorage storage $ = _getFactoryStorage();
        $.vrfCoordinator = _vrfCoordinator;
        
        emit VRFCoordinatorUpdated(_vrfCoordinator);
    }

    /**
     * @notice Set game implementation address (owner only)
     * @param _gameImplementation New game implementation address
     * @dev Use this to update the master game contract for clones
     */
    function setGameImplementation(address _gameImplementation) external onlyOwner {
        require(_gameImplementation != address(0), "Game implementation cannot be zero address");
        FactoryStorage storage $ = _getFactoryStorage();
        $.gameImplementation = _gameImplementation;
    }

    /**
     * @notice Get configuration values
     */
    function getConfig() external view returns (
        address vrfCoordinator,
        address linkAddress,
        uint256 linkFee,
        uint256 minBet
    ) {
        FactoryStorage storage $ = _getFactoryStorage();
        return FactoryConfigLib.getConfig(
            $.vrfCoordinator,
            $.linkAddress,
            $.linkFee,
            $.minBet
        );
    }

    /**
     * @notice Get the game address for a pending VRF request
     * @param requestId The VRF request ID
     * @return gameAddress The game that requested VRF, or address(0) if fulfilled/invalid
     * @dev Used by VRF simulator to check if a request is still pending
     */
    function getVRFRequestGame(uint256 requestId) external view returns (address gameAddress) {
        FactoryStorage storage $ = _getFactoryStorage();
        return $.vrfRequestToGame[requestId];
    }

    /**
     * @notice Emergency withdraw (only owner, only if no active games)
     * @dev Burns all factory tokens to maintain deflationary mechanism
     *      This prevents unbacked tokens from circulating
     */
    function emergencyWithdraw() external onlyOwner nonReentrant {
        FactoryStorage storage $ = _getFactoryStorage();
        FactoryKeeperLib.emergencyWithdraw(
            $.lockedLiquidity,
            $.gameTokenAddress,
            owner()
        );
    }

    /**
     * @notice Emergency recovery from stuck or hacked game contract
     * @param gameAddress Address of the game contract to recover funds from
     * @dev Only callable by owner. Use if game is compromised or stuck.
     *      Burns recovered tokens to maintain deflationary mechanism.
     */
    function emergencyRecoverFromGame(address payable gameAddress) external onlyOwner nonReentrant {
        FactoryStorage storage $ = _getFactoryStorage();
        $.lockedLiquidity = FactoryKeeperLib.emergencyRecoverFromGame(
            gameAddress,
            $.activeGames,
            $.gameReservedLiquidity,
            $.lockedLiquidity,
            $.gameTokenAddress,
            owner()
        );
    }

    // ============================================
    // CHAINLINK VRF PROXY (Factory as VRF Consumer)
    // ============================================
    
    /**
     * @notice Request VRF randomness on behalf of a game
     * @param numWords Number of random words requested
     * @return requestId The VRF request ID
     * @dev Only callable by active games. Factory makes the VRF request and will forward
     *      the result to the calling game via receiveRandomness()
     *      Uses Factory's configured vrfCallbackGasLimit from storage
     */
    function requestVRFForGame(
        uint32 numWords
    ) external onlyActiveGame returns (uint256 requestId) {
        FactoryStorage storage $ = _getFactoryStorage();
        
        // Always use Factory's configured gas limit
        // This allows us to adjust gas limits without redeploying games
        require($.vrfCallbackGasLimit > 0, "VRF callback gas limit not configured");
        
        // Make VRF request using factory's subscription
        requestId = s_vrfCoordinator.requestRandomWords(
            VRFV2PlusClient.RandomWordsRequest({
                keyHash: VRFRequestLogic.getKeyHash(),
                subId: $.subscriptionId,
                requestConfirmations: VRFRequestLogic.getRequestConfirmations(),
                callbackGasLimit: $.vrfCallbackGasLimit,
                numWords: numWords,
                extraArgs: VRFV2PlusClient._argsToBytes(VRFV2PlusClient.ExtraArgsV1({nativePayment: false}))
            })
        );
        
        // Map request to calling game
        $.vrfRequestToGame[requestId] = msg.sender;
        
        emit VRFRequested(requestId, msg.sender);
    }
    
    /**
     * @notice Chainlink VRF V2.5 callback - receives random words and forwards to game
     * @param requestId The VRF request ID
     * @param randomWords Array of random words from VRF
     * @dev Called by VRF V2.5 Coordinator (function name changed from rawFulfillRandomWords in V2)
     *      Forwards randomness to the requesting game
     */
    function fulfillRandomWords(
        uint256 requestId,
        uint256[] calldata randomWords
    ) external {
        _fulfillRandomWords(requestId, randomWords);
    }

    /**
     * @notice VRF V2 compatibility - alias for fulfillRandomWords
     * @param requestId The VRF request ID
     * @param randomWords Array of random words from VRF
     * @dev MockVRFCoordinator uses the V2 callback name, so we provide this alias
     */
    function rawFulfillRandomWords(
        uint256 requestId,
        uint256[] calldata randomWords
    ) external {
        _fulfillRandomWords(requestId, randomWords);
    }

    /**
     * @notice Internal function to handle VRF fulfillment
     * @param requestId The VRF request ID
     * @param randomWords Array of random words from VRF
     */
    function _fulfillRandomWords(
        uint256 requestId,
        uint256[] calldata randomWords
    ) internal {
        FactoryStorage storage $ = _getFactoryStorage();
        
        // Only VRF coordinator can call this
        require(msg.sender == $.vrfCoordinator, "Only VRF coordinator");
        
        // Get the game that made this request
        address gameAddress = $.vrfRequestToGame[requestId];
        require(gameAddress != address(0), "Unknown VRF request");
        
        // Clean up mapping
        delete $.vrfRequestToGame[requestId];
        
        // Forward randomness to the game
        GameUpgradeable(gameAddress).receiveRandomness(requestId, randomWords);
        
        emit VRFFulfilled(requestId, gameAddress);
    }

    // ============================================
    // CHAINLINK KEEPER SUPPORT
    // ============================================
    
    /**
     * @notice Chainlink Automation - check if any games need cancellation
     * @return upkeepNeeded True if there are expired games to cancel
     * @return performData Encoded game address to cancel
     * @dev Called by Chainlink Automation every block (~2 seconds)
     */
    function checkUpkeep(bytes calldata /* checkData */) external view returns (bool upkeepNeeded, bytes memory performData) {
        FactoryStorage storage $ = _getFactoryStorage();
        
        // Scan all games for expired ones
        for (uint256 i = 0; i < $.allGames.length; i++) {
            address gameAddress = $.allGames[i];
            
            // Only check active games
            if (!$.activeGames[gameAddress]) continue;
            
            // Check if game is expired
            try GameUpgradeable(payable(gameAddress)).isExpired() returns (bool expired) {
                if (expired) {
                    // Found an expired game - return it
                    upkeepNeeded = true;
                    performData = abi.encode(gameAddress);
                    return (upkeepNeeded, performData);
                }
            } catch {
                // Game might be in invalid state, skip it
                continue;
            }
        }
        
        // No expired games found
        return (false, "");
    }
    
    /**
     * @notice Chainlink Automation - cancel expired game
     * @param performData Encoded game address from checkUpkeep
     * @dev Called automatically by Chainlink Automation when checkUpkeep returns true
     *      MUST be callable by keeper address (Chainlink forwarder)
     */
    function performUpkeep(bytes calldata performData) external nonReentrant {
        FactoryStorage storage $ = _getFactoryStorage();
        require(msg.sender == $.keeperAddress || msg.sender == owner(), "Only keeper or owner");
        
        // Decode game address
        address gameAddress = abi.decode(performData, (address));
        
        // Cancel the expired game directly (internal call to preserve msg.sender)
        $.lockedLiquidity = FactoryKeeperLib.cancelExpiredGameByKeeper(
            payable(gameAddress),
            $.activeGames,
            $.gameReservedLiquidity,
            $.lockedLiquidity,
            $.gameTokenAddress,
            $.keeperAddress,
            owner()
        );
    }
    
    /**
     * @notice Cancel expired game - callable by keeper
     * @param gameAddress Address of the expired game
     * @dev Only callable by registered keeper or owner
     *      This is the manual entry point (vs performUpkeep for automated)
     */
    function cancelExpiredGameByKeeper(address payable gameAddress) external nonReentrant {
        FactoryStorage storage $ = _getFactoryStorage();
        require(msg.sender == $.keeperAddress || msg.sender == owner(), "Only keeper or owner");
        
        $.lockedLiquidity = FactoryKeeperLib.cancelExpiredGameByKeeper(
            gameAddress,
            $.activeGames,
            $.gameReservedLiquidity,
            $.lockedLiquidity,
            $.gameTokenAddress,
            $.keeperAddress,
            owner()
        );
    }
    
    /**
     * @notice Get all active game addresses
     * @return Array of active game addresses
     * @dev Used by keeper to scan for expired games
     *      Optimized to iterate through allGames array directly
     */
    function getAllActiveGames() external view returns (address[] memory) {
        FactoryStorage storage $ = _getFactoryStorage();
        return FactoryConfigLib.getAllActiveGames($.allGames, $.activeGames);
    }
    
    /**
     * @notice Get game address at index (for Chainlink Keeper scanning)
     * @param index Index in allGames array
     * @return Game address or address(0) if index out of bounds
     */
    function getGameAtIndex(uint256 index) external view returns (address) {
        FactoryStorage storage $ = _getFactoryStorage();
        return FactoryConfigLib.getGameAtIndex($.allGames, index);
    }
    
    /**
     * @notice Get total number of games ever created
     * @return Total games count
     */
    function getTotalGamesCount() external view returns (uint256) {
        FactoryStorage storage $ = _getFactoryStorage();
        return FactoryConfigLib.getTotalGamesCount($.allGames);
    }
    
    /**
     * @notice Check if game is still active
     * @param gameAddress Address of game to check
     * @return True if game is active
     */
    function isGameActive(address gameAddress) external view returns (bool) {
        FactoryStorage storage $ = _getFactoryStorage();
        return FactoryConfigLib.isGameActive($.activeGames, gameAddress);
    }
    
    /**
     * @notice Get GameToken interface for keeper
     * @return GameToken contract
     */
    function gameToken() external view returns (IERC20) {
        FactoryStorage storage $ = _getFactoryStorage();
        return IERC20($.gameTokenAddress);
    }
    
    /**
     * @notice Get contract version
     * @return Version string
     */
    function version() external view returns (string memory) {
        FactoryStorage storage $ = _getFactoryStorage();
        return $.version;
    }
    
    /**
     * @notice Get minimum concurrent players setting
     * @return Minimum concurrent players
     */
    function minConcurrentPlayers() external view returns (uint256) {
        FactoryStorage storage $ = _getFactoryStorage();
        return $.minConcurrentPlayers;
    }
    
    /**
     * @notice Get locked liquidity amount
     * @return Locked liquidity in POL
     */
    function lockedLiquidity() external view returns (uint256) {
        FactoryStorage storage $ = _getFactoryStorage();
        return $.lockedLiquidity;
    }
}
