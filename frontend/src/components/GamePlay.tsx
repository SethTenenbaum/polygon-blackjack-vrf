"use client";

import { useAccount, useReadContract, useWriteContract, useWaitForTransactionReceipt, useWatchContractEvent, usePublicClient } from "wagmi";
import { useQueryClient } from "@tanstack/react-query";
import { GAME_ABI, LINK_TOKEN_ABI, FACTORY_ABI, GAME_TOKEN_ABI } from "@/lib/abis";
import { useState, useEffect, useCallback, useRef, useMemo } from "react";
import { PlayingCard } from "./PlayingCard";
import { useGameTransaction } from "@/hooks/useGameTransaction";
import { Fireworks } from "./Fireworks";
import { VRFStatusDisplay } from "./VRFStatusDisplay";
import { formatUnits } from "viem";
import { calculateGameOutcome, canCalculateOutcome, type PlayerHand } from "@/lib/gameOutcomeCalculator";

const LINK_TOKEN_ADDRESS = process.env.NEXT_PUBLIC_LINK_TOKEN as `0x${string}`;
const FACTORY_ADDRESS = process.env.NEXT_PUBLIC_FACTORY_ADDRESS as `0x${string}`;
const GAME_TOKEN_ADDRESS = process.env.NEXT_PUBLIC_GAME_TOKEN_ADDRESS as `0x${string}`;

type GamePlayProps = {
  gameAddress: `0x${string}`;
  onMinimize?: () => void;
};

// Game states from contract
enum GameState {
  NotStarted = 0,
  Dealing = 1,
  InsuranceOffer = 2,
  PlayerTurn = 3,
  DealerTurn = 4,
  Finished = 5,
}

