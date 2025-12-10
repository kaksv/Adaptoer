# Sealed Bid Auction Hook for Uniswap v4 🔒🦄

### **Privacy-Preserving Price Discovery with Fully Homomorphic Encryption**

> A Uniswap v4 hook built on the BaseHook architecture that enables sealed bid auctions within liquidity pools, allowing traders to submit encrypted bids without revealing their intent, enabling natural price discovery through FHE-encrypted bid matching.

## Overview

The Sealed Bid Auction Hook implements a novel auction mechanism for Uniswap v4 pools that combines the benefits of:
- **Privacy**: Bids are encrypted using Fhenix FHE, preventing front-running and intent leakage
- **Price Discovery**: Natural market clearing through encrypted bid comparison
- **MEV Resistance**: Traders can't see others' bids until reveal phase
- **Decentralized Execution**: All matching and settlement happens on-chain
- **Commitment Scheme**: Cryptographic commitments prevent bid manipulation

### How It Works

1. **Start Auction**: An auction is initiated for a specific pool with configurable time periods
2. **Bidding Phase**: Traders submit encrypted bids (amount and price) with cryptographic commitments
3. **Reveal Phase**: After bidding ends, traders reveal their bids with nonces to verify commitments
4. **Matching**: Revealed bids are matched (buy orders with sell orders) based on price compatibility
5. **Settlement**: Auction is settled, transitioning to the settled phase
6. **Price Discovery**: The clearing price emerges naturally from matched bids

## Architecture

### BaseHook Integration

This hook extends the `BaseHook` contract from Uniswap v4, which provides:
- Standardized hook interface implementation
- Pool manager integration
- Hook permission management
- Built-in access control for pool operations

### Core Components

```
┌─────────────────────────────────────────────────────────┐
│              SealedBidAuctionHook                        │
│                                                          │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐ │
│  │ Bid Storage  │  │ FHE Matching │  │  Settlement  │ │
│  │  (Encrypted) │  │   Engine     │  │   Logic      │ │
│  └──────────────┘  └──────────────┘  └──────────────┘ │
│                                                          │
│              ┌──────────────────────┐                  │
│              │  Uniswap v4 Pool     │                  │
│              │      Manager          │                  │
│              └──────────────────────┘                  │
└─────────────────────────────────────────────────────────┘
```

### Key Features

- **FHE-Encrypted Bid Storage**: All bids stored as `euint128` encrypted values
- **Commitment Scheme**: Cryptographic commitments prevent bid manipulation
- **Privacy-Preserving**: Bids remain encrypted until reveal phase
- **Auction Phases**: Three-phase system (Bidding → Reveal → Settled)
- **Multi-Pool Support**: Single hook instance can manage multiple pools
- **Time-Based Phases**: Configurable bidding (1 hour) and reveal (30 minutes) durations

## Installation

### Prerequisites

