# Polygon Blackjack

A fully on-chain blackjack game deployed on Polygon Amoy testnet. Card randomness is verifiable on-chain via Chainlink VRF. The frontend is built in Next.js and interacts with the contracts directly from the browser using wagmi and viem.

## Live Demo

[polygon-blackjack.vercel.app](https://polygon-blackjack.vercel.app)

## How It Works

Players connect a MetaMask wallet, buy game tokens with POL, and play blackjack against a dealer whose actions are automated by Chainlink Keepers. Every hand of cards is dealt using randomness from Chainlink VRF V2.5. The randomness request and fulfillment are recorded on-chain so the outcome is independently verifiable.

## Contract Architecture

The system has three main pieces: a factory, individual game contracts, and a token.

**Factory** is a UUPS upgradeable proxy that owns the Chainlink VRF subscription and holds the LINK tokens needed to pay for randomness. When a player starts a game, the factory deploys a new game contract using the minimal proxy clone pattern (EIP-1167), which is a cheap copy of a master implementation that delegates all logic to it. Deploying a new game costs very little gas. Individual game contracts are not upgradeable themselves and exist only for the duration of a game.

Because individual game clones can't hold a VRF subscription directly, they route all randomness requests through the factory. The factory holds the subscription, makes the VRF request to Chainlink on the game's behalf, and forwards the random words back when Chainlink responds. This keeps subscription management centralized while allowing any number of concurrent games.

**Game contracts** handle the full blackjack ruleset: hit, stand, double down, split, insurance, and surrender. Each player action that requires new cards triggers a VRF request. The game logic is split across roughly 20 Solidity libraries to stay within the 24KB contract size limit imposed by the EVM. Once a player stands, a Chainlink Keeper picks up the dealer hand and completes it automatically without any manual transaction.

**GameToken** is an ERC20 token backed by POL at a fixed rate of 1000 tokens per POL. There is no initial supply. Every token in circulation was minted by someone depositing POL. Tokens can be redeemed for POL at the same rate at any time with no fees, so the contract always holds enough POL to cover all outstanding tokens.

## Test Suite

The test suite covers the full game lifecycle including edge cases:

- Core game flow and hand progression
- VRF failure and retry handling
- Concurrent players running simultaneous games
- Insurance and double down combinations
- Emergency fund withdrawal
- Chainlink Keeper automation
- Proxy upgrade flow
- LINK token accounting
- Gas benchmarks across different action types

## Getting Started

### Smart Contracts

Requires [Foundry](https://getfoundry.sh/).

```bash
forge install
forge test
```

To deploy, copy `.env.example` to `.env`, fill in your RPC URL, private key, and Chainlink config, then run the deployment scripts in `deployment-scripts/`.

### Frontend

```bash
cd frontend
npm install
cp .env.template .env.local
npm run dev
```

## Tech Stack

- Solidity + Foundry
- Chainlink VRF V2.5
- Chainlink Automation
- OpenZeppelin (UUPS proxy, ERC20, ReentrancyGuard, EIP-1167 clones)
- Next.js + TypeScript
- wagmi + viem
- Tailwind CSS
