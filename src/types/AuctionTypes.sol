// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {euint128} from "@fhenixprotocol/cofhe-contracts/FHE.sol";

/// @title AuctionTypes
/// @notice Type definitions for sealed bid auction system
library AuctionTypes {
    /// @notice Auction phase enum
    enum Phase {
        Bidding,    // Users can submit encrypted bids
        Reveal,     // Users reveal their bids
        Settled     // Auction is complete
    }

    /// @notice Bid type enum
    enum BidType {
        Buy,  // Buying output token (zeroForOne = false)
        Sell  // Selling input token (zeroForOne = true)
    }

    /// @notice Auction state structure
    struct AuctionState {
        Phase phase;
        uint256 biddingEndTime;
        uint256 revealEndTime;
        uint256 totalBids;
        uint256 totalRevealed;
        uint256 clearingPrice; // Decrypted clearing price after settlement
    }

    /// @notice Encrypted bid structure
    struct EncryptedBid {
        address bidder;
        euint128 encryptedAmount;
        euint128 encryptedPrice;
        BidType bidType;
        bytes32 commitment; // Hash of (amount, price, nonce)
        bool revealed;
        bool matched;
    }
}

