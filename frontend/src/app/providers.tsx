"use client";

import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { type ReactNode, useState } from "react";
import { type State, WagmiProvider } from "wagmi";
import { getConfig } from "@/wagmi";

type Props = {
  children: ReactNode;
  initialState?: State;
};

export function Providers({ children, initialState }: Props) {
  const [config] = useState(() => getConfig());
  const [queryClient] = useState(() => new QueryClient({
    defaultOptions: {
      queries: {
        refetchOnWindowFocus: false, // CRITICAL: Prevent refetch storm on window focus
        refetchOnMount: false, // CRITICAL: Prevent refetch on every mount
        refetchOnReconnect: false, // CRITICAL: Prevent refetch on reconnect
        retry: 1, // Only retry once
        staleTime: 30000, // Cache for 30 seconds
      },
    },
  }));

  return (
    <WagmiProvider config={config} initialState={initialState}>
      <QueryClientProvider client={queryClient}>
        {children}
      </QueryClientProvider>
    </WagmiProvider>
  );
}
