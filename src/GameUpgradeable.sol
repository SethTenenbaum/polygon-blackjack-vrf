// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuardTransient} from "lib/openzeppelin-contracts/contracts/utils/ReentrancyGuardTransient.sol";
import {CardLogic} from "./libraries/CardLogic.sol";
import {WinnerDeterminationLogic} from "./libraries/WinnerDeterminationLogic.sol";
import {HandProgressionLogic} from "./libraries/HandProgressionLogic.sol";
import {GameViewLib} from "./libraries/GameViewLib.sol";
import {GameEmergencyLogic} from "./libraries/GameEmergencyLogic.sol";
import {VRFRequestLogic} from "./libraries/VRFRequestLogic.sol";
import {PlayerActionsLogic} from "./libraries/PlayerActionsLogic.sol";
import {DealerLogic} from "./libraries/DealerLogic.sol";
import {VRFFulfillmentLogic} from "./libraries/VRFFulfillmentLogic.sol";
import {PlayerActionValidation} from "./libraries/PlayerActionValidation.sol";
import {GameActionsLib} from "./libraries/GameActionsLib.sol";
import {VRFFulfillmentHandler} from "./libraries/VRFFulfillmentHandler.sol";
import {VRFRequestHelper} from "./libraries/VRFRequestHelper.sol";
import {VRFStatusLib} from "./libraries/VRFStatusLib.sol";
import {IGameToken} from "./interfaces/IGameToken.sol";

/**
 * @dev Minimal interface for GameFactory to notify game completion and handle VRF requests
 */
interface IGameFactory {
    function notifyGameFinished() external;
    function requestVRFForGame(uint32 numWords) external returns (uint256 requestId);
}

// Note: IGameToken interface now imported from ./interfaces/IGameToken.sol

// Custom errors (saves ~2.5KB vs require strings)
error NotYourGame();
error GameAlreadyStarted();
error InsufficientLINK();
error NotYourTurn();
error HandAlreadyStood();
error HandBusted();
error CannotHitAfterDouble();
error LINKTransferFailed();
error NotPlayerTurn();
error TooManyHands();
error CannotSplitDifferentRanks();
error NotInsurancePhase();
error InsuranceTooHigh();
error NotDealerTurn();
error WaitingForRandomness();
error GameHasExpired();
error UnknownRequest();
error StaleRequest();
error InvalidHandIndex();
error OnlyFactory();
error CannotEmergencyWithdraw();
error GameNotExpired();
error GameAlreadyFinished();
error NotWaitingForVRF();
error NoPendingVRFRequest();
error VRFRequestNotTimedOut();
error BetTransferFailed();
error TokenTransferFailed();
error PayoutFailed();
error InvalidState();

/**
 * @title GameUpgradeable
 * @notice Individual blackjack game contract (non-upgradeable, created by upgradeable factory)
 * @dev NO LONGER inherits from VRFConsumerBaseV2Plus - factory handles all VRF operations
 */
