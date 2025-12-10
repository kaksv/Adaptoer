# Sealed Bid Auction Hook for Uniswap v4 🔒🦄

### **Privacy-Preserving Price Discovery with Fully Homomorphic Encryption**

> A Uniswap v4 hook that enables sealed bid auctions within liquidity pools, allowing traders to submit encrypted bids without revealing their intent, enabling natural price discovery through FHE-encrypted bid matching.

## Overview

The Sealed Bid Auction Hook implements a novel auction mechanism for Uniswap v4 pools that combines the benefits of:
- **Privacy**: Bids are encrypted using Fhenix FHE, preventing front-running and intent leakage
- **Price Discovery**: Natural market clearing through encrypted bid comparison
- **MEV Resistance**: Traders can't see others' bids until reveal phase
- **Decentralized Execution**: All matching and settlement happens on-chain

### How It Works

1. **Bidding Phase**: Traders submit encrypted bids (amount and price) to the hook
2. **Reveal Phase**: Bids are decrypted and matched using FHE comparison operations
3. **Settlement**: Matched bids execute swaps through the Uniswap v4 pool at discovered prices
4. **Price Discovery**: The clearing price emerges naturally from the highest matched bids

## Architecture

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
│              │  Uniswap v4 Pool      │                  │
│              │      Manager          │                  │
│              └──────────────────────┘                  │
└─────────────────────────────────────────────────────────┘
```

### Key Features

- **FHE-Encrypted Bid Storage**: All bids stored as `euint128` encrypted values
- **Privacy-Preserving Comparison**: Bid matching without revealing individual bid values
- **Auction Phases**: Configurable bidding and reveal periods
- **Automatic Settlement**: Matched bids automatically execute swaps
- **Multi-Pool Support**: Single hook instance can manage multiple pools

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

```solidity
// Deploy with correct flags for hook permissions
address hookAddress = HookMiner.find(
    salt,
    type(SealedBidAuctionHook).creationCode,
    abi.encode(poolManager),
    flags
);

SealedBidAuctionHook hook = new SealedBidAuctionHook{salt: salt}(poolManager);
```

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

### Submitting a Sealed Bid

```solidity
// User encrypts their bid amount and price
euint128 encryptedAmount = FHE.asEuint128(amount);
euint128 encryptedPrice = FHE.asEuint128(price);

// Submit encrypted bid
hook.submitBid(
    poolId,
    encryptedAmount,
    encryptedPrice,
    zeroForOne  // true if selling token0 for token1
);
```

### Revealing and Matching Bids

```solidity
// After bidding period ends, reveal bids
hook.revealBid(poolId, bidId, nonce);

