import { useReadContract, useWatchContractEvent } from "wagmi";
import { useEffect, useState, useCallback, useRef } from "react";
import { GAME_ABI } from "@/lib/abis";

type VRFStatus = {
  hasFailed: boolean;
  timeWaiting: bigint;
  canRetry: boolean;
  timeRemaining: bigint;
  isWaitingForVRF: boolean;
  lastRequestId: bigint;
};

/**
 * Hook to monitor VRF request status for a game
 * Uses event watching + polling for reliable timeout detection
 */
export function useVRFStatus(gameAddress: `0x${string}` | undefined) {
  
  const [status, setStatus] = useState<VRFStatus>({
    hasFailed: false,
    timeWaiting: BigInt(0),
    canRetry: false,
    timeRemaining: BigInt(120), // 2 minutes in seconds
    isWaitingForVRF: false,
    lastRequestId: BigInt(0),
  });

  // Track the last request ID to detect when a new VRF request is made after retry
  const lastSeenRequestIdRef = useRef<bigint>(BigInt(0));

  // Track the last time we got data from the contract for local countdown
  const [lastContractTime, setLastContractTime] = useState<number | null>(null);
  const [contractTimeRemaining, setContractTimeRemaining] = useState<bigint | null>(null);

  // ALWAYS poll every 2 seconds when we have a game address - simpler and more reliable
  // Read game state to determine if waiting for VRF
  const { data: gameState, refetch: refetchGameState } = useReadContract({
    address: gameAddress,
    abi: GAME_ABI,
    functionName: "state",
    query: {
      enabled: !!gameAddress,
      refetchInterval: 2000, // Always poll
    },
  });

  // Read VRF request status
  const { data: vrfRequestStatus, refetch: refetchStatus } = useReadContract({
    address: gameAddress,
    abi: GAME_ABI,
    functionName: "getVRFRequestStatus",
    query: {
      enabled: !!gameAddress,
      refetchInterval: 2000, // Always poll
      gcTime: 0, // Don't cache
      staleTime: 0, // Always consider stale
    },
  });

  // Read time remaining
  const { data: timeRemainingData, refetch: refetchTimeRemaining } = useReadContract({
    address: gameAddress,
    abi: GAME_ABI,
    functionName: "getVRFTimeRemaining",
    query: {
      enabled: !!gameAddress,
      refetchInterval: 2000, // Always poll
      gcTime: 0, // Don't cache
      staleTime: 0, // Always consider stale
    },
  });

  // Read last request ID
  const { data: lastRequestId } = useReadContract({
    address: gameAddress,
    abi: GAME_ABI,
    functionName: "lastRequestId",
    query: {
      enabled: !!gameAddress,
    },
  });

  // Watch for VRFRequested events (indicates new VRF request)
  useWatchContractEvent({
    address: gameAddress,
    abi: GAME_ABI,
    eventName: "VRFRequested",
    onLogs: useCallback(() => {
      // Refetch data when new VRF request is made
      refetchStatus();
      refetchTimeRemaining();
      refetchGameState();
    }, [refetchStatus, refetchTimeRemaining, refetchGameState]),
  });

  // Watch for CardsDealt event (indicates VRF fulfilled)
  useWatchContractEvent({
    address: gameAddress,
    abi: GAME_ABI,
    eventName: "CardsDealt",
    onLogs: useCallback(() => {
      // Refetch when VRF is fulfilled
      refetchStatus();
      refetchTimeRemaining();
      refetchGameState();
    }, [refetchStatus, refetchTimeRemaining, refetchGameState]),
  });

  // Watch for GameFinished event (game ended)
  useWatchContractEvent({
    address: gameAddress,
    abi: GAME_ABI,
    eventName: "GameFinished",
    onLogs: useCallback(() => {
      // Refetch when game finishes
      refetchGameState();
    }, [refetchGameState]),
  });

  // Update status when data changes
  useEffect(() => {
    if (!gameAddress) return;

    const isWaitingForVRF = Number(gameState) === 1; // GameState.Dealing = 1
    
    const timestamp = new Date().toISOString();
    
    // Always update isWaitingForVRF even if we don't have full VRF data yet
    if (isWaitingForVRF) {
      if (vrfRequestStatus !== undefined && timeRemainingData !== undefined) {
        // Full data available - update complete status
        
        // Handle different possible return formats
        let hasFailed: boolean;
        let timeWaiting: bigint;
        let canRetry: boolean;
        
        if (Array.isArray(vrfRequestStatus)) {
          [hasFailed, timeWaiting, canRetry] = vrfRequestStatus as [boolean, bigint, boolean];
        } else if (typeof vrfRequestStatus === 'object' && vrfRequestStatus !== null) {
          // Could be an object with named properties
          const statusObj = vrfRequestStatus as any;
          hasFailed = statusObj.hasFailed || statusObj[0];
          timeWaiting = statusObj.timeWaiting || statusObj[1];
          canRetry = statusObj.canRetry || statusObj[2];
        } else {
          // Fallback
          hasFailed = false;
          timeWaiting = BigInt(0);
          canRetry = false;
        }
        
        
        const contractTimeRemaining = timeRemainingData as bigint;

        // Detect if this is a NEW VRF request (after a retry)
        const currentRequestId = (lastRequestId as bigint) || BigInt(0);
        const isNewRequest = currentRequestId > BigInt(0) && currentRequestId !== lastSeenRequestIdRef.current;
        
        let effectiveTimeRemaining: bigint;
        
        if (isNewRequest) {
          lastSeenRequestIdRef.current = currentRequestId;
          // Force fresh countdown for new request
          effectiveTimeRemaining = BigInt(120);
        } else {
          // Use contract's time remaining, but clamp negative values to 0
          effectiveTimeRemaining = contractTimeRemaining < BigInt(0) ? BigInt(0) : contractTimeRemaining;
        }

        const newStatus = {
          hasFailed,
          timeWaiting,
          canRetry,
          timeRemaining: effectiveTimeRemaining,
          isWaitingForVRF: true,
          lastRequestId: currentRequestId,
        };

        const prevTimeRemaining = status.timeRemaining;
        setStatus(newStatus);
      } else {
        // Game is in Dealing state but VRF data not loaded yet - show waiting status
        const newStatus = {
          hasFailed: false,
          timeWaiting: BigInt(0),
          canRetry: false,
          timeRemaining: BigInt(120), // Default 2 minutes
          isWaitingForVRF: true,
          lastRequestId: lastRequestId as bigint || BigInt(0),
        };

        setStatus(newStatus);
      }
    } else {
      // Not waiting for VRF - clear status
      setStatus({
        hasFailed: false,
        timeWaiting: BigInt(0),
        canRetry: false,
        timeRemaining: BigInt(120),
        isWaitingForVRF: false,
        lastRequestId: BigInt(0),
      });
    }
  }, [vrfRequestStatus, timeRemainingData, gameState, lastRequestId, gameAddress]);

  // Local countdown timer - update every second between contract polls
  // Use refs to avoid dependency array issues - CRITICAL: only restart interval when truly transitioning states
  const intervalRef = useRef<NodeJS.Timeout | null>(null);
  const refetchStatusRef = useRef(refetchStatus);
  const refetchTimeRemainingRef = useRef(refetchTimeRemaining);
  
  // Keep refs up to date
  useEffect(() => {
    refetchStatusRef.current = refetchStatus;
    refetchTimeRemainingRef.current = refetchTimeRemaining;
  }, [refetchStatus, refetchTimeRemaining]);
  
  // Track if we're in a "waiting" state to avoid restarting the interval on every render
  const isActivelyWaitingRef = useRef(false);
  const lastRequestIdForTimerRef = useRef<bigint>(BigInt(0));
  
  useEffect(() => {
    const shouldBeWaiting = status.isWaitingForVRF && !status.hasFailed;
    const hasNewRequest = status.lastRequestId !== lastRequestIdForTimerRef.current;
    
    // Only clear and restart the interval if:
    // 1. We're transitioning from not-waiting to waiting
    // 2. We're transitioning from waiting to not-waiting
    // 3. There's a new VRF request (after retry)
    const shouldRestartInterval = 
      (shouldBeWaiting !== isActivelyWaitingRef.current) || 
      (shouldBeWaiting && hasNewRequest);
    
    if (!shouldRestartInterval) {
      // No state change - don't touch the interval
      return;
    }
    
    
    // Clear any existing interval
    if (intervalRef.current) {
      clearInterval(intervalRef.current);
      intervalRef.current = null;
    }
    
    // Update our tracking refs
    isActivelyWaitingRef.current = shouldBeWaiting;
    lastRequestIdForTimerRef.current = status.lastRequestId;
    
    // Only start the timer if we should be waiting
    if (!shouldBeWaiting) {
      return;
    }
    
    
    intervalRef.current = setInterval(() => {
      setStatus(prev => {
        if (!prev.isWaitingForVRF || prev.hasFailed) {
          return prev;
        }
        
        const newTimeRemaining = prev.timeRemaining > BigInt(0) 
          ? prev.timeRemaining - BigInt(1) 
          : BigInt(0);
        
        
        // If we hit 0, trigger a contract refetch to check if it failed
        if (newTimeRemaining === BigInt(0) && prev.timeRemaining === BigInt(1)) {
          refetchStatusRef.current();
          refetchTimeRemainingRef.current();
        }
        
        // Also refetch when we're getting close (at 10s, 5s, 1s) to ensure we catch the failure
        if ([BigInt(10), BigInt(5), BigInt(1)].includes(newTimeRemaining)) {
          refetchStatusRef.current();
          refetchTimeRemainingRef.current();
        }
        
        return {
          ...prev,
          timeRemaining: newTimeRemaining,
        };
      });
    }, 1000); // Update every second
    
    return () => {
      if (intervalRef.current) {
        clearInterval(intervalRef.current);
        intervalRef.current = null;
      }
    };
  }, [status.isWaitingForVRF, status.hasFailed, status.lastRequestId, gameAddress]);

  return status;
}
