"use client";

import { useState, useEffect, useCallback, useMemo, memo } from "react";
import { useAccount, useReadContract } from "wagmi";
import { FACTORY_ABI, GAME_ABI } from "@/lib/abis";
import { GamePlay } from "./GamePlay";

const FACTORY_ADDRESS = process.env.NEXT_PUBLIC_FACTORY_ADDRESS as `0x${string}`;

// Shared state for game selection with callback support
let sharedSelectedGame: `0x${string}` | null = null;
let sharedSetSelectedGame: ((game: `0x${string}` | null) => void) | null = null;
let sharedStateListeners: Set<(game: `0x${string}` | null) => void> = new Set();

// Helper to notify all listeners
function notifyListeners(game: `0x${string}` | null) {
  sharedStateListeners.forEach(listener => listener(game));
}

export function PlayerGames() {
  const { address } = useAccount();
  const [selectedGame, setSelectedGame] = useState<`0x${string}` | null>(null);
  const [hasInitiallySelected, setHasInitiallySelected] = useState(false);
  const [currentPage, setCurrentPage] = useState(0);
  const GAMES_PER_PAGE = 5;

  // Wrapped setter that notifies listeners - use useCallback to maintain stable reference
  const setSelectedGameWithNotify = useCallback((game: `0x${string}` | null) => {
    
    setSelectedGame(game);
    sharedSelectedGame = game;
    
    notifyListeners(game);
  }, []);

  // Share state and expose globally for CreateGame to use
  // CRITICAL: Put in useEffect to prevent running on every render
  useEffect(() => {
    sharedSelectedGame = selectedGame;
    sharedSetSelectedGame = setSelectedGameWithNotify;
  }, [selectedGame, setSelectedGameWithNotify]);
  
  // Make setter available globally for CreateGame event watcher
  useEffect(() => {
    if (typeof window !== 'undefined') {
      (window as any).setSelectedGameGlobal = setSelectedGameWithNotify;
    }
    return () => {
      if (typeof window !== 'undefined') {
        delete (window as any).setSelectedGameGlobal;
      }
    };
  }, [setSelectedGameWithNotify]);

  const { data: playerGames, isLoading, refetch: refetchGames } = useReadContract({
    address: FACTORY_ADDRESS,
    abi: FACTORY_ABI,
    functionName: "getPlayerGames",
    args: address ? [address] : undefined,
    query: {
      enabled: !!address,
      // No polling - only refetch manually when games are created or finished
      refetchInterval: false,
      staleTime: Infinity,
    },
  });

  // Make refetch available globally for CreateGame to trigger after game creation
  useEffect(() => {
    if (typeof window !== 'undefined') {
      (window as any).refetchPlayerGames = refetchGames;
    }
    return () => {
      if (typeof window !== 'undefined') {
        delete (window as any).refetchPlayerGames;
      }
    };
  }, [refetchGames]);

  // Reverse the games array to show newest first, then paginate
  // Use useMemo to avoid creating new array reference on every render
  const reversedGames = useMemo(() => {
    return playerGames ? [...playerGames].reverse() : [];
  }, [playerGames]);
  
  const totalPages = Math.ceil(reversedGames.length / GAMES_PER_PAGE);
  const paginatedGames = reversedGames.slice(
    currentPage * GAMES_PER_PAGE,
    (currentPage + 1) * GAMES_PER_PAGE
  );

  // Auto-select first game when games load (only once, not after minimize)
  // Select the newest game (first in reversed array)
  useEffect(() => {
    if (!hasInitiallySelected && !selectedGame && reversedGames.length > 0) {
      setSelectedGameWithNotify(reversedGames[0] as `0x${string}`);
      setHasInitiallySelected(true);
    }
  }, [reversedGames, selectedGame, hasInitiallySelected, setSelectedGameWithNotify]);

  if (!address) {
    return (
      <div className="card">
        <h2 className="text-xl font-bold mb-2">🎮 Your Games</h2>
        <p className="text-sm text-gray-600 dark:text-gray-400">
          Connect your wallet to see your games
        </p>
      </div>
    );
  }

  if (isLoading) {
    return (
      <div className="card">
        <h2 className="text-xl font-bold mb-2">🎮 Your Games</h2>
        <p className="text-sm text-gray-600 dark:text-gray-400">Loading...</p>
      </div>
    );
  }

  if (!playerGames || playerGames.length === 0) {
    return (
      <div className="card">
        <h2 className="text-xl font-bold mb-2">🎮 Your Games</h2>
        <p className="text-sm text-gray-600 dark:text-gray-400">
          No games yet. Create one above!
        </p>
      </div>
    );
  }

  return (
    <div className="card">
      <h2 className="text-xl font-bold mb-4">🎮 Your Games ({playerGames.length})</h2>
      <div className="space-y-1">
        {paginatedGames.map((gameAddress) => (
          <GameListItem
            key={gameAddress}
            gameAddress={gameAddress as `0x${string}`}
            isSelected={selectedGame === gameAddress}
            onSelect={() => setSelectedGameWithNotify(gameAddress as `0x${string}`)}
          />
        ))}
      </div>
      {totalPages > 1 && (
        <div className="flex items-center justify-between mt-4 pt-4 border-t border-gray-200 dark:border-gray-700">
          <button
            onClick={() => setCurrentPage((prev) => Math.max(0, prev - 1))}
            disabled={currentPage === 0}
            className={`px-3 py-1 text-sm rounded ${
              currentPage === 0
                ? "bg-gray-200 dark:bg-gray-700 text-gray-400 cursor-not-allowed"
                : "bg-blue-500 text-white hover:bg-blue-600"
            }`}
          >
            ← Previous
          </button>
          <span className="text-sm text-gray-600 dark:text-gray-400">
            Page {currentPage + 1} of {totalPages}
          </span>
          <button
            onClick={() => setCurrentPage((prev) => Math.min(totalPages - 1, prev + 1))}
            disabled={currentPage === totalPages - 1}
            className={`px-3 py-1 text-sm rounded ${
              currentPage === totalPages - 1
                ? "bg-gray-200 dark:bg-gray-700 text-gray-400 cursor-not-allowed"
                : "bg-blue-500 text-white hover:bg-blue-600"
            }`}
          >
            Next →
          </button>
        </div>
      )}
    </div>
  );
}

