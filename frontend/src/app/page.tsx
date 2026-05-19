"use client";

import { WalletDropdown } from "@/components/WalletDropdown";
import { BuyTokens } from "@/components/BuyTokens";
import { CreateGame } from "@/components/CreateGame";
import { PlayerGames, SelectedGameDisplay } from "@/components/PlayerGames";
import { RpcSwitcher } from "@/components/RpcSwitcher";

export default function Home() {
  return (
    <main className="min-h-screen p-8">
      <div className="max-w-7xl mx-auto">
        {/* Top Bar with Wallet - Fixed position */}
        <div className="fixed top-0 right-0 p-4 z-50">
          <WalletDropdown />
        </div>

        {/* Header */}
        <div className="mb-8">
          <h1 className="text-4xl font-bold mb-2">Blackjack on Polygon Amoy</h1>
          <p className="text-gray-600 dark:text-gray-400">
            Play blackjack with verifiable randomness on-chain
          </p>
        </div>

        {/* Main Content */}
        <div className="grid grid-cols-1 lg:grid-cols-3 gap-8">
          <div className="lg:col-span-1 space-y-6">
            <RpcSwitcher />
            <BuyTokens />
            <CreateGame />
            <PlayerGames />
          </div>
          <div className="lg:col-span-2">
            <SelectedGameDisplay />
          </div>
        </div>

        {/* Footer */}
        <div className="mt-12 pt-8 border-t border-gray-200 dark:border-gray-700">
          <div className="grid grid-cols-1 md:grid-cols-3 gap-4 text-sm text-gray-600 dark:text-gray-400">
            <div>
              <h3 className="font-semibold mb-2">How to Play</h3>
              <ol className="list-decimal list-inside space-y-1">
                <li>Connect your wallet</li>
                <li>Buy BJT tokens</li>
                <li>Create a game with your bet</li>
                <li>Hit or Stand to play</li>
                <li>Get paid instantly when you win!</li>
              </ol>
            </div>
            <div>
              <h3 className="font-semibold mb-2">Game Rules</h3>
              <ul className="space-y-1">
                <li>• Get closer to 21 than dealer</li>
                <li>• Aces count as 1 or 11</li>
                <li>• Face cards count as 10</li>
                <li>• Dealer stands on 17</li>
                <li>• Instant automated payouts</li>
              </ul>
            </div>
            <div>
              <h3 className="font-semibold mb-2">Payouts</h3>
              <ul className="space-y-1">
                <li>• Win: 2x your bet</li>
                <li>• Blackjack: 2.5x your bet</li>
                <li>• Push: Get bet back</li>
                <li>• Lose: Lose your bet</li>
                <li>• All payouts are instant!</li>
              </ul>
            </div>
          </div>
        </div>
      </div>
    </main>
  );
}