// Hook automatically matches bids and executes swaps
// Matching happens using FHE comparison:
// - Compare encrypted prices
// - Match highest bids with lowest asks
// - Execute swaps at clearing price
```

## Technical Details

### FHE Operations

The hook leverages Fhenix FHE for privacy-preserving operations:

1. **Encrypted Storage**: Bids stored as `euint128` encrypted values
2. **Comparison Operations**: `FHE.lt()`, `FHE.gt()`, `FHE.eq()` for matching
3. **Arithmetic Operations**: `FHE.add()`, `FHE.sub()` for calculations
4. **Select Operations**: `FHE.select()` for conditional logic

### Auction Phases

#### Phase 1: Bidding
- Users submit encrypted bids
- No bid values are visible on-chain
- Bids are stored with commitment hashes
- Duration: Configurable (e.g., 1 hour)

#### Phase 2: Reveal
- Users reveal their bids with nonces
- Bids are decrypted and validated
- Invalid reveals are rejected
- Duration: Configurable (e.g., 30 minutes)

#### Phase 3: Matching & Settlement
- Hook matches bids using FHE comparison
- Highest bids matched with lowest asks
- Clearing price determined from matched bids
- Swaps executed through pool manager

### Bid Matching Algorithm

```solidity
// Pseudocode for bid matching
function matchBids(encryptedBids) {
    // Sort bids by price (using FHE comparison)
    sortedBids = sortByPrice(encryptedBids);
    
    // Match highest bids with lowest asks
    for (bid in sortedBids) {
        if (bid.type == BUY && hasMatchingAsk(bid)) {
            executeSwap(bid, matchingAsk);
        }
    }
    
    // Return clearing price
    return clearingPrice;
}
```

### Security Considerations

1. **Commitment Scheme**: Bids use cryptographic commitments to prevent bid manipulation
2. **Nonce Verification**: Reveals must match original commitments
3. **Reentrancy Protection**: All state changes before external calls
4. **Access Control**: Only pool manager can execute swaps
5. **FHE Permissions**: Proper `FHE.allow()` calls for encrypted data access

## Example Workflow

### Scenario: Trading Token A for Token B

1. **Alice wants to buy 100 Token B at max price 1.1 Token A per Token B**
   ```solidity
   // Alice encrypts her bid
   euint128 amount = FHE.asEuint128(100e18);
   euint128 maxPrice = FHE.asEuint128(1.1e18);
   
   // Submit sealed bid
   hook.submitBid(poolId, amount, maxPrice, false);
   ```

2. **Bob wants to sell 50 Token B at min price 1.05 Token A per Token B**
   ```solidity
   // Bob encrypts his ask
   euint128 amount = FHE.asEuint128(50e18);
   euint128 minPrice = FHE.asEuint128(1.05e18);
   
   // Submit sealed bid (as ask)
   hook.submitBid(poolId, amount, minPrice, true);
   ```

3. **After bidding period, bids are revealed**
   ```solidity
   // Both Alice and Bob reveal
   hook.revealBid(poolId, aliceBidId, aliceNonce);
   hook.revealBid(poolId, bobBidId, bobNonce);
   ```

4. **Hook matches bids and executes swap**
   - Alice's bid: 100 Token B @ max 1.1 Token A
   - Bob's ask: 50 Token B @ min 1.05 Token A
   - Match: 50 Token B @ clearing price (e.g., 1.08 Token A)
   - Swap executes: Bob receives 54 Token A, Alice receives 50 Token B

## API Reference

### Key Functions

#### `submitBid`
Submit an encrypted bid to the auction.

```solidity
function submitBid(
    PoolId poolId,
    euint128 encryptedAmount,
    euint128 encryptedPrice,
    bool zeroForOne
) external returns (uint256 bidId);
```

#### `revealBid`
Reveal a previously submitted bid.

```solidity
function revealBid(
    PoolId poolId,
    uint256 bidId,
    bytes32 nonce
) external;
```

#### `matchAndSettle`
Match revealed bids and execute swaps.

```solidity
function matchAndSettle(PoolId poolId) external;
```

#### `getAuctionState`
Get current auction state for a pool.

```solidity
function getAuctionState(PoolId poolId) 
    external 
    view 
    returns (AuctionState memory);
```

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

- Bid submission and encryption
- Bid reveal and validation
- Bid matching algorithm
- Swap execution
- Multi-user scenarios
- Edge cases (no matches, partial fills)

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

## Gas Optimization

- Batch bid reveals to reduce gas costs
- Efficient FHE operation ordering
- Minimal storage writes
- Reusable encrypted values where possible

## Limitations

1. **FHE Computation Cost**: FHE operations are more expensive than plain operations
2. **Bid Count Limits**: Large numbers of bids may hit gas limits
3. **Reveal Timing**: Users must reveal within the reveal window
4. **Price Precision**: Limited by FHE precision (euint128)

## Future Enhancements

- [ ] Partial fill support for large bids
- [ ] Multi-round auctions
- [ ] Dynamic fee calculation based on auction volume
- [ ] Integration with off-chain order books
- [ ] Batch reveal optimization
- [ ] Support for limit orders within auctions

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

## Acknowledgments

- Built on [fhe-hook-template](https://github.com/marronjo/fhe-hook-template)
- Uses [Fhenix CoFhe](https://github.com/fhenixprotocol/cofhe-contracts) for FHE operations
- Implements Uniswap v4 hook architecture

---

**⚠️ Disclaimer**: This is experimental software. Use at your own risk. Always audit smart contracts before deploying to mainnet.
