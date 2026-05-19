import { useState, useCallback } from "react";
import { useAccount, useConfig } from "wagmi";
import { simulateContract, writeContract, waitForTransactionReceipt, estimateGas } from "@wagmi/core";
import { parseGwei, encodeFunctionData } from "viem";

interface UseGameTransactionProps {
  gameAddress: `0x${string}`;
  abi: any;
  onSuccess?: (receipt?: any) => void;
  onError?: (error: Error) => void;
}

export function useGameTransaction({ 
  gameAddress, 
  abi, 
  onSuccess,
  onError 
}: UseGameTransactionProps) {
  const { address } = useAccount();
  const config = useConfig();
  const [isPending, setIsPending] = useState(false);
  const [hash, setHash] = useState<`0x${string}` | undefined>();
  const [error, setError] = useState<Error | null>(null);

  const execute = useCallback(async (
    functionName: string,
    args?: any[],
    value?: bigint
  ) => {
    if (!address) {
      const err = new Error("Wallet not connected");
      setError(err);
      onError?.(err);
      return;
    }

    setIsPending(true);
    setError(null);
    setHash(undefined);

    try {
      // Default args to empty array if undefined
      const functionArgs = args ?? [];
      
      // 1. Estimate gas for the transaction (with fallback if it fails)
      let contractGasFee: bigint;
      try {
        const baseGasEstimate = await estimateGas(config, {
          to: gameAddress,
          data: encodeFunctionData({
            abi,
            functionName,
            args: functionArgs,
          }),
          account: address,
          ...(value ? { value } : {}),
        });
        
        // Add buffer: 50% for doubleDown (more operations), 20% for others
        const gasMultiplier = functionName === 'doubleDown' ? 1.5 : 1.2;
        contractGasFee = (baseGasEstimate * BigInt(Math.floor(gasMultiplier * 100))) / BigInt(100);
      } catch (gasError: any) {
        // Re-throw the error so we can see what's actually wrong
        throw gasError;
      }

      // 2. Fetch gas prices from Polygon
      // Network minimum is ~25 Gwei, so we set defaults higher to be safe
      let gasPrice = {
        maxFee: "35",
        maxPriorityFee: "30",
      };
      try {
        const response = await fetch("https://gasstation.polygon.technology/amoy");
        if (!response.ok) {
        } else {
          const data = await response.json();
          gasPrice = data.fast; // Gas price in gwei
        }
      } catch (error) {
      }

      // Ensure gas prices meet network minimum (at least 30 Gwei for priority fee)
      const MINIMUM_PRIORITY_FEE = 30; // Gwei
      const priorityFee = Math.max(parseFloat(gasPrice.maxPriorityFee), MINIMUM_PRIORITY_FEE);
      const maxFee = Math.max(parseFloat(gasPrice.maxFee), priorityFee + 5);


      const gasConfig = {
        gas: contractGasFee,
        maxFeePerGas: parseGwei(maxFee.toString()),
        maxPriorityFeePerGas: parseGwei(priorityFee.toString()),
      };
      
      // 3. Build contract call config - only include fields that have values
      const contractConfig: any = {
        address: gameAddress,
        abi,
        functionName,
        account: address,
        ...gasConfig,
      };
      
      // Only include args if we have actual arguments (non-empty array)
      // For functions with no parameters, omit args entirely
      if (functionArgs && functionArgs.length > 0) {
        contractConfig.args = functionArgs;
      }
      
      // Only add value if it's provided and greater than 0
      if (value !== undefined && value > BigInt(0)) {
        contractConfig.value = value;
      }

      // 4. Simulate the transaction
      await simulateContract(config, contractConfig);

      // 5. Execute the transaction
      const txHash = await writeContract(config, contractConfig);

      setHash(txHash);

      // 6. Wait for confirmation
      const receipt = await waitForTransactionReceipt(config, { hash: txHash });

      onSuccess?.(receipt);
    } catch (err: any) {
      
      // More detailed error message parsing
      let errorMessage = "Transaction failed";
      
      // Map of custom error selectors to human-readable names
      const customErrors: Record<string, string> = {
        "0x1356fe96": "NotInsurancePhase - Insurance phase has ended",
        "0x01dfa6bc": "InsufficientLINK - Not enough LINK tokens in game contract",
        "0x66479f8c": "LINKTransferFailed - LINK transfer failed",
        "0x81cfce7c": "NotPlayerTurn - Not your turn to play",
        "0x8baa579f": "NotDealerTurn - Not dealer's turn",
        "0x6fb48ba8": "NotYourGame - This is not your game",
        "0x1e4e0091": "GameAlreadyStarted - Game already started",
        "0x72507bac": "HandAlreadyStood - Hand already stood",
        "0x5a98c85e": "HandBusted - Hand is busted",
        "0x7e27a6ea": "NotYourTurn - Not your turn",
      };
      
      // Try to extract the revert reason from various error formats
      // Check metaMessages for the error data
      if (err.metaMessages || err.cause?.metaMessages) {
        const messages = err.metaMessages || err.cause?.metaMessages;
        const dataMsg = messages?.find((msg: string) => msg.includes('data:'));
        if (dataMsg) {
          const match = dataMsg.match(/data:\s*"?(0x[0-9a-fA-F]+)"?/);
          if (match) {
            const errorData = match[1];
            const selector = errorData.slice(0, 10).toLowerCase();
            if (customErrors[selector]) {
              errorMessage = customErrors[selector];
            } else {
              errorMessage = `Contract reverted with custom error ${selector}`;
            }
          }
        }
      }
      
      // First check for custom error in the data field
      if (!errorMessage.includes("Contract reverted") && (err.data || err.cause?.data)) {
        const errorData = (err.data || err.cause?.data) as string;
        if (errorData && typeof errorData === 'string' && errorData.startsWith('0x')) {
          // Extract the first 10 characters (0x + 8 hex chars = 4 bytes = function selector)
          const selector = errorData.slice(0, 10).toLowerCase();
          if (customErrors[selector]) {
            errorMessage = customErrors[selector];
          } else {
            errorMessage = `Contract reverted with custom error ${selector}`;
          }
        }
      }
      
      if (errorMessage === "Transaction failed" && err.cause?.reason) {
        errorMessage = err.cause.reason;
      } else if (errorMessage === "Transaction failed" && err.reason) {
        errorMessage = err.reason;
      } else if (errorMessage === "Transaction failed" && err.shortMessage) {
        errorMessage = err.shortMessage;
      } else if (errorMessage === "Transaction failed" && err.details) {
        errorMessage = err.details;
      } else if (errorMessage === "Transaction failed" && err.message) {
        // Try to extract useful info from the error message
        if (err.message.includes("execution reverted")) {
          // Try to extract custom error selector
          const customErrorMatch = err.message.match(/custom error (0x[0-9a-fA-F]+)/);
          if (customErrorMatch) {
            const selector = customErrorMatch[1].toLowerCase();
            errorMessage = customErrors[selector] || `Contract reverted with custom error ${selector}`;
          } else {
            // Try to extract the revert reason string
            const revertMatch = err.message.match(/reverted with reason string '([^']+)'/);
            if (revertMatch) {
              errorMessage = `Contract reverted: ${revertMatch[1]}`;
            } else {
              errorMessage = "Transaction reverted by contract (check console for details)";
            }
          }
          
          // For dealer actions, this is often expected (game state changed)
          if (functionName === "dealerHit") {
          }
        } else {
          errorMessage = err.message;
        }
      }
      
      // Log the decoded error
      
      const error = new Error(errorMessage);
      setError(error);
      
      // Only call onError for user actions, not automated dealer actions
      if (functionName !== "dealerHit") {
        onError?.(error);
      }
    } finally {
      setIsPending(false);
    }
  }, [address, config, gameAddress, abi, onSuccess, onError]);

  return {
    execute,
    isPending,
    hash,
    error,
  };
}
