"use client";

import { useVRFStatus } from "@/hooks/useVRFStatus";
import { useWriteContract, useWaitForTransactionReceipt } from "wagmi";
import { GAME_ABI } from "@/lib/abis";
import { useState, useEffect, useCallback, useRef } from "react";

type VRFStatusDisplayProps = {
  gameAddress: `0x${string}`;
};

export function VRFStatusDisplay({ gameAddress }: VRFStatusDisplayProps) {
  const vrfStatus = useVRFStatus(gameAddress);
  const [error, setError] = useState<string | null>(null);
  const [hasAttemptedAutoRetry, setHasAttemptedAutoRetry] = useState(false);
  const lastSeenRequestIdRef = useRef<bigint>(BigInt(0));

  console.log("🎬 VRFStatusDisplay RENDER - gameAddress:", gameAddress, "vrfStatus:", vrfStatus);

  const { 
    writeContract: retryVRF, 
    data: retryTxHash, 
    isPending: isRetrying,
    error: retryError 
  } = useWriteContract();

  const { isSuccess: isRetrySuccess, isError: isRetryError } = useWaitForTransactionReceipt({
    hash: retryTxHash,
  });

  // Handle retry errors
  useEffect(() => {
    if (retryError) {
      setError(`Retry failed: ${retryError.message}`);
    }
  }, [retryError]);

  useEffect(() => {
    if (isRetryError) {
      setError("Retry transaction failed on-chain. Please try again.");
    }
  }, [isRetryError]);

  // Clear error on successful retry and reset flag when we detect new countdown started
  useEffect(() => {
    if (isRetrySuccess) {
      setError(null);
      // Don't reset hasAttemptedAutoRetry here - wait for new request ID or countdown reset
    }
  }, [isRetrySuccess]);

  // Reset retry flag when a new VRF request is detected (by request ID OR countdown reset)
  // IMPORTANT: All dependencies must be in array from the start to avoid size changes
  useEffect(() => {
    const currentRequestId = vrfStatus.lastRequestId;
    const timeRemaining = Number(vrfStatus.timeRemaining);
    
    // Method 1: New request ID detected (most reliable)
    if (currentRequestId > BigInt(0) && currentRequestId !== lastSeenRequestIdRef.current) {
      lastSeenRequestIdRef.current = currentRequestId;
      setHasAttemptedAutoRetry(false);
      setError(null);
      return;
    }
    
    // Method 2: Countdown was reset to high value after retry was attempted
    // This catches cases where request ID hasn't updated yet but countdown reset
    if (hasAttemptedAutoRetry && timeRemaining > 100) {
      setHasAttemptedAutoRetry(false);
      setError(null);
    }
  }, [vrfStatus.lastRequestId, vrfStatus.timeRemaining, hasAttemptedAutoRetry]); // All dependencies present from start

  const handleRetry = useCallback(async () => {
    console.log("🔄🔄🔄 VRF RETRY TRIGGERED - VRFStatusDisplay.handleRetry called");
    console.log("🔄 Game address:", gameAddress);
    console.log("🔄 VRF status:", vrfStatus);
    try {
      setError(null);
      console.log("🔄 Calling retryVRFRequest on contract...");
      retryVRF({
        address: gameAddress,
        abi: GAME_ABI,
        functionName: "retryVRFRequest",
        gas: BigInt(800000), // Higher gas limit for external call to factory + VRF coordinator
      });
      console.log("✅ retryVRFRequest transaction submitted");
    } catch (err) {
      console.error("❌ VRF retry failed:", err);
      setError("Failed to initiate retry");
    }
  }, [gameAddress, retryVRF, vrfStatus]);

  // DISABLED: Automatic retry when local countdown reaches 0
  // This was causing phantom transactions during normal VRF processing
  // Users can manually retry if needed via the button in the UI
  useEffect(() => {
    const timeRemainingNumber = Number(vrfStatus.timeRemaining);
    const isWaiting = vrfStatus.isWaitingForVRF;

    console.log("🕐 VRF countdown check - timeRemaining:", timeRemainingNumber, "isWaiting:", isWaiting);

    // AUTO-RETRY DISABLED - show manual retry button instead
    if (isWaiting && timeRemainingNumber === 0) {
      console.log("⏰ VRF countdown reached 0 - showing manual retry button");
    }
  }, [vrfStatus.timeRemaining, vrfStatus.isWaitingForVRF]);

  // Don't show anything if not waiting for VRF (hide immediately when VRF completes)
  // This prevents showing "Retrying automatically..." after VRF fulfillment
  if (!vrfStatus.isWaitingForVRF) {
    return null;
  }

  const timeRemainingSeconds = Number(vrfStatus.timeRemaining);
  
  // Additional check: if countdown is 0 but we're still "waiting", only show if actively retrying
  // This prevents the brief flash of "Retrying automatically..." after VRF completes
  if (timeRemainingSeconds === 0 && !isRetrying && !hasAttemptedAutoRetry) {
    return null;
  }

  const minutes = Math.floor(timeRemainingSeconds / 60);
  const seconds = timeRemainingSeconds % 60;

  return (
    <div className="mt-4 p-4 bg-gradient-to-br from-purple-900/50 to-indigo-900/50 border border-purple-400/50 rounded-lg">
      {timeRemainingSeconds > 0 ? (
        <div className="space-y-3">
          <div className="flex items-center justify-center gap-2">
            <svg className="animate-spin h-5 w-5 text-yellow-400" xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24">
              <circle className="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" strokeWidth="4"></circle>
              <path className="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"></path>
            </svg>
            <span className="text-lg font-semibold text-white">
              VRF Request Pending
            </span>
          </div>
          
          <div className="text-center">
            <p className="text-sm text-gray-300 mb-2">Time remaining:</p>
            <div className="text-3xl font-mono font-bold text-yellow-400">
              {minutes}:{seconds.toString().padStart(2, '0')}
            </div>
          </div>
          
          <div className="w-full bg-gray-700 rounded-full h-2">
            <div 
              className="bg-gradient-to-r from-yellow-400 to-yellow-500 h-2 rounded-full transition-all duration-1000"
              style={{ 
                width: `${(timeRemainingSeconds / 120) * 100}%` 
              }}
            />
          </div>
          
          <p className="text-xs text-center text-gray-400">
            Chainlink VRF is generating provably fair randomness
          </p>
        </div>
      ) : (
        <div className="space-y-2">
          <div className="flex items-center justify-center gap-2">
            <svg className="animate-spin h-5 w-5 text-green-400" xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24">
              <circle className="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" strokeWidth="4"></circle>
              <path className="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 714 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"></path>
            </svg>
            <span className="text-lg font-semibold text-green-400">
              {isRetrying ? "Retrying automatically..." : "Finalizing..."}
            </span>
          </div>
          <p className="text-sm text-center text-gray-300">
            Request timed out - automatic retry in progress (FREE)
          </p>
          {error && (
            <div className="bg-red-500/20 border border-red-500 rounded p-2 mt-2">
              <p className="text-xs text-center text-red-200">{error}</p>
            </div>
          )}
        </div>
      )}
    </div>
  );
}
