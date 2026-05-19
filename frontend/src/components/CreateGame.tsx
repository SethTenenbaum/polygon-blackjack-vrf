"use client";

import { useState, useEffect } from "react";
import { useAccount, useReadContract, useBalance, useSwitchChain, useWatchContractEvent } from "wagmi";
import { parseEther, formatEther, formatUnits, parseUnits } from "viem";
import { FACTORY_ABI, GAME_TOKEN_ABI, LINK_TOKEN_ABI } from "@/lib/abis";
import { useGameTransaction } from "@/hooks/useGameTransaction";

const FACTORY_ADDRESS = process.env.NEXT_PUBLIC_FACTORY_ADDRESS as `0x${string}`;
const GAME_TOKEN_ADDRESS = process.env.NEXT_PUBLIC_GAME_TOKEN_ADDRESS as `0x${string}`;
const LINK_TOKEN_ADDRESS = process.env.NEXT_PUBLIC_LINK_TOKEN as `0x${string}`;
const EXPECTED_CHAIN_ID = parseInt(process.env.NEXT_PUBLIC_CHAIN_ID || "80002");

// Import the shared game selector from PlayerGames
declare global {
  var setSelectedGameGlobal: ((game: `0x${string}` | null) => void) | undefined;
}

export function CreateGame() {
  const { address, chain } = useAccount();
  const { switchChain } = useSwitchChain();
  const [betAmount, setBetAmount] = useState("");
  const [needsApproval, setNeedsApproval] = useState(true);
  const [showRpcSwitcher, setShowRpcSwitcher] = useState(false);
  const [customRpcUrl, setCustomRpcUrl] = useState("");
  
  const isCorrectNetwork = chain?.id === EXPECTED_CHAIN_ID;

  // DEBUG: Log everything

  // Auto-switch to correct network if on wrong network
  useEffect(() => {
    if (address && !isCorrectNetwork && switchChain) {
      try {
        switchChain({ chainId: EXPECTED_CHAIN_ID as 31337 | 80002 });
      } catch (error) {
      }
    }
  }, [address, isCorrectNetwork, switchChain]);
  
  const { data: liquidity, refetch: refetchLiquidity } = useReadContract({
    address: FACTORY_ADDRESS,
    abi: FACTORY_ABI,
    functionName: "totalLiquidity",
    chainId: EXPECTED_CHAIN_ID as 31337 | 80002,
  });

  const { data: balance } = useBalance({
    address: address,
    chainId: EXPECTED_CHAIN_ID as 31337 | 80002,
  });

  const { data: tokenBalance, refetch: refetchTokenBalance, isError: tokenBalanceError, error: tokenError } = useReadContract({
    address: GAME_TOKEN_ADDRESS,
    abi: GAME_TOKEN_ABI,
    functionName: "balanceOf",
    args: address ? [address] : undefined,
    chainId: EXPECTED_CHAIN_ID as 31337 | 80002,
  });

  // DEBUG: Log token balance query result

  const { data: linkBalance, isError: linkBalanceError, error: linkError } = useReadContract({
    address: LINK_TOKEN_ADDRESS,
    abi: LINK_TOKEN_ABI,
    functionName: "balanceOf",
    args: address ? [address] : undefined,
    chainId: EXPECTED_CHAIN_ID as 31337 | 80002,
  });


  // Debug: Log balance data
  useEffect(() => {
    if (tokenBalance) {
    }
    if (linkBalance) {
    }
  }, [tokenBalance, linkBalance, balance, chain, address, isCorrectNetwork]);

  const { data: allowance, refetch: refetchAllowance, isError: allowanceError, error: allowanceErrorDetails } = useReadContract({
    address: GAME_TOKEN_ADDRESS,
    abi: GAME_TOKEN_ABI,
    functionName: "allowance",
    args: address ? [address, FACTORY_ADDRESS] : undefined,
    chainId: EXPECTED_CHAIN_ID as 31337 | 80002,
  });

  const { data: linkAllowance, refetch: refetchLinkAllowance, isError: linkAllowanceError, error: linkAllowanceErrorDetails } = useReadContract({
    address: LINK_TOKEN_ADDRESS,
    abi: LINK_TOKEN_ABI,
    functionName: "allowance",
    args: address ? [address, FACTORY_ADDRESS] : undefined,
    chainId: EXPECTED_CHAIN_ID as 31337 | 80002,
  });

  // DEBUG: Log allowance data

  const { data: liquidityStats, isError: liquidityStatsError, error: liquidityStatsErrorDetails, refetch: refetchLiquidityStats } = useReadContract({
    address: FACTORY_ADDRESS,
    abi: FACTORY_ABI,
    functionName: "getLiquidityStats",
    chainId: EXPECTED_CHAIN_ID as 31337 | 80002,
    query: {
      refetchInterval: false, // No polling - manual refresh button available
    },
  });

  // Extract min/max bet from liquidity stats
  // Returns: (total, available, locked, maxBet, minBet, capacityAt90Percent)
  const statsArray = liquidityStats as bigint[] | undefined;
  const minBet = statsArray?.[4];
  const maxBet = statsArray?.[3];

  // Debug logging
  if (liquidityStatsError) {
  }
  if (statsArray) {
  }

  // Watch for GameFinalized events from the factory to update max bet when games finish
  useWatchContractEvent({
    address: FACTORY_ADDRESS,
    abi: FACTORY_ABI,
    eventName: "GameFinalized",
    onLogs(logs) {
      refetchLiquidityStats();
      refetchLiquidity();
      refetchTokenBalance();
    },
  });

  // Set default bet amount to maxBet when it's loaded or when maxBet changes
  useEffect(() => {
    if (maxBet) {
      const maxBetFormatted = formatUnits(maxBet, 18);
      // Always update to the current maxBet when it changes
      setBetAmount(maxBetFormatted);
    }
  }, [maxBet]);

  // Game transaction handler
  const gameTransaction = useGameTransaction({
    gameAddress: FACTORY_ADDRESS,
    abi: FACTORY_ABI,
    onSuccess: async (receipt) => {
      
      refetchLiquidity();
      refetchTokenBalance();
      refetchLiquidityStats(); // Refetch max bet after game creation (useEffect will update bet amount)
      
      // Extract the new game address from the GameCreated event in the transaction receipt
      if (receipt && receipt.logs) {
        
        // Log all logs for debugging
        receipt.logs.forEach((log: any, index: number) => {
        });
        
        // GameCreated event signature: keccak256("GameCreated(address,address,uint256)")
        const GAME_CREATED_SIGNATURE = "0x4b2ba94c95bc6be4e5469685dbb6d3f2f1ba2a3e84c7e2a1f5e7d8c7f6b3e9a8"; // This will need to be calculated
        
        // Find the GameCreated event log from the factory contract
        const gameCreatedLog = receipt.logs.find((log: any) => {
          const addressMatch = log.address.toLowerCase() === FACTORY_ADDRESS.toLowerCase();
          // For now, just match by address and check if data is not empty
          const hasData = log.data && log.data.length > 2;
          return addressMatch && hasData;
        });
        
        if (gameCreatedLog) {
          
          // Event GameCreated(address indexed player, address gameAddress, uint256 bet)
          // topics[0] = event signature
          // topics[1] = player (indexed)
          // data = gameAddress (32 bytes padded) + bet (32 bytes)
          
          if (gameCreatedLog.data && gameCreatedLog.data.length >= 130) {
            // Data format: 0x + 64 hex chars (32 bytes for address, padded) + 64 hex chars (32 bytes for bet)
            // Extract address: skip 0x (2) + skip padding (24 hex chars = 12 bytes) = start at position 26
            // Take next 40 hex chars (20 bytes = address)
            const gameAddress = `0x${gameCreatedLog.data.slice(26, 66)}` as `0x${string}`;
            
            // Verify global setter is available
            
            // Auto-select the newly created game
            if (typeof window !== 'undefined' && (window as any).setSelectedGameGlobal) {
              (window as any).setSelectedGameGlobal(gameAddress);
            } else {
            }
          } else {
          }
        } else {
        }
      } else {
      }
    },
  });

  // Token approval handler
  const approvalTransaction = useGameTransaction({
    gameAddress: GAME_TOKEN_ADDRESS,
    abi: GAME_TOKEN_ABI,
    onSuccess: () => {
      refetchAllowance();
      setNeedsApproval(false);
    },
  });

  // LINK approval handler
  const linkApprovalTransaction = useGameTransaction({
    gameAddress: LINK_TOKEN_ADDRESS,
    abi: LINK_TOKEN_ABI,
    onSuccess: () => {
      refetchLinkAllowance();
    },
  });

  const handleApprove = async () => {
    if (!address) return;
    
    try {
      // Approve a large amount (1 billion tokens)
      const approvalAmount = parseUnits("1000000000", 18);
      await approvalTransaction.execute("approve", [FACTORY_ADDRESS, approvalAmount]);
    } catch (error) {
    }
  };

  const handleApproveLINK = async () => {
    if (!address) return;
    
    try {
      // Approve a large amount (1000 LINK tokens)
      const approvalAmount = parseUnits("1000", 18);
      await linkApprovalTransaction.execute("approve", [FACTORY_ADDRESS, approvalAmount]);
    } catch (error) {
    }
  };

  const handleCreateGame = async () => {
    if (!address) return;
    
    try {
      const betInTokens = parseUnits(betAmount, 18);
      
      // Validation is now handled by button disabled state
      // These are just safety checks
      if (minBet && betInTokens < minBet) {
        return;
      }
      if (maxBet && betInTokens > maxBet) {
        return;
      }
      
      await gameTransaction.execute("createGame", [betInTokens]);
    } catch (error) {
    }
  };
  
  // Watch for successful game creation and auto-select the new game
  const { data: playerGamesForAutoSelect } = useReadContract({
    address: FACTORY_ADDRESS,
    abi: FACTORY_ABI,
    functionName: "getPlayerGames",
    args: address ? [address] : undefined,
    query: {
      enabled: !!gameTransaction.hash && !gameTransaction.isPending, // Only query after tx completes
    },
  });
  
  // Auto-select the newest game when player games update after transaction
  useEffect(() => {
    if (playerGamesForAutoSelect && playerGamesForAutoSelect.length > 0 && gameTransaction.hash && !gameTransaction.isPending) {
      // The newest game is the last one in the array
      const newestGame = playerGamesForAutoSelect[playerGamesForAutoSelect.length - 1] as `0x${string}`;
      
      if (typeof window !== 'undefined' && (window as any).setSelectedGameGlobal) {
        (window as any).setSelectedGameGlobal(newestGame);
      } else {
      }
    }
  }, [playerGamesForAutoSelect, gameTransaction.hash, gameTransaction.isPending]);

  // Check if user has enough allowance
  const betAmountBigInt = betAmount ? parseUnits(betAmount, 18) : BigInt(0);
  const linkFeeAmount = parseUnits("0.005", 18); // 0.005 LINK per game (updated for Polygon Amoy costs)
  const hasEnoughAllowance = !!(allowance && allowance >= betAmountBigInt);
  const hasEnoughLinkAllowance = !!(linkAllowance && linkAllowance >= linkFeeAmount);
  const hasEnoughTokens = !!(tokenBalance && tokenBalance >= betAmountBigInt);
  const hasLinkTokens = !!(linkBalance && linkBalance >= linkFeeAmount);

  // DEBUG: Log all checks

  return (
    <div className="card">
      <div className="flex items-center justify-between mb-4">
        <h2 className="text-2xl font-bold">🎮 Create New Game</h2>
      </div>
      
      {!address ? (
        /* NOT CONNECTED - Show message */
        <div className="text-center py-12">
          <p className="text-gray-500 dark:text-gray-400 mb-4">
            Please connect your wallet to create a game
          </p>
        </div>
      ) : (
        /* CONNECTED - Show game creation form */
        <>
      {/* Network Status Display */}
      {address && (
        <div className={`mb-4 p-3 rounded-lg border ${
          isCorrectNetwork 
            ? 'bg-green-50 dark:bg-green-900/20 border-green-200 dark:border-green-800' 
            : 'bg-red-50 dark:bg-red-900/20 border-red-200 dark:border-red-800'
        }`}>
          <p className={`text-sm font-medium ${
            isCorrectNetwork 
              ? 'text-green-700 dark:text-green-300' 
              : 'text-red-700 dark:text-red-300'
          }`}>
            {isCorrectNetwork ? '✅' : '❌'} Connected to: {chain?.name || 'Unknown Network'}
          </p>
          {chain?.id && (
            <p className="text-xs text-gray-600 dark:text-gray-400 mt-1">
              Chain ID: {chain.id}
            </p>
          )}
        </div>
      )}
      
      {!isCorrectNetwork && address && (
        <div className="mb-4 p-3 bg-yellow-50 dark:bg-yellow-900/20 rounded-lg border border-yellow-200 dark:border-yellow-800">
          <p className="text-sm text-yellow-700 dark:text-yellow-300 mb-2">
            ⚠️ Wrong Network! Please switch to {EXPECTED_CHAIN_ID === 31337 ? "Anvil" : "Polygon Amoy"}.
          </p>
          <div className="text-sm text-gray-600 dark:text-gray-400 mb-2">
            <p>Network Name: {EXPECTED_CHAIN_ID === 31337 ? "Anvil" : "Polygon Amoy"}</p>
            <p>RPC URL: {EXPECTED_CHAIN_ID === 31337 ? "http://127.0.0.1:8545" : "https://rpc-amoy.polygon.technology"}</p>
            <p>Chain ID: {EXPECTED_CHAIN_ID}</p>
            <p>Currency Symbol: {EXPECTED_CHAIN_ID === 31337 ? "ETH" : "POL"}</p>
          </div>
          <button
            onClick={() => switchChain && switchChain({ chainId: EXPECTED_CHAIN_ID as 31337 | 80002 })}
            className="btn btn-warning btn-sm w-full"
          >
            Switch to {EXPECTED_CHAIN_ID === 31337 ? "Anvil" : "Polygon Amoy"}
          </button>
        </div>
      )}
      
      <div className="mb-4">
        <label className="block text-sm font-medium mb-2">
          Bet Amount (BJT Tokens)
        </label>
        <div className="flex gap-2">
          <input
            type="number"
            value={betAmount}
            onChange={(e) => {
              const value = e.target.value;
              setBetAmount(value);
              // Show warning if exceeds max
              if (maxBet && value) {
                try {
                  const betInTokens = parseUnits(value, 18);
                  if (betInTokens > maxBet) {
                  }
                } catch (err) {
                  // Ignore parse errors during typing
                }
              }
            }}
            step="10"
            min={minBet ? formatUnits(minBet, 18) : "10"}
            max={maxBet ? formatUnits(maxBet, 18) : undefined}
            className={`flex-1 px-4 py-2 border rounded-lg dark:bg-gray-700 dark:border-gray-600 ${
              maxBet && betAmount && parseUnits(betAmount || "0", 18) > maxBet
                ? "border-red-500 dark:border-red-500"
                : ""
            }`}
            placeholder={maxBet ? formatUnits(maxBet, 18) : "Enter bet amount"}
          />
          <button
            onClick={() => {
              refetchLiquidityStats();
              refetchLiquidity();
            }}
            className="px-3 py-2 bg-blue-500 hover:bg-blue-600 text-white rounded-lg transition-colors text-sm"
            title="Refresh liquidity and bet limits"
          >
            🔄
          </button>
        </div>
        <div className="mt-2 flex justify-between text-xs text-gray-600 dark:text-gray-400">
          <span>
            Min: {minBet ? formatUnits(minBet, 18) : "..."} BJT
          </span>
          <span>
            Max: {maxBet ? formatUnits(maxBet, 18) : "..."} BJT
          </span>
        </div>
        {maxBet && betAmount && parseUnits(betAmount || "0", 18) > maxBet && (
          <p className="mt-2 text-xs text-red-600 dark:text-red-400">
            ⚠️ Bet amount exceeds maximum of {formatUnits(maxBet, 18)} BJT
          </p>
        )}
        {maxBet && minBet && maxBet < minBet && (
          <p className="mt-2 text-xs text-red-600 dark:text-red-400">
            ⚠️ Factory needs more liquidity! Max bet ({formatUnits(maxBet, 18)} BJT) is below minimum ({formatUnits(minBet, 18)} BJT)
          </p>
        )}
      </div>

      {!hasEnoughTokens ? (
        <div className="mb-4 p-3 bg-red-50 dark:bg-red-900/20 rounded-lg border border-red-200 dark:border-red-800">
          <p className="text-sm text-red-700 dark:text-red-300">
            ⚠️ Insufficient BJT tokens. Buy tokens first!
          </p>
        </div>
      ) : null}

      {!hasLinkTokens ? (
        <div className="mb-4 p-3 bg-orange-50 dark:bg-orange-900/20 rounded-lg border border-orange-200 dark:border-orange-800">
          <p className="text-sm text-orange-700 dark:text-orange-300">
            ⚠️ You need LINK tokens for game turns! Get from{" "}
            <a 
              href="https://faucets.chain.link/polygon-amoy" 
              target="_blank" 
              rel="noopener noreferrer"
              className="font-bold underline hover:text-orange-900"
            >
              Chainlink Faucet
            </a>
          </p>
        </div>
      ) : null}

      {!hasEnoughAllowance && hasEnoughTokens && isCorrectNetwork && (
        <>
          <button
            onClick={handleApprove}
            disabled={!address || approvalTransaction.isPending}
            className={`btn w-full mb-2 ${
              !address || approvalTransaction.isPending ? "btn-disabled" : "btn-warning"
            }`}
          >
            {approvalTransaction.isPending ? "Approving..." : "🔓 Approve BJT Tokens (Step 1)"}
          </button>
          <p className="mb-4 text-xs text-gray-600 dark:text-gray-400 text-center">
            First approve the factory to spend your BJT tokens
          </p>
        </>
      )}

      {hasEnoughAllowance && !hasEnoughLinkAllowance && hasLinkTokens && isCorrectNetwork && (
        <>
          <button
            onClick={handleApproveLINK}
            disabled={!address || linkApprovalTransaction.isPending}
            className={`btn w-full mb-2 ${
              !address || linkApprovalTransaction.isPending ? "btn-disabled" : "btn-warning"
            }`}
          >
            {linkApprovalTransaction.isPending ? "Approving..." : "🔗 Approve LINK Tokens (Step 2)"}
          </button>
          <p className="mb-4 text-xs text-gray-600 dark:text-gray-400 text-center">
            Approve the factory to spend LINK for randomness
          </p>
        </>
      )}

      <button
        onClick={handleCreateGame}
        disabled={
          !address || 
          !isCorrectNetwork || 
          !hasEnoughAllowance || 
          !hasEnoughLinkAllowance || 
          !hasEnoughTokens || 
          !hasLinkTokens || 
          gameTransaction.isPending ||
          !betAmount ||
          (maxBet && betAmount ? parseUnits(betAmount, 18) > maxBet : false) ||
          (minBet && betAmount ? parseUnits(betAmount, 18) < minBet : false)
        }
        className={`btn w-full ${
          !address || 
          !isCorrectNetwork || 
          !hasEnoughAllowance || 
          !hasEnoughLinkAllowance || 
          !hasEnoughTokens || 
          !hasLinkTokens || 
          gameTransaction.isPending ||
          !betAmount ||
          (maxBet && betAmount ? parseUnits(betAmount, 18) > maxBet : false) ||
          (minBet && betAmount ? parseUnits(betAmount, 18) < minBet : false)
            ? "btn-disabled"
            : "btn-primary"
        }`}
      >
        {!isCorrectNetwork ? "⚠️ Wrong Network" : gameTransaction.isPending ? "Creating Game..." : "🎲 Create Game"}
      </button>

      {gameTransaction.hash && (
        <p className="mt-4 text-green-600 dark:text-green-400 break-all">
          Game created! Transaction: {gameTransaction.hash}
        </p>
      )}

      {(gameTransaction.error || approvalTransaction.error || linkApprovalTransaction.error) && (
        <p className="mt-4 text-red-600 dark:text-red-400">
          Error: {gameTransaction.error?.message || approvalTransaction.error?.message || linkApprovalTransaction.error?.message}
        </p>
      )}
        </>
      )}
    </div>
  );
}