// Component for displaying the selected game in main area
export function SelectedGameDisplay() {
  const { address } = useAccount();
  const [displayedGame, setDisplayedGame] = useState<`0x${string}` | null>(sharedSelectedGame);
  const [updateCounter, setUpdateCounter] = useState(0);

  // Subscribe to shared state changes
  useEffect(() => {
    
    const listener = (game: `0x${string}` | null) => {
      setDisplayedGame(game);
      setUpdateCounter(prev => prev + 1); // Force re-render
    };
    
    sharedStateListeners.add(listener);
    
    // Sync with current shared state on mount
    if (sharedSelectedGame !== displayedGame) {
      setDisplayedGame(sharedSelectedGame);
    }
    
    return () => {
      sharedStateListeners.delete(listener);
    };
  }, []); // Empty dependency array - only run once on mount

  const handleMinimize = () => {
    
    // Clear the selected game to minimize it to sidebar only
    if (sharedSetSelectedGame) {
      sharedSetSelectedGame(null);
    } else {
    }
  };


  if (!address || !displayedGame) {
    return (
      <div className="card h-full flex items-center justify-center min-h-[400px]">
        <p className="text-center text-gray-600 dark:text-gray-400">
          {!address ? "Connect your wallet to play" : "Select a game from the sidebar to view details"}
        </p>
      </div>
    );
  }

  if (!address || !displayedGame) {
    return (
      <div className="card h-full flex items-center justify-center min-h-[400px]">
        <p className="text-center text-gray-600 dark:text-gray-400">
          {!address ? "Connect your wallet to play" : "Select a game from the sidebar to view details"}
        </p>
      </div>
    );
  }

  return (
    <GamePlay 
      key={displayedGame} 
      gameAddress={displayedGame}
      onMinimize={handleMinimize}
    />
  );
}

// Game List Item Component - Compact single-line display
// Memoized to prevent unnecessary re-renders
const GameListItem = memo(function GameListItem({
  gameAddress,
  isSelected,
  onSelect,
}: {
  gameAddress: `0x${string}`;
  isSelected: boolean;
  onSelect: () => void;
}) {
  const { data: gameState } = useReadContract({
    address: gameAddress,
    abi: GAME_ABI,
    functionName: "state",
    query: {
      enabled: true,
      // DISABLED: No polling in list items - only manual refresh
      refetchInterval: false,
      staleTime: Infinity,
    },
  });

  const state = Number(gameState || 0);

  const stateLabels = ["Not Started", "Dealing", "Insurance", "Playing", "Dealer Turn", "Finished"];
  const stateColors = [
    "bg-gray-500",
    "bg-blue-500",
    "bg-purple-500",
    "bg-green-500",
    "bg-yellow-500",
    "bg-red-500"
  ];

  return (
    <div
      className={`flex items-center gap-2 px-3 py-2 rounded cursor-pointer transition-all ${
        isSelected
          ? "bg-blue-500 text-white"
          : "bg-gray-100 dark:bg-gray-700 hover:bg-gray-200 dark:hover:bg-gray-600"
      }`}
      onClick={onSelect}
    >
      <span className={`w-2 h-2 rounded-full flex-shrink-0 ${
        isSelected ? "bg-white" : stateColors[state] || "bg-gray-500"
      }`} />
      <span className="text-xs font-mono truncate flex-1">
        {gameAddress.slice(0, 8)}...{gameAddress.slice(-6)}
      </span>
      <span className="text-xs font-medium flex-shrink-0">
        {stateLabels[state] || "Unknown"}
      </span>
    </div>
  );
});
