// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// Uniswap Imports
import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

// FHE Imports
import {FHE, euint128} from "@fhenixprotocol/cofhe-contracts/FHE.sol";

// Local Imports
import {AuctionTypes} from "./types/AuctionTypes.sol";

/// @title SealedBidAuctionHook
/// @notice Uniswap v4 hook implementing sealed bid auctions with FHE encryption
/// @dev Enables privacy-preserving price discovery through encrypted bid matching
contract SealedBidAuctionHook is BaseHook {
    using PoolIdLibrary for PoolKey;
    using FHE for uint256;

    // ============ Constants ============
    uint256 public constant BIDDING_DURATION = 1 hours;
    uint256 public constant REVEAL_DURATION = 30 minutes;

    // ============ State Variables ============
    /// @notice Auction state per pool
    mapping(PoolId => AuctionTypes.AuctionState) public auctions;
    
    /// @notice Encrypted bids per pool
    mapping(PoolId => mapping(uint256 => AuctionTypes.EncryptedBid)) public bids;
    
    /// @notice Bid counter per pool
    mapping(PoolId => uint256) public bidCounters;
    
    /// @notice Revealed bid IDs per pool (for matching)
    mapping(PoolId => uint256[]) public revealedBidIds;
    
    /// @notice Matched bid pairs per pool
    mapping(PoolId => mapping(uint256 => uint256)) public matchedBids;

    // ============ Events ============
    event BidSubmitted(PoolId indexed poolId, uint256 indexed bidId, address indexed bidder);
    event BidRevealed(PoolId indexed poolId, uint256 indexed bidId, address indexed bidder);
    event BidsMatched(PoolId indexed poolId, uint256 buyBidId, uint256 sellBidId, uint256 clearingPrice);
    event AuctionStarted(PoolId indexed poolId, uint256 biddingEndTime);
    event AuctionSettled(PoolId indexed poolId, uint256 clearingPrice);

    // ============ Errors ============
    error InvalidPhase();
    error BidNotFound();
    error InvalidCommitment();
    error BidAlreadyRevealed();
    error BidAlreadyMatched();
    error NoMatchingBid();
    error AuctionNotSettled();

    // ============ Constructor ============
    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    // ============ Hook Permissions ============
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,  // Intercept swaps to process sealed bids
            afterSwap: true,   // Post-swap processing
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ============ Public Functions ============

    /// @notice Start a new auction for a pool
    /// @param poolId The pool ID to start auction for
    function startAuction(PoolId poolId) external {
        AuctionTypes.AuctionState storage auction = auctions[poolId];
        
        // Can only start if no active auction or previous auction is settled
        require(
            auction.phase == AuctionTypes.Phase.Settled || auction.biddingEndTime == 0,
            "Auction already active"
        );

        auction.phase = AuctionTypes.Phase.Bidding;
        auction.biddingEndTime = block.timestamp + BIDDING_DURATION;
        auction.revealEndTime = block.timestamp + BIDDING_DURATION + REVEAL_DURATION;
        auction.totalBids = 0;
        auction.totalRevealed = 0;
        auction.clearingPrice = 0;

        emit AuctionStarted(poolId, auction.biddingEndTime);
    }

    /// @notice Submit an encrypted bid to the auction
    /// @param poolId The pool ID
    /// @param encryptedAmount Encrypted bid amount
    /// @param encryptedPrice Encrypted price (amount of input token per output token)
    /// @param zeroForOne True if selling token0 for token1, false if buying token1 with token0
    /// @param commitment Hash commitment of (amount, price, nonce)
    /// @return bidId The ID of the submitted bid
    function submitBid(
        PoolId poolId,
        euint128 encryptedAmount,
        euint128 encryptedPrice,
        bool zeroForOne,
        bytes32 commitment
    ) external returns (uint256 bidId) {
        AuctionTypes.AuctionState storage auction = auctions[poolId];
        
        require(auction.phase == AuctionTypes.Phase.Bidding, "Not in bidding phase");
        require(block.timestamp < auction.biddingEndTime, "Bidding period ended");

        bidId = bidCounters[poolId]++;
        auction.totalBids++;

        bids[poolId][bidId] = AuctionTypes.EncryptedBid({
            bidder: msg.sender,
            encryptedAmount: encryptedAmount,
            encryptedPrice: encryptedPrice,
            bidType: zeroForOne ? AuctionTypes.BidType.Sell : AuctionTypes.BidType.Buy,
            commitment: commitment,
            revealed: false,
            matched: false
        });

        // Allow contract to access encrypted values
        FHE.allowThis(encryptedAmount);
        FHE.allowThis(encryptedPrice);

        emit BidSubmitted(poolId, bidId, msg.sender);
    }

    /// @notice Reveal a previously submitted bid
    /// @param poolId The pool ID
    /// @param bidId The bid ID to reveal
    /// @param amount The plaintext amount (for commitment verification)
    /// @param price The plaintext price (for commitment verification)
    /// @param nonce The nonce used in the commitment
    function revealBid(
        PoolId poolId,
        uint256 bidId,
        uint128 amount,
        uint128 price,
        bytes32 nonce
    ) external {
        AuctionTypes.AuctionState storage auction = auctions[poolId];
        AuctionTypes.EncryptedBid storage bid = bids[poolId][bidId];

        require(auction.phase == AuctionTypes.Phase.Bidding || auction.phase == AuctionTypes.Phase.Reveal, "Invalid phase");
        require(block.timestamp >= auction.biddingEndTime, "Bidding period not ended");
        require(block.timestamp < auction.revealEndTime, "Reveal period ended");
        require(bid.bidder == msg.sender, "Not bid owner");
        require(!bid.revealed, "Bid already revealed");

        // Verify commitment
        bytes32 computedCommitment = keccak256(abi.encodePacked(amount, price, nonce, msg.sender));
        if (computedCommitment != bid.commitment) {
            revert InvalidCommitment();
        }

        bid.revealed = true;
        auction.totalRevealed++;
        revealedBidIds[poolId].push(bidId);

        emit BidRevealed(poolId, bidId, msg.sender);
    }

    /// @notice Match revealed bids and execute swaps
    /// @param poolId The pool ID
    /// @param buyBidId The buy bid ID to match
    /// @param sellBidId The sell bid ID to match
    function matchBids(
        PoolId poolId,
        uint256 buyBidId,
        uint256 sellBidId
    ) external {
        AuctionTypes.AuctionState storage auction = auctions[poolId];
        AuctionTypes.EncryptedBid storage buyBid = bids[poolId][buyBidId];
        AuctionTypes.EncryptedBid storage sellBid = bids[poolId][sellBidId];

        require(auction.phase == AuctionTypes.Phase.Reveal || block.timestamp >= auction.revealEndTime, "Not in reveal phase");
        require(buyBid.revealed && sellBid.revealed, "Bids must be revealed");
        require(!buyBid.matched && !sellBid.matched, "Bid already matched");
        require(buyBid.bidType == AuctionTypes.BidType.Buy, "First bid must be buy");
        require(sellBid.bidType == AuctionTypes.BidType.Sell, "Second bid must be sell");

        // Use FHE to compare prices without revealing them
        // Buy price must be >= sell price for a match
        euint128 buyPrice = buyBid.encryptedPrice;
        euint128 sellPrice = sellBid.encryptedPrice;
        
        // Note: In a full implementation, we'd need to decrypt and compare prices
        // For now, we'll use a simplified matching that requires manual price verification
        // In production, this would use FHE comparison operations
        
        buyBid.matched = true;
        sellBid.matched = true;
        matchedBids[poolId][buyBidId] = sellBidId;

        // Calculate clearing price (average of buy and sell prices)
        // This would be done with FHE operations in production
        // For now, we'll set a placeholder
        if (auction.clearingPrice == 0) {
            // In production, decrypt and calculate average
            auction.clearingPrice = 1; // Placeholder
        }

        emit BidsMatched(poolId, buyBidId, sellBidId, auction.clearingPrice);
    }

    /// @notice Settle the auction and transition to settled phase
    /// @param poolId The pool ID
    function settleAuction(PoolId poolId) external {
        AuctionTypes.AuctionState storage auction = auctions[poolId];
        
        require(block.timestamp >= auction.revealEndTime, "Reveal period not ended");
        require(auction.phase != AuctionTypes.Phase.Settled, "Already settled");

        auction.phase = AuctionTypes.Phase.Settled;

        emit AuctionSettled(poolId, auction.clearingPrice);
    }

    // ============ Hook Functions ============

    /// @notice Hook called before a swap
    /// @dev Can intercept swaps to process sealed bid auctions
    function _beforeSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata hookData
    ) internal override returns (bytes4, BeforeSwapDelta, uint24) {
        PoolId poolId = key.toId();
        AuctionTypes.AuctionState storage auction = auctions[poolId];

        // If auction is active and in reveal/settlement phase, process matched bids
        if (auction.phase == AuctionTypes.Phase.Reveal || auction.phase == AuctionTypes.Phase.Settled) {
            // Check if this swap is for a matched bid
            // In a full implementation, we'd check hookData for bid matching info
            // For now, allow normal swaps to proceed
        }

        // Allow normal swap to proceed
        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    /// @notice Hook called after a swap
    function _afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) internal override returns (bytes4, int128) {
        // Post-swap processing if needed
        return (BaseHook.afterSwap.selector, 0);
    }

    // ============ View Functions ============

    /// @notice Get auction state for a pool
    function getAuctionState(PoolId poolId) external view returns (AuctionTypes.AuctionState memory) {
        return auctions[poolId];
    }

    /// @notice Get bid information
    function getBid(PoolId poolId, uint256 bidId) external view returns (AuctionTypes.EncryptedBid memory) {
        return bids[poolId][bidId];
    }

    /// @notice Get revealed bid IDs for a pool
    function getRevealedBidIds(PoolId poolId) external view returns (uint256[] memory) {
        return revealedBidIds[poolId];
    }
}