export function GamePlay({ gameAddress, onMinimize }: GamePlayProps) {
  const { address } = useAccount();
  const queryClient = useQueryClient();
  const [refreshTrigger, setRefreshTrigger] = useState(0);
  
  // Admin wallet for debug features
  const ADMIN_ADDRESS = "0xC6d04Dd0433860b99D37C866Ff31853B45E02F1f";
  const isAdmin = address?.toLowerCase() === ADMIN_ADDRESS.toLowerCase();
  
  const [placedInsuranceAmount, setPlacedInsuranceAmount] = useState<bigint>(BigInt(0)); // Track actual insurance placed
  const [txError, setTxError] = useState<string | null>(null);
  const [pendingAction, setPendingAction] = useState<string | null>(null); // Track action to execute after approval
  const [currentAction, setCurrentAction] = useState<string | null>(null); // Track currently executing action
  const [recentlySplitHand, setRecentlySplitHand] = useState<number | null>(null); // Track which hand was just split to prevent duplicate splits
  const [approvalPhase, setApprovalPhase] = useState<"none" | "link" | "token">("none"); // Track which approval is in progress
  const [gameResult, setGameResult] = useState<{ result: string; payout: bigint } | null>(null);
  const [dealerHoleCardRevealed, setDealerHoleCardRevealed] = useState(false); // Track if dealer's 2nd card has been revealed
  const [showFireworks, setShowFireworks] = useState(false);
  const [lastKnownDealerCards, setLastKnownDealerCards] = useState<bigint[]>([]); // Preserve dealer cards during VRF
  const publicClient = usePublicClient();
  
  // Track if we've already triggered dealer hit for current dealer turn to prevent duplicate calls
  const dealerHitTriggeredRef = useRef(false);
  
  // Track if we've already triggered ANY dealer automation action for this DealerTurn session
  // This prevents multiple automation attempts (timer-based or manual) within the same dealer turn
  const dealerAutomationTriggeredRef = useRef(false);
  
  // Track which DealerTurn session we're in to prevent effect from running multiple times
  // This is different from dealerAutomationTriggeredRef - this tracks whether we've SET UP
  // the timer for this session, not whether we've triggered an action
  const dealerTurnSessionIdRef = useRef<number>(0);
  
  // Track the PREVIOUS game state from the PREVIOUS render to detect state changes
  // This is separate from latestGameStateRef which gets updated during render
  const previousGameStateRef = useRef<GameState | undefined>(undefined);
  
  // Track if we've already set up the timer for the current DealerTurn session
  // This is the FINAL DEFENSE against duplicate timers - even if the effect runs multiple times
  // during the same session, we won't set up multiple timers
  const timerSetUpForSessionRef = useRef<number>(-1);
  
  // Track the action being executed so we can reference it in onSuccess (since currentAction state might be stale)
  const executingActionRef = useRef<string | null>(null);
  
  // Track fallback event fetch attempts to prevent infinite retries
  const fetchAttemptsRef = useRef(0);
  const maxFetchAttempts = 5;
  
  // Track the latest game state to avoid stale closures in setTimeout callbacks
  const latestGameStateRef = useRef<GameState | undefined>(undefined);
  
  // Track the latest isPending state to avoid stale closures in setTimeout callbacks
  const isPendingRef = useRef<boolean>(false);
  
  // Track the latest dealer cards data to avoid stale closures in setTimeout callbacks
  const latestDealerCardsRef = useRef<readonly bigint[]>([]);
  
  // Track the latest hole card revealed state to avoid stale closures in setTimeout callbacks
  const latestHoleCardRevealedRef = useRef<boolean>(false);
  
  // Track if we're currently refetching game data - prevents dealer automation during refetch
  const isRefetchingRef = useRef<boolean>(false);
  
  // Track the latest LINK approval state to avoid stale closures in setTimeout callbacks
  const isLINKApprovedRef = useRef<boolean>(false);
  
  // Track failed dealer actions that need retry
  const [failedDealerAction, setFailedDealerAction] = useState<string | null>(null);

  // Track which cards have been "seen" to trigger animations only on initial deal
  const [seenDealerCardCount, setSeenDealerCardCount] = useState(0);
  const [seenPlayerCardCounts, setSeenPlayerCardCounts] = useState<number[]>([0, 0, 0, 0]);
  // Track if dealer's first card should flip (set to true after card has mounted and second card arrives)
  const [dealerFirstCardShouldFlip, setDealerFirstCardShouldFlip] = useState(false);

  // NOTE: We don't watch for GameFinished event because it can cause race conditions
  // where the event's "result" string doesn't match our frontend calculation.
  // Instead, we poll contractFinalPayout and calculate the result consistently
  // in the useEffect below. This ensures the result is always correct and doesn't
  // flash "lost" then change to "won" (or vice versa).

  // Read LINK fee per action from factory contract
  const { data: factoryConfig } = useReadContract({
    address: FACTORY_ADDRESS,
    abi: FACTORY_ABI,
    functionName: "getConfig",
  });

  // Extract linkFee from factory config
  const linkFeePerAction = factoryConfig ? factoryConfig[2] : BigInt(0); // linkFee is the 3rd return value

  // Read game state with auto-refetch
  const { data: gameState, refetch } = useReadContract({
    address: gameAddress,
    abi: GAME_ABI,
    functionName: "state",
    query: {
      enabled: !!gameAddress,
      refetchInterval: false, // DISABLED - only manual refetch
      gcTime: 0, // Don't cache results
      staleTime: 0, // Consider data stale immediately
    },
  });

  const { data: currentHandIndex } = useReadContract({
    address: gameAddress,
    abi: GAME_ABI,
    functionName: "currentHand",
    query: {
      refetchInterval: false,
    },
  });

  const { data: playerHandsLength } = useReadContract({
    address: gameAddress,
    abi: GAME_ABI,
    functionName: "getPlayerHandsLength",
    query: {
      refetchInterval: false,
    },
  });

  // Dynamically fetch all player hands
  const numHands = Number(playerHandsLength || 1);
  
  const { data: playerHand0Cards, refetch: refetchHand0Cards } = useReadContract({
    address: gameAddress,
    abi: GAME_ABI,
    functionName: "getPlayerHandCards",
    args: [BigInt(0)],
    query: {
      refetchInterval: false,
      enabled: numHands >= 1,
      gcTime: 0,
      staleTime: 0,
    },
  });

  const { data: playerHand0Bet, refetch: refetchHand0Bet } = useReadContract({
    address: gameAddress,
    abi: GAME_ABI,
    functionName: "getPlayerHandBet",
    args: [BigInt(0)],
    query: {
      refetchInterval: false, // DISABLED - only manual refetch to prevent crash
      enabled: numHands >= 1,
    },
  });

  // Hand 1 (only fetch if split occurred)
  const { data: playerHand1Cards, refetch: refetchHand1Cards } = useReadContract({
    address: gameAddress,
    abi: GAME_ABI,
    functionName: "getPlayerHandCards",
    args: [BigInt(1)],
    query: {
      refetchInterval: false,
      enabled: numHands >= 2,
    },
  });

  const { data: playerHand1Bet, refetch: refetchHand1Bet } = useReadContract({
    address: gameAddress,
    abi: GAME_ABI,
    functionName: "getPlayerHandBet",
    args: [BigInt(1)],
    query: {
      refetchInterval: false, // DISABLED - only manual refetch to prevent crash
      enabled: numHands >= 2,
    },
  });

  // Hand 2 (if double split)
  const { data: playerHand2Cards, refetch: refetchHand2Cards } = useReadContract({
    address: gameAddress,
    abi: GAME_ABI,
    functionName: "getPlayerHandCards",
    args: [BigInt(2)],
    query: {
      refetchInterval: false,
      enabled: numHands >= 3,
    },
  });

  const { data: playerHand2Bet, refetch: refetchHand2Bet } = useReadContract({
    address: gameAddress,
    abi: GAME_ABI,
    functionName: "getPlayerHandBet",
    args: [BigInt(2)],
    query: {
      refetchInterval: false, // DISABLED - only manual refetch to prevent crash
      enabled: numHands >= 3,
    },
  });

  // Hand 3 (max hands)
  const { data: playerHand3Cards, refetch: refetchHand3Cards } = useReadContract({
    address: gameAddress,
    abi: GAME_ABI,
    functionName: "getPlayerHandCards",
    args: [BigInt(3)],
    query: {
      refetchInterval: false, // DISABLED - only manual refetch to prevent crash
      enabled: numHands >= 4,
    },
  });

  const { data: playerHand3Bet, refetch: refetchHand3Bet } = useReadContract({
    address: gameAddress,
    abi: GAME_ABI,
    functionName: "getPlayerHandBet",
    args: [BigInt(3)],
    query: {
      refetchInterval: false, // DISABLED - only manual refetch to prevent crash
      enabled: numHands >= 4,
    },
  });

  const { data: dealerCardsData, refetch: refetchDealerCards } = useReadContract({
    address: gameAddress,
    abi: GAME_ABI,
    functionName: "getDealerCards",
    query: {
      refetchInterval: false, // DISABLED - only manual refetch to prevent crash
      gcTime: 0,
      staleTime: 0,
    },
  });

  // NOTE: isDealerHitting was removed as it's not available in the contract ABI
  // Dealer automation now relies on dealer score calculation instead
  const isDealerHittingFromContract = undefined;

  // Check LINK balance of player's wallet
  const { data: linkBalance, refetch: refetchLinkBalance } = useReadContract({
    address: LINK_TOKEN_ADDRESS,
    abi: LINK_TOKEN_ABI,
    functionName: "balanceOf",
    args: address ? [address] : undefined,
    query: {
      refetchInterval: false, // DISABLED - only manual refetch to prevent crash
    },
  });

  // Check LINK allowance for this game contract
  const { data: linkAllowance, refetch: refetchLinkAllowance } = useReadContract({
    address: LINK_TOKEN_ADDRESS,
    abi: LINK_TOKEN_ABI,
    functionName: "allowance",
    args: address ? [address, gameAddress] : undefined,
    query: {
      refetchInterval: false, // DISABLED - only manual refetch to prevent crash
    },
  });

  // Approve LINK for the game contract
  const { 
    writeContract: approveLINK, 
    data: approveTxHash, 
    isPending: isApprovingLINK,
    error: approveError 
  } = useWriteContract();
  
  const { isSuccess: isApproveSuccess, isError: isApproveError } = useWaitForTransactionReceipt({
    hash: approveTxHash,
  });

  // Log LINK approval errors
  useEffect(() => {
    if (approveError) {
      setTxError(`LINK approval failed: ${approveError.message}`);
      setPendingAction(null);
      setApprovalPhase("none");
    }
  }, [approveError, setTxError]);

  useEffect(() => {
    if (isApproveError) {
      setTxError("LINK approval transaction failed on-chain. Please check your transaction in the block explorer.");
      setPendingAction(null);
      setApprovalPhase("none");
    }
  }, [isApproveError, setTxError]);

  const handleApproveLINK = useCallback(async (action: string) => {
    if (!linkFeePerAction) return;
    try {
      setPendingAction(action); // Store the action to execute after approval
      setApprovalPhase("link"); // Mark that we're in LINK approval phase
      // Approve enough for many actions (100 actions worth)
      const approvalAmount = linkFeePerAction * BigInt(100);
      
      // Set gas prices explicitly to meet Polygon Amoy minimum requirements
      // The network requires at least 25 Gwei for maxPriorityFeePerGas
      // We set both values to 30 Gwei to ensure we're above the minimum
      const minGasPrice = BigInt(30_000_000_000); // 30 Gwei in wei
      
      approveLINK({
        address: LINK_TOKEN_ADDRESS,
        abi: LINK_TOKEN_ABI,
        functionName: "approve",
        args: [gameAddress, approvalAmount],
        maxPriorityFeePerGas: minGasPrice,
        maxFeePerGas: minGasPrice * BigInt(2), // Set maxFeePerGas to 2x priority fee
      });
    } catch (err) {
      setTxError("Failed to approve LINK");
      setPendingAction(null);
      setApprovalPhase("none");
    }
  }, [linkFeePerAction, approveLINK, gameAddress]);

  // Check if LINK is approved for at least one more action
  const isLINKApproved = linkAllowance && linkFeePerAction && linkAllowance >= linkFeePerAction;
  
  // Update ref on every render so timer callback has fresh value
  isLINKApprovedRef.current = !!isLINKApproved;

  // Read insurance bet from contract (more reliable than React state)
  // Note: insuranceBet is a public state variable, which auto-generates a getter function
  const { data: contractInsuranceBet, isLoading: isLoadingInsuranceBet, error: insuranceBetError } = useReadContract({
    address: gameAddress,
    abi: GAME_ABI,
    functionName: "insuranceBet",
    query: {
      enabled: !!gameAddress,
      refetchInterval: false, // DISABLED - only manual refetch to prevent crash
    },
  });



  // Read final payout from contract (set when game finishes, reliable after reloads)
  const { data: contractFinalPayout, refetch: refetchFinalPayout } = useReadContract({
    address: gameAddress,
    abi: GAME_ABI,
    functionName: "finalPayout",
    query: {
      enabled: !!gameAddress,
      refetchInterval: false, // DISABLED - only manual refetch to prevent crash
      staleTime: gameState === GameState.Finished ? Infinity : 0, // Cache forever when finished
    },
  });

  // Check GameToken allowance for this game contract
  const { data: tokenAllowance, refetch: refetchTokenAllowance } = useReadContract({
    address: GAME_TOKEN_ADDRESS,
    abi: GAME_TOKEN_ABI,
    functionName: "allowance",
    args: address ? [address, gameAddress] : undefined,
    query: {
      refetchInterval: false, // DISABLED - only manual refetch to prevent crash
    },
  });

  // Approve GameToken for the game contract
  const { 
    writeContract: approveToken, 
    data: approveTokenTxHash, 
    isPending: isApprovingToken,
    error: approveTokenError 
  } = useWriteContract();
  
  const { isSuccess: isTokenApproveSuccess, isError: isTokenApproveError } = useWaitForTransactionReceipt({
    hash: approveTokenTxHash,
  });

  // Log approval errors
  useEffect(() => {
    if (approveTokenError) {
      setTxError(`Token approval failed: ${approveTokenError.message}`);
      setPendingAction(null);
      setApprovalPhase("none");
    }
  }, [approveTokenError, setTxError]);

  useEffect(() => {
    if (isTokenApproveError) {
      setTxError("Token approval transaction failed on-chain. Please check your transaction in the block explorer.");
      setPendingAction(null);
      setApprovalPhase("none");
    }
  }, [isTokenApproveError, setTxError]);

  const handleApproveToken = async (action: string, amount: bigint) => {
    try {
      setPendingAction(action); // Store the action to execute after approval
      setApprovalPhase("token"); // Mark that we're in token approval phase
      // Approve the specific amount needed (or a bit more for buffer)
      const approvalAmount = amount * BigInt(2); // 2x buffer
      
      approveToken({
        address: GAME_TOKEN_ADDRESS,
        abi: GAME_TOKEN_ABI,
        functionName: "approve",
        args: [gameAddress, approvalAmount],
      });
    } catch (err) {
      setTxError(`Failed to approve tokens: ${err instanceof Error ? err.message : 'Unknown error'}`);
      setPendingAction(null);
      setApprovalPhase("none");
    }
  };

  // Check if tokens are approved for a specific amount
  const isTokenApprovedFor = (amount: bigint) => {
    return tokenAllowance && tokenAllowance >= amount;
  };

  // Parse game state early (needed for refetchAllGameData)
  const state = gameState ? Number(gameState) : 0;
  const currentHand = Number(currentHandIndex || 0);
  const dealerCardsFromContract = Array.isArray(dealerCardsData) ? dealerCardsData.map(c => BigInt(c)) : [];

  // CRITICAL: Update refs on every render so setTimeout callbacks have fresh values
  // This prevents stale closure issues in the dealer automation effect
  latestGameStateRef.current = state;
  latestDealerCardsRef.current = (dealerCardsData as readonly bigint[] | undefined) || [];
  latestHoleCardRevealedRef.current = dealerHoleCardRevealed;
  // Note: isPendingRef is updated after isPending is declared (see below)

  // COMPREHENSIVE REFETCH: Invalidates cache and forces UI update
  const refetchAllGameData = useCallback(async () => {
    // Set refetching flag to prevent dealer automation during refetch
    isRefetchingRef.current = true;
    
    // Step 1: Invalidate ALL wagmi queries for this game contract
    // Use a safer predicate that doesn't rely on JSON.stringify (which can't handle BigInt)
    await queryClient.invalidateQueries({
      predicate: (query) => {
        // Check if query key contains the game address (as a string or in any form)
        const keyStr = String(query.queryKey);
        return keyStr.toLowerCase().includes(gameAddress.toLowerCase());
      }
    });
    
    // Step 2: Force refetch all queries (including token allowance after insurance)
    await Promise.all([
      refetch(),
      refetchHand0Cards(),
      refetchHand1Cards(),
      refetchHand2Cards(),
      refetchHand3Cards(),
      refetchDealerCards(),
      refetchHand0Bet(),
      refetchHand1Bet(),
      refetchHand2Bet(),
      refetchHand3Bet(),
      refetchTokenAllowance(), // CRITICAL: Refetch allowance after insurance/actions
    ]);
    
    // Step 3: Force component re-render by updating state
    setRefreshTrigger(prev => prev + 1);
    
    // Clear refetching flag after a longer delay to prevent dealer automation
    // during the refetch window. This is especially important after VRF completion
    // when we do multiple waves of refetching.
    setTimeout(() => {
      isRefetchingRef.current = false;
    }, 2000); // Extended to 2 seconds to cover multiple refetch waves
  }, [
    queryClient, 
    gameAddress,
    refetch, 
    refetchHand0Cards, 
    refetchHand1Cards, 
    refetchHand2Cards, 
    refetchHand3Cards, 
    refetchDealerCards,
    refetchHand0Bet,
    refetchHand1Bet,
    refetchHand2Bet,
    refetchHand3Bet,
    refetchTokenAllowance,
  ]);

  // Transaction handler with gas optimization and simulation
  // Memoize callbacks to prevent execute function from changing on every render
  const onSuccess = useCallback(() => {
    const completedAction = executingActionRef.current;
    const isDealerAction = completedAction === "dealerHit" || completedAction === "continueDealer";
    
    console.log(`✅ TRANSACTION SUCCESS: ${completedAction} (isDealerAction: ${isDealerAction})`);
    
    // CRITICAL: Use comprehensive refetch after successful transaction
    // This ensures cards appear after VRF completes and cache is invalidated
    setTimeout(() => {
      console.log(`🔄 onSuccess refetch for ${completedAction}`);
      refetchAllGameData();
    }, 1000);
    
    setTxError(null);
    
    // If we just completed a split action, mark the current hand as recently split
    // Use ref instead of state since state might be stale in this callback
    if (completedAction === "split") {
      setRecentlySplitHand(0); // Mark that a split just happened
      // Clear this flag after a delay to allow state to refetch
      setTimeout(() => {
        setRecentlySplitHand(null);
      }, 3000); // Increased to 3 seconds to ensure state has time to update
    }
    
    // Reset dealer hit trigger flag after successful dealerHit or continueDealer
    // This allows the next DealerNeedsToHit event to trigger another dealerHit
    if (isDealerAction) {
      console.log(`🎰 Resetting dealer automation flags after ${completedAction} success`);
      dealerHitTriggeredRef.current = false;
      dealerActionInProgressRef.current = false; // Reset so polling can trigger next action
      
      // CRITICAL: Do NOT reset dealerAutomationTriggeredRef here!
      // This flag prevents multiple automation attempts within the same DealerTurn session.
      // It should only be reset when leaving DealerTurn state, not after each dealer action.
      // Resetting it here would allow the timer to fire again if the refetch causes a re-render.
    }
    
    setCurrentAction(null); // Clear current action on success
    executingActionRef.current = null; // Clear the ref
  }, [refetchAllGameData]);

  const onError = useCallback((err: Error) => {
    // Check if this was a dealer action that failed
    const failedAction = executingActionRef.current;
    const isDealerAction = failedAction === "dealerHit" || failedAction === "continueDealer";
    
    // CRITICAL: Silence the 0x756fbea8 error for dealer actions
    // This error occurs when dealer automation tries to act at the wrong time
    // (e.g., game already finished, wrong state). We handle this gracefully
    // with our state checks, so no need to show it to the user.
    const isContractRevertError = err.message.includes('0x756fbea8');
    
    if (isDealerAction) {
      if (isContractRevertError) {
        console.log(`🔇 Silenced contract revert error (0x756fbea8) for ${failedAction} - game state likely changed`);
        // Don't show error to user, just log it and clean up
        setCurrentAction(null);
        executingActionRef.current = null;
        dealerActionInProgressRef.current = false;
        return; // Exit early - don't retry or show error
      }
      
      console.error(`❌ Dealer action failed: ${failedAction} - Error: ${err.message}`);
      
      // RETRY LOGIC: Schedule a retry after 3 seconds (only for non-contract-revert errors)
      console.log("🔄 Scheduling dealer action retry in 3 seconds...");
      setTimeout(() => {
        // Check if we're still in DealerTurn before retrying
        const currentState = latestGameStateRef.current;
        if (currentState === GameState.DealerTurn && !isPendingRef.current) {
          console.log(`🔄 Triggering retry for failed dealer action: ${failedAction}`);
          setFailedDealerAction(failedAction); // Set state to trigger retry
        } else {
          console.log(`⏭️ Skipping retry - game state changed to ${currentState ? GameState[currentState] : 'unknown'} or transaction pending`);
        }
      }, 3000); // Wait 3 seconds before retry
    } else {
      // For non-dealer actions, always show the error
      setTxError(err.message);
    }
    
    setCurrentAction(null); // Clear current action on error
    executingActionRef.current = null; // Clear the ref
    dealerActionInProgressRef.current = false; // Reset on error to allow retry
  }, []);

  const { execute: executeRaw, isPending, hash, error } = useGameTransaction({
    gameAddress,
    abi: GAME_ABI,
    onSuccess,
    onError,
  });

  // Update isPending ref on every render (after isPending is declared)
  isPendingRef.current = isPending;

  // SMART POLLING: Only poll during Dealing state to detect VRF completion
  // SAFE: Poll every 3 seconds to avoid system crash
  useEffect(() => {
    if (state === GameState.Dealing) {
      console.log("🎲 VRF in progress - starting smart polling...");
      
      const interval = setInterval(async () => {
        console.log("🔄 Polling for VRF completion...");
        
        const result = await refetch(); // Refetch game state
        console.log("🔄 Polling result - new state:", result.data);
      }, 3000); // Poll every 3 seconds (SAFE)
      
      return () => {
        console.log("✅ VRF complete or state changed - stopping polling");
        clearInterval(interval);
      };
    }
  }, [state, refetch]);
  
  // Track previous state to detect VRF completion
  const prevDealingState = useRef<GameState | undefined>(undefined);
  
  // Separate effect to refetch cards when transitioning OUT of Dealing state
  useEffect(() => {
    const wasDealing = prevDealingState.current === GameState.Dealing;
    const isDealingNow = state === GameState.Dealing;
    
    console.log(`🔍 State transition check - wasDealing: ${wasDealing}, isDealingNow: ${isDealingNow}, current state: ${state}`);
    
    // If we were in Dealing and now we're not, VRF just completed - refetch ALL card data
    if (wasDealing && !isDealingNow) {
      console.log("🃏 VRF completed! Using COMPREHENSIVE REFETCH...");
      
      // CRITICAL FIX: Only do ONE refetch, not two!
      // Multiple refetches were extending the isRefetchingRef window past the 3-second
      // dealer automation timer, causing race conditions.
      refetchAllGameData();
      
      // REMOVED: Second wave refetch was causing timing issues
      // The single comprehensive refetch is sufficient, and avoiding the second
      // refetch prevents the isRefetchingRef flag from being extended past the
      // 3-second dealer automation timer.
    }
    
    // Update the ref for next render
    prevDealingState.current = state;
    // CRITICAL: Remove refetchAllGameData from deps to prevent effect from re-running
    // when refetch function identity changes. This ensures we only refetch ONCE per
    // Dealing->DealerTurn transition, preventing phantom transactions.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [state]); // ONLY depend on state
  
  // REMOVED: This effect was causing race conditions with dealer automation!
  // The dealer automation effect already handles resetting all flags when leaving DealerTurn.
  // This effect was running AFTER the automation effect set up the timer and was resetting
  // dealerAutomationTriggeredRef.current = false, which allowed the timer to execute
  // even though automation had already been triggered. This was the source of phantom transactions!
  
  // Create stable hash of dealer cards for dependency tracking
  const dealerCardsHash = dealerCardsFromContract.length > 0 
    ? dealerCardsFromContract.map((c: bigint) => c.toString()).join('-') 
    : '';
  const cachedCardsHash = lastKnownDealerCards.length > 0
    ? lastKnownDealerCards.map(c => c.toString()).join('-')
    : '';
  
  // Preserve dealer cards during VRF requests to prevent visual reset
  // CRITICAL RULE: Once we have N dealer cards, we NEVER accept fewer than N cards from contract
  // unless the game state is NotStarted (indicating a fresh game)
  useEffect(() => {
    const contractCardCount = dealerCardsFromContract.length;
    const cachedCardCount = lastKnownDealerCards.length;
    const isNotStarted = state === GameState.NotStarted;
    
    // RESET on new game: Clear cache when game is NotStarted
    if (isNotStarted && cachedCardCount > 0) {
      setLastKnownDealerCards([]);
      return;
    }
    
    // Case 1: We have MORE cards from contract - always update (new card added)
    if (contractCardCount > cachedCardCount) {
      setLastKnownDealerCards(dealerCardsFromContract);
      return;
    }
    
    // Case 2: We have FEWER cards from contract - IGNORE UNLESS it's a clear new game
    if (contractCardCount < cachedCardCount) {
      if (contractCardCount === 1 && isNotStarted) {
        // This is a new game starting with 1 card
        setLastKnownDealerCards(dealerCardsFromContract);
      } else {
        // Contract returning old state during VRF - IGNORE
      }
      return;
    }
    
    // Case 3: SAME number of cards - check if content changed
    if (contractCardCount === cachedCardCount && contractCardCount > 0) {
      const cardsChanged = dealerCardsFromContract.some((card, i) => card !== lastKnownDealerCards[i]);
      if (cardsChanged) {
        // Cards changed but count is same - could be VRF replacing cards
        // Only update if we have MORE information (e.g., hole card revealed)
        
        // Only update if this looks like a legitimate change (e.g., card values increased)
        // Check if any card ID is larger - indicates new cards, not old state
        const hasLargerCard = dealerCardsFromContract.some((card, i) => {
          const oldCard = lastKnownDealerCards[i];
          return oldCard === BigInt(0) || card > oldCard;
        });
        
        if (hasLargerCard || contractCardCount === 2) {
          setLastKnownDealerCards(dealerCardsFromContract);
        }
      }
      return;
    }
    
    // Case 4: Contract returns 0 cards but we have cached cards - keep cached cards
    if (contractCardCount === 0 && cachedCardCount > 0) {
      return;
    }
    
    // Case 5: First render with cards from contract
    if (contractCardCount > 0 && cachedCardCount === 0) {
      setLastKnownDealerCards(dealerCardsFromContract);
      return;
    }
    
    // Case 6: Both empty - nothing to do
    if (contractCardCount === 0 && cachedCardCount === 0) {
      // No cards yet
    }
  }, [dealerCardsFromContract.length, dealerCardsHash, lastKnownDealerCards.length, cachedCardsHash, state]);
  
  // Always use cached cards as the source of truth
  // Fall back to contract data only if we have no cached cards yet
  const dealerCards = lastKnownDealerCards.length > 0 ? lastKnownDealerCards : dealerCardsFromContract;

  // Track initial card count on mount to distinguish between cards already present vs newly dealt
  const initialDealerCardCount = useRef<number | null>(null);
  const initialPlayerCardCounts = useRef<number[] | null>(null);

  // Set initial counts on first render with cards (so we don't animate cards that were already there)
  useEffect(() => {
    // Special case: If game is NotStarted and we have no initial count, set it to 0
    // This means we're starting fresh and should animate all cards
    if (state === GameState.NotStarted && initialDealerCardCount.current === null) {
      initialDealerCardCount.current = 0;
      return;
    }
    
    // For Dealing state, if initial count is null, record the count once cards arrive
    // This handles the initial deal - cards that appear during Dealing are from VRF, should NOT animate
    if (state === GameState.Dealing && initialDealerCardCount.current === null && dealerCards.length > 0) {
      initialDealerCardCount.current = dealerCards.length;
      return;
    }
    
    // For PlayerTurn/DealerTurn/Finished states ONLY:
    // If we have cards and no initial count, this is a page refresh/reload
    // Record the current count so we don't animate existing cards
    if (initialDealerCardCount.current === null && dealerCards.length > 0) {
      // Only set initial count if we're not in the middle of a game starting
      // If state is PlayerTurn but we have 0 cards initially, this means cards are being dealt NOW
      if (state !== GameState.PlayerTurn || dealerCards.length > 1) {
        initialDealerCardCount.current = dealerCards.length;
      } else {
        initialDealerCardCount.current = 0;
      }
    }
  }, [dealerCards.length, state]);

  // Track when dealer gets NEW cards (beyond initial count) for fade/flip animations
  useEffect(() => {
    
    // Skip if we haven't set initial count yet
    if (initialDealerCardCount.current === null) {
      return;
    }
    
    const currentCount = dealerCards.length;
    const initialCount = initialDealerCardCount.current;
    
    // Only update if we have MORE cards than the initial count (new cards added during gameplay)
    // seenDealerCardCount tracks cards added AFTER the initial load
    if (currentCount > initialCount && seenDealerCardCount < (currentCount - initialCount)) {
      const newSeenCount = currentCount - initialCount;
      setSeenDealerCardCount(newSeenCount);
    }
    
    // If dealer cards went from something to zero (game reset), ensure flip state is reset
    if (currentCount === 0 && dealerFirstCardShouldFlip) {
      setDealerFirstCardShouldFlip(false);
    }
  }, [dealerCards.length, seenDealerCardCount, state, dealerFirstCardShouldFlip]);

  // Separate effect to trigger flip animation when first card arrives
  // This runs AFTER the seenDealerCardCount is updated in the previous effect
  // We use DOUBLE RAF to ensure the card renders first before triggering the flip
  useEffect(() => {
    // When first card arrives (seenCount becomes 1) and flip not yet triggered
    if (seenDealerCardCount === 1 && !dealerFirstCardShouldFlip && dealerCards.length > 0) {
      // Double RAF: ensures the card renders with shouldFlip={false} first, then we can trigger the flip
      requestAnimationFrame(() => {
        requestAnimationFrame(() => {
          setDealerFirstCardShouldFlip(true);
        });
      });
    }
  }, [seenDealerCardCount, dealerFirstCardShouldFlip, dealerCards.length, dealerCards[0]]);

  // Reset seen cards when game is NotStarted (new game)
  useEffect(() => {
    if (state === GameState.NotStarted) {
      setSeenDealerCardCount(0);
      setSeenPlayerCardCounts([0, 0, 0, 0]);
      setDealerFirstCardShouldFlip(false);
      initialDealerCardCount.current = null; // Reset so we can set new initial count
      initialPlayerCardCounts.current = null;
    }
  }, [state]);

  // Get player card counts early for animation tracking (before early return)
  const playerCardCounts = [
    Array.isArray(playerHand0Cards) ? playerHand0Cards.length : 0,
    Array.isArray(playerHand1Cards) ? playerHand1Cards.length : 0,
    Array.isArray(playerHand2Cards) ? playerHand2Cards.length : 0,
    Array.isArray(playerHand3Cards) ? playerHand3Cards.length : 0,
  ];

  // Set initial player card counts on first render (so we don't animate cards that were already there)
  useEffect(() => {
    // Special case: If game is NotStarted and we have no initial counts, set them to [0,0,0,0]
    // This means we're starting fresh and should animate all cards
    if (state === GameState.NotStarted && initialPlayerCardCounts.current === null) {
      initialPlayerCardCounts.current = [0, 0, 0, 0];
      return;
    }
    
    // For other states, if we have cards and no initial counts, record the current counts
    // This handles page refresh - we don't want to animate cards that already exist
    if (initialPlayerCardCounts.current === null && playerCardCounts.some(count => count > 0)) {
      initialPlayerCardCounts.current = [...playerCardCounts];
    }
  }, [playerCardCounts[0], playerCardCounts[1], playerCardCounts[2], playerCardCounts[3], state]);

  // Track when player hands get NEW cards (beyond initial count) for fade animations
  useEffect(() => {
    // Skip if we haven't set initial counts yet
    if (initialPlayerCardCounts.current === null) return;
    
    const newCounts = [...seenPlayerCardCounts];
    let changed = false;
    
    playerCardCounts.forEach((count, index) => {
      const initialCount = initialPlayerCardCounts.current![index];
      const currentSeenCount = seenPlayerCardCounts[index];
      
      // Track cards added AFTER initial load
      // seenPlayerCardCounts[i] represents how many cards were added to hand i after page load
      const newlyAddedCards = count - initialCount;
      
      if (newlyAddedCards > currentSeenCount) {
        newCounts[index] = newlyAddedCards;
        changed = true;
      }
    });
    
    if (changed) {
      setSeenPlayerCardCounts(newCounts);
    }
  }, [playerCardCounts[0], playerCardCounts[1], playerCardCounts[2], playerCardCounts[3]]);
  // CRITICAL: seenPlayerCardCounts removed from deps to prevent infinite loop

  // Wrapper to prevent execution if game is finished or in wrong state
  const execute = useCallback((functionName: string, args?: any[], value?: bigint) => {
    // CRITICAL FIX: Use latestGameStateRef.current for state checks to avoid stale closure issues
    // This ensures we always check the CURRENT state, not the state from when execute was created
    const currentState = latestGameStateRef.current ?? 0;
    const isDealerAction = functionName === "dealerHit" || functionName === "continueDealer";
    
    console.log(`📞 EXECUTE CALLED: ${functionName} - Current state: ${GameState[currentState]} (${currentState}), isPending: ${isPendingRef.current}, dealerActionInProgress: ${dealerActionInProgressRef.current}`);
    
    // CRITICAL FIX: Always prevent dealer actions if game is finished
    // This prevents contract errors at game end
    if (currentState === GameState.Finished) {
      if (isDealerAction) {
        console.log(`🛑 BLOCKED: Prevented ${functionName} - game is finished`);
        dealerActionInProgressRef.current = false; // Reset flag
        return;
      }
      
      // For non-dealer actions, show error (unless starting new game)
      if (functionName !== "startGame") {
        setTxError("Cannot perform action - game is finished");
      }
      return;
    }
    
    // Validate game state for player actions
    const isPlayerTurnAction = ["hit", "stand", "doubleDown", "split"].includes(functionName);
    const isInsuranceAction = functionName === "placeInsurance" || functionName === "skipInsurance";
    const isSurrender = functionName === "surrender";
    
    if (isPlayerTurnAction && currentState !== GameState.PlayerTurn) {
      console.log(`🛑 BLOCKED: Prevented ${functionName} - not in PlayerTurn (current: ${GameState[currentState]})`);
      setTxError(`Cannot ${functionName} - game state changed to ${GameState[currentState]}. Please wait for your turn.`);
      return;
    }
    
    if (isInsuranceAction && currentState !== GameState.InsuranceOffer) {
      console.log(`🛑 BLOCKED: Prevented ${functionName} - not in InsuranceOffer (current: ${GameState[currentState]})`);
      setTxError(`Cannot perform insurance action - game state changed to ${GameState[currentState]}.`);
      return;
    }
    
    if (isSurrender && currentState !== GameState.PlayerTurn && currentState !== GameState.InsuranceOffer) {
      console.log(`🛑 BLOCKED: Prevented ${functionName} - not in PlayerTurn or InsuranceOffer (current: ${GameState[currentState]})`);
      setTxError(`Cannot surrender - game state changed to ${GameState[currentState]}.`);
      return;
    }
    
    // CRITICAL: Dealer actions can ONLY run in DealerTurn state
    if (isDealerAction && currentState !== GameState.DealerTurn) {
      console.log(`🛑 BLOCKED: Prevented ${functionName} - not in DealerTurn (current: ${GameState[currentState]})`);
      // Reset the action in progress flag since we're blocking the action
      dealerActionInProgressRef.current = false;
      return;
    }
    
    // CRITICAL: Also prevent dealer actions if we're in Dealing state (VRF in progress)
    // This prevents the race condition where we call a dealer action, it transitions to Dealing,
    // but the frontend state hasn't updated yet and tries to call again
    if (isDealerAction && currentState === GameState.Dealing) {
      console.log(`🛑 BLOCKED: Prevented ${functionName} - VRF in progress (Dealing state)`);
      // Reset the action in progress flag since we're blocking the action
      dealerActionInProgressRef.current = false;
      return;
    }
    
    // CRITICAL: EXTRA SAFETY CHECK - Block dealer actions if we're in PlayerTurn or InsuranceOffer
    // This should never happen due to earlier checks, but adds defense in depth
    if (isDealerAction && (currentState === GameState.PlayerTurn || currentState === GameState.InsuranceOffer)) {
      console.log(`🛑🛑🛑 CRITICAL BLOCK: Prevented ${functionName} - state is ${GameState[currentState]} (this should never happen!)`);
      dealerActionInProgressRef.current = false;
      return;
    }
    
    console.log(`✅ EXECUTE APPROVED: ${functionName} - State check passed, executing transaction`);
    
    // Set current action before executing (both in state and ref)
    setCurrentAction(functionName);
    executingActionRef.current = functionName;
    executeRaw(functionName, args, value);
  }, [executeRaw, setTxError]); // REMOVED isPending and pendingAction - they're only used for logging

  // Refetch token allowance after successful approval and execute pending action
  useEffect(() => {
    // Only process if we're in the token approval phase
    if (isTokenApproveSuccess && pendingAction && approvalPhase === "token") {
      
      // Refetch allowance and wait for it to complete before executing action
      const executeAfterRefetch = async () => {
        try {
          // Multiple refetch attempts with increasing delays to ensure allowance is updated
          let attempts = 0;
          const maxAttempts = 5;
          const checkAndExecute = async (): Promise<void> => {
            attempts++;
            
            const { data: newAllowance } = await refetchTokenAllowance();
            
            // Check if the allowance is now sufficient
            const currentBet = playerHand0Bet ? BigInt(playerHand0Bet) : BigInt(0);
            // Insurance is always half the bet (maximum allowed by contract)
            const insuranceAmountBigInt = currentBet / BigInt(2);
            
            // For insurance, check against the insurance amount; for others, check against current bet
            const requiredAmount = pendingAction === "placeInsurance" ? insuranceAmountBigInt : currentBet;
            const isNowApproved = newAllowance && newAllowance >= requiredAmount;
            
            if (isNowApproved) {
              
              // Check if game state is still valid for the action
              const currentState = gameState ? Number(gameState) : 0;
              const isPlayerTurnAction = ["doubleDown", "split", "hit", "stand"].includes(pendingAction);
              const isInsuranceAction = pendingAction === "placeInsurance";
              
              if (isPlayerTurnAction && currentState !== GameState.PlayerTurn) {
                setTxError(`Cannot ${pendingAction}: game state changed. Please try again if still in player's turn.`);
                setPendingAction(null);
                setApprovalPhase("none");
                return;
              }
              
              if (isInsuranceAction && currentState !== GameState.InsuranceOffer) {
                setTxError(`Cannot place insurance: game state changed.`);
                setPendingAction(null);
                setApprovalPhase("none");
                return;
              }
              
              // Execute with args if it's placeInsurance
              if (pendingAction === "placeInsurance") {
                execute(pendingAction, [insuranceAmountBigInt]);
              } else {
                execute(pendingAction);
              }
              setPendingAction(null);
              setApprovalPhase("none");
            } else if (attempts < maxAttempts) {
              // Try again after a delay
              await new Promise(resolve => setTimeout(resolve, 1000));
              return checkAndExecute();
            } else {
              setTxError('Token approval succeeded but allowance not updated. Please try again.');
              setPendingAction(null);
              setApprovalPhase("none");
            }
          };
          
          // Start checking after initial delay
          await new Promise(resolve => setTimeout(resolve, 2000));
          await checkAndExecute();
        } catch (err) {
          setTxError('Failed to verify token approval. Please try again.');
          setPendingAction(null);
          setApprovalPhase("none");
        }
      };
      
      executeAfterRefetch();
    }
  }, [isTokenApproveSuccess, pendingAction, approvalPhase, execute, playerHand0Bet, setTxError]);
  // NOTE: refetchTokenAllowance is NOT in deps to avoid infinite loop

  // Refetch LINK allowance after successful approval and execute pending action
  useEffect(() => {
    // Only process if we're in the LINK approval phase
    if (isApproveSuccess && pendingAction && approvalPhase === "link") {
      
      // Refetch allowance and wait for it to complete before executing action
      const executeAfterRefetch = async () => {
        try {
          // Multiple refetch attempts with increasing delays to ensure allowance is updated
          let attempts = 0;
          const maxAttempts = 5;
          const checkAndExecute = async (): Promise<void> => {
            attempts++;
            
            const { data: newAllowance } = await refetchLinkAllowance();
            
            // Check if the allowance is now sufficient
            const isNowApproved = newAllowance && linkFeePerAction && newAllowance >= linkFeePerAction;
            
            if (isNowApproved) {
              
              // Before executing, check if token approval is also needed for this action
              const currentBet = playerHand0Bet ? BigInt(playerHand0Bet) : BigInt(0);
              // Insurance is always half the bet (maximum allowed by contract)
              const insuranceAmountBigInt = currentBet / BigInt(2);
              
              const needsTokenApproval = 
                (pendingAction === "doubleDown" || pendingAction === "split") && !isTokenApprovedFor(currentBet) ||
                (pendingAction === "placeInsurance" && !isTokenApprovedFor(insuranceAmountBigInt));
              
              if (needsTokenApproval) {
                const amount = pendingAction === "placeInsurance" ? insuranceAmountBigInt : currentBet;
                // Move to token approval phase - this will prevent this useEffect from running again
                handleApproveToken(pendingAction, amount);
                // Don't clear pendingAction - let token approval flow handle execution
                return;
              }
              
              // Check if game state is still valid for the action
              const currentState = gameState ? Number(gameState) : 0;
              const isPlayerTurnAction = ["doubleDown", "split", "hit", "stand"].includes(pendingAction);
              const isInsuranceAction = pendingAction === "placeInsurance";
              const isSurrender = pendingAction === "surrender";
              const isDealerAction = pendingAction === "dealerHit" || pendingAction === "continueDealer";
              
              if (isPlayerTurnAction && currentState !== GameState.PlayerTurn) {
                setTxError(`Cannot ${pendingAction}: game state changed. Please try again if still in player's turn.`);
                setPendingAction(null);
                setApprovalPhase("none");
                return;
              }
              
              if (isInsuranceAction && currentState !== GameState.InsuranceOffer) {
                setTxError(`Cannot place insurance: game state changed.`);
                setPendingAction(null);
                setApprovalPhase("none");
                return;
              }
              
              if (isSurrender && currentState !== GameState.PlayerTurn && currentState !== GameState.InsuranceOffer) {
                setTxError(`Cannot surrender: game state changed.`);
                setPendingAction(null);
                setApprovalPhase("none");
                return;
              }
              
              if (isDealerAction && currentState !== GameState.DealerTurn) {
                console.log(`⚠️ LINK approval complete but no longer in DealerTurn - aborting ${pendingAction}`);
                setPendingAction(null);
                setApprovalPhase("none");
                dealerActionInProgressRef.current = false;
                return;
              }
              
              execute(pendingAction);
              setPendingAction(null);
              setApprovalPhase("none");
            } else if (attempts < maxAttempts) {
              // Try again after a delay
              await new Promise(resolve => setTimeout(resolve, 1000));
              return checkAndExecute();
            } else {
              setTxError('LINK approval succeeded but allowance not updated. Please try again.');
              setPendingAction(null);
              setApprovalPhase("none");
            }
          };
          
          // Start checking after initial delay
          await new Promise(resolve => setTimeout(resolve, 2000));
          await checkAndExecute();
        } catch (err) {
          setTxError('Failed to verify LINK approval. Please try again.');
          setPendingAction(null);
          setApprovalPhase("none");
        }
      };
      
      executeAfterRefetch();
    }
  }, [isApproveSuccess, pendingAction, approvalPhase, execute, linkFeePerAction, setTxError]);
  // NOTE: refetchLinkAllowance is NOT in deps to avoid infinite loop

  const handleHit = () => {
    // Prevent action if game is finished
    if (gameState === GameState.Finished || gameResult) {
      return;
    }
    execute("hit");
  };

  const handleStand = () => {
    // Prevent action if game is finished
    if (gameState === GameState.Finished || gameResult) {
      return;
    }
    
    // Check if we have enough LINK approved (stand() needs LINK for dealer's hole card)
    if (!isLINKApproved) {
      handleApproveLINK("stand");
      return;
    }
    
    execute("stand");
  };

  const handleDoubleDown = () => {
    // Prevent action if game is finished
    if (gameState === GameState.Finished || gameResult) {
      return;
    }
    
    // Don't allow action if ANY approval is pending or already executing
    if (isApprovingToken || isApprovingLINK || isPending) {
      return;
    }
    
    // Don't allow if there's already a pending action
    if (pendingAction) {
      return;
    }
    
    // Don't allow if there's already a current action being executed
    if (currentAction) {
      return;
    }
    
    // Double down requires additional bet equal to original bet
    const currentBet = playerHand0Bet ? BigInt(playerHand0Bet) : BigInt(0);
    
    // Priority 1: Check LINK approval FIRST (most important)
    if (!isLINKApproved) {
      handleApproveLINK("doubleDown");
      return;
    }
    
    // Priority 2: Check token approval AFTER LINK is approved
    if (!isTokenApprovedFor(currentBet)) {
      handleApproveToken("doubleDown", currentBet);
      return;
    }
    
    // Priority 3: Execute action only when both approvals are done
    execute("doubleDown");
  };

  const handleSplit = () => {
    // Prevent action if game is finished
    if (gameState === GameState.Finished || gameResult) {
      return;
    }
    
    // Don't allow action if ANY approval is pending or already executing
    if (isApprovingToken || isApprovingLINK || isPending) {
      return;
    }
    
    // Don't allow if there's already a pending action
    if (pendingAction) {
      return;
    }
    
    // Don't allow if there's already a current action being executed
    if (currentAction) {
      return;
    }
    
    // Split requires additional bet equal to original bet
    const currentBet = playerHand0Bet ? BigInt(playerHand0Bet) : BigInt(0);
    
    // Priority 1: Check LINK approval FIRST
    if (!isLINKApproved) {
      handleApproveLINK("split");
      return;
    }
    
    // Priority 2: Check token approval AFTER LINK is approved
    if (!isTokenApprovedFor(currentBet)) {
      handleApproveToken("split", currentBet);
      return;
    }
    
    // Priority 3: Execute action only when both approvals are done
    execute("split");
  };

  const handlePlaceInsurance = () => {
    // Prevent action if game is finished
    if (gameState === GameState.Finished || gameResult) {
      return;
    }
    
    // Check if we're still in insurance phase
    if (gameState !== GameState.InsuranceOffer) {
      setTxError("Insurance phase has ended. The game has moved to the next phase.");
      return;
    }
    
    // Don't allow action if ANY approval is pending or already executing
    if (isApprovingToken || isApprovingLINK || isPending) {
      return;
    }
    
    // Don't allow if there's already a pending action
    if (pendingAction) {
      return;
    }
    
    // Calculate insurance amount as half the bet (contract maximum)
    const currentBet = playerHand0Bet ? BigInt(playerHand0Bet) : BigInt(0);
    const amount = currentBet / BigInt(2);
    
    if (amount === BigInt(0)) {
      setTxError("Cannot place insurance - invalid bet amount");
      return;
    }
    
    // Priority 1: Check LINK approval FIRST
    if (!isLINKApproved) {
      handleApproveLINK("placeInsurance");
      return;
    }
    
    // Priority 2: Check token approval AFTER LINK is approved
    // Insurance requires tokens equal to the insurance amount
    if (!isTokenApprovedFor(amount)) {
      handleApproveToken("placeInsurance", amount);
      return;
    }
    
    // Priority 3: Execute action only when both approvals are done
    setPlacedInsuranceAmount(amount); // Track the insurance bet
    execute("placeInsurance", [amount]);
  };

  const handleSkipInsurance = () => {
    // Prevent action if game is finished
    if (gameState === GameState.Finished || gameResult) {
      return;
    }
    execute("skipInsurance");
  };

  const handleSurrender = () => {
    // Prevent action if game is finished
    if (gameState === GameState.Finished || gameResult) {
      return;
    }
    
    // Get current player hand data from contract
    const firstHandCards = playerHand0Cards?.length || 0;
    
    // Log current state for debugging
    
    // Double-check state before executing
    if (gameState !== GameState.PlayerTurn && gameState !== GameState.InsuranceOffer) {
      setTxError(`Cannot surrender - game state is ${gameState}, not PlayerTurn or InsuranceOffer`);
      return;
    }
    
    if (firstHandCards !== 2) {
      setTxError(`Cannot surrender - you have ${firstHandCards} cards (need exactly 2)`);
      return;
    }
    
    execute("surrender");
  };

  // Clear pending actions when game finishes
  useEffect(() => {
    if (state === GameState.Finished) {
      setPendingAction(null);
      setCurrentAction(null);
      setApprovalPhase("none");
    }
  }, [state]);

  // Clear recentlySplitHand flag when number of hands increases (split successful and refetched)
  const prevNumHandsRef = useRef<number>(1);
  useEffect(() => {
    if (numHands > prevNumHandsRef.current && recentlySplitHand !== null) {
      setRecentlySplitHand(null);
    }
    prevNumHandsRef.current = numHands;
  }, [numHands, recentlySplitHand]);

  // Initialize dealer hole card revealed state on first load based on game state
  const initializedRef = useRef(false);
  useEffect(() => {
    // Only run once on component mount when we have state data
    if (!initializedRef.current && state !== undefined) {
      const isDealerTurn = state === GameState.DealerTurn;
      const isFinished = state === GameState.Finished;
      
      // If the game is already in DealerTurn or Finished state when we load the page,
      // the hole card should already be revealed (no flip animation on page load)
      if (isDealerTurn || isFinished) {
        setDealerHoleCardRevealed(true);
      }
      
      initializedRef.current = true;
    }
  }, [state]);

  // Track when dealer's hole card should be revealed (and keep it revealed once revealed)
  useEffect(() => {
    const isDealerTurn = state === GameState.DealerTurn;
    const isFinished = state === GameState.Finished;
    const isNotStarted = state === GameState.NotStarted;
    
    // Reset flag ONLY when game hasn't started yet (not during dealing after initial)
    if (isNotStarted && dealerHoleCardRevealed) {
      setDealerHoleCardRevealed(false);
      initializedRef.current = false; // Reset for next game
    }
    
    // Clear cached dealer cards and insurance amount when starting a new game
    if (isNotStarted) {
      // Dealer cards reset handled by contract
    }
    
    if (isNotStarted && placedInsuranceAmount > BigInt(0)) {
      setPlacedInsuranceAmount(BigInt(0));
    }
    
    // Clear recently split flag for new game
    if (isNotStarted && recentlySplitHand !== null) {
      setRecentlySplitHand(null);
    }
    
    // Reveal card when dealer's turn or game finished, and keep it revealed
    if ((isDealerTurn || isFinished) && !dealerHoleCardRevealed) {
      setDealerHoleCardRevealed(true);
    }
  }, [state, dealerHoleCardRevealed, dealerCards.length, recentlySplitHand, placedInsuranceAmount]);

  // Helper function to calculate dealer score from cards (matches contract CardLogic)
  // CRITICAL: Memoized with useCallback to prevent effect re-runs
  const calculateDealerScore = useCallback((cards: readonly bigint[]): number => {
    if (!cards || cards.length === 0) return 0;
    
    let score = 0;
    let aces = 0;
    
    for (const cardId of cards) {
      const id = Number(cardId);
      if (id < 1 || id > 52) continue;
      
      const rank = ((id - 1) % 13) + 1;
      let value: number;
      
      if (rank === 1) {
        value = 11; // Ace
        aces++;
      } else if (rank >= 11) {
        value = 10; // Face cards
      } else {
        value = rank; // 2-10
      }
      
      score += value;
    }
    
    // Adjust for aces
    while (score > 21 && aces > 0) {
      score -= 10;
      aces--;
    }
    
    return score;
  }, []); // No dependencies - pure calculation function

  // Auto-trigger dealer actions by polling contract state (not relying on events!)
  // This is more reliable than event-based automation
  const continueDealerTriggeredRef = useRef(false);
  const finalContinueDealerAttemptedRef = useRef(false);
  const dealerActionInProgressRef = useRef(false);
  const lastDealerCardCountRef = useRef(0);
  const contractStatePollingIntervalRef = useRef<NodeJS.Timeout | null>(null);
  const waitingForContractStabilizationRef = useRef(false); // NEW: Track if we're waiting for the 1.5s delay
  const hasInitiallyFetchedCardsRef = useRef(false); // Track if we've fetched cards on page load in DealerTurn
  
  const dealerAutomationStateRef = useRef<{
    lastAttemptTime: number;
    lastCardCount: number;
    lastScore: number;
    attemptCount: number;
    stateEnteredAt: number; // Track when we first entered DealerTurn state
  }>({
    lastAttemptTime: 0,
    lastCardCount: 0,
    lastScore: 0,
    attemptCount: 0,
    stateEnteredAt: 0,
  });
  
  // State for timeout UI - show manual retry button if dealer is stuck
  const [secondsWaiting, setSecondsWaiting] = useState(0);
  
  // UI COUNTDOWN TIMER: Track how long we've been in DealerTurn for the countdown/retry UI
  useEffect(() => {
    const isDealerTurn = state === GameState.DealerTurn;
    
    if (!isDealerTurn) {
      // Reset timer when leaving DealerTurn
      dealerAutomationStateRef.current.stateEnteredAt = 0;
      setSecondsWaiting(0);
      return;
    }
    
    // Don't update counter if transaction is pending
    if (isPending || pendingAction) {
      return;
    }
    
    // Record when we first entered DealerTurn state
    if (dealerAutomationStateRef.current.stateEnteredAt === 0) {
      dealerAutomationStateRef.current.stateEnteredAt = Date.now();
      setSecondsWaiting(0);
    }
    
    // Update seconds counter every second for the UI
    const counterInterval = setInterval(() => {
      if (dealerAutomationStateRef.current.stateEnteredAt > 0) {
        const elapsed = Math.floor((Date.now() - dealerAutomationStateRef.current.stateEnteredAt) / 1000);
        setSecondsWaiting(elapsed);
      }
    }, 1000);
    
    // Cleanup timer on unmount or state change
    return () => {
      clearInterval(counterInterval);
    };
  }, [state, isPending, pendingAction]);
  
  // Manual retry handler for timeout UI
  const handleRetryDealerAction = useCallback(async () => {
    console.log("🔄🔄🔄 RETRY BUTTON CLICKED - handleRetryDealerAction called");
    console.log("🔄 User manually retrying dealer action after timeout");
    console.log("🔄 Current dealerCardsData (raw from contract):", dealerCardsData);
    console.log("🔄 Current dealerCards (cached/UI):", dealerCards);
    console.log("🔄 Current game state:", state);
    console.log("🔄 Player hands data:", {
      hand0: playerHand0Cards,
      hand1: playerHand1Cards,
      hand2: playerHand2Cards,
      hand3: playerHand3Cards
    });
    
    // CRITICAL: Verify we're actually in DealerTurn state
    if (state !== GameState.DealerTurn) {
      console.error("🔄 ERROR: Cannot retry - not in DealerTurn state (current:", state, ")");
      setTxError("Cannot retry dealer action - game state changed");
      return;
    }
    
    // Reset timeout state
    dealerAutomationStateRef.current.stateEnteredAt = Date.now(); // Reset timer
    setSecondsWaiting(0);
    
    // CRITICAL: Reset automation flag to allow retry
    console.log("🔄 Resetting dealerAutomationTriggeredRef to allow retry");
    dealerAutomationTriggeredRef.current = false;
    
    // CRITICAL: Reset the action in progress flag BEFORE any checks
    // This ensures we're not blocked by stale state from a previous failed transaction
    console.log("🔄 Resetting dealerActionInProgressRef to allow retry");
    dealerActionInProgressRef.current = false;
    
    // CRITICAL: Refetch contract state to ensure we have latest data
    console.log("🔄 Refetching contract state before retry...");
    const { data: freshState } = await refetch();
    const freshStateNum = freshState ? Number(freshState) : 0;
    
    if (freshStateNum !== GameState.DealerTurn) {
      console.error("🔄 ERROR: Contract not in DealerTurn after refetch (state:", freshStateNum, ")");
      setTxError("Contract not ready for dealer action");
      return;
    }
    
    console.log("✅ Contract confirmed in DealerTurn state");
    
    // STRATEGY: Try to use cached cards first (what UI is showing)
    // If that fails, refetch and use fresh data
    let cardsToUse = dealerCards; // Start with cached cards
    
    console.log("🔄 Cached dealer cards length:", cardsToUse.length);
    
    // If we don't have enough cards in cache, try refetching
    if (cardsToUse.length < 2) {
      console.log(`🔄 Cached cards insufficient (${cardsToUse.length} cards) - fetching fresh data`);
      
      try {
        // Force a comprehensive refetch of all game data
        await refetchAllGameData();
        
        // Fetch fresh dealer cards
        const { data: freshDealerCards } = await refetchDealerCards();
        console.log("🔄 Fresh dealer cards from contract:", freshDealerCards);
        
        // Convert to bigint array
        const freshDealerCardsBigInt = Array.isArray(freshDealerCards) 
          ? freshDealerCards.map(c => BigInt(c)) 
          : [];
        
        if (freshDealerCardsBigInt.length >= 2) {
          console.log("🔄 Fresh cards available, using those");
          cardsToUse = freshDealerCardsBigInt;
        } else {
          console.log("🔄 WARNING: Fresh cards still insufficient, will attempt transaction anyway");
          // Don't return - try to execute with whatever we have
        }
      } catch (err) {
        console.error("🔄 Refetch failed:", err);
        // Don't return - try to execute with cached cards anyway
      }
    }
    
    // ALWAYS attempt to execute a transaction when in DealerTurn
    // Even if cards are incomplete, the contract knows the truth and will handle it
    console.log("🔄 Cards to use for transaction:", cardsToUse);
    console.log("🔄 FORCING transaction attempt - contract will handle actual game state");
    
    // CRITICAL BUST CHECK: Check if all player hands are busted before taking dealer action
    // If all hands busted, we should only call continueDealer (which will end the game immediately)
    const playerHandsForBustCheck = [];
    if (playerHand0Cards) playerHandsForBustCheck.push({ cards: (playerHand0Cards as readonly number[]).map(c => BigInt(c)) });
    if (playerHand1Cards) playerHandsForBustCheck.push({ cards: (playerHand1Cards as readonly number[]).map(c => BigInt(c)) });
    if (playerHand2Cards) playerHandsForBustCheck.push({ cards: (playerHand2Cards as readonly number[]).map(c => BigInt(c)) });
    if (playerHand3Cards) playerHandsForBustCheck.push({ cards: (playerHand3Cards as readonly number[]).map(c => BigInt(c)) });
    
    const allHandsBusted = playerHandsForBustCheck.length > 0 && playerHandsForBustCheck.every(hand => {
      const score = calculateDealerScore(hand.cards);
      return score > 21;
    });
    
    console.log("🔄 Player hands bust check:", {
      numHands: playerHandsForBustCheck.length,
      allBusted: allHandsBusted,
      hands: playerHandsForBustCheck.map(h => ({ cards: h.cards.length, score: calculateDealerScore(h.cards) }))
    });
    
    if (allHandsBusted) {
      console.log("🔄 ALL PLAYER HANDS BUSTED - ending game immediately");
      
      // FIXED: When all hands are busted, always call continueDealer
      // The contract's playDealer() will immediately end the game without requesting VRF
      // No need to get dealer's hole card - dealer wins automatically
      console.log("🔄 Calling continueDealer to end game (all hands busted, no dealer cards needed)");
      execute("continueDealer");
      return;
    }
    
    // Calculate dealer score from available cards (if any)
    // If we have no cards or incomplete cards, default to dealerHit (most common case)
    if (cardsToUse.length < 2) {
      console.log("🔄 Insufficient cards - defaulting to dealerHit, contract will handle it");
      
      // CRITICAL FIX: Check if LINK is approved before calling dealerHit
      if (!isLINKApproved) {
        console.log("🔄 ERROR: LINK not approved for dealerHit - prompting user");
        setTxError("Please approve LINK tokens for dealer action");
        handleApproveLINK("dealerHit");
        return;
      }
      
      execute("dealerHit");
    } else {
      const dealerScore = calculateDealerScore(cardsToUse);
      console.log("🔄 Dealer score:", dealerScore, "Cards:", cardsToUse.length);
      
      // Execute the appropriate action based on score
      if (dealerScore < 17) {
        console.log("🔄 Manual retry: Calling dealerHit");
        
        // CRITICAL FIX: Check if LINK is approved before calling dealerHit
        if (!isLINKApproved) {
          console.log("🔄 ERROR: LINK not approved for dealerHit - prompting user");
          setTxError("Please approve LINK tokens for dealer action");
          handleApproveLINK("dealerHit");
          return;
        }
        
        execute("dealerHit");
      } else {
        console.log("🔄 Manual retry: Calling continueDealer");
        execute("continueDealer");
      }
    }
  }, [dealerCards, calculateDealerScore, execute, refetchAllGameData, refetchDealerCards, state, setTxError, dealerCardsData, refetch, playerHand0Cards, playerHand1Cards, playerHand2Cards, playerHand3Cards, isLINKApproved, handleApproveLINK]);
  
  // SIMPLIFIED DEALER AUTOMATION EFFECT
  // This effect ONLY runs when UI is in "Dealer's Turn" state
  // It triggers the appropriate dealer action based on dealer cards:
  // - If hole card not revealed: call continueDealer() to reveal it
  // - If dealer score < 17: call dealerHit()
  // - If dealer score >= 17: call continueDealer() to finalize
  //
  // FALLBACK: After 3 seconds in DealerTurn with no pending transaction,
  // automatically trigger the appropriate dealer action
  useEffect(() => {
    const effectRunId = Math.random().toString(36).substring(7);
    const prevState = previousGameStateRef.current;
    const currentSessionId = dealerTurnSessionIdRef.current;
    console.log(`🎬 DEALER AUTOMATION EFFECT TRIGGERED [${effectRunId}] - state: ${state}, prevState: ${prevState}, automationTriggered: ${dealerAutomationTriggeredRef.current}, sessionId: ${currentSessionId}, timerSetUp: ${timerSetUpForSessionRef.current === currentSessionId ? 'YES' : 'NO'}`);
    
    // CRITICAL: ONLY run automation when UI is showing "Dealer's Turn"
    if (state !== GameState.DealerTurn) {
      // Reset all flags when leaving DealerTurn
      if (dealerActionInProgressRef.current || prevState === GameState.DealerTurn) {
        console.log("🔄 Left DealerTurn - resetting all dealer automation flags");
        dealerActionInProgressRef.current = false;
        continueDealerTriggeredRef.current = false;
        finalContinueDealerAttemptedRef.current = false;
        lastDealerCardCountRef.current = 0;
        dealerAutomationTriggeredRef.current = false; // Reset automation flag
        dealerTurnSessionIdRef.current += 1; // Increment session ID for next DealerTurn
        timerSetUpForSessionRef.current = -1; // Reset timer tracking
      }
      
      // Update previous state ref for next render
      previousGameStateRef.current = state;
      return;
    }
    
    // FIRST DEFENSE: Check if we're TRANSITIONING into DealerTurn or already in DealerTurn
    // If prevState was already DealerTurn, this is a re-render during the same session - SKIP!
    const isTransitioningIntoDealerTurn = prevState !== GameState.DealerTurn;
    
    if (!isTransitioningIntoDealerTurn) {
      console.log(`⏸️ Already in DealerTurn session ${currentSessionId} (re-render) - skipping timer setup [${effectRunId}]`);
      // Update previous state ref for next render
      previousGameStateRef.current = state;
      return;
    }
    
    // SECOND DEFENSE: Check if we've already set up a timer for this exact session
    // This prevents duplicate timers even if the effect somehow runs multiple times
    // during the transition (e.g., due to rapid refetches)
    if (timerSetUpForSessionRef.current === currentSessionId) {
      console.log(`🛡️ DUPLICATE TIMER PREVENTION - Timer already set up for session ${currentSessionId} [${effectRunId}]`);
      previousGameStateRef.current = state;
      return;
    }
    
    // Mark that we're setting up a timer for this session
    timerSetUpForSessionRef.current = currentSessionId;
    
    // We're entering a NEW DealerTurn session - this is the TRANSITION from another state to DealerTurn
    console.log(`✅ NEW DealerTurn session ${currentSessionId} (transitioning from ${prevState ? GameState[prevState] : 'undefined'}) - setting up SINGLE timer [${effectRunId}]`);
    
    // Update refs so setTimeout callback can access latest values
    latestGameStateRef.current = state;
    
    // Update previous state ref for next render
    previousGameStateRef.current = state;
    
    console.log(`⏰ Setting 3-second fallback timer [${effectRunId}] for dealer automation (SINGLE TIMER ON STATE ENTRY)`);
    
    // CAPTURE these values at the time the effect runs so they're available in the timeout callback
    // This is safe because the timeout is only 3 seconds and these shouldn't change during DealerTurn
    const capturedExecute = execute;
    const capturedHandleApproveLINK = handleApproveLINK;
    const capturedCalculateDealerScore = calculateDealerScore;
    const capturedSessionId = currentSessionId; // Capture session ID to verify we're in the same session
    // NOTE: isLINKApproved is NOT captured - we use isLINKApprovedRef.current for fresh value!
    
    const fallbackTimer = setTimeout(() => {
      console.log(`⏰⏰⏰ TIMER FIRED [session ${capturedSessionId}] - Checking conditions...`);
      
      // ULTIMATE DEFENSE: Verify we're still in the same DealerTurn session
      // If the session ID has changed, we've left and re-entered DealerTurn, so cancel this timer
      if (dealerTurnSessionIdRef.current !== capturedSessionId) {
        console.log(`🛡️ TIMER CANCELLED - Session changed from ${capturedSessionId} to ${dealerTurnSessionIdRef.current}`);
        return;
      }
      
      console.log(`⏰ Timer check - state: ${latestGameStateRef.current}, isPending: ${isPendingRef.current}, actionInProgress: ${dealerActionInProgressRef.current}, isRefetching: ${isRefetchingRef.current}, automationTriggered: ${dealerAutomationTriggeredRef.current}`);
      
      // Check if we're still in DealerTurn
      if (latestGameStateRef.current !== GameState.DealerTurn) {
        console.log("⏸️ Fallback automation cancelled - no longer in DealerTurn");
        return;
      }
      
      // CRITICAL: Check if automation has already been triggered for this DealerTurn session
      if (dealerAutomationTriggeredRef.current) {
        console.log("⏸️ Fallback automation cancelled - automation already triggered this session");
        return;
      }
      
      // REMOVED: isRefetchingRef check - it was blocking dealer automation!
      // The refetch after VRF completion takes 2 seconds, which extends past our 3-second timer
      // We don't need to wait for refetch to complete - the dealer action will trigger based on
      // whatever data we have, and the contract is the source of truth anyway.
      
      // Check if transaction is already pending
      if (isPendingRef.current) {
        console.log("⏸️ Fallback automation cancelled - transaction already pending");
        return;
      }
      
      // CRITICAL FIX: Don't check dealerActionInProgressRef here!
      // This ref can get stuck if a previous attempt failed before calling executeRaw
      // Instead, we'll let the execute function handle duplicate prevention
      
      console.log("⏰ FALLBACK AUTOMATION TRIGGERED (3 seconds elapsed)");
      
      // Mark automation as triggered for this DealerTurn session
      dealerAutomationTriggeredRef.current = true;
      
      // Mark action as in progress AFTER checks pass
      dealerActionInProgressRef.current = true;
      
      // CRITICAL: Get FRESH dealer cards data from refs
      // Refs are updated on every render, so we always have the latest values
      const freshDealerCards = latestDealerCardsRef.current;
      const freshDealerScore = capturedCalculateDealerScore(freshDealerCards);
      const freshHoleCardRevealed = latestHoleCardRevealedRef.current;
      const freshIsLINKApproved = isLINKApprovedRef.current; // CRITICAL: Use ref for fresh value!
      
      console.log(`🤖 Fallback dealer state - cards: ${freshDealerCards.length}, score: ${freshDealerScore}, holeCardRevealed: ${freshHoleCardRevealed}`);
      console.log(`🤖 Fresh values - isLINKApproved: ${freshIsLINKApproved}`);
      
      // Determine which action to take
      if (freshDealerCards.length < 2) {
        console.log("⏰ Fallback: No cards loaded - calling continueDealer");
        capturedExecute("continueDealer");
      } else if (!freshHoleCardRevealed) {
        console.log("⏰ Fallback: Hole card not revealed - calling continueDealer");
        capturedExecute("continueDealer");
      } else if (freshDealerScore < 17) {
        console.log(`⏰ Fallback: Dealer score ${freshDealerScore} < 17 - calling dealerHit`);
        if (!freshIsLINKApproved) {
          console.log("⚠️ Fallback: LINK not approved - triggering approval flow");
          capturedHandleApproveLINK("dealerHit");
          dealerActionInProgressRef.current = false; // Reset since we're not executing
          dealerAutomationTriggeredRef.current = false; // Reset so user can retry
          return;
        }
        capturedExecute("dealerHit");
      } else {
        console.log(`⏰ Fallback: Dealer score ${freshDealerScore} >= 17 - calling continueDealer`);
        capturedExecute("continueDealer");
      }
    }, 3000); // 3 second fallback
    
    // Cleanup timer when effect re-runs or component unmounts
    return () => {
      console.log(`🧹 Cleaning up fallback timer [${effectRunId}] - effect is re-running or component unmounting`);
      clearTimeout(fallbackTimer);
    };
    
    // CRITICAL FIX FOR PHANTOM TRANSACTIONS:
    // ONLY depend on state - nothing else!
    // This ensures the effect runs ONCE when entering DealerTurn and sets a single timer.
    // We capture execute, handleApproveLINK, etc. as local variables so they're available
    // in the timeout callback, but we don't add them to dependencies.
    // 
    // WHY THIS WORKS:
    // - Effect runs ONCE when state becomes DealerTurn
    // - Captures current values of execute, isLINKApproved, etc.
    // - Timer callback uses captured values (stable for 3 seconds)
    // - Refs provide fresh values for cards, isPending, etc.
    // - No re-runs = no phantom transactions
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [state]); // ONLY state - nothing else!

  // RETRY LOGIC: Handle retrying failed dealer actions
  useEffect(() => {
    if (failedDealerAction && state === GameState.DealerTurn && !isPending && !dealerActionInProgressRef.current) {
      console.log(`🔄 Executing retry for failed dealer action: ${failedDealerAction}`);
      
      // Clear the failed action state
      setFailedDealerAction(null);
      
      // Execute the action
      dealerActionInProgressRef.current = true;
      execute(failedDealerAction);
    }
  }, [failedDealerAction, state, isPending, execute]);

  // NOTE: After the VRF gas limit fix, dealerHit is no longer called automatically.
  // Instead, the player must call continueDealer() after the VRF callback completes
  // and the game enters DealerTurn state. This ensures the dealer logic runs in a
  // separate transaction with sufficient gas, avoiding "gas limit set too low" errors.

  // When game transitions to Finished, refetch all bet data to ensure we have the latest values
  // This is critical after double downs or splits where bet amounts change
  const [betDataRefetched, setBetDataRefetched] = useState(false);
  
  // Track retry attempts for bet data loading (to avoid infinite waiting)
  const betDataRetryCount = useRef(0);
  const maxBetDataRetries = 5;
  const [forceRefetchTrigger, setForceRefetchTrigger] = useState(0); // State to trigger re-fetches
  
  // Track whether we've cleared the result for the current finished game (to prevent infinite loop)
  const clearedResultForFinishedGame = useRef(false);
  
  // Track previous state to detect transitions
  const previousState = useRef<GameState | undefined>(undefined);
  
  // DEBUG: Log at the top of render to see current state
  
  useEffect(() => {
    
    if (state === GameState.Finished && !betDataRefetched) {
      
      // CRITICAL: Clear any existing game result to prevent showing stale data
      // This ensures the UI shows "Loading bet data..." instead of an incorrect result
      if (gameResult !== null) {
        setGameResult(null);
      }
      
      // Reset retry counter when first entering Finished state
      betDataRetryCount.current = 0;
      
      // Refetch all bet data AND finalPayout
      const refetchPromises = [refetchHand0Bet(), refetchFinalPayout()];
      if (numHands >= 2) refetchPromises.push(refetchHand1Bet());
      if (numHands >= 3) refetchPromises.push(refetchHand2Bet());
      if (numHands >= 4) refetchPromises.push(refetchHand3Bet());
      
      // Set a timeout to proceed even if refetch takes too long
      const timeoutId = setTimeout(() => {
        setBetDataRefetched(true);
      }, 5000); // 5 second timeout
      
      // Wait for all refetches to complete before allowing result calculation
      Promise.all(refetchPromises).then(() => {
        clearTimeout(timeoutId);
        
        // Add delay to ensure wagmi cache is updated
        setTimeout(() => {
          setBetDataRefetched(true);
        }, 1000); // 1 second delay for cache to update
      }).catch(err => {
        clearTimeout(timeoutId);
        // Still set to true to allow calculation to proceed
        setTimeout(() => setBetDataRefetched(true), 1000);
      });
    }
    
    // Reset flag when starting a new game
    if (state === GameState.NotStarted && betDataRefetched) {
      setBetDataRefetched(false);
      betDataRetryCount.current = 0; // Also reset retry counter
    }
  }, [state, numHands, betDataRefetched, gameResult]);
  // NOTE: refetch functions NOT in deps to avoid infinite loop - they're stable refs

  // Reset gameResult when starting a new game
  // DON'T clear result when transitioning to Finished - let the result calculation handle it
  useEffect(() => {
    // Track state transitions
    const prevState = previousState.current;
    
    // When transitioning to NotStarted, clear everything for new game
    if (state === GameState.NotStarted && prevState !== GameState.NotStarted) {
      setGameResult(null);
      clearedResultForFinishedGame.current = false; // Reset the flag for next game
    }
    
    // REMOVED: Don't clear gameResult when transitioning to Finished
    // This was causing a brief flash of "lost" before the correct result loaded
    // Instead, the result calculation effect will update gameResult once bet data is ready
    
    // Update previous state for next render
    previousState.current = state;
  }, [state]); // Only depend on state, not gameResult or betDataRefetched

  // Read final payout from contract when game is finished
  // This is the source of truth - stored on-chain during game settlement
  // Works reliably even after page reloads or if events are missed
  useEffect(() => {
    // COMPREHENSIVE DEBUG: Log EVERY time this effect runs, regardless of conditions
    
    // Priority 1: Use contract's finalPayout if available (most reliable)
    // CRITICAL: Only calculate result AFTER bet data has been refetched to avoid stale data
    // Always recalculate when betDataRefetched becomes true to ensure we use fresh bet amounts
    if (state === GameState.Finished && contractFinalPayout !== undefined && betDataRefetched) {
      
      // Build player hands to calculate total bet for result determination
      const hands: PlayerHand[] = [];
      
      if (playerHand0Cards && playerHand0Bet !== undefined) {
        const bet = BigInt(playerHand0Bet);
        hands.push({
          cards: Array.isArray(playerHand0Cards) ? playerHand0Cards.map(c => BigInt(c)) : [],
          bet,
        });
      }
      
      if (numHands >= 2 && playerHand1Cards && playerHand1Bet !== undefined) {
        const bet = BigInt(playerHand1Bet);
        hands.push({
          cards: Array.isArray(playerHand1Cards) ? playerHand1Cards.map(c => BigInt(c)) : [],
          bet,
        });
      }
      
      if (numHands >= 3 && playerHand2Cards && playerHand2Bet !== undefined) {
        const bet = BigInt(playerHand2Bet);
        hands.push({
          cards: Array.isArray(playerHand2Cards) ? playerHand2Cards.map(c => BigInt(c)) : [],
          bet,
        });
      }
      
      if (numHands >= 4 && playerHand3Cards && playerHand3Bet !== undefined) {
        const bet = BigInt(playerHand3Bet);
        hands.push({
          cards: Array.isArray(playerHand3Cards) ? playerHand3Cards.map(c => BigInt(c)) : [],
          bet,
        });
      }
      
      const payout = BigInt(contractFinalPayout);
      const totalMainBet = hands.reduce((sum, hand) => sum + hand.bet, BigInt(0));
      const insurancePaid = contractInsuranceBet ? BigInt(contractInsuranceBet) : BigInt(0);
      const totalBet = totalMainBet + insurancePaid;
      
      
      // CRITICAL FIX: Validate BOTH payout and bet data before calculating result
      // This prevents showing "lost" when data is still loading
      
      // Check 1: If totalMainBet is 0, bet data hasn't loaded yet
      if (totalMainBet === BigInt(0)) {
        
        // If we've already refetched but still have 0, increment retry counter
        // After max retries, we'll proceed with calculation anyway
        if (betDataRefetched) {
          if (betDataRetryCount.current < maxBetDataRetries) {
            betDataRetryCount.current += 1;
            
            // Trigger manual refetch with a small delay
            setTimeout(() => {
              refetchHand0Bet();
              refetchFinalPayout(); // Also refetch finalPayout!
              if (numHands >= 2) refetchHand1Bet();
              if (numHands >= 3) refetchHand2Bet();
              if (numHands >= 4) refetchHand3Bet();
              
              // Force a re-render after refetch by updating state
              setTimeout(() => {
                setForceRefetchTrigger(prev => prev + 1);
              }, 1000);
            }, 500);
            
            // Don't proceed yet - wait for next render with updated data
            return;
          } else {
            // Fall through to calculate result even with 0 bet (edge case)
          }
        } else {
          // Not refetched yet, just wait
          return;
        }
      }
      
      // Check 2: If payout is 0 but totalBet > 0, the payout data might be stale
      // This can happen if betDataRefetched becomes true before contractFinalPayout updates
      // However, payout=0 is ALSO a valid result if the player lost everything
      // Only wait if we haven't retried yet
      if (payout === BigInt(0) && totalBet > BigInt(0) && gameResult === null && betDataRetryCount.current < 2) {
        
        // Trigger manual refetch of finalPayout
        betDataRetryCount.current += 1;
        setTimeout(() => {
          refetchFinalPayout();
          
          // Force re-render after refetch
          setTimeout(() => {
            setForceRefetchTrigger(prev => prev + 1);
          }, 1000);
        }, 500);
        
        // The next time contractFinalPayout updates, this effect will re-run
        // and we'll calculate the result properly
        return;
      }
      
      // Check if dealer has blackjack for insurance scenario detection
      const dealerHasBlackjack = dealerCards.length === 2 && (() => {
        const cards = dealerCards.map(c => Number(c));
        const hasAce = cards.some(c => c % 13 === 1);
        const hasTen = cards.some(c => {
          const rank = c % 13;
          return rank === 10 || rank === 11 || rank === 12 || rank === 0;
        });
        return hasAce && hasTen;
      })();
      
      // Check if this was an insurance scenario
      const hadInsurance = insurancePaid > BigInt(0);
      const expectedInsurancePayout = insurancePaid * BigInt(3);
      
      // Detect insurance scenario using multiple methods
      const isInsuranceScenario = (dealerHasBlackjack && hadInsurance) || 
                                  (hadInsurance && payout === expectedInsurancePayout) ||
                                  (hadInsurance && payout > BigInt(0) && 
                                   ((payout > expectedInsurancePayout ? payout - expectedInsurancePayout : expectedInsurancePayout - payout) < BigInt(1e15)));
      
      // Check for player blackjack
      const hasPlayerBlackjack = hands.some(hand => {
        if (hand.cards.length !== 2) return false;
        const cards = hand.cards.map(c => Number(c));
        const hasAce = cards.some(c => c % 13 === 1);
        const hasTen = cards.some(c => {
          const rank = c % 13;
          return rank === 10 || rank === 11 || rank === 12 || rank === 0;
        });
        return hasAce && hasTen;
      });
      
      // Calculate profit ratio for blackjack detection
      const profit = payout - totalBet;
      const profitRatio = totalBet > BigInt(0) ? Number(profit) / Number(totalBet) : 0;
      const isBlackjackPayout = hasPlayerBlackjack && profitRatio >= 1.4 && profitRatio <= 1.6;
      
      // CRITICAL FIX: Determine result WITHOUT a default "lost" fallback
      // We must be CERTAIN of the result before setting it
      // Priority order:
      // 1. Insurance scenario (highest priority - prevents showing "won" incorrectly)
      // 2. Player blackjack (3:2 payout)
      // 3. Regular win/push/loss
      let result: string;
      
      if (isInsuranceScenario) {
        result = "insurance_payout";
      } else if (isBlackjackPayout) {
        result = "blackjack";
      } else if (payout > totalBet) {
        result = "won";
      } else if (payout === totalBet) {
        result = "push";
      } else if (payout < totalBet) {
        result = "lost";
      } else {
        // SAFETY: If we can't determine the result, DON'T SET IT
        // This prevents showing incorrect "lost" state
        return; // Don't set gameResult if we can't determine it
      }
      
      
      // CRITICAL FIX: Only update gameResult if the new result is DIFFERENT
      // This prevents unnecessary re-renders and prevents flashing from "lost" to "won"
      // when the effect runs multiple times with the same data
      const shouldUpdate = !gameResult || 
                           gameResult.result !== result || 
                           gameResult.payout !== payout;
      
      if (shouldUpdate) {
        setGameResult({
          result,
          payout,
        });
      } else {
      }
    }
  }, [
    state,
    contractFinalPayout,
    betDataRefetched,
    gameResult, // Re-added: needed for the shouldUpdate check (won't cause infinite loop due to conditional update)
    playerHand0Cards,
    playerHand0Bet,
    playerHand1Cards,
    playerHand1Bet,
    playerHand2Cards,
    playerHand2Bet,
    playerHand3Cards,
    playerHand3Bet,
    numHands,
    contractInsuranceBet,
    dealerCards,
    refetchHand0Bet,
    refetchHand1Bet,
    refetchHand2Bet,
    refetchHand3Bet,
    refetchFinalPayout, // Added for manual refetch capability
    forceRefetchTrigger, // Triggers re-run when manual refetch is executed
  ]);

  // Trigger fireworks when player wins (must be before early return to maintain hook order)
  useEffect(() => {
    if (gameResult && state === GameState.Finished) {
      // Use the pre-calculated result to determine if fireworks should show
      // Show fireworks for wins and blackjacks, but NOT for insurance payouts (those are defensive wins)
      const shouldShowFireworks = gameResult.result === "won" || gameResult.result === "blackjack";
      
      if (shouldShowFireworks) {
        setShowFireworks(true);
        // Hide fireworks after 5 seconds
        const timer = setTimeout(() => setShowFireworks(false), 5000);
        return () => clearTimeout(timer);
      }
    }
  }, [gameResult, state]);

  // Refetch player games list when game finishes (updates sidebar game states)
  useEffect(() => {
    if (state === GameState.Finished && gameResult) {
      // Refetch the player games list to update the game states in the sidebar
      if (typeof window !== 'undefined' && (window as any).refetchPlayerGames) {
        (window as any).refetchPlayerGames();
      }
    }
  }, [state, gameResult]);

  if (!gameState) {
    return <div className="card">Loading game...</div>;
  }

  // Build playerHands array from all fetched hand data
  const playerHands = [];
  
  // Hand 0
  if (playerHand0Cards && playerHand0Bet !== undefined) {
    const cards = Array.isArray(playerHand0Cards) ? playerHand0Cards : [];
    const bet = typeof playerHand0Bet === 'bigint' || typeof playerHand0Bet === 'number' ? playerHand0Bet : BigInt(0);
    
    playerHands.push({ 
      cards: cards.map(c => BigInt(c)), 
      bet: BigInt(bet),
      stood: false,
      busted: false,
      doubled: false
    });
  }
  
  // Hand 1 (if exists)
  if (numHands >= 2 && playerHand1Cards && playerHand1Bet !== undefined) {
    const cards = Array.isArray(playerHand1Cards) ? playerHand1Cards : [];
    const bet = typeof playerHand1Bet === 'bigint' || typeof playerHand1Bet === 'number' ? playerHand1Bet : BigInt(0);
    
    playerHands.push({ 
      cards: cards.map(c => BigInt(c)), 
      bet: BigInt(bet),
      stood: false,
      busted: false,
      doubled: false
    });
  }
  
  // Hand 2 (if exists)
  if (numHands >= 3 && playerHand2Cards && playerHand2Bet !== undefined) {
    const cards = Array.isArray(playerHand2Cards) ? playerHand2Cards : [];
    const bet = typeof playerHand2Bet === 'bigint' || typeof playerHand2Bet === 'number' ? playerHand2Bet : BigInt(0);
    
    playerHands.push({ 
      cards: cards.map(c => BigInt(c)), 
      bet: BigInt(bet),
      stood: false,
      busted: false,
      doubled: false
    });
  }
  
  // Hand 3 (if exists)
  if (numHands >= 4 && playerHand3Cards && playerHand3Bet !== undefined) {
    const cards = Array.isArray(playerHand3Cards) ? playerHand3Cards : [];
    const bet = typeof playerHand3Bet === 'bigint' || typeof playerHand3Bet === 'number' ? playerHand3Bet : BigInt(0);
    
    playerHands.push({ 
      cards: cards.map(c => BigInt(c)), 
      bet: BigInt(bet),
      stood: false,
      busted: false,
      doubled: false
    });
  }

  // Calculate scores
  const calculateScore = (cards: readonly bigint[]) => {
    let score = 0;
    let aces = 0;
    for (const card of cards) {
      // Match Solidity: ((cardId - 1) % 13) + 1 gives rank 1-13
      const rank = ((Number(card) - 1) % 13) + 1;
      if (rank === 1) {
        // Ace
        aces++;
        score += 11;
      } else if (rank >= 11) {
        // Face cards (J=11, Q=12, K=13)
        score += 10;
      } else {
        // Number cards 2-10
        score += rank;
      }
    }
    while (score > 21 && aces > 0) {
      score -= 10;
      aces--;
    }
    return score;
  };

  // Determine if we can perform special actions
  const isPlayerTurn = state === GameState.PlayerTurn;
  const isInsuranceOffer = state === GameState.InsuranceOffer;
  const isFinished = state === GameState.Finished;
  const isDealerTurn = state === GameState.DealerTurn;

  const currentPlayerHand = playerHands[currentHand];
  // Check game conditions (LINK approval handled separately in button logic)
  const canHit = isPlayerTurn && currentPlayerHand && !currentPlayerHand.doubled && !currentPlayerHand.stood;
  const canStand = isPlayerTurn && currentPlayerHand && !currentPlayerHand.stood;
  const canDoubleDown = isPlayerTurn && currentPlayerHand && currentPlayerHand.cards.length === 2 && !currentPlayerHand.doubled;
  
  // Allow splitting on any hand, up to 4 hands total (contract limit)
  // Also prevent splitting if we just completed a split action (waiting for state to refetch)
  // IMPORTANT: Also check if a split from this hand already created a new hand
  // For example, if we're on hand 0 and hand 1 exists, hand 0 was already split
  // If we're on hand 1 and hand 2 exists, hand 1 was already split
  const alreadySplitThisHand = currentHand < playerHands.length - 1; // If there's a hand after current, this was already split
  const canSplit = isPlayerTurn && 
                   playerHands.length < 4 &&  // Contract allows max 4 hands
                   recentlySplitHand === null &&  // Don't allow split if we just split (waiting for refetch)
                   !alreadySplitThisHand &&  // Don't allow split if this hand already created a new hand
                   currentPlayerHand && 
                   currentPlayerHand.cards.length === 2 && 
                   !currentPlayerHand.stood &&  // Can't split a hand that's already stood
                   (((Number(currentPlayerHand.cards[0]) - 1) % 13) + 1) === (((Number(currentPlayerHand.cards[1]) - 1) % 13) + 1);
  
  // Debug log for split eligibility
  if (currentPlayerHand && currentPlayerHand.cards.length === 2) {
  }
  
  const canSurrender = (isPlayerTurn || isInsuranceOffer) && playerHands.length === 1 && playerHands[0] && playerHands[0].cards.length === 2;


  return (
    <div className="relative max-w-6xl mx-auto">
      {showFireworks && <Fireworks duration={5000} />}
      
      <div className="card bg-gradient-to-br from-green-800 to-green-900 text-white">
      <div className="flex justify-between items-center mb-6">
        <div>
          <h2 className="text-3xl font-bold text-yellow-300">♠️ Blackjack ♥️</h2>
          <p className="text-xs font-mono text-gray-300 mt-1 break-all">
            Game: {gameAddress}
          </p>
        </div>
        <div className="flex items-center gap-3">
          <div className="text-sm bg-black/30 px-4 py-2 rounded-lg">
            <span className="font-semibold">State:</span> {GameState[state]}
          </div>
          {/* LINK Status Indicator */}
          {linkAllowance !== undefined && linkFeePerAction && (
            <div className={`text-xs px-3 py-2 rounded-lg ${
              isLINKApproved 
                ? "bg-green-600/30 border border-green-400" 
                : "bg-red-600/30 border border-red-400"
            }`}>
              <div className="font-semibold">
                {isLINKApproved ? "✓ LINK OK" : "⚠ Need LINK"}
              </div>
              <div className="text-[10px] text-gray-300">
                {Math.floor(Number(linkAllowance) / Number(linkFeePerAction))} actions left
              </div>
            </div>
          )}
          {onMinimize && (
            <button
              onClick={() => {
                onMinimize();
              }}
              className="bg-yellow-500/80 hover:bg-yellow-600 text-white px-4 py-2 rounded-lg transition-colors"
              title="Minimize to sidebar"
            >
              ⬇️ Minimize
            </button>
          )}
        </div>
      </div>

      {/* Card Dealing Area - with inner shadow from top-right */}
      <div className="card-area-shadow rounded-xl p-6 mb-6 border border-white/20 relative">
        {/* Win/Loss overlay tint */}
        {state === GameState.Finished && gameResult && (
          <div className="absolute inset-0 rounded-xl pointer-events-none z-10 animate-fade-in-overlay bg-black/25" />
        )}
        
        {/* Dealer Hand */}
        <div className="mb-4 pt-3 px-4 pb-5 bg-black/20 rounded-xl card-box-highlight">
          <h3 className="text-xl font-semibold mb-2 text-yellow-300 pl-2">
            Dealer {(isFinished || isDealerTurn || dealerCards.length > 2) && dealerCards.length > 0 ? `(${calculateScore(dealerCards)})` : ""}
          </h3>
        <div className="flex flex-wrap gap-2">
          {dealerCards.length > 0 ? (
            <>
              {/* First card (up card) - always face-up */}
              {(() => {
                // First card is ALWAYS face-up (dealer's up card)
                // EXCEPTION: During initial deal (before VRF completes), show back then flip
                
                const isDealDuringGameplay = initialDealerCardCount.current === 0;
                
                // CRITICAL: If game is finished, ALWAYS show cards face-up (no animation)
                // This handles page reloads when game is already complete
                if (state === GameState.Finished) {
                  return (
                    <PlayingCard 
                      key="dealer-first-card"
                      cardValue={Number(dealerCards[0])}
                      isHidden={false}
                      shouldFlip={false}
                      shouldFadeIn={false}
                    />
                  );
                }
                
                // Determine if this card was already present on page load (should show immediately)
                // vs. being dealt during gameplay (should animate)
                const wasAlreadyPresent = initialDealerCardCount.current !== null && initialDealerCardCount.current >= 1;
                
                // If card was already there on load, just show it face-up (no animation)
                if (wasAlreadyPresent) {
                  return (
                    <PlayingCard 
                      key="dealer-first-card"
                      cardValue={Number(dealerCards[0])}
                      isHidden={false}
                      shouldFlip={false}
                      shouldFadeIn={false}
                    />
                  );
                }
                
                // Card is being dealt during gameplay - should start face-down then flip
                const shouldFlip = dealerFirstCardShouldFlip;
                
                return (
                  <PlayingCard 
                    key="dealer-first-card"
                    cardValue={Number(dealerCards[0])}
                    isHidden={true}
                    shouldFlip={shouldFlip}
                    shouldFadeIn={false}
                  />
                );
              })()}
              
              {/* Second card logic: */}
              {/* ALWAYS render the hole card slot to avoid mounting/unmounting which causes blink */}
              {(() => {
                const hasHoleCard = dealerCards.length > 1;
                
                if (!hasHoleCard) {
                  // No hole card yet - show placeholder (back of card)
                  // Show during active game states (not NotStarted)
                  if (state !== GameState.NotStarted) {
                    return <PlayingCard key="dealer-hole-card" cardValue={0} isHidden />;
                  }
                  return null;
                }
                
                // Dealer has hole card
                // Keep it hidden (show card back) unless explicitly revealed
                // DON'T fade in because we're replacing a placeholder (that was already visible)
                // Fade in would cause a blink (opacity goes 0->1)
                return (
                  <PlayingCard 
                    key="dealer-hole-card"
                    cardValue={Number(dealerCards[1])} 
                    isHidden={!dealerHoleCardRevealed}
                    shouldFlip={dealerHoleCardRevealed}
                    shouldFadeIn={false}
                  />
                );
              })()}
              
              {/* Show all additional cards face up with fade-in animation */}
              {dealerCards.slice(2).map((card, index) => {
                const cardPosition = index + 2;
                const initialCount = initialDealerCardCount.current || 0;
                // Fade in if this card was added after initial load
                const shouldFade = cardPosition >= initialCount && seenDealerCardCount >= (cardPosition - initialCount + 1);
                return (
                  <PlayingCard 
                    key={`dealer-${cardPosition}`}
                    cardValue={Number(card)}
                    shouldFadeIn={shouldFade}
                  />
                );
              })}
            </>
          ) : (
            <>
              <PlayingCard cardValue={0} isHidden />
              {state !== GameState.NotStarted && (
                <PlayingCard cardValue={0} isHidden />
              )}
            </>
          )}
        </div>
      </div>

      {/* Player Hands */}
      <div>
        {playerHands.map((hand, index) => (
          <div
            key={index}
            className={`pt-3 px-4 pb-5 rounded-xl mb-4 card-box-highlight ${
              index === currentHand && isPlayerTurn
                ? "bg-green-500/15 ring-4 ring-green-400/60 border border-white/40"
                : "bg-black/20"
            }`}
          >
            <div className="flex justify-between items-center mb-1 pl-2">
              <h3 className="text-xl font-semibold text-yellow-200">
                {playerHands.length > 1 ? `Hand ${index + 1}` : "Your Hand"}
                {hand.cards.length > 0 && ` (${calculateScore(hand.cards)})`}
                {index === currentHand && isPlayerTurn && (
                  <span className="ml-3 text-sm bg-yellow-400 text-black px-3 py-1 rounded-full">
                    Active
                  </span>
                )}
              </h3>
              <div className="text-lg bg-black/40 px-4 py-2 rounded-lg">
                <span className="font-semibold">Bet:</span> {Math.floor(Number(hand.bet) / 1e18)} BJT
              </div>
            </div>

            <div className="flex flex-wrap gap-2">
              {hand.cards.map((card, cardIndex) => {
                const initialCount = initialPlayerCardCounts.current ? initialPlayerCardCounts.current[index] : 0;
                // Fade in only when this specific card position was added after initial load
                // Use >= so prop stays true even when more cards are added
                const cardPositionInNewCards = cardIndex - initialCount + 1; // 1-indexed position among new cards
                const shouldFade = cardIndex >= initialCount && seenPlayerCardCounts[index] >= cardPositionInNewCards;
                return (
                  <PlayingCard 
                    key={`hand-${index}-card-${cardIndex}`}
                    cardValue={Number(card)}
                    shouldFadeIn={shouldFade}
                  />
                );
              })}
            </div>

            {hand.busted && (
              <div className="mt-3 text-red-400 font-bold text-xl">BUSTED!</div>
            )}
            {hand.doubled && (
              <div className="mt-3 text-blue-400 font-semibold">Doubled Down</div>
            )}
            {hand.stood && !hand.busted && (
              <div className="mt-3 text-gray-400 font-semibold">Standing</div>
            )}
          </div>
        ))}
      </div>
      </div>
      {/* End Card Dealing Area */}

      {/* Insurance Offer */}
      {isInsuranceOffer && (
        <div className="mb-6 p-6 bg-blue-600/30 rounded-xl border-2 border-blue-400">
          <h3 className="text-xl font-bold mb-3">Insurance Offer</h3>
          <p className="mb-3">
            The dealer is showing an Ace and might have Blackjack. Would you like to purchase insurance?
          </p>
          <div className="mb-4 p-4 bg-blue-900/50 rounded-lg border border-blue-300">
            <p className="text-lg font-semibold mb-2">💰 Insurance Details:</p>
            <ul className="space-y-1 text-sm">
              <li>• Cost: <span className="font-bold text-green-300">{playerHand0Bet ? formatUnits(BigInt(playerHand0Bet) / BigInt(2), 18) : "0"} BJT</span> (half of your bet)</li>
              <li>• Pays 2:1 if the dealer has Blackjack</li>
              <li>• If dealer has Blackjack, you'll win back your full bet amount</li>
              <li>• If dealer doesn't have Blackjack, you lose the insurance bet and play continues</li>
            </ul>
          </div>
          <div className="flex gap-4 items-center">
            <button
              onClick={handlePlaceInsurance}
              disabled={isPending || isApprovingLINK || isApprovingToken}
              className="btn btn-primary flex-1"
            >
              {(isApprovingLINK || isApprovingToken) && pendingAction === "placeInsurance" ? "Approving..." : 
               isPending && currentAction === "placeInsurance" ? "Placing Insurance..." : 
               !isLINKApproved ? "🔓 Buy Insurance (Approve LINK)" : 
               (playerHand0Bet && !isTokenApprovedFor(BigInt(playerHand0Bet) / BigInt(2))) ? "🔓 Buy Insurance (Approve Tokens)" : 
               `Buy Insurance (${playerHand0Bet ? formatUnits(BigInt(playerHand0Bet) / BigInt(2), 18) : "0"} BJT)`}
            </button>
            <button
              onClick={handleSkipInsurance}
              disabled={isPending || isApprovingLINK}
              className="btn btn-secondary flex-1"
            >
              {isPending && currentAction === "skipInsurance" ? "Skipping..." : "No Insurance"}
            </button>
          </div>
          {!isLINKApproved && (
            <p className="text-sm text-yellow-300 mt-3">
              ℹ️ Click "Buy Insurance" to approve LINK first (one-time approval for all game actions)
            </p>
          )}
          {isLINKApproved && playerHand0Bet && !isTokenApprovedFor(BigInt(playerHand0Bet) / BigInt(2)) && (
            <p className="text-sm text-yellow-300 mt-3">
              ℹ️ Click "Buy Insurance" again to approve {formatUnits(BigInt(playerHand0Bet) / BigInt(2), 18)} BJT tokens for this insurance bet
            </p>
          )}
        </div>
      )}

      {/* Action Buttons */}
      {isPlayerTurn && gameState !== GameState.Finished && !gameResult && (
        <>
          <div className="grid grid-cols-2 md:grid-cols-4 gap-4">
            <button
              onClick={() => !isLINKApproved ? handleApproveLINK("hit") : handleHit()}
              disabled={!canHit || isPending || isApprovingLINK}
              className={`btn ${canHit ? "btn-primary" : "btn-disabled"}`}
              title={canHit ? "Draw another card" : "Not available"}
            >
              {isApprovingLINK && pendingAction === "hit" ? "Approving..." : isPending ? "Processing..." : "🃏 Hit"}
            </button>
            <button
              onClick={() => !isLINKApproved ? handleApproveLINK("stand") : handleStand()}
              disabled={!canStand || isPending || isApprovingLINK}
              className={`btn ${canStand ? "btn-danger" : "btn-disabled"}`}
              title={canStand ? "Keep current hand" : "Not available"}
            >
              {isApprovingLINK && pendingAction === "stand" ? "Approving..." : isPending && currentAction === "stand" ? "Standing..." : "✋ Stand"}
            </button>
            <button
              onClick={handleDoubleDown}
              disabled={!canDoubleDown || isPending || isApprovingLINK || isApprovingToken || !!pendingAction}
              className={`btn ${canDoubleDown && !isPending && !isApprovingLINK && !isApprovingToken && !pendingAction ? (!isLINKApproved ? "btn-warning" : (currentPlayerHand && !isTokenApprovedFor(currentPlayerHand.bet) ? "btn-warning" : "btn-success")) : "btn-disabled"}`}
              title={!isLINKApproved ? "Click to approve LINK for Double Down" : currentPlayerHand && !isTokenApprovedFor(currentPlayerHand.bet) ? "Click to approve tokens for Double Down" : canDoubleDown ? "Double bet, get one card, then stand" : "Not available"}
            >
              {(isApprovingLINK || isApprovingToken) && pendingAction === "doubleDown" ? "Approving..." : 
               isPending ? "Processing..." : 
               !isLINKApproved ? "🔓 Double Down (Approve LINK)" : 
               currentPlayerHand && !isTokenApprovedFor(currentPlayerHand.bet) ? "🔓 Double Down (Approve Tokens)" : 
               "2️⃣ Double Down"}
            </button>
            <button
              onClick={handleSplit}
              disabled={!canSplit || isPending || isApprovingLINK || isApprovingToken || !!pendingAction || !!currentAction}
              className={`btn ${canSplit && !isPending && !isApprovingLINK && !isApprovingToken && !pendingAction && !currentAction ? (!isLINKApproved ? "btn-warning" : (currentPlayerHand && !isTokenApprovedFor(currentPlayerHand.bet) ? "btn-warning" : "btn-success")) : "btn-disabled"}`}
              title={!isLINKApproved ? "Click to approve LINK for Split" : currentPlayerHand && !isTokenApprovedFor(currentPlayerHand.bet) ? "Click to approve tokens for Split" : canSplit ? `Split matching cards into two hands (${playerHands.length}/4 hands)` : playerHands.length >= 4 ? "Maximum 4 hands reached" : "Not available"}
            >
              {(isApprovingLINK || isApprovingToken) && pendingAction === "split" ? "Approving..." : 
               isPending ? "Processing..." : 
               !isLINKApproved ? "🔓 Split (Approve LINK)" : 
               currentPlayerHand && !isTokenApprovedFor(currentPlayerHand.bet) ? "🔓 Split (Approve Tokens)" : 
               "✂️ Split"}
            </button>
          </div>
          {/* LINK Fee Info */}
          {linkFeePerAction && (
            <div className="mt-3 text-center text-sm text-gray-300">
              ℹ️ Each action requires <strong>{(Number(linkFeePerAction) / 1e18).toFixed(4)} LINK</strong> for VRF
              {!isLINKApproved && (
                <span className="text-yellow-300"> - Click any action to approve</span>
              )}
            </div>
          )}
        </>
      )}

      {/* Surrender Button */}
      {canSurrender && gameState !== GameState.Finished && !gameResult && (
        <div className="mt-4">
          <button
            onClick={() => !isLINKApproved ? handleApproveLINK("surrender") : handleSurrender()}
            disabled={isPending || isApprovingLINK}
            className={`btn w-full btn-secondary`}
            title={!isLINKApproved ? "Approve LINK first" : "Get half your bet back and end game"}
          >
            {isApprovingLINK && pendingAction === "surrender" ? "Approving..." : isPending && (pendingAction === "surrender" || currentAction === "surrender") ? "Surrendering..." : "🏳️ Surrender (Get Half Bet Back)"}
          </button>
        </div>
      )}

      {/* Transaction Status */}
      {hash && (
        <div className="mt-4 p-4 bg-green-600/20 rounded-lg">
          <p className="text-green-400 break-all">
            Transaction sent: {hash}
          </p>
        </div>
      )}

      {txError && (
        <div className="mt-4 p-4 bg-red-600/20 rounded-lg border border-red-400">
          <p className="text-red-400">
            <strong>Error:</strong> {txError}
          </p>
        </div>
      )}

      {/* Waiting states */}
      {pendingAction && (isTokenApproveSuccess || isApproveSuccess) && (
        <div className="text-center p-6 bg-yellow-600/20 rounded-xl border border-yellow-400 mb-4">
          <p className="text-xl font-semibold animate-pulse">⏳ Verifying approval and executing {pendingAction}...</p>
          <p className="text-sm text-gray-300 mt-2">Please wait while we confirm your approval on the blockchain</p>
        </div>
      )}
      
      {state === GameState.Dealing && (
        <div className="text-center p-6 bg-blue-600/20 rounded-xl border-2 border-blue-400">
          <p className="text-2xl font-bold animate-pulse mb-2">🎲 Dealing cards...</p>
          <p className="text-sm text-gray-300 mt-2">
            Waiting for Chainlink VRF to provide randomness
          </p>
          <p className="text-xs text-gray-400 mt-1">
            This usually takes 1-5 minutes on testnet
          </p>
          <VRFStatusDisplay gameAddress={gameAddress} />
        </div>
      )}

      {state === GameState.DealerTurn && (
        <div className="text-center p-6 bg-purple-600/20 rounded-xl border-2 border-purple-400">
          <p className="text-xl font-semibold mb-4">🎰 Dealer's Turn</p>
          {isPending ? (
            <div>
              <p className="text-lg animate-pulse mb-2">⏳ Processing dealer action...</p>
              <p className="text-xs text-gray-400">Waiting for transaction confirmation</p>
            </div>
          ) : (
            <div>
              <p className="text-lg animate-pulse mb-2">🎲 Dealer is playing...</p>
              <p className="text-sm text-gray-400 mb-4">
                {(() => {
                  const dealerCards = dealerCardsData as readonly bigint[] | undefined;
                  if (!dealerCards || dealerCards.length < 2) {
                    return "Waiting for dealer cards...";
                  }
                  const dealerScore = calculateDealerScore(dealerCards);
                  if (dealerScore < 17) {
                    return `Dealer has ${dealerScore}, needs to hit. Waiting for VRF...`;
                  } else {
                    return `Dealer has ${dealerScore}, stands. Game finishing...`;
                  }
                })()}
              </p>
              <VRFStatusDisplay gameAddress={gameAddress} />
              
              {/* Show processing message while waiting for automation */}
              {secondsWaiting > 0 && secondsWaiting < 5 && (
                <div className="mt-4 p-4 bg-blue-600/30 border-2 border-blue-400 rounded-lg">
                  <p className="text-lg font-semibold text-blue-200 mb-2">
                    🎲 Processing dealer action...
                  </p>
                  <p className="text-sm text-gray-300">
                    {secondsWaiting < 3 
                      ? `Will auto-trigger in ${3 - secondsWaiting} second${3 - secondsWaiting !== 1 ? 's' : ''}...`
                      : 'Transaction should start any moment...'
                    }
                  </p>
                </div>
              )}
              
              {/* Show manual retry after 5 seconds (in case fallback automation failed) */}
              {secondsWaiting >= 5 && (
                <div className="mt-4 p-4 bg-yellow-600/30 border-2 border-yellow-400 rounded-lg">
                  <p className="text-lg font-semibold text-yellow-200 mb-2">
                    ⚠️ Dealer action delayed
                  </p>
                  <p className="text-sm text-gray-300 mb-3">
                    Waiting for {secondsWaiting} seconds. You can manually trigger the action:
                  </p>
                  <button
                    onClick={handleRetryDealerAction}
                    className="px-4 py-2 bg-yellow-500 hover:bg-yellow-600 text-black font-bold rounded-lg transition-colors"
                  >
                    🔄 Retry Dealer Action
                  </button>
                </div>
              )}
            </div>
          )}
        </div>
      )}

      {isFinished && (
        <div className="text-center p-6 bg-yellow-600/20 rounded-xl border-2 border-yellow-400">
          {/* Only show "Game Over!" when we have a valid result */}
          {/* Check if we have bet data loaded to avoid showing before data is ready */}
          {gameResult && (
            <p className="text-2xl font-bold mb-4">Game Over!</p>
          )}
          {!gameResult && (
            <div className="text-center p-4">
              <p className="text-lg animate-pulse mb-2">
                ⏳ Loading final result...
              </p>
              <p className="text-sm text-gray-300">
                Please wait while we calculate the outcome
              </p>
            </div>
          )}
          {gameResult && (() => {
            // Use the pre-calculated result from gameResult to avoid race conditions
            // This ensures the UI shows the correct result immediately
            const result = gameResult.result;
            
            if (result === "blackjack") {
              return <p className="text-4xl font-bold mb-2 text-yellow-300 animate-pulse">🃏 BLACKJACK! 🃏</p>;
            } else if (result === "won") {
              return <p className="text-3xl font-bold mb-2 text-green-400 animate-pulse">🎉 Congratulations! You Win! 🎉</p>;
            } else if (result === "push") {
              return <p className="text-3xl font-bold mb-2 text-yellow-400 animate-pulse">🤝 It's a Push! 🤝</p>;
            } else if (result === "insurance_payout") {
              return <p className="text-3xl font-bold mb-2 text-blue-400 animate-pulse">🛡️ Insurance Paid Out! 🛡️</p>;
            } else {
              return <p className="text-3xl font-bold mb-2 text-red-400 animate-pulse">😔 Sorry! You Lose! 😔</p>;
            }
          })()}
          {gameResult && (
            <div className="mt-4">
              {(() => {
                // Calculate total bet INCLUDING insurance for display purposes only
                // DO NOT recalculate result here - use gameResult.result which was already calculated correctly
                const totalMainBet = playerHands.reduce((sum, hand) => sum + Number(hand.bet), 0);
                const insurancePaid = contractInsuranceBet ? Number(contractInsuranceBet) : Number(placedInsuranceAmount);
                const totalBet = totalMainBet + insurancePaid;
                const payoutAmount = Number(gameResult.payout);
                
                
                // Use the pre-calculated result from gameResult - this is the source of truth
                const actualResult = gameResult.result;
                
                
                
                return (
                  <>
                    <div className="mb-4 p-3 bg-black/40 rounded-lg">
                      <p className="text-sm text-gray-400">Main Bet Amount</p>
                      <p className="text-2xl font-bold text-white">
                        {(totalMainBet / 1e18).toFixed(2)} BJT
                      </p>
                      {insurancePaid > 0 && (
                        <>
                          <p className="text-sm text-gray-400 mt-2">Insurance Bet</p>
                          <p className="text-xl font-semibold text-blue-300">
                            +{(insurancePaid / 1e18).toFixed(2)} BJT
                          </p>
                          <div className="border-t border-gray-600 mt-2 pt-2">
                            <p className="text-sm text-gray-400">Total Amount Paid</p>
                            <p className="text-2xl font-bold text-yellow-300">
                              {(totalBet / 1e18).toFixed(2)} BJT
                            </p>
                          </div>
                        </>
                      )}
                    </div>
                    {payoutAmount > 0 ? (
                      <div className={`border rounded-lg p-4 ${
                        actualResult === "blackjack"
                          ? "bg-yellow-600/30 border-yellow-400"
                          : actualResult === "won" 
                          ? "bg-green-600/30 border-green-400" 
                          : actualResult === "push"
                          ? "bg-yellow-600/30 border-yellow-400"
                          : actualResult === "insurance_payout"
                          ? "bg-blue-600/30 border-blue-400"
                          : "bg-gray-600/30 border-gray-400"
                      }`}>
                        <p className={`text-lg font-bold ${
                          actualResult === "blackjack"
                            ? "text-yellow-300"
                            : actualResult === "won" 
                            ? "text-green-300" 
                            : actualResult === "push"
                            ? "text-yellow-300"
                            : actualResult === "insurance_payout"
                            ? "text-blue-300"
                            : "text-gray-300"
                        }`}>
                          {actualResult === "blackjack" && "🃏 BLACKJACK! 3:2 Payout!"}
                          {actualResult === "won" && "💰 You Won!"}
                          {actualResult === "push" && "🤝 Push - Tie Game"}
                          {actualResult === "insurance_payout" && "🛡️ Insurance Protected You!"}
                          {actualResult === "lost" && "💸 Bet Lost"}
                        </p>
                        {(actualResult === "won" || actualResult === "blackjack") && (
                          <>
                            <p className="text-2xl font-bold text-green-400 mt-3">
                              +{((payoutAmount - totalBet) / 1e18).toFixed(2)} BJT
                            </p>
                            <p className="text-sm text-gray-400 mt-1">
                              Net Profit {actualResult === "blackjack" ? "(3:2 Blackjack)" : ""}
                            </p>
                          </>
                        )}
                        {actualResult === "insurance_payout" && (
                          <>
                            <div className="mt-3 space-y-2">
                              <div className="bg-red-900/30 rounded p-3 border border-red-400/50">
                                <p className="text-sm text-red-200 font-semibold">⚠️ Dealer had Blackjack</p>
                                <p className="text-base text-red-300 mt-1">Main bet lost: -{(totalMainBet / 1e18).toFixed(2)} BJT</p>
                              </div>
                              <div className="bg-blue-900/40 rounded p-3 border border-blue-400/50">
                                <p className="text-sm text-blue-200 font-semibold">🛡️ Insurance paid 2:1</p>
                                <p className="text-base text-blue-300 mt-1">
                                  Insurance return: +{((insurancePaid * 3) / 1e18).toFixed(2)} BJT
                                </p>
                                <p className="text-xs text-blue-200 mt-1 italic">
                                  (3x your {(insurancePaid / 1e18).toFixed(2)} BJT insurance bet)
                                </p>
                              </div>
                              <div className="bg-yellow-900/30 rounded p-3 border border-yellow-400/50">
                                <p className="text-sm text-yellow-200 font-semibold">💰 Final Result</p>
                                <p className="text-2xl font-bold text-yellow-300 mt-1">
                                  {payoutAmount === totalBet ? "±0.00 BJT" : 
                                   payoutAmount > totalBet ? `+${((payoutAmount - totalBet) / 1e18).toFixed(2)} BJT` :
                                   `${((payoutAmount - totalBet) / 1e18).toFixed(2)} BJT`}
                                </p>
                                <p className="text-xs text-yellow-200 mt-1">
                                  {payoutAmount === totalBet ? "Break even - insurance covered your loss!" : 
                                   payoutAmount > totalBet ? "Profit - insurance paid more than you lost!" :
                                   "Reduced loss - insurance helped recover some of your bet"}
                                </p>
                              </div>
                            </div>
                            <p className="text-xs text-blue-300 mt-3 p-2 bg-blue-900/20 rounded border border-blue-400/30 italic">
                              💡 Insurance is a side bet that pays when the dealer has Blackjack. It costs half your main bet and pays 2:1 (returns 3x your insurance), helping you recover losses when the dealer gets lucky!
                            </p>
                          </>
                        )}
                        {actualResult === "push" && (
                          <p className="text-xl font-semibold text-yellow-300 mt-2">
                            {(totalBet / 1e18).toFixed(2)} BJT (bet returned)
                          </p>
                        )}
                        <p className="text-sm text-gray-300 mt-2 border-t border-gray-600 pt-2">
                          Total Payout: {(payoutAmount / 1e18).toFixed(2)} BJT
                        </p>
                        <p className="text-xs text-gray-300 mt-1">
                          (Automatically transferred to your wallet)
                        </p>
                      </div>
                    ) : (
                      <div className="bg-red-600/30 border border-red-400 rounded-lg p-4">
                        <p className="text-lg font-bold text-red-300">
                          No payout - Better luck next time!
                        </p>
                        <p className="text-sm text-gray-300 mt-1">
                          Lost: {(totalBet / 1e18).toFixed(2)} BJT
                        </p>
                      </div>
                    )}
                  </>
                );
              })()}
            </div>
          )}
        </div>
      )}
    </div>
    </div>
  );
}
