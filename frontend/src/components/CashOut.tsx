"use client";

import { useAccount, useReadContract, useWriteContract, useWaitForTransactionReceipt } from "wagmi";
import { GAME_TOKEN_ABI } from "@/lib/abis";
import { useState } from "react";
import { formatUnits, parseUnits } from "viem";

const GAME_TOKEN_ADDRESS = process.env.NEXT_PUBLIC_GAME_TOKEN_ADDRESS as `0x${string}`;

export function CashOut() {
  const { address, isConnected } = useAccount();
  const [amount, setAmount] = useState("");
  const [txError, setTxError] = useState<string | null>(null);

  // Read user's token balance
  const { data: balance, refetch: refetchBalance } = useReadContract({
    address: GAME_TOKEN_ADDRESS,
    abi: GAME_TOKEN_ABI,
    functionName: "balanceOf",
    args: address ? [address] : undefined,
    query: {
      enabled: isConnected && !!address,
      // No polling - user has manual refresh button
      refetchInterval: false,
    },
  });

  // Calculate how much POL user will receive
  const { data: polOut } = useReadContract({
    address: GAME_TOKEN_ADDRESS,
    abi: GAME_TOKEN_ABI,
    functionName: "calculateSellReturn",
    args: amount && amount !== "0" ? [parseUnits(amount, 18)] : [BigInt(0)],
    query: {
      enabled: !!amount && amount !== "0",
    },
  });

  // Redeem tokens
  const { writeContract: redeemTokens, isPending, data: txHash } = useWriteContract();
  
  const { isSuccess } = useWaitForTransactionReceipt({
    hash: txHash,
  });

  const handleRedeem = () => {
    if (!amount || amount === "0") {
      setTxError("Please enter an amount");
      return;
    }

    try {
      const tokenAmount = parseUnits(amount, 18);
      
      if (balance && tokenAmount > balance) {
        setTxError("Insufficient balance");
        return;
      }

      setTxError(null);
      redeemTokens({
        address: GAME_TOKEN_ADDRESS,
        abi: GAME_TOKEN_ABI,
        functionName: "redeemTokens",
        args: [tokenAmount],
      });
    } catch (err) {
      setTxError(err instanceof Error ? err.message : "Failed to redeem tokens");
    }
  };

  const handleMax = () => {
    if (balance) {
      setAmount(formatUnits(balance, 18));
    }
  };

  // Reset form after successful redemption
  if (isSuccess && amount) {
    setTimeout(() => {
      setAmount("");
      refetchBalance();
    }, 1000);
  }

  const balanceDisplay = balance ? formatUnits(balance, 18) : "0";
  const polOutDisplay = polOut ? formatUnits(polOut, 18) : "0";

  if (!isConnected) {
    return (
      <div className="card">
        <h2 className="text-xl font-bold mb-4">💰 Cash Out to POL</h2>
        <p className="text-gray-600 dark:text-gray-400">
          Connect your wallet to cash out your tokens
        </p>
      </div>
    );
  }

  return (
    <div className="card">
      <h2 className="text-xl font-bold mb-4">💰 Cash Out to POL</h2>
      
      <div className="mb-4 p-3 bg-gray-100 dark:bg-gray-800 rounded-lg">
        <div className="text-sm text-gray-600 dark:text-gray-400">Your BJT Balance</div>
        <div className="text-2xl font-bold">{Number(balanceDisplay).toFixed(2)} BJT</div>
        <div className="text-xs text-gray-500">
          ≈ {Number(balanceDisplay) / 1000} POL
        </div>
      </div>

      <div className="space-y-4">
        <div>
          <label className="block text-sm font-medium mb-2">
            Amount to Cash Out (BJT)
          </label>
          <div className="flex gap-2">
            <input
              type="number"
              value={amount}
              onChange={(e) => {
                setAmount(e.target.value);
                setTxError(null);
              }}
              placeholder="0.0"
              className="input flex-1"
              step="0.01"
              min="0"
              disabled={isPending}
            />
            <button
              onClick={handleMax}
              disabled={isPending || !balance || balance === BigInt(0)}
              className="btn btn-secondary px-4"
            >
              MAX
            </button>
          </div>
        </div>

        {amount && polOut && (
          <div className="p-3 bg-blue-50 dark:bg-blue-900/20 rounded-lg border border-blue-200 dark:border-blue-800">
            <div className="text-sm text-gray-600 dark:text-gray-400">You will receive</div>
            <div className="text-xl font-bold text-blue-600 dark:text-blue-400">
              {Number(polOutDisplay).toFixed(6)} POL
            </div>
            <div className="text-xs text-gray-500 mt-1">
              Rate: 1000 BJT = 1 POL (no fees)
            </div>
          </div>
        )}

        <button
          onClick={handleRedeem}
          disabled={isPending || !amount || amount === "0"}
          className="btn btn-primary w-full"
        >
          {isPending ? "Cashing Out..." : "Cash Out to POL"}
        </button>

        {isSuccess && (
          <div className="p-3 bg-green-100 dark:bg-green-900/20 border border-green-500 rounded-lg">
            <p className="text-green-700 dark:text-green-400 font-semibold">
              ✓ Successfully cashed out!
            </p>
            <p className="text-sm text-green-600 dark:text-green-500 mt-1">
              POL has been sent to your wallet
            </p>
          </div>
        )}

        {txError && (
          <div className="p-3 bg-red-100 dark:bg-red-900/20 border border-red-500 rounded-lg">
            <p className="text-red-700 dark:text-red-400">
              <strong>Error:</strong> {txError}
            </p>
          </div>
        )}
      </div>

      <div className="mt-6 pt-4 border-t border-gray-200 dark:border-gray-700">
        <h3 className="font-semibold mb-2 text-sm">How it works</h3>
        <ul className="text-xs text-gray-600 dark:text-gray-400 space-y-1">
          <li>• Convert your BJT tokens back to POL at a fixed 1000:1 rate</li>
          <li>• No fees - you get the full value of your tokens</li>
          <li>• POL is sent directly to your wallet</li>
          <li>• Your tokens are burned when you cash out</li>
        </ul>
      </div>
    </div>
  );
}
