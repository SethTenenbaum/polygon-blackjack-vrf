"use client";

import { useState, useEffect } from "react";
import { useAccount } from "wagmi";

// Admin wallet address (only this address can change RPC)
const ADMIN_ADDRESS = "0xC6d04Dd0433860b99D37C866Ff31853B45E02F1f";

// Popular RPC providers for Polygon Amoy
const RPC_PROVIDERS = [
  { name: "Alchemy", url: "https://polygon-amoy.g.alchemy.com/v2/N72iogGVN-7pd1OaxcDdh" },
  { name: "Infura", url: "https://polygon-amoy.infura.io/v3/12e85042b37a43bd9abb050061b90ada" },
  { name: "Polygon Public", url: "https://rpc-amoy.polygon.technology" },
  { name: "Custom", url: "" }, // User can enter their own
];

export function RpcSwitcher() {
  const { address, chain } = useAccount();
  const [isOpen, setIsOpen] = useState(false);
  const [customUrl, setCustomUrl] = useState("");
  const [currentRpc, setCurrentRpc] = useState("");

  // Check if current user is admin
  const isAdmin = address?.toLowerCase() === ADMIN_ADDRESS.toLowerCase();
  
  // Get expected chain ID from environment
  const EXPECTED_CHAIN_ID = parseInt(process.env.NEXT_PUBLIC_CHAIN_ID || "80002");

  // Get current RPC from env or local storage
  useEffect(() => {
    const savedRpc = localStorage.getItem("CUSTOM_RPC_URL");
    if (savedRpc) {
      setCurrentRpc(savedRpc);
    } else {
      setCurrentRpc(process.env.NEXT_PUBLIC_RPC_URL || "");
    }
  }, []);

  const handleSelectRpc = (url: string) => {
    if (url) {
      localStorage.setItem("CUSTOM_RPC_URL", url);
      setCurrentRpc(url);
      // Force page reload to apply new RPC
      window.location.reload();
    }
  };

  const handleCustomRpc = () => {
    if (customUrl.startsWith("http")) {
      handleSelectRpc(customUrl);
    }
  };

  const getCurrentProviderName = () => {
    const provider = RPC_PROVIDERS.find(p => currentRpc.includes(p.name.toLowerCase()) || currentRpc === p.url);
    return provider?.name || "Current";
  };

  // Don't show the component if not admin or if on Anvil (local network)
  if (!isAdmin || EXPECTED_CHAIN_ID === 31337) {
    return null;
  }

  return (
    <div className="mb-4">
      <button
        onClick={() => setIsOpen(!isOpen)}
        className="w-full p-3 bg-blue-50 dark:bg-blue-900/20 rounded-lg border border-blue-200 dark:border-blue-800 hover:bg-blue-100 dark:hover:bg-blue-900/30 transition-colors text-left"
      >
        <div className="flex justify-between items-center">
          <div>
            <p className="text-sm font-medium text-blue-700 dark:text-blue-300">
              🌐 RPC Provider: {getCurrentProviderName()}
            </p>
            <p className="text-xs text-gray-600 dark:text-gray-400 mt-1 truncate">
              {currentRpc || "Default"}
            </p>
          </div>
          <span className="text-blue-600 dark:text-blue-400">
            {isOpen ? "▼" : "▶"}
          </span>
        </div>
      </button>

      {isOpen && (
        <div className="mt-2 p-4 bg-white dark:bg-gray-800 rounded-lg border border-gray-200 dark:border-gray-700 space-y-3">
          <p className="text-sm font-semibold text-gray-700 dark:text-gray-300 mb-2">
            Select RPC Provider:
          </p>
          
          {RPC_PROVIDERS.filter(p => p.url).map((provider) => (
            <button
              key={provider.name}
              onClick={() => handleSelectRpc(provider.url)}
              className={`w-full p-2 text-left rounded-lg border transition-colors ${
                currentRpc === provider.url
                  ? "bg-blue-100 dark:bg-blue-900/30 border-blue-400 dark:border-blue-600"
                  : "bg-gray-50 dark:bg-gray-700 border-gray-200 dark:border-gray-600 hover:bg-gray-100 dark:hover:bg-gray-600"
              }`}
            >
              <div className="text-sm font-medium">
                {currentRpc === provider.url && "✓ "}
                {provider.name}
              </div>
              <div className="text-xs text-gray-500 dark:text-gray-400 truncate">
                {provider.url}
              </div>
            </button>
          ))}

          <div className="pt-2 border-t border-gray-200 dark:border-gray-700">
            <p className="text-sm font-medium text-gray-700 dark:text-gray-300 mb-2">
              Custom RPC URL:
            </p>
            <div className="flex gap-2">
              <input
                type="text"
                value={customUrl}
                onChange={(e) => setCustomUrl(e.target.value)}
                placeholder="https://your-rpc-url.com"
                className="flex-1 px-3 py-2 text-sm border rounded-lg dark:bg-gray-700 dark:border-gray-600"
              />
              <button
                onClick={handleCustomRpc}
                disabled={!customUrl.startsWith("http")}
                className={`px-4 py-2 text-sm rounded-lg transition-colors ${
                  customUrl.startsWith("http")
                    ? "bg-blue-500 hover:bg-blue-600 text-white"
                    : "bg-gray-300 dark:bg-gray-600 text-gray-500 dark:text-gray-400 cursor-not-allowed"
                }`}
              >
                Apply
              </button>
            </div>
            <p className="text-xs text-gray-500 dark:text-gray-400 mt-2">
              ⚠️ Page will reload after applying changes
            </p>
          </div>

          <div className="pt-2 border-t border-gray-200 dark:border-gray-700">
            <p className="text-xs text-gray-500 dark:text-gray-400">
              💡 <strong>Tip:</strong> If you're hitting rate limits, try switching to a different provider or get a free API key from:
            </p>
            <ul className="text-xs text-blue-600 dark:text-blue-400 mt-1 space-y-1">
              <li>• <a href="https://www.alchemy.com/" target="_blank" rel="noopener noreferrer" className="underline hover:text-blue-800">Alchemy</a> (300M compute units/month free)</li>
              <li>• <a href="https://www.infura.io/" target="_blank" rel="noopener noreferrer" className="underline hover:text-blue-800">Infura</a> (100k requests/day free)</li>
            </ul>
          </div>
        </div>
      )}
    </div>
  );
}
