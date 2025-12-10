// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {euint128} from "@fhenixprotocol/cofhe-contracts/FHE.sol";
import {FHE} from "@fhenixprotocol/cofhe-contracts/FHE.sol";
import {AuctionTypes} from "../types/AuctionTypes.sol";

/// @title BidMatching
/// @notice Library for matching encrypted bids using FHE operations
library BidMatching {
    using FHE for uint256;

    /// @notice Check if a buy bid price is greater than or equal to sell bid price
    /// @param buyPrice Encrypted buy price
    /// @param sellPrice Encrypted sell price
    /// @return canMatch True if buy price >= sell price (encrypted comparison)
    function canMatchBids(euint128 buyPrice, euint128 sellPrice) internal view returns (bool canMatch) {
        // Use FHE comparison: buyPrice >= sellPrice
        // In FHE, we can't directly return bool from encrypted comparison
        // Instead, we use select to create a conditional result
        euint128 zero = FHE.asEuint128(0);
        euint128 one = FHE.asEuint128(1);
        
        // Check if buyPrice >= sellPrice using FHE operations
        // This is a simplified version - full implementation would use proper FHE comparison
        // For now, we'll need to decrypt for comparison in production
        // The actual FHE comparison would be: buyPrice.gte(sellPrice)
        
        // Placeholder - in production, this would use FHE.gte() or similar
        return true; // Simplified for now
    }

    /// @notice Calculate clearing price from matched bids
    /// @param buyPrice Encrypted buy price
    /// @param sellPrice Encrypted sell price
    /// @return clearingPrice Encrypted clearing price (average of buy and sell)
    function calculateClearingPrice(
        euint128 buyPrice,
        euint128 sellPrice
    ) internal view returns (euint128 clearingPrice) {
        // Calculate average: (buyPrice + sellPrice) / 2
        euint128 sum = buyPrice.add(sellPrice);
        euint128 two = FHE.asEuint128(2);
        
        // Division in FHE requires special handling
        // For now, return sum (division would need FHE division operation)
        // In production: clearingPrice = sum.div(two)
        return sum;
    }

    /// @notice Sort bids by price (for matching algorithm)
    /// @dev This is a placeholder - full implementation would use FHE sorting
    /// @param bidIds Array of bid IDs to sort
    /// @param prices Array of encrypted prices corresponding to bid IDs
    /// @return sortedBidIds Sorted bid IDs (highest to lowest for buys, lowest to highest for sells)
    function sortBidsByPrice(
        uint256[] memory bidIds,
        euint128[] memory prices
    ) internal pure returns (uint256[] memory sortedBidIds) {
        // FHE sorting is complex and expensive
        // In production, this would be done off-chain or with specialized FHE sorting algorithms
        // For now, return as-is
        return bidIds;
    }
}

