# Polygon Blackjack

A fully on-chain blackjack game deployed on Polygon Amoy testnet. Uses Chainlink VRF for provably fair card randomness, an upgradeable proxy architecture, and a custom ERC20 token backed by POL.

## Live Demo

Frontend: [polygon-blackjack.vercel.app](https://polygon-blackjack.vercel.app)

## Architecture

### Smart Contracts (Foundry)

```
src/
├── GameUpgradeable.sol          # Main game logic (upgradeable proxy)
├── GameFactoryUpgradeable.sol   # Factory for creating and managing games
├── GameImplementation.sol       # Implementation contract
├── GameKeeperAutomation.sol     # Chainlink Keeper automation for dealer logic
├── GameToken.sol                # ERC20 game token (POL-backed, 1000 tokens per POL)
└── libraries/
    ├── CardLogic.sol            # Card dealing and deck management
    ├── DealerLogic.sol          # Dealer hand progression
    ├── VRFRequestLogic.sol      # Chainlink VRF request handling
    ├── VRFFulfillmentLogic.sol  # VRF response fulfillment
    ├── HandProgressionLogic.sol # Hit, stand, double, split, insurance
    ├── WinnerDeterminationLogic.sol
    └── ...
```

### Frontend (Next.js)

```
frontend/
├── src/
│   ├── components/
│   │   ├── GamePlay.tsx         # Main game UI
│   │   ├── PlayingCard.tsx      # Card rendering
│   │   ├── CreateGame.tsx       # Game creation flow
│   │   ├── BuyTokens.tsx        # Token purchase
│   │   ├── ConnectWallet.tsx    # Wallet connection
│   │   └── VRFStatusDisplay.tsx # VRF request status
│   ├── hooks/
│   │   ├── useGameTransaction.ts
│   │   └── useVRFStatus.ts
│   └── wagmi.ts                 # Wallet config
```

## How It Works

1. Player connects a MetaMask wallet and buys game tokens (1 POL = 1000 tokens)
2. A new game instance is deployed via the factory contract
3. Player places a bet and starts a hand
4. The contract requests randomness from Chainlink VRF to deal cards
5. Player actions (hit, stand, double down, split, insurance) trigger further VRF requests as needed
6. Chainlink Keepers automate the dealer hand after the player stands
7. Winner is determined on-chain and tokens are paid out

## Key Design Decisions

**Chainlink VRF V2.5** — All card randomness is verifiable on-chain. No pseudorandom shortcuts.

**Upgradeable Proxy Pattern** — Game logic can be upgraded without redeploying or migrating funds.

**Library Architecture** — Game logic is split across ~20 libraries to stay within the contract size limit (24KB).

**POL-backed Token** — GameToken has no initial supply. Every token in circulation is backed 1:1000 by POL, redeemable at any time.

**Chainlink Automation** — Dealer hand progression runs automatically via Keeper contracts, no manual triggering needed.

## Test Suite

20+ test files covering the full game lifecycle:

- `Game.t.sol` — Core game flow
- `VRFFailureRetry.t.sol` — VRF failure and retry handling
- `InsuranceDoubleDown.t.sol` — Insurance and double down logic
- `ConcurrentPlayers.t.sol` — Multiple simultaneous games
- `EmergencyWithdrawal.t.sol` — Emergency fund recovery
- `GameKeeperAutomation.t.sol` — Keeper automation
- `UpgradeScript.t.sol` — Proxy upgrade flow
- `LinkAccounting.t.sol` — LINK token accounting
- `GasComparison.t.sol` — Gas benchmarks

## Getting Started

### Prerequisites

- [Foundry](https://getfoundry.sh/)
- [Node.js 18+](https://nodejs.org/)
- MetaMask with Polygon Amoy testnet configured
- Alchemy or Infura RPC URL

### Smart Contracts

```bash
# Install dependencies
forge install

# Run tests
forge test

# Deploy (copy .env.example to .env and fill in values)
cp .env.example .env
forge script deployment-scripts/Deploy.s.sol --rpc-url $POLYGON_AMOY_RPC_URL --broadcast
```

### Frontend

```bash
cd frontend
npm install

# Copy template and fill in deployed contract addresses
cp .env.template .env.local

npm run dev
```

## Deployed Contracts (Polygon Amoy)

| Contract | Address |
|----------|---------|
| Factory Proxy | see `.env.example` |
| Game Token | see `.env.example` |
| VRF Coordinator | `0x343300b5d84D444B2ADc9116FEF1bED02BE49Cf2` |

## Tech Stack

- **Solidity ^0.8.30** — Smart contracts
- **Foundry** — Testing and deployment
- **Chainlink VRF V2.5** — Verifiable randomness
- **Chainlink Automation** — Keeper automation
- **OpenZeppelin** — Upgradeable proxy, ERC20, ReentrancyGuard
- **Next.js + TypeScript** — Frontend
- **wagmi + viem** — Wallet and contract interaction
- **Tailwind CSS** — Styling
