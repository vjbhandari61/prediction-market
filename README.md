# Prediction Market

A decentralized binary prediction market built on Solidity. Users trade YES/NO shares on the outcome of any question using an on-chain Constant Product Market Maker (CPMM). The market is permissionless for trading and trustless for settlement — anyone can verify all logic on-chain.

---

## Problem Statement

Prediction markets allow people to express probabilistic beliefs about future events by putting money behind their opinions. When properly incentivised, they produce some of the most accurate forecasts available.

The problems with existing prediction markets:

- **Centralized settlement** — a trusted operator decides the outcome, creating a single point of failure and manipulation risk.
- **Custodial funds** — collateral sits in off-chain or semi-centralized systems.
- **Opaque pricing** — price discovery happens in black boxes.
- **No refund path** — if a market goes stale (host disappears, event doesn't resolve), funds can be locked forever.

This project solves these by:
- Encoding all market logic in immutable smart contracts
- Using a CPMM so prices are fully deterministic and on-chain
- Giving traders an automatic refund path when a market expires without resolution
- Isolating fees from collateral so the host can never accidentally drain the prize pool

---

## Architecture

```
PredictionMarketFactory   (Factory.sol)
│
│  createMarket(...)
│  ──────────────►  PredictionMarket   (Core.sol)
│                   ┌────────────────────────┐
│                   │  yesPool / noPool      │
│                   │  CPMM: x * y = k       │
│                   │  status: OPEN          │
│                   │         RESOLVED       │
│                   │         EXPIRED        │
│                   └────────────────────────┘
│
└── registry: _allMarkets[], isMarket, marketCount
```

### `Factory.sol` — Market Registry and Deployment

The factory is the single entry point for creating markets. Responsibilities:

- **Deploy** a fresh `PredictionMarket` for every call to `createMarket`.
- **Seed** — pulls `2 × initialLiquidity` from the host and forwards it to the new contract. The host receives equal YES and NO shares, bootstrapping the AMM at a 50/50 price.
- **Registry** — maintains `_allMarkets` (paginated via `getMarkets`), per-host lists, and an `isMarket` whitelist for integrators to verify a contract is legitimate.
- **Protocol config** — `protocolAdmin` can update the treasury address and protocol fee (capped at 30% of the market fee, stored for future use).

Why a factory and not a single monolithic contract? Each market is independent — isolated collateral, isolated state. Deploying separate contracts limits blast radius: a bug in one market cannot drain another.

### `Core.sol` — Market Logic

Each `PredictionMarket` is an independent contract. Its lifecycle has three phases:

| Phase | Entry | Exit |
|---|---|---|
| `OPEN` | deployment | host calls `resolve()` or deadline passes |
| `RESOLVED` | `resolve()` | — (terminal) |
| `EXPIRED` | first `claimRefund()` after deadline | — (terminal) |

#### CPMM Pricing (`x * y = k`)

The market maintains two virtual pools: `yesPool` and `noPool`.

```
k = yesPool * noPool  (constant product invariant)

Buying YES with amount A (after fee):
  newNoPool  = noPool + A
  newYesPool = k / newNoPool
  sharesOut  = yesPool - newYesPool

yesPrice = noPool  / (yesPool + noPool)   → scaled to 1e18
noPrice  = yesPool / (yesPool + noPool)   → scaled to 1e18
```

**Why CPMM?** It requires zero order book infrastructure, provides continuous liquidity, and prices are always bounded `(0, 1)` with `yesPrice + noPrice = 1`. The formula is battle-tested (Uniswap v2 AMM). Starting both pools equal means prices start at 0.5 — no initial bias.

**Integer division note:** `k / newPool` floors, so `k_after ≤ k_before` by at most 1 ULP. The pool rounds in favour of itself (not the trader), which is correct behaviour.

#### `resolvedPot` Snapshot (solvency invariant)

When the host calls `resolve()`, the contract records:

```solidity
resolvedPot = balanceOf(address(this)) - accruedFees;
```

Every subsequent `claimReward()` divides against this **fixed** snapshot:

```
payout = (userWinningShares / totalWinningShares) × resolvedPot
```

**Why snapshot?** If we used a live `balanceOf`, each successful claim would shrink the denominator, underpaying later claimants and permanently stranding the difference. With a snapshot, the sum of all payouts equals `resolvedPot` exactly (±1 wei rounding dust per claimer), regardless of claim order.

#### Fee Isolation

Fees are tracked separately in `accruedFees` and always excluded from `resolvedPot` and from refund calculations. The host can call `withdrawFees()` at any time — including after resolution — without affecting the winner pot. This is enforced by the snapshot: `resolvedPot = balance - accruedFees` captures the fee-free collateral.

#### Lazy Expiry

There is no `expire()` function. The first trader to call `claimRefund()` after the deadline pays the gas to flip `OPEN → EXPIRED`. This avoids the need for keepers or cron jobs and ensures the state transition only happens when someone actually needs it.

#### Security

- **`ReentrancyGuard`** on all state-changing external functions — prevents reentrant token callbacks from exploiting mid-execution state.
- **`SafeERC20`** — handles non-standard ERC20 tokens that return `false` instead of reverting.
- **`hasClaimed` flag** — shared across `claimReward` and `claimRefund`, so the same address can never collect twice regardless of path.
- **Slippage guard** — `buyShares` takes a `minSharesOut` parameter; the transaction reverts if the AMM gives fewer shares than the caller's minimum.
- **Input validation** in both constructor and `createMarket` with custom errors.

---

## File Structure

```
src/
  Core.sol          # PredictionMarket — per-market AMM + lifecycle logic
  Factory.sol       # PredictionMarketFactory — deployment + registry
  mocks/
    Token.sol       # Mock USDC (6 decimals) for local use

script/
  Deploy.s.sol      # Foundry deployment script for PredictionMarketFactory

test/
  Core.t.sol        # Full test suite (unit, integration, fuzz)

lib/
  forge-std/              # Foundry standard library
  openzeppelin-contracts/ # OZ v5 (ERC20, SafeERC20, ReentrancyGuard)

foundry.toml        # Foundry project config
.env.example        # Required environment variables (copy to .env)
.github/workflows/
  test.yml          # CI: fmt check, build, test
```

---

## Prerequisites

Install [Foundry](https://getfoundry.sh):

```bash
curl -L https://foundry.paradigm.xyz | bash
foundryup
```

Verify:

```bash
forge --version
```

---

## Installation

Clone the repo and pull submodule dependencies:

```bash
git clone <repo-url>
cd prediction-market
git submodule update --init --recursive
```

---

## Build

```bash
forge build
```

To also print contract sizes (useful for checking against the 24 KB EVM limit):

```bash
forge build --sizes
```

---

## Testing

Run the full test suite with verbose output:

```bash
forge test -vvv
```

Run only unit tests (excludes fuzz):

```bash
forge test --match-test "^test_" -vvv
```

Run only fuzz tests:

```bash
forge test --match-test "^testFuzz_" -vvv
```

Run a single test by name:

```bash
forge test --match-test test_claimReward_solvency_allWinnersCanClaim -vvv
```

Increase fuzz runs (default is 256):

```bash
forge test --fuzz-runs 10000 -vvv
```

### What the tests cover

| Area | Tests |
|---|---|
| Factory initial state | admin, treasury, fee, market count |
| Market creation | event emission, LP shares, validation reverts |
| Market registry | pagination, offset bounds, host lookup |
| Factory admin | access control, fee/treasury updates |
| Market initial state | pool sizes, prices, status |
| `buyShares` | price movement, CPMM invariant, fee accrual, deposit tracking, slippage, deadline, min-bet |
| `resolve` | status transition, pot snapshot, event, access control, deadline |
| `claimReward` | winner payout, loser rejection, proportionality, double-claim prevention, claim-order independence, solvency |
| `claimRefund` | net-deposit return, lazy expiry, event de-duplication, before-deadline revert, double-claim prevention, solvency |
| `withdrawFees` | host access, zero-fee guard, isolation from collateral |
| Security | double-claim paths, role checks, fee/collateral separation, `resolvedPot` immutability |
| Fuzz | prices bounded `(0, 1e18)`, sum-to-one, fee formula, full lifecycle, solvency after all claims |

---

## Deployment

### 1. Set up environment variables

Copy `.env.example` to `.env` and fill in your values:

```bash
cp .env.example .env
```

Open `.env` and set:

| Variable | Description |
|---|---|
| `PRIVATE_KEY` | Private key of the deployer wallet (with `0x` prefix) |
| `RPC_URL` | RPC endpoint for the target network |
| `TREASURY_ADDRESS` | Address that receives the protocol's share of fees |
| `PROTOCOL_FEE_BPS` | Protocol fee in basis points — max `3000` (= 30 % of the market fee). E.g. `1000` = 10 % |
| `ETHERSCAN_API_KEY` | *(optional)* Required only if you add `--verify` |

> **Never commit `.env`** — it contains your private key. `.env` is already in `.gitignore`.

### 2. Deploy to a local node (Anvil)

Start a local node in one terminal:

```bash
anvil
```

The first Anvil account's private key is always:

```
0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
```

Set your `.env` to use that key and `RPC_URL=http://localhost:8545`, then run:

```bash
source .env
forge script script/Deploy.s.sol \
  --rpc-url "$RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  --broadcast \
  -vvv
```

### 3. Deploy to a live network

```bash
source .env
forge script script/Deploy.s.sol \
  --rpc-url "$RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  --broadcast \
  -vvv
```

Add `--verify --etherscan-api-key "$ETHERSCAN_API_KEY"` to verify the contract on Etherscan in the same step:

```bash
source .env
forge script script/Deploy.s.sol \
  --rpc-url "$RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  --broadcast \
  --verify \
  --etherscan-api-key "$ETHERSCAN_API_KEY" \
  -vvv
```

The script prints the deployed factory address, `protocolAdmin`, `protocolTreasury`, and `protocolFeeBps` to stdout. The broadcast transaction is also saved under `broadcast/Deploy.s.sol/<chainId>/run-latest.json` for reference.

---

## Key Constants

| Constant | Value | Meaning |
|---|---|---|
| `MIN_BET` | `1e4` (0.01 USDC at 6 decimals) | Minimum trade size |
| `MAX_MARKET_FEE_BPS` | `1_000` | Max 10% per-trade host fee |
| `MAX_PROTOCOL_FEE_BPS` | `3_000` | Max 30% of market fee to protocol |
| `FEE_DENOMINATOR` | `10_000` | Basis point denominator |

---

## Roles

| Role | Who | Capabilities |
|---|---|---|
| `protocolAdmin` | Factory deployer | Update treasury, fee, transfer admin role |
| `host` | Market creator | Resolve market, withdraw accrued fees |
| trader | Anyone | Buy shares, claim reward or refund |