- [Foundry](https://book.getfoundry.sh) (Stable version)
- Node.js and npm/pnpm
- Access to Fhenix network or local FHE test environment

### Setup

```bash
# Clone the repository
git clone <repository-url>
cd fhe-hook-template

# Install dependencies
npm install

# Install Foundry dependencies
forge install

# Run tests
forge test --via-ir
```

## Usage

### Deploying the Hook

The hook extends `BaseHook` from Uniswap v4, which requires proper flag configuration:

```solidity
// Calculate required hook flags (only beforeSwap and afterSwap are enabled)
uint160 flags = uint160(
    Hooks.BEFORE_SWAP_FLAG |
    Hooks.AFTER_SWAP_FLAG
);

// Deploy with correct flags for hook permissions
address hookAddress = HookMiner.find(
    CREATE2_DEPLOYER,
    flags,
    type(SealedBidAuctionHook).creationCode,
    abi.encode(poolManager)
);

SealedBidAuctionHook hook = new SealedBidAuctionHook{salt: salt}(poolManager);
```

The hook implements `getHookPermissions()` to return the required permissions, which must match the deployment flags. Currently, only `beforeSwap` and `afterSwap` hooks are enabled.

### Creating a Pool with the Hook

```solidity
PoolKey memory key = PoolKey({
    currency0: Currency.wrap(token0),
    currency1: Currency.wrap(token1),
    fee: 3000,
    tickSpacing: 60,
    hooks: IHooks(hookAddress)
});

poolManager.initialize(key, sqrtPriceX96);
```

### Starting an Auction

```solidity
// Start a new auction for a pool
hook.startAuction(poolId);
```

### Submitting a Sealed Bid

```solidity
// 1. Create commitment hash (off-chain or on-chain)
bytes32 nonce = keccak256("user-nonce-1");
bytes32 commitment = keccak256(abi.encodePacked(amount, price, nonce, msg.sender));

// 2. Encrypt bid values
euint128 encryptedAmount = FHE.asEuint128(amount);
euint128 encryptedPrice = FHE.asEuint128(price);

// 3. Submit encrypted bid with commitment
uint256 bidId = hook.submitBid(
    poolId,
    encryptedAmount,
    encryptedPrice,
    zeroForOne,  // true if selling token0 for token1
    commitment
);
```

### Revealing Bids

```solidity
// After bidding period ends (1 hour), reveal bids
// Must provide the same amount, price, and nonce used in commitment
hook.revealBid(
    poolId,
    bidId,
    amount,   // Plaintext amount
    price,    // Plaintext price
    nonce     // Nonce used in commitment
);
```

### Matching Bids

```solidity
// Match a buy bid with a sell bid
// Both bids must be revealed and compatible (buy price >= sell price)
hook.matchBids(poolId, buyBidId, sellBidId);
```

### Settling Auction

```solidity
// After reveal period ends, settle the auction
hook.settleAuction(poolId);
```

## Technical Details

### BaseHook Implementation

The hook extends `BaseHook` from `v4-periphery/src/utils/BaseHook.sol`, which provides:

- **Standardized Interface**: Implements `IHooks` interface required by Uniswap v4
- **Pool Manager Access**: Direct integration with `IPoolManager` for swap execution
- **Hook Lifecycle**: Proper handling of `beforeSwap`, `afterSwap`, and other hook callbacks
- **Access Control**: Built-in `onlyPoolManager` modifier for security

Key hook methods:
- `_beforeSwap()`: Intercept swaps to process sealed bids
- `_afterSwap()`: Post-swap processing and state updates
- `getHookPermissions()`: Define which hooks are enabled

### FHE Operations

The hook leverages Fhenix FHE for privacy-preserving operations:

1. **Encrypted Storage**: Bids stored as `euint128` encrypted values
2. **Comparison Operations**: `FHE.lt()`, `FHE.gt()`, `FHE.eq()` for matching (future enhancement)
3. **Arithmetic Operations**: `FHE.add()`, `FHE.sub()` for calculations
4. **Select Operations**: `FHE.select()` for conditional logic
5. **Permissions**: Proper `FHE.allowThis()` calls for encrypted data access

### Auction Phases

#### Phase 1: Bidding (`Bidding`)
- Users submit encrypted bids with cryptographic commitments
- No bid values are visible on-chain (stored as `euint128`)
- Commitments prevent bid manipulation
- Duration: **1 hour** (constant: `BIDDING_DURATION`)
- Functions: `startAuction()`, `submitBid()`

#### Phase 2: Reveal (`Reveal`)
- Users reveal their bids with plaintext values and nonces
- Commitments are verified: `keccak256(amount, price, nonce, bidder) == commitment`
- Invalid reveals are rejected
- Duration: **30 minutes** (constant: `REVEAL_DURATION`)
- Functions: `revealBid()`, `matchBids()`

#### Phase 3: Settled (`Settled`)
- Auction is complete
- All matching and settlement has occurred
- Clearing price is recorded
- Functions: `settleAuction()`

### Bid Matching Algorithm

The matching process requires manual pairing of buy and sell bids:

```solidity
// Matching is done explicitly by calling matchBids()
// Both bids must be:
// 1. Revealed (bid.revealed == true)
// 2. Not already matched (bid.matched == false)
// 3. Compatible types (one Buy, one Sell)
// 4. Price compatible (buy price >= sell price)

function matchBids(PoolId poolId, uint256 buyBidId, uint256 sellBidId) external {
    // Validates bid types and states
    // Marks both bids as matched
    // Records the match in matchedBids mapping
    // Updates clearing price if needed
}
```

**Note**: Full FHE-based automatic matching is a future enhancement. Currently, matching requires explicit calls with revealed bids.

### Security Considerations

1. **BaseHook Security**: Inherits security patterns from Uniswap v4 BaseHook
2. **Commitment Scheme**: Bids use cryptographic commitments to prevent bid manipulation
3. **Nonce Verification**: Reveals must match original commitments
4. **Reentrancy Protection**: All state changes before external calls
5. **Access Control**: Only pool manager can execute swaps (enforced by BaseHook)
6. **FHE Permissions**: Proper `FHE.allowThis()` calls for encrypted data access
7. **Hook Permissions**: Only enabled hooks can be called by pool manager
8. **Phase Validation**: Operations are restricted to appropriate auction phases

## Example Workflow

### Scenario: Trading Token A for Token B

1. **Start the auction**
   ```solidity
   hook.startAuction(poolId);
   ```

2. **Alice wants to buy 100 Token B at max price 1.1 Token A per Token B**
   ```solidity
   // Create commitment
   uint128 amount = 100e18;
   uint128 price = 1.1e18;
   bytes32 nonce = keccak256("alice-nonce-1");
   bytes32 commitment = keccak256(abi.encodePacked(amount, price, nonce, alice));
   
   // Encrypt and submit
   euint128 encryptedAmount = FHE.asEuint128(amount);
   euint128 encryptedPrice = FHE.asEuint128(price);
   uint256 aliceBidId = hook.submitBid(poolId, encryptedAmount, encryptedPrice, false, commitment);
   ```

3. **Bob wants to sell 50 Token B at min price 1.05 Token A per Token B**
   ```solidity
   // Create commitment
   uint128 amount = 50e18;
   uint128 price = 1.05e18;
   bytes32 nonce = keccak256("bob-nonce-1");
   bytes32 commitment = keccak256(abi.encodePacked(amount, price, nonce, bob));
   
   // Encrypt and submit
   euint128 encryptedAmount = FHE.asEuint128(amount);
   euint128 encryptedPrice = FHE.asEuint128(price);
   uint256 bobBidId = hook.submitBid(poolId, encryptedAmount, encryptedPrice, true, commitment);
   ```

4. **After bidding period (1 hour), bids are revealed**
   ```solidity
   // Alice reveals
   hook.revealBid(poolId, aliceBidId, 100e18, 1.1e18, keccak256("alice-nonce-1"));
   
   // Bob reveals
   hook.revealBid(poolId, bobBidId, 50e18, 1.05e18, keccak256("bob-nonce-1"));
   ```

5. **Match bids and settle**
   ```solidity
   // Match the bids (buy price 1.1 >= sell price 1.05, so compatible)
   hook.matchBids(poolId, aliceBidId, bobBidId);
   
   // After reveal period ends, settle
   hook.settleAuction(poolId);
   ```
   
   Result:
   - Alice's bid: 100 Token B @ max 1.1 Token A
   - Bob's ask: 50 Token B @ min 1.05 Token A
   - Match: 50 Token B @ clearing price (average of 1.1 and 1.05)
   - Both bids marked as matched

## API Reference

### Key Functions

#### `startAuction`
Start a new auction for a pool.

```solidity
function startAuction(PoolId poolId) external;
```

#### `submitBid`
Submit an encrypted bid to the auction with a commitment.

```solidity
function submitBid(
    PoolId poolId,
    euint128 encryptedAmount,
    euint128 encryptedPrice,
    bool zeroForOne,
    bytes32 commitment
) external returns (uint256 bidId);
```

#### `revealBid`
Reveal a previously submitted bid with plaintext values.

```solidity
function revealBid(
    PoolId poolId,
    uint256 bidId,
    uint128 amount,
    uint128 price,
    bytes32 nonce
) external;
```

#### `matchBids`
Match a buy bid with a sell bid.

```solidity
function matchBids(
    PoolId poolId,
    uint256 buyBidId,
    uint256 sellBidId
) external;
```

#### `settleAuction`
Settle the auction after reveal period ends.

```solidity
function settleAuction(PoolId poolId) external;
```

#### `getAuctionState`
Get current auction state for a pool.

```solidity
function getAuctionState(PoolId poolId) 
    external 
    view 
    returns (AuctionTypes.AuctionState memory);
```

#### `getBid`
Get bid information.

```solidity
function getBid(PoolId poolId, uint256 bidId) 
    external 
    view 
    returns (AuctionTypes.EncryptedBid memory);
```

#### `getRevealedBidIds`
Get all revealed bid IDs for a pool.

```solidity
function getRevealedBidIds(PoolId poolId) 
    external 
    view 
    returns (uint256[] memory);
```

### Events

- `AuctionStarted(PoolId indexed poolId, uint256 biddingEndTime)`
- `BidSubmitted(PoolId indexed poolId, uint256 indexed bidId, address indexed bidder)`
- `BidRevealed(PoolId indexed poolId, uint256 indexed bidId, address indexed bidder)`
- `BidsMatched(PoolId indexed poolId, uint256 buyBidId, uint256 sellBidId, uint256 clearingPrice)`
- `AuctionSettled(PoolId indexed poolId, uint256 clearingPrice)`

### Errors

- `InvalidPhase()` - Operation attempted in wrong auction phase
- `InvalidCommitment()` - Commitment verification failed
- `BidAlreadyRevealed()` - Bid has already been revealed
- `BidAlreadyMatched()` - Bid has already been matched
- `BidNotFound()` - Bid ID does not exist
- `NoMatchingBid()` - No compatible bid found for matching

## Testing

### Running Tests

```bash
# Run all tests
forge test --via-ir

# Run with verbosity
forge test --via-ir -vvv

# Run specific test
forge test --via-ir --match-test testSealedBidAuction
```

### Test Coverage

The test suite (`test/SealedBidAuctionHook.t.sol`) includes:

- ✅ Auction lifecycle (start, bid, reveal, match, settle)
- ✅ Bid submission with encrypted values and commitments
- ✅ Bid reveal with commitment verification
- ✅ Invalid commitment rejection
- ✅ Bid matching between buy and sell orders
- ✅ Multi-user scenarios (Alice, Bob, Charlie)
- ✅ Phase transitions and timing validation

### Running Specific Tests

```bash
# Test auction start
forge test --via-ir --match-test testStartAuction

# Test bid submission
forge test --via-ir --match-test testSubmitBid

# Test bid reveal
forge test --via-ir --match-test testRevealBid

# Test bid matching
forge test --via-ir --match-test testMatchBids
```

## Local Development

### Using Anvil

```bash
# Start local chain with FHE support
anvil --code-size-limit 40000

# In another terminal, deploy and test
forge script script/DeploySealedBidAuction.s.sol \
    --rpc-url http://localhost:8545 \
    --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 \
    --broadcast
```

## Project Structure

```
fhe-hook-template/
├── src/
│   ├── SealedBidAuctionHook.sol    # Main hook contract
│   ├── types/
│   │   └── AuctionTypes.sol        # Type definitions (Phase, BidType, structs)
│   └── libraries/
│       └── BidMatching.sol         # Bid matching utilities
├── test/
│   └── SealedBidAuctionHook.t.sol   # Comprehensive test suite
├── script/
│   └── DeploySealedBidAuction.s.sol # Deployment script
└── README.md
```

## Gas Optimization

- Batch bid reveals to reduce gas costs
- Efficient FHE operation ordering
- Minimal storage writes
- Reusable encrypted values where possible

## Limitations

1. **FHE Computation Cost**: FHE operations are more expensive than plain operations
2. **Manual Matching**: Currently requires explicit `matchBids()` calls (automatic matching is future work)
3. **Bid Count Limits**: Large numbers of bids may hit gas limits
4. **Reveal Timing**: Users must reveal within the 30-minute reveal window
5. **Price Precision**: Limited by FHE precision (euint128)
6. **No Automatic Swap Execution**: Matched bids are recorded but swaps must be executed separately

## Future Enhancements

- [ ] Automatic bid matching using FHE comparison operations
- [ ] Automatic swap execution for matched bids through pool manager
- [ ] Partial fill support for large bids
- [ ] Multi-round auctions
- [ ] Dynamic fee calculation based on auction volume
- [ ] Integration with off-chain order books
- [ ] Batch reveal optimization
- [ ] Support for limit orders within auctions
- [ ] FHE-based price sorting for efficient matching
- [ ] Gas-optimized batch operations

## Contributing

Contributions are welcome! Please ensure:
- All tests pass
- Code follows Solidity style guide
- FHE operations are properly secured
- Gas optimizations are documented

## License

MIT License - see LICENSE file for details

## Resources

### Fhenix 🔒
- [FHE Limit Order Hook](https://github.com/marronjo/iceberg-cofhe) - Similar FHE hook example
- [CoFhe Documentation](https://cofhe-docs.fhenix.zone/docs/devdocs/overview)
- [FHERC20 Token Docs](https://cofhe-docs.fhenix.zone/docs/devdocs/fherc/fherc20)
- [Fhenix Hooks Dev Wiki](https://fhenix.notion.site/hooks-dev-wiki)

### Uniswap 🦄
- [Uniswap v4 Documentation](https://docs.uniswap.org/contracts/v4/overview)
- [Hook Examples](https://github.com/Uniswap/v4-periphery/tree/example-contracts/contracts/hooks/examples)
- [v4-by-example](https://v4-by-example.org)
- [v4-core Repository](https://github.com/uniswap/v4-core)
- [v4-periphery Repository](https://github.com/uniswap/v4-periphery)

## Implementation Details

### Constants

- `BIDDING_DURATION`: 1 hour (3600 seconds)
- `REVEAL_DURATION`: 30 minutes (1800 seconds)

### State Variables

- `auctions`: Mapping of pool ID to auction state
- `bids`: Mapping of pool ID and bid ID to encrypted bid data
- `bidCounters`: Per-pool bid counter
- `revealedBidIds`: Array of revealed bid IDs per pool
- `matchedBids`: Mapping of buy bid ID to matched sell bid ID

### Hook Permissions

The hook currently enables:
- `beforeSwap`: true - Can intercept swaps
- `afterSwap`: true - Can process post-swap events
- All other hooks: false

## Acknowledgments

- Built on [fhe-hook-template](https://github.com/marronjo/fhe-hook-template)
- Uses [Fhenix CoFhe](https://github.com/fhenixprotocol/cofhe-contracts) for FHE operations
- Extends [Uniswap v4 BaseHook](https://github.com/uniswap/v4-periphery) architecture
- Implements Uniswap v4 hook interface (`IHooks`)
- Uses commitment scheme for bid integrity

---

**⚠️ Disclaimer**: This is experimental software. Use at your own risk. Always audit smart contracts before deploying to mainnet.
