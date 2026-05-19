"use client";

import { useState, useEffect } from "react";
import { useAccount, useSwitchChain } from "wagmi";

export function NetworkStatus() {
  const { address, chain } = useAccount();
  const { switchChain } = useSwitchChain();

  // Track chain info also from window.ethereum so the UI can show network when wallet isn't connected via wagmi
  const [externalChainName, setExternalChainName] = useState<string | null>(null);
  const [externalChainId, setExternalChainId] = useState<number | null>(null);

  // Derive displayed chain info (prefer wagmi's chain when available)
  const displayedChainName = chain?.name ?? externalChainName ?? "Not connected";
  const displayedChainId = chain?.id ?? externalChainId ?? undefined;

  // Support both Polygon Amoy and local Anvil
  const EXPECTED_CHAIN_ID = parseInt(process.env.NEXT_PUBLIC_CHAIN_ID || "80002");
  const isCorrectNetwork = displayedChainId === EXPECTED_CHAIN_ID;
  
  const EXPECTED_NETWORK_NAME = EXPECTED_CHAIN_ID === 31337 ? "Anvil" : "Polygon Amoy";
  const EXPECTED_RPC_URL = EXPECTED_CHAIN_ID === 31337 ? "http://127.0.0.1:8545" : "https://rpc-amoy.polygon.technology";

  // Read chain from window.ethereum on mount and listen for changes
  useEffect(() => {
    const eth = (window as any).ethereum;
    if (!eth || !eth.request) return;

    const updateFromProvider = async () => {
      try {
        const hex = await eth.request({ method: "eth_chainId" });
        if (hex) {
          const id = Number.parseInt(hex as string, 16);
          setExternalChainId(id);
          if (id === 31337) setExternalChainName("Anvil");
          else if (id === 80002) setExternalChainName("Polygon Amoy");
          else if (id === 137) setExternalChainName("Polygon Mainnet");
          else if (id === 1) setExternalChainName("Ethereum Mainnet");
          else setExternalChainName(`Chain ${id}`);
        }
      } catch (e) {
        // ignore
      }
    };

    updateFromProvider();

    const handleChainChanged = (hex: string) => {
      const id = Number.parseInt(hex, 16);
      setExternalChainId(id);
      if (id === 31337) setExternalChainName("Anvil");
      else if (id === 80002) setExternalChainName("Polygon Amoy");
      else if (id === 137) setExternalChainName("Polygon Mainnet");
      else if (id === 1) setExternalChainName("Ethereum Mainnet");
      else setExternalChainName(`Chain ${id}`);
    };

    eth.on?.("chainChanged", handleChainChanged);
    return () => {
      eth.removeListener?.("chainChanged", handleChainChanged);
    };
  }, []);

  // Manual switch handler
  const handleSwitchToAmoy = async () => {
    const targetChainId = EXPECTED_CHAIN_ID;
    const chainIdHex = `0x${targetChainId.toString(16)}`;
    
    if (switchChain) {
      try {
        await switchChain({ chainId: targetChainId as any });
        return;
      } catch (e) {
        console.error("switchChain failed:", e);
      }
    }

    const eth = (window as any).ethereum;
    if (eth?.request) {
      try {
        await eth.request({ 
          method: "wallet_switchEthereumChain", 
          params: [{ chainId: chainIdHex }] 
        });
      } catch (switchError: any) {
        // If network doesn't exist, add it
        if (switchError.code === 4902 && EXPECTED_CHAIN_ID === 31337) {
          try {
            await eth.request({
              method: "wallet_addEthereumChain",
              params: [{
                chainId: chainIdHex,
                chainName: "Anvil",
                nativeCurrency: {
                  name: "Ethereum",
                  symbol: "ETH",
                  decimals: 18
                },
                rpcUrls: ["http://127.0.0.1:8545"],
                blockExplorerUrls: null
              }]
            });
          } catch (addError) {
            console.error("Failed to add network:", addError);
          }
        }
      }
    }
  };

  return (
    <>
      {/* Network Status Display - Always Visible at Top */}
      <div className={`mb-6 p-4 rounded-lg border ${
          isCorrectNetwork
            ? 'bg-green-50 dark:bg-green-900/20 border-green-200 dark:border-green-800'
            : 'bg-red-50 dark:bg-red-900/20 border-red-200 dark:border-red-800'
        }`}>
        <div className="flex items-center justify-between">
          <div>
            <p className={`text-sm font-medium ${
              isCorrectNetwork
                ? 'text-green-700 dark:text-green-300'
                : 'text-red-700 dark:text-red-300'
            }`}>
              {isCorrectNetwork ? '✅' : '❌'} Network: {displayedChainName}
              {address ? ` — Wallet: ${address.slice(0,6)}...${address.slice(-4)}` : ' — Wallet not connected'}
            </p>
            {typeof displayedChainId === 'number' && (
              <p className="text-xs text-gray-600 dark:text-gray-400 mt-1">
                Chain ID: {displayedChainId}
              </p>
            )}
          </div>
          
          {!isCorrectNetwork && address && (
            <button
              onClick={handleSwitchToAmoy}
              className="btn btn-warning btn-sm"
            >
              Switch to {EXPECTED_NETWORK_NAME}
            </button>
          )}
        </div>
      </div>

      {/* Wrong Network Warning Banner */}
      {!isCorrectNetwork && (
        <div className="mb-6 p-4 bg-yellow-50 dark:bg-yellow-900/20 rounded-lg border border-yellow-200 dark:border-yellow-800">
          <p className="text-sm text-yellow-700 dark:text-yellow-300 mb-2 font-semibold">
            ⚠️ Wrong Network! Please switch to {EXPECTED_NETWORK_NAME} to use this dApp.
          </p>
          <div className="text-xs text-gray-600 dark:text-gray-400 space-y-1">
            <p><strong>Network Name:</strong> {EXPECTED_NETWORK_NAME}</p>
            <p><strong>RPC URL:</strong> {EXPECTED_RPC_URL}</p>
            <p><strong>Chain ID:</strong> {EXPECTED_CHAIN_ID}</p>
            <p><strong>Currency Symbol:</strong> {EXPECTED_CHAIN_ID === 31337 ? "ETH" : "POL"}</p>
          </div>
          {!address && (
            <p className="mt-2 text-xs text-yellow-600 dark:text-yellow-400">
              👉 Connect your wallet first, then you can switch networks.
            </p>
          )}
        </div>
      )}
    </>
  );
}
