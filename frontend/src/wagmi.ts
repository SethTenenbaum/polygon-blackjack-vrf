import { http, cookieStorage, createConfig, createStorage } from "wagmi";
import { polygonAmoy } from "wagmi/chains";
import { metaMask } from "wagmi/connectors";
import { defineChain } from "viem";

// Define local Anvil chain
const anvil = defineChain({
  id: 31337,
  name: "Anvil",
  nativeCurrency: {
    decimals: 18,
    name: "Ether",
    symbol: "ETH",
  },
  rpcUrls: {
    default: {
      http: ["http://127.0.0.1:8545"],
    },
  },
  blockExplorers: {
    default: { name: "Anvil", url: "" },
  },
});

export function getConfig() {
  // Check for custom RPC URL in localStorage (client-side only)
  const customRpc = typeof window !== 'undefined' 
    ? localStorage.getItem("CUSTOM_RPC_URL") 
    : null;
  
  const chainId = parseInt(process.env.NEXT_PUBLIC_CHAIN_ID || "80002");
  
  // Set RPC URLs based on chain ID - ALWAYS hardcode Anvil to localhost
  const anvilRpcUrl = "http://127.0.0.1:8545";
  const amoyRpcUrl = customRpc || process.env.NEXT_PUBLIC_RPC_URL || "https://polygon-amoy.g.alchemy.com/v2/N72iogGVN-7pd1OaxcDdh";
  
  // Determine which chains to support based on environment
  const chains = chainId === 31337 ? [anvil, polygonAmoy] as const : [polygonAmoy, anvil] as const;
  const transports = {
    [anvil.id]: http(anvilRpcUrl),
    [polygonAmoy.id]: http(amoyRpcUrl),
  };
  
  return createConfig({
    chains: chains as any,
    connectors: [
      metaMask({
        dappMetadata: {
          name: chainId === 31337 ? "Blackjack on Anvil" : "Blackjack on Polygon Amoy",
        },
        enableAnalytics: false,
      }),
    ],
    storage: createStorage({
      storage: cookieStorage,
    }),
    ssr: true,
    transports,
  });
}

declare module "wagmi" {
  interface Register {
    config: ReturnType<typeof getConfig>;
  }
}