contract GameUpgradeable is ReentrancyGuardTransient {
    // LINK Token (configured per game for flexibility)
    IERC20 public linkToken;

    // Game Token
    IGameToken public gameToken;

    // Game state
    enum GameState { NotStarted, Dealing, InsuranceOffer, PlayerTurn, DealerTurn, Finished }
    enum RequestType { None, InitialDeal, PlayerHit, DealerHit, Split, DealerHoleCard }

    struct Hand {
        uint8[] cards;
        uint256 bet;
        bool stood;
        bool busted;
        bool doubled;
    }

    // Game timeout
    uint256 public constant GAME_TIMEOUT = 24 hours;
    uint256 public constant PLAYER_PRIORITY_PERIOD = 1 hours;

    address public player;
    Hand[] public playerHands;
    uint8[] public dealerCards;
    GameState public state;
    uint256 public insuranceBet;
    uint256 public linkSpent;
    mapping(uint256 => RequestType) public pendingRequests;
    mapping(uint256 => uint256) public requestTimestamps;
    uint256 public constant VRF_REQUEST_TIMEOUT = 2 minutes;
    uint256 public lastRequestId; // Track last VRF request for retry
    RequestType public lastRequestType; // Track last request type for retry
    
    uint256 private _flags;
    
    // Final payout stored on-chain for reliable frontend display
    uint256 public finalPayout;
    
    uint8 public currentHand;
    uint256 public bet;
    address public factory;
    uint256 public createdAt;

    function isPlayerHitting() public view returns (bool) { return _flags & 1 == 1; }
    function isDealerHitting() public view returns (bool) { return _flags & 2 == 2; }
    function dealerHasBlackjack() public view returns (bool) { return _flags & 4 == 4; }
    function playerHasBlackjack() public view returns (bool) { return _flags & 8 == 8; }
    function _setIsPlayerHitting(bool value) internal { if(value) _flags |= 1; else _flags &= ~uint256(1); }
    function _setIsDealerHitting(bool value) internal { if(value) _flags |= 2; else _flags &= ~uint256(2); }
    function _setDealerHasBlackjack(bool value) internal { if(value) _flags |= 4; else _flags &= ~uint256(4); }
    function _setPlayerHasBlackjack(bool value) internal { if(value) _flags |= 8; else _flags &= ~uint256(8); }

    event CardsDealt(uint8[] playerCards, uint8 dealerCard);
    event PlayerHit(uint8 card);
    event PlayerStood();
    event DealerPlayed(uint8[] dealerCards);
    event GameFinished(string result, uint256 payout);
    event DealerNeedsToHit();

    modifier notExpired() { if (block.timestamp >= createdAt + GAME_TIMEOUT && state != GameState.Finished) revert GameHasExpired(); _; }
    modifier onlyFactory() virtual { if (msg.sender != factory) revert OnlyFactory(); _; }

    constructor(address _player, uint256 _bet, address _factory, address _vrfCoordinator, address _gameToken, address _linkToken) 
    {
        if (_player == address(0) || _factory == address(0) || _vrfCoordinator == address(0) || _gameToken == address(0) || _linkToken == address(0)) revert NotYourGame();
        if (_bet == 0) revert NotYourGame();
        
        player = _player;
        bet = _bet;
        factory = _factory;
        gameToken = IGameToken(_gameToken);
        linkToken = IERC20(_linkToken);
        createdAt = block.timestamp;
        playerHands.push(Hand(new uint8[](0), _bet, false, false, false));
    }

    /**
     * @notice Initialize a cloned game instance
     * @dev Called by factory when creating a new game via minimal proxy pattern
     */
    function initializeClone(
        address _player,
        uint256 _bet,
        address _factory,
        address _gameToken,
        address _linkToken
    ) external virtual {
        if (createdAt != 0) revert GameAlreadyStarted();
        if (_player == address(0) || _factory == address(0) || _gameToken == address(0) || _linkToken == address(0)) revert NotYourGame();
        if (_bet == 0) revert NotYourGame();
        
        // ReentrancyGuardTransient doesn't need initialization (uses transient storage)
        
        player = _player;
        bet = _bet;
        factory = _factory;
        gameToken = IGameToken(_gameToken);
        linkToken = IERC20(_linkToken);
        createdAt = block.timestamp;
        playerHands.push(Hand(new uint8[](0), _bet, false, false, false));
    }

    /**
     * @notice Internal helper to request VRF through factory
     * @param numWords Number of random words needed
     * @return requestId The VRF request ID
     */
    function _requestVRFThroughFactory(uint32 numWords) internal returns (uint256 requestId) {
        return IGameFactory(factory).requestVRFForGame(numWords);
    }

    function startGame() external onlyFactory {
        if (state != GameState.NotStarted) revert GameAlreadyStarted();
        uint256 linkFee = VRFRequestLogic.getLinkFee();
        state = GameState.Dealing;
        // Factory uses its configured callback gas limit
        uint256 newRequestId = _requestVRFThroughFactory(VRFRequestLogic.getNumWords());
        pendingRequests[newRequestId] = RequestType.InitialDeal;
        requestTimestamps[newRequestId] = block.timestamp;
        lastRequestId = newRequestId;
        lastRequestType = RequestType.InitialDeal;
        linkSpent += linkFee;
    }

    /**
     * @notice Receive randomness from factory after VRF fulfillment
     * @param _requestId The VRF request ID
     * @param randomWords Array of random words from VRF
     * @dev Only callable by factory after VRF coordinator fulfills the request
     *      Made virtual for testing purposes
     */
    function receiveRandomness(uint256 _requestId, uint256[] memory randomWords) external virtual onlyFactory {
        RequestType reqType = pendingRequests[_requestId];
        if (reqType == RequestType.None) revert UnknownRequest();
        if (block.timestamp >= createdAt + GAME_TIMEOUT) revert GameHasExpired();
        if (block.timestamp > requestTimestamps[_requestId] + VRFStatusLib.VRF_REQUEST_TIMEOUT) revert StaleRequest();

        delete pendingRequests[_requestId];
        delete requestTimestamps[_requestId];
        
        uint256 random = randomWords[0];

        if (reqType == RequestType.PlayerHit) {
            (uint8 newCurrentHand, bool shouldPlayDealer) = VRFFulfillmentHandler.handlePlayerHit(playerHands, currentHand, random);
            _setIsPlayerHitting(false);
            emit PlayerHit(playerHands[currentHand].cards[playerHands[currentHand].cards.length - 1]);
            
            if (shouldPlayDealer) {
                currentHand = newCurrentHand;
                state = GameState.DealerTurn;
                // CRITICAL: Don't call playDealer() here to save gas in VRF callback
                // Player must call stand() or frontend auto-calls it to continue
            } else {
                currentHand = newCurrentHand;
                state = GameState.PlayerTurn;
            }
        } else if (reqType == RequestType.Split) {
            (uint8 card1, uint8 card2) = VRFFulfillmentHandler.handleSplit(playerHands, currentHand, random);
            _setIsPlayerHitting(false);
            state = GameState.PlayerTurn;
            emit PlayerHit(card1);
            emit PlayerHit(card2);
        } else if (reqType == RequestType.DealerHit) {
            VRFFulfillmentHandler.handleDealerHit(dealerCards, random);
            _setIsDealerHitting(false);
            // CRITICAL: Don't call playDealer() recursively in VRF callback to save gas
            // Player must call continueDealer() or frontend auto-calls it
            state = GameState.DealerTurn; // Stays in dealer turn, waiting for continuation
        } else if (reqType == RequestType.InitialDeal) {
            (bool playerBlackjack, bool offerInsurance, uint8 dealerUpCard) = VRFFulfillmentHandler.handleInitialDeal(playerHands, dealerCards, random);
            
            if (playerBlackjack) {
                _setPlayerHasBlackjack(true);
                state = GameState.Finished;
                determineWinner();
                return;
            }
            
            state = offerInsurance ? GameState.InsuranceOffer : GameState.PlayerTurn;
            emit CardsDealt(playerHands[0].cards, dealerUpCard);
        } else if (reqType == RequestType.DealerHoleCard) {
            bool dealerBlackjack = VRFFulfillmentHandler.handleDealerHoleCard(dealerCards, random);
            _setIsDealerHitting(false);
            
            if (dealerBlackjack) {
                _setDealerHasBlackjack(true);
            }
            
            // CRITICAL: Don't call playDealer() in VRF callback to save gas
            // Player must call continueDealer() or frontend auto-calls it
            state = GameState.DealerTurn; // Dealer turn, waiting for continuation
        }
    }

    function hit() external notExpired {
        // Validate and execute hit logic
        PlayerActionValidation.validatePlayer(player, msg.sender);
        PlayerActionValidation.validatePlayerTurn(uint8(state));
        PlayerActionsLogic.validateHit(uint8(state), currentHand, playerHands);
        
        // Make VRF request through helper library
        (uint256 newRequestId, uint256 linkFee) = VRFRequestHelper.makeVRFRequest(
            factory, linkToken, player, uint8(RequestType.PlayerHit)
        );
        
        // Track request
        pendingRequests[newRequestId] = RequestType.PlayerHit;
        requestTimestamps[newRequestId] = block.timestamp;
        lastRequestId = newRequestId;
        lastRequestType = RequestType.PlayerHit;
        
        _setIsPlayerHitting(true);
        linkSpent += linkFee;
        state = GameState.Dealing;
    }

    function stand() external notExpired {
        // Inline validation (was in PlayerActionsExecutionLib.executeStand)
        if (msg.sender != player) revert NotYourGame();
        if (state != GameState.PlayerTurn) revert NotPlayerTurn();
        if (playerHands[currentHand].stood) revert HandAlreadyStood();

        playerHands[currentHand].stood = true;
        (uint8 nextHand, bool moveToDealerTurn) = PlayerActionsLogic.processStand(currentHand, playerHands);
        
        emit PlayerStood();

        if (!moveToDealerTurn) {
            currentHand = nextHand;
        } else {
            state = GameState.DealerTurn;
            playDealer();
        }
    }

    function doubleDown() external notExpired {
        // Validate player and action
        if (msg.sender != player) revert NotYourGame();
        uint256 additionalBet = PlayerActionsLogic.validateDoubleDown(uint8(state), currentHand, playerHands);
        
        // Transfer additional bet from player
        if (!gameToken.transferFrom(player, address(this), additionalBet)) revert BetTransferFailed();
        PlayerActionsLogic.applyDoubleDown(currentHand, playerHands, additionalBet);
        
        // Make VRF request through helper library
        (uint256 newRequestId, uint256 linkFee) = VRFRequestHelper.makeVRFRequest(
            factory, linkToken, player, uint8(RequestType.PlayerHit)
        );
        
        // Track request
        pendingRequests[newRequestId] = RequestType.PlayerHit;
        requestTimestamps[newRequestId] = block.timestamp;
        lastRequestId = newRequestId;
        lastRequestType = RequestType.PlayerHit;

        _setIsPlayerHitting(true);
        linkSpent += linkFee;
        state = GameState.Dealing;
    }

    function split() external notExpired {
        // Validate player and action
        if (msg.sender != player) revert NotYourGame();
        (uint8 card1, uint8 card2, uint256 splitBet) = PlayerActionsLogic.validateSplit(uint8(state), currentHand, playerHands);
        
        // Transfer split bet from player
        if (!gameToken.transferFrom(player, address(this), splitBet)) revert BetTransferFailed();
        PlayerActionsLogic.executeSplitLogic(currentHand, playerHands, card1, card2, splitBet);
        
        // Make VRF request through helper library
        (uint256 newRequestId, uint256 linkFee) = VRFRequestHelper.makeVRFRequest(
            factory, linkToken, player, uint8(RequestType.Split)
        );
        
        // Track request
        pendingRequests[newRequestId] = RequestType.Split;
        requestTimestamps[newRequestId] = block.timestamp;
        lastRequestId = newRequestId;
        lastRequestType = RequestType.Split;

        _setIsPlayerHitting(true);
        linkSpent += linkFee;
        state = GameState.Dealing;
    }

    function surrender() external notExpired {
        state = GameState(GameActionsLib.executeSurrender(
            player,
            factory,
            gameToken,
            uint8(state),
            playerHands.length,
            playerHands[0].cards.length,
            playerHands[0].bet
        ));
    }

    function placeInsurance(uint256 amount) external notExpired {
        (uint8 newState, bool shouldDetermineWinner) = GameActionsLib.executePlaceInsurance(
            player,
            uint8(state),
            amount,
            bet,
            dealerHasBlackjack(),
            playerHasBlackjack()
        );
        
        if (!gameToken.transferFrom(player, address(this), amount)) revert TokenTransferFailed();
        insuranceBet = amount;
        
        state = GameState(newState);
        if (shouldDetermineWinner) {
            determineWinner();
        }
    }

    function skipInsurance() external notExpired {
        bool shouldDetermineWinner;
        uint8 newState;
        (newState, shouldDetermineWinner) = GameActionsLib.executeSkipInsurance(player, uint8(state), dealerHasBlackjack(), playerHasBlackjack());
        state = GameState(newState);

        if (shouldDetermineWinner) {
            determineWinner();
        }
    }

    /**
     * @notice Continue dealer turn after VRF callback completes
     * @dev Call this after doubleDown or other actions that transition to dealer turn
     *      This separates the gas-expensive playDealer() from the VRF callback
     *      THIS IS NEEDED TO SAVE GAS DO NOT TRY TO AUTOMATE AUTO-HIT IN CALLBACK
     */
    function continueDealer() external notExpired {
        if (msg.sender != player) revert NotYourGame();
        if (state != GameState.DealerTurn) revert NotDealerTurn();
        if (isDealerHitting() || isPlayerHitting()) revert WaitingForRandomness();
        
        // Optimization: If all player hands are busted, skip dealer play entirely
        if (HandProgressionLogic.areAllHandsBusted(playerHands)) {
            state = GameState.Finished;
            determineWinner();
            return;
        }
        
        // Now it's safe to call playDealer() in a separate transaction
        playDealer();
    }

    function dealerHit() external notExpired {
        if (msg.sender != player) revert NotYourGame();
        if (state != GameState.DealerTurn) revert NotDealerTurn();
        
        // Make VRF request through helper library
        (uint256 newRequestId, uint256 linkFee) = VRFRequestHelper.makeVRFRequest(
            factory, linkToken, player, uint8(RequestType.DealerHit)
        );
        
        // Track request
        pendingRequests[newRequestId] = RequestType.DealerHit;
        requestTimestamps[newRequestId] = block.timestamp;
        lastRequestId = newRequestId;
        lastRequestType = RequestType.DealerHit;

        _setIsDealerHitting(true);
        linkSpent += linkFee;
        state = GameState.Dealing;
    }

    /**
     * @notice Retry a timed-out VRF request
     * @dev Anyone can call after 2min timeout. Retry is FREE - factory pays via subscription.
     */
    function retryVRFRequest() external notExpired {
        VRFStatusLib.validateRetry(uint8(state), lastRequestId, requestTimestamps[lastRequestId]);
        
        delete pendingRequests[lastRequestId];
        delete requestTimestamps[lastRequestId];
        
        // Factory pays retry cost via subscription and uses its configured gas limit
        uint256 newRequestId = _requestVRFThroughFactory(VRFRequestLogic.getNumWords());
        
        pendingRequests[newRequestId] = lastRequestType;
        requestTimestamps[newRequestId] = block.timestamp;
        lastRequestId = newRequestId;
    }
    /**
     * @return hasFailed True if request older than 2min timeout
     * @return timeWaiting Seconds waited for current request  
     * @return canRetry True if retry available
     */
    function getVRFRequestStatus() external view returns (bool hasFailed, uint256 timeWaiting, bool canRetry) {
        return VRFStatusLib.getVRFRequestStatus(uint8(state), lastRequestId, requestTimestamps[lastRequestId]);
    }
    
    /// @return timeRemaining Seconds until timeout, 0 if timed out
    function getVRFTimeRemaining() external view returns (uint256) {
        return VRFStatusLib.getVRFTimeRemaining(uint8(state), lastRequestId, requestTimestamps[lastRequestId]);
    }
    function playDealer() internal {
        // Optimization: If all player hands are busted, skip dealer play entirely
        if (HandProgressionLogic.areAllHandsBusted(playerHands)) {
            state = GameState.Finished;
            determineWinner();
            return;
        }
        
        // Set to dealer turn
        state = GameState.DealerTurn;
        
        // SECURITY FIX: If dealer only has 1 card (up card), request the hole card via VRF
        if (dealerCards.length == 1) {
            uint256 linkFee = VRFRequestLogic.getLinkFee();
            
            // Collect LINK fee from player (service fee)
            if (!linkToken.transferFrom(player, address(this), linkFee)) revert LINKTransferFailed();
            
            // Request the dealer hole card through factory
            // Factory uses its configured callback gas limit
            uint256 newRequestId = _requestVRFThroughFactory(1);
            
            pendingRequests[newRequestId] = RequestType.DealerHoleCard;
            requestTimestamps[newRequestId] = block.timestamp;
            lastRequestId = newRequestId;
            lastRequestType = RequestType.DealerHoleCard;
            linkSpent += linkFee;
            _setIsDealerHitting(true);
            state = GameState.Dealing; // Set to Dealing state while waiting for VRF
            return; // Wait for VRF callback
        }
        
        // Dealer has hole card, continue with normal dealer logic
        (, bool isFinished) = DealerLogic.processDealerTurn(dealerCards);
        if (isFinished) {
            state = GameState.Finished;
            determineWinner();
        } else {
            emit DealerNeedsToHit();
        }
    }

    function determineWinner() internal nonReentrant {
        if (state != GameState.Finished) revert InvalidState();

        uint8 dealerScore = CardLogic.calculateScore(dealerCards);
        bool dealerBusted = dealerScore > 21;
        
        // Calculate payouts
        uint256 totalPayout = GameActionsLib.calculateInsurancePayout(dealerHasBlackjack(), insuranceBet);
        totalPayout += WinnerDeterminationLogic.calculateTotalPayout(playerHands, dealerCards, dealerBusted);

        // Store final payout on-chain for reliable frontend display (before transfers for safety)
        finalPayout = totalPayout;

        if (totalPayout > 0) {
            if (!gameToken.transfer(player, totalPayout)) revert PayoutFailed();
        }

        uint256 remainingBalance = gameToken.balanceOf(address(this));
        if (remainingBalance > 0) {
            gameToken.burn(remainingBalance);
        }

        IGameFactory(factory).notifyGameFinished();
        emit DealerPlayed(dealerCards);
        emit GameFinished(totalPayout > 0 ? "won" : "lost", totalPayout);
    }



    function emergencyWithdrawToFactory() external onlyFactory nonReentrant {
        state = GameState(GameEmergencyLogic.emergencyWithdrawToFactory(GameEmergencyLogic.EmergencyParams(factory,address(gameToken),address(linkToken),createdAt,GAME_TIMEOUT,PLAYER_PRIORITY_PERIOD,uint8(state))));
    }

    function getPlayerHandCards(uint256 handIndex) external view returns (uint8[] memory) { return playerHands[handIndex].cards; }
    function getPlayerHandBet(uint256 handIndex) external view returns (uint256) { return playerHands[handIndex].bet; }
    function getPlayerHandsLength() external view returns (uint256) { return playerHands.length; }
    function getDealerCards() external view returns (uint8[] memory) {
        return GameViewLib.getVisibleDealerCards(dealerCards, uint8(state));
    }
    function getDealerHasBlackjack() external view returns (bool) { return dealerHasBlackjack(); }
    function getPlayerHasBlackjack() external view returns (bool) { return playerHasBlackjack(); }
    function canCoverMaxPayout() public view returns (bool) { return GameViewLib.canCoverMaxPayout(bet, address(gameToken), address(this)); }
    function hasEnoughLINK(uint256 turns) public view returns (bool) { return GameViewLib.hasEnoughLINK(address(linkToken), address(this), turns); }
    function getRecommendedFunding() public view returns (uint256 tokenAmount, uint256 linkAmount) { return GameViewLib.getRecommendedFunding(bet); }
    function getFundStatus() external view returns (uint256 tokenBalance, uint256 linkBalance, uint256 linkSpentSoFar, bool canCoverPayout) { return GameViewLib.getFundStatus(bet, linkSpent, address(gameToken), address(linkToken), address(this)); }
    function getMaxLINKNeeded() public view returns (uint256) { return GameViewLib.getMaxLINKNeeded(playerHands.length); }
    function getTimeRemaining() external view returns (uint256) { return GameEmergencyLogic.getTimeRemaining(createdAt, GAME_TIMEOUT, uint8(state)); }
    function isExpired() external view returns (bool) { return GameEmergencyLogic.isExpired(createdAt, GAME_TIMEOUT, uint8(state)); }
    function cancelExpiredGame() external onlyFactory nonReentrant { state = GameState(GameEmergencyLogic.cancelExpiredGame(address(gameToken),address(linkToken),factory,createdAt,GAME_TIMEOUT,uint8(state),player)); }
}
