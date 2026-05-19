"use client";

import { useState, useEffect } from "react";
import { useAccount, useReadContract, useBalance } from "wagmi";
import { parseEther, formatEther, formatUnits, parseUnits } from "viem";
import { GAME_TOKEN_ABI, LINK_TOKEN_ABI } from "@/lib/abis";
import { useGameTransaction } from "@/hooks/useGameTransaction";

const GAME_TOKEN_ADDRESS = process.env.NEXT_PUBLIC_GAME_TOKEN_ADDRESS as `0x${string}`;
const LINK_TOKEN_ADDRESS = process.env.NEXT_PUBLIC_LINK_TOKEN as `0x${string}`;
const TOKEN_RATE = 1000; // 1 POL = 1000 tokens

export function BuyTokens({ showBalanceOnly = false }: { showBalanceOnly?: boolean }) {
  const { address } = useAccount();
  const [polAmount, setPolAmount] = useState("0.1");
  const [redeemAmount, setRedeemAmount] = useState("100");
  const [showRedeem, setShowRedeem] = useState(false);

  const { data: tokenBalance, refetch: refetchTokenBalance } = useReadContract({
    address: GAME_TOKEN_ADDRESS,
    abi: GAME_TOKEN_ABI,
    functionName: "balanceOf",
    args: address ? [address] : undefined,
    query: {
      // No polling - only refetch after buy/redeem/game actions
      refetchInterval: false,
      staleTime: Infinity,
    },
  });

  const { data: linkBalance } = useReadContract({
    address: LINK_TOKEN_ADDRESS,
    abi: LINK_TOKEN_ABI,
    functionName: "balanceOf",
    args: address ? [address] : undefined,
  });

  const { data: polBalance } = useBalance({
    address: address,
  });

  // Make refetch available globally for game actions (create, split, double)
  useEffect(() => {
    if (typeof window !== 'undefined') {
      (window as any).refetchTokenBalance = refetchTokenBalance;
    }
    return () => {
      if (typeof window !== 'undefined') {
        delete (window as any).refetchTokenBalance;
      }
    };
  }, [refetchTokenBalance]);

  const { execute: executeBuy, isPending: isBuying, hash: buyHash, error: buyError } = useGameTransaction({
    gameAddress: GAME_TOKEN_ADDRESS,
    abi: GAME_TOKEN_ABI,
    onSuccess: () => {
      setTimeout(() => refetchTokenBalance(), 500); // Delay refetch slightly to ensure block is mined
      setPolAmount("0.1");
    },
  });

  const { execute: executeRedeem, isPending: isRedeeming, hash: redeemHash, error: redeemError } = useGameTransaction({
    gameAddress: GAME_TOKEN_ADDRESS,
    abi: GAME_TOKEN_ABI,
    onSuccess: () => {
      setTimeout(() => refetchTokenBalance(), 500); // Delay refetch slightly to ensure block is mined
      setRedeemAmount("100");
    },
  });

  const handleBuyTokens = async () => {
    if (!address) return;
    
    try {
      // buyTokens has no parameters, so we don't pass args
      await executeBuy("buyTokens", undefined, parseEther(polAmount));
    } catch (error) {
    }
  };

  const handleRedeemTokens = async () => {
    if (!address) return;
    
    try {
      const tokensToRedeem = parseUnits(redeemAmount, 18);
      await executeRedeem("redeemTokens", [tokensToRedeem]);
    } catch (error) {
    }
  };

  const estimatedTokens = parseFloat(polAmount || "0") * TOKEN_RATE;
  const estimatedPol = parseFloat(redeemAmount || "0") / TOKEN_RATE;

  return (
    <div className="card">
      <div className="flex items-center justify-between mb-4">
        <h2 className="text-2xl font-bold">💰 Token Management</h2>
        {address && (
          <button
            onClick={() => setShowRedeem(!showRedeem)}
            className="text-sm px-3 py-1 rounded-lg bg-gray-200 dark:bg-gray-700 hover:bg-gray-300 dark:hover:bg-gray-600"
          >
            {showRedeem ? "💵 Buy Tokens" : "🔄 Redeem Tokens"}
          </button>
        )}
      </div>
      
      {!address ? (
        /* NOT CONNECTED - Show message */
        <div className="text-center py-12">
          <p className="text-gray-500 dark:text-gray-400 mb-4">
            Please connect your wallet to manage tokens
          </p>
        </div>
      ) : (
        /* CONNECTED - Show balances and forms */
        <>
          <div className="mb-6 p-4 bg-blue-50 dark:bg-blue-900/20 rounded-lg space-y-3">
            <div className="flex justify-between items-center mb-2">
              <span className="text-sm font-semibold text-gray-700 dark:text-gray-300">
                💼 Your Balances
              </span>
              <button
                onClick={() => refetchTokenBalance()}
                className="text-xs px-2 py-1 bg-blue-500 hover:bg-blue-600 text-white rounded transition-colors"
                title="Refresh balances"
              >
                🔄 Refresh
              </button>
            </div>
            <div className="flex justify-between items-center">
              <span className="text-sm font-medium text-gray-700 dark:text-gray-300">
                Your POL Balance:
              </span>
              <span className="text-sm font-bold text-blue-600 dark:text-blue-400">
                {polBalance ? `${parseFloat(formatEther(polBalance.value)).toFixed(4)} POL` : "0 POL"}
              </span>
            </div>
            <div className="flex justify-between items-center">
              <span className="text-sm font-medium text-gray-700 dark:text-gray-300">
                Your Token Balance:
              </span>
              <span className="text-sm font-bold text-green-600 dark:text-green-400">
                {tokenBalance ? `${formatUnits(tokenBalance, 18)} BJT` : "0 BJT"}
              </span>
            </div>
            <div className="flex justify-between items-center border-t border-gray-200 dark:border-gray-700 pt-2">
              <span className="text-sm font-medium text-gray-700 dark:text-gray-300">
                Your LINK Balance:
              </span>
              <span className="text-sm font-bold text-orange-600 dark:text-orange-400">
                {linkBalance ? `${parseFloat(formatUnits(linkBalance, 18)).toFixed(4)} LINK` : "0 LINK"}
              </span>
            </div>
            <div className="pt-2 border-t border-gray-200 dark:border-gray-700">
              <p className="text-xs font-semibold text-center text-purple-600 dark:text-purple-400 mb-1">
                🔄 Exchange Rate: 1 POL = {TOKEN_RATE} BJT
              </p>
              <p className="text-xs text-gray-500 dark:text-gray-500 text-center">
                (1 BJT token = 10<sup>18</sup> base units, same as POL/ETH)
              </p>
            </div>
          </div>

          {!showRedeem ? (
            /* BUY TOKENS SECTION */
            <>
              <div className="mb-4">
                <label className="block text-sm font-medium mb-2">
                  POL Amount to Spend
                </label>
                <input
                  type="number"
                  value={polAmount}
                  onChange={(e) => setPolAmount(e.target.value)}
                  step="0.1"
                  min="0.01"
                  className="w-full px-4 py-2 border rounded-lg dark:bg-gray-700 dark:border-gray-600"
                  placeholder="0.1"
                />
                <div className="mt-2 p-3 bg-green-50 dark:bg-green-900/20 rounded border border-green-200 dark:border-green-800">
                  <p className="text-sm font-semibold text-green-700 dark:text-green-300">
                    💰 You will receive: <span className="text-lg">{estimatedTokens.toFixed(2)} BJT</span>
                  </p>
                  <p className="text-xs text-gray-600 dark:text-gray-400 mt-1">
                    📊 That's {(estimatedTokens * 1e18).toExponential(2)} base units (with 18 decimals)
                  </p>
                </div>
              </div>

              <button
                onClick={handleBuyTokens}
                disabled={!address || isBuying || !polAmount || parseFloat(polAmount) <= 0}
                className={`btn w-full ${
                  !address || isBuying || !polAmount || parseFloat(polAmount) <= 0
                    ? "btn-disabled"
                    : "btn-primary"
                }`}
              >
                {isBuying ? "Buying Tokens..." : "💵 Buy Tokens"}
              </button>

              {buyHash && (
                <p className="mt-4 text-green-600 dark:text-green-400 break-all">
                  Tokens purchased! Transaction: {buyHash}
                </p>
              )}

              {buyError && (
                <p className="mt-4 text-red-600 dark:text-red-400">
                  Error: {buyError.message}
                </p>
              )}
            </>
          ) : (
            /* REDEEM TOKENS SECTION */
            <>
              <div className="mb-4">
                <label className="block text-sm font-medium mb-2">
                  BJT Tokens to Redeem
                </label>
                <input
                  type="number"
                  value={redeemAmount}
                  onChange={(e) => setRedeemAmount(e.target.value)}
                  step="10"
                  min="10"
                  className="w-full px-4 py-2 border rounded-lg dark:bg-gray-700 dark:border-gray-600"
                  placeholder="100"
                />
                <p className="mt-2 text-sm text-gray-600 dark:text-gray-400">
                  You will receive: <span className="font-bold text-blue-600 dark:text-blue-400">
                    {estimatedPol.toFixed(4)} POL
                  </span>
                </p>
                <p className="mt-1 text-xs text-gray-500 dark:text-gray-500">
                  Available: {tokenBalance ? `${formatUnits(tokenBalance, 18)} BJT` : "0 BJT"}
                </p>
              </div>

              <button
                onClick={handleRedeemTokens}
                disabled={
                  !address || 
                  isRedeeming || 
                  !redeemAmount || 
                  parseFloat(redeemAmount) <= 0 || 
                  (tokenBalance ? parseUnits(redeemAmount, 18) > tokenBalance : false)
                }
                className={`btn w-full ${
                  !address || 
                  isRedeeming || 
                  !redeemAmount || 
                  parseFloat(redeemAmount) <= 0 || 
                  (tokenBalance ? parseUnits(redeemAmount, 18) > tokenBalance : false)
                    ? "btn-disabled"
                    : "btn-success"
                }`}
              >
                {isRedeeming ? "Redeeming Tokens..." : "🔄 Redeem for POL"}
              </button>

              {redeemHash && (
                <p className="mt-4 text-green-600 dark:text-green-400 break-all">
                  Tokens redeemed! Transaction: {redeemHash}
                </p>
              )}

              {redeemError && (
                <p className="mt-4 text-red-600 dark:text-red-400">
                  Error: {redeemError.message}
                </p>
              )}
            </>
          )}

          <div className="mt-6 p-4 bg-yellow-50 dark:bg-yellow-900/20 rounded-lg border border-yellow-200 dark:border-yellow-800">
            <h3 className="text-sm font-semibold mb-2 text-yellow-800 dark:text-yellow-300">
              ℹ️ Understanding BJT Tokens:
            </h3>
            {!showRedeem ? (
              <div className="text-xs text-gray-700 dark:text-gray-300 space-y-2">
                <div className="bg-white dark:bg-gray-800 p-2 rounded border border-gray-200 dark:border-gray-700">
                  <p className="font-semibold mb-1">🔢 Token Denomination:</p>
                  <ul className="list-disc list-inside space-y-0.5 ml-2">
                    <li><strong>1 BJT token = 10^18 base units</strong> (like POL/ETH)</li>
                    <li>Exchange rate: <strong>1 POL = 1,000 BJT tokens</strong></li>
                    <li>Example: 0.1 POL = 100 BJT = 100 × 10^18 base units</li>
                  </ul>
                </div>
                <div className="bg-white dark:bg-gray-800 p-2 rounded border border-gray-200 dark:border-gray-700">
                  <p className="font-semibold mb-1">🎮 How to Play:</p>
                  <ol className="list-decimal list-inside space-y-0.5 ml-2">
                    <li>Buy BJT tokens with POL at 1:1000 rate</li>
                    <li>Get LINK from <a href="https://faucets.chain.link/polygon-amoy" target="_blank" rel="noopener noreferrer" className="text-blue-600 hover:underline font-semibold">Chainlink Faucet</a></li>
                    <li>Create games with BJT tokens (minimum 10 BJT bet)</li>
                    <li>VRF uses your LINK for provably fair card draws</li>
                    <li>Win or lose BJT, then redeem back to POL anytime</li>
                  </ol>
                </div>
              </div>
            ) : (
              <div className="text-xs text-gray-700 dark:text-gray-300 space-y-2">
                <div className="bg-white dark:bg-gray-800 p-2 rounded border border-gray-200 dark:border-gray-700">
                  <p className="font-semibold mb-1">💱 Redeem to POL:</p>
                  <ol className="list-decimal list-inside space-y-0.5 ml-2">
                    <li>Enter BJT tokens to redeem (whole tokens, e.g., 100)</li>
                    <li>Receive POL at 1000:1 rate (1000 BJT = 1 POL)</li>
                    <li>POL sent directly to your wallet</li>
                    <li>Use POL for gas or buy more tokens later</li>
                  </ol>
                </div>
                <p className="text-xs italic text-gray-500 dark:text-gray-500">
                  Remember: BJT uses 18 decimals, so 100 BJT = 100 × 10^18 base units
                </p>
              </div>
            )}
          </div>
        </>
      )}
    </div>
  );
}
