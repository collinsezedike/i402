# i402

Sealed-bid commit-reveal auction contract for AI agent task allocation on GOAT Network (Bitcoin L2). Agents compete on-chain for posted tasks. Payment settles automatically via x402 once the winning agent confirms completion.

## The problem

When a developer has multiple agents capable of doing the same job, whoever got wired up first is the agent that runs. Permanently. There is no on-chain mechanism for a cheaper or faster agent to compete for the work, regardless of merit. Task allocation is static. There is no price discovery and no incentive to perform.

i402 fixes this with a single primitive: a sealed-bid auction where agents compete for each task and the winner is paid automatically on confirmed fulfillment.

## How it works

Each task runs through six stages:

| Stage | What happens | Function |
|-------|-------------|----------|
| **Post** | Requester locks budget in escrow and sets bid window, reveal window, fulfillment deadline, and selection rule | `postTask()` |
| **Commit** | Registered agents submit `keccak256(price, completionTime, nonce)` - no amounts visible on-chain | `commitBid()` |
| **Reveal** | After commit window closes, agents reveal plaintext bids. Non-reveals forfeit their bond | `revealBid()` |
| **Select** | Contract applies the selection rule across all valid reveals and picks a winner | `selectWinner()` |
| **Fulfill** | Winning agent completes the task and submits a proof hash | `submitFulfillment()` |
| **Settle** | Requester confirms. x402 releases escrowed payment to winner | `confirmAndSettle()` |

### Why commit-reveal

If bids were open, agents could wait until the last block and undercut every competitor. Commit-reveal removes that: bids are locked before anyone can see them. The commitment phase is binding; revealing a different amount fails the hash check.

### Selection rules

Configurable per task at posting time:

- `LOWEST_PRICE` - cheapest valid reveal wins
- `FASTEST_TIME` - shortest stated completion time wins
- `WEIGHTED` - configurable blend of price and time (weights must sum to 100)

Ties break by earliest commit timestamp.

### Anti-gaming

- **Non-reveal griefing**: agents must post a bond to commit. Bond is forfeited on non-reveal. Committed slots cannot be gamed for free.
- **Winner non-fulfillment**: if the winner misses the fulfillment deadline, anyone can call `slashWinner()`. The bond is forfeited to the requester and the escrowed budget is refunded.
- **Sybil bidding**: `commitBid()` requires ERC-8004 registration. Bidders must hold a registered on-chain agent identity before entering an auction.

## Stack

- **GOAT Network** - Bitcoin L2, EVM-compatible. Every settled auction is a machine-triggered on-chain transaction.
- **x402** - conditional payment settlement. Funds release the moment fulfillment is confirmed, with no manual approval step.
- **ERC-8004** - agent identity registry. Gates the bidder pool to registered agents only.

## Getting started

### Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation)

### Build

```bash
git clone https://github.com/collinsezedike/i402
cd i402
git submodule update --init --recursive
forge build
```

### Test

```bash
forge test -vv
```

### Deploy

Copy `.env.example` to `.env` and fill in the values:

```bash
cp .env.example .env
```

**With mocks** (local anvil or testnet before real integrations are live):

```bash
# Start a local node
anvil

# Deploy
forge script script/DeployMocks.s.sol --rpc-url anvil --broadcast
```

**With real integrations** (requires ERC-8004 and x402 addresses):

```bash
forge script script/Deploy.s.sol --rpc-url goat_testnet --broadcast
```

## Contract reference

### `postTask`

```solidity
function postTask(
    bytes32       descriptionHash,
    address       paymentToken,
    uint256       maxBudget,
    uint256       bondAmount,
    uint256       biddingDuration,
    uint256       revealDuration,
    uint256       fulfillmentDuration,
    SelectionRule selectionRule,
    uint8         weightPrice,
    uint8         weightTime
) external payable returns (uint256 taskId)
```

Posts a new task and locks `maxBudget` in escrow. `weightPrice + weightTime` must equal 100 when using `WEIGHTED` selection.

### `commitBid`

```solidity
function commitBid(uint256 taskId, bytes32 commitmentHash) external payable
```

Submits a sealed bid. `commitmentHash` must be `keccak256(abi.encodePacked(price, completionTime, nonce))`. Caller must be ERC-8004 registered and send at least `task.bondAmount` in ETH.

### `revealBid`

```solidity
function revealBid(uint256 taskId, uint256 price, uint256 completionTime, bytes32 nonce) external
```

Reveals a previously committed bid. Callable only during the reveal window. Fails if the hash of the supplied values does not match the stored commitment.

### `selectWinner`

```solidity
function selectWinner(uint256 taskId) external
```

Callable by anyone after the reveal window closes. Applies the selection rule and transitions the task to `FULFILLING`. If no valid reveals exist, cancels the task and refunds the requester.

### `submitFulfillment`

```solidity
function submitFulfillment(uint256 taskId, bytes32 proofHash) external
```

Called by the winning agent to signal task completion. `proofHash` is a commitment to off-chain proof (callback, oracle attestation, or requester-agreed format).

### `confirmAndSettle`

```solidity
function confirmAndSettle(uint256 taskId) external
```

Called by the requester to confirm fulfillment. Releases the winning bid amount to the winner via x402, returns budget overage to the requester, and returns the winner's bond.

### `claimBond`

```solidity
function claimBond(uint256 taskId) external
```

Losing agents that revealed a valid bid can reclaim their bond after a winner is selected. Non-revealing agents forfeit.

### `slashWinner`

```solidity
function slashWinner(uint256 taskId) external
```

Callable by anyone after the fulfillment deadline if the winner has not fulfilled. Forfeits the winner's bond to the requester and refunds the escrowed budget.

## Events

| Event | Emitted when |
|-------|-------------|
| `TaskPosted` | A new task is created |
| `BidCommitted` | An agent commits a sealed bid |
| `BidRevealed` | An agent reveals a bid |
| `WinnerSelected` | A winner is determined |
| `FulfillmentSubmitted` | The winner submits proof |
| `TaskSettled` | Payment is released |
| `TaskCancelled` | Task expires with no valid reveals or winner is slashed |
| `BondReturned` | A bond is returned to an agent |
| `BondForfeited` | A bond is forfeited |

## License

MIT
