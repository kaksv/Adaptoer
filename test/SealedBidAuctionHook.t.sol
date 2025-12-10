// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// Foundry Imports
import "forge-std/Test.sol";

// Uniswap Imports
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {SealedBidAuctionHook} from "../src/SealedBidAuctionHook.sol";
import {AuctionTypes} from "../src/types/AuctionTypes.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {SortTokens} from "./utils/SortTokens.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {EasyPosm} from "./utils/EasyPosm.sol";
import {Fixtures} from "./utils/Fixtures.sol";

// FHE Imports
import {FHE, InEuint128, euint128} from "@fhenixprotocol/cofhe-contracts/FHE.sol";
import {CoFheTest} from "@fhenixprotocol/cofhe-foundry-mocks/CoFheTest.sol";
import {HybridFHERC20} from "../src/HybridFHERC20.sol";
import {IFHERC20} from "../src/interface/IFHERC20.sol";

contract SealedBidAuctionHookTest is Test, Fixtures {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    // Test instance with useful utilities for testing FHE contracts locally
    CoFheTest CFT;

    SealedBidAuctionHook hook;
    PoolId poolId;

    HybridFHERC20 fheToken0;
    HybridFHERC20 fheToken1;

    Currency fheCurrency0;
    Currency fheCurrency1;

    uint256 tokenId;
    int24 tickLower;
    int24 tickUpper;

    address private alice = makeAddr("alice");
    address private bob = makeAddr("bob");
    address private charlie = makeAddr("charlie");

    function setUp() public {
        // Initialize new CoFheTest instance with logging turned off
        CFT = new CoFheTest(false);

        bytes memory token0Args = abi.encode("TOKEN0", "TOK0");
        deployCodeTo("HybridFHERC20.sol:HybridFHERC20", token0Args, address(123));

        bytes memory token1Args = abi.encode("TOKEN1", "TOK1");
        deployCodeTo("HybridFHERC20.sol:HybridFHERC20", token1Args, address(456));

        fheToken0 = HybridFHERC20(address(123));
        fheToken1 = HybridFHERC20(address(456)); // Ensure address token1 always > address token0

        vm.label(alice, "alice");
        vm.label(bob, "bob");
        vm.label(charlie, "charlie");
        vm.label(address(this), "test");
        vm.label(address(fheToken0), "token0");
        vm.label(address(fheToken1), "token1");

        // Creates the pool manager, utility routers, and test tokens
        deployFreshManagerAndRouters();

        vm.startPrank(alice);
        (fheCurrency0, fheCurrency1) = mintAndApprove2Currencies(address(fheToken0), address(fheToken1));
        deployAndApprovePosm(manager);
        vm.stopPrank();

        // Deploy the hook to an address with the correct flags
        address flags = address(
            uint160(
                Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
            ) ^ (0x4444 << 144) // Namespace the hook to avoid collisions
        );
        bytes memory constructorArgs = abi.encode(manager);
        deployCodeTo("SealedBidAuctionHook.sol:SealedBidAuctionHook", constructorArgs, flags);
        hook = SealedBidAuctionHook(flags);

        vm.label(address(hook), "hook");
        vm.label(address(this), "test");

        // Create the pool
        key = PoolKey(currency0, currency1, 3000, 60, IHooks(hook));
        poolId = key.toId();
        manager.initialize(key, SQRT_PRICE_1_1);

        // Provide full-range liquidity to the pool
        tickLower = TickMath.minUsableTick(key.tickSpacing);
        tickUpper = TickMath.maxUsableTick(key.tickSpacing);

        uint128 liquidityAmount = 100e18;

        (uint256 amount0Expected, uint256 amount1Expected) = LiquidityAmounts.getAmountsForLiquidity(
            SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            liquidityAmount
        );

        vm.startPrank(alice);
        (tokenId,) = posm.mint(
            key,
            tickLower,
            tickUpper,
            liquidityAmount,
            amount0Expected + 1,
            amount1Expected + 1,
            address(this),
            block.timestamp,
            ZERO_BYTES
        );
        vm.stopPrank();

        // Mint tokens for bob and charlie
        vm.startPrank(bob);
        (fheCurrency0, fheCurrency1) = mintAndApprove2Currencies(address(fheToken0), address(fheToken1));
        vm.stopPrank();

        vm.startPrank(charlie);
        (fheCurrency0, fheCurrency1) = mintAndApprove2Currencies(address(fheToken0), address(fheToken1));
        vm.stopPrank();
    }

    function testStartAuction() public {
        vm.prank(alice);
        hook.startAuction(poolId);

        AuctionTypes.AuctionState memory auction = hook.getAuctionState(poolId);
        assertEq(uint256(auction.phase), uint256(AuctionTypes.Phase.Bidding));
        assertGt(auction.biddingEndTime, block.timestamp);
    }

    function testSubmitBid() public {
        // Start auction
        hook.startAuction(poolId);

        // Alice wants to buy 100 Token1 at max price 1.1 Token0 per Token1
        uint128 amount = 100e18;
        uint128 price = 1.1e18; // 1.1 Token0 per Token1
        bytes32 nonce = keccak256("alice-nonce-1");
        bytes32 commitment = keccak256(abi.encodePacked(amount, price, nonce, alice));

        // Encrypt the bid
        InEuint128 memory encryptedAmount = CFT.createInEuint128(amount, alice);
        InEuint128 memory encryptedPrice = CFT.createInEuint128(price, alice);

        vm.startPrank(alice);
        uint256 bidId = hook.submitBid(
            poolId,
            FHE.asEuint128(encryptedAmount),
            FHE.asEuint128(encryptedPrice),
            false, // zeroForOne = false (buying token1 with token0)
            commitment
        );
        vm.stopPrank();

        assertEq(bidId, 0);
        
        AuctionTypes.EncryptedBid memory bid = hook.getBid(poolId, bidId);
        assertEq(bid.bidder, alice);
        assertEq(bid.bidType, AuctionTypes.BidType.Buy);
        assertFalse(bid.revealed);
        assertFalse(bid.matched);
    }

    function testRevealBid() public {
        // Start auction
        hook.startAuction(poolId);

        // Submit bid
        uint128 amount = 100e18;
        uint128 price = 1.1e18;
        bytes32 nonce = keccak256("alice-nonce-1");
        bytes32 commitment = keccak256(abi.encodePacked(amount, price, nonce, alice));

        InEuint128 memory encryptedAmount = CFT.createInEuint128(amount, alice);
        InEuint128 memory encryptedPrice = CFT.createInEuint128(price, alice);

        vm.startPrank(alice);
        uint256 bidId = hook.submitBid(
            poolId,
            FHE.asEuint128(encryptedAmount),
            FHE.asEuint128(encryptedPrice),
            false,
            commitment
        );
        vm.stopPrank();

        // Fast forward past bidding period
        vm.warp(block.timestamp + 1 hours + 1);

        // Reveal bid
        vm.prank(alice);
        hook.revealBid(poolId, bidId, amount, price, nonce);

        AuctionTypes.EncryptedBid memory bid = hook.getBid(poolId, bidId);
        assertTrue(bid.revealed);
    }

    function testMatchBids() public {
        // Start auction
        hook.startAuction(poolId);

        // Alice submits buy bid: 100 Token1 @ max 1.1 Token0
        uint128 aliceAmount = 100e18;
        uint128 alicePrice = 1.1e18;
        bytes32 aliceNonce = keccak256("alice-nonce-1");
        bytes32 aliceCommitment = keccak256(abi.encodePacked(aliceAmount, alicePrice, aliceNonce, alice));

        InEuint128 memory aliceEncryptedAmount = CFT.createInEuint128(aliceAmount, alice);
        InEuint128 memory aliceEncryptedPrice = CFT.createInEuint128(alicePrice, alice);

        vm.startPrank(alice);
        uint256 aliceBidId = hook.submitBid(
            poolId,
            FHE.asEuint128(aliceEncryptedAmount),
            FHE.asEuint128(aliceEncryptedPrice),
            false, // Buy
            aliceCommitment
        );
        vm.stopPrank();

        // Bob submits sell bid: 50 Token1 @ min 1.05 Token0
        uint128 bobAmount = 50e18;
        uint128 bobPrice = 1.05e18;
        bytes32 bobNonce = keccak256("bob-nonce-1");
        bytes32 bobCommitment = keccak256(abi.encodePacked(bobAmount, bobPrice, bobNonce, bob));

        InEuint128 memory bobEncryptedAmount = CFT.createInEuint128(bobAmount, bob);
        InEuint128 memory bobEncryptedPrice = CFT.createInEuint128(bobPrice, bob);

        vm.startPrank(bob);
        uint256 bobBidId = hook.submitBid(
            poolId,
            FHE.asEuint128(bobEncryptedAmount),
            FHE.asEuint128(bobEncryptedPrice),
            true, // Sell
            bobCommitment
        );
        vm.stopPrank();

        // Fast forward past bidding period
        vm.warp(block.timestamp + 1 hours + 1);

        // Reveal bids
        vm.prank(alice);
        hook.revealBid(poolId, aliceBidId, aliceAmount, alicePrice, aliceNonce);

        vm.prank(bob);
        hook.revealBid(poolId, bobBidId, bobAmount, bobPrice, bobNonce);

        // Match bids
        hook.matchBids(poolId, aliceBidId, bobBidId);

        AuctionTypes.EncryptedBid memory aliceBid = hook.getBid(poolId, aliceBidId);
        AuctionTypes.EncryptedBid memory bobBid = hook.getBid(poolId, bobBidId);

        assertTrue(aliceBid.matched);
        assertTrue(bobBid.matched);
    }

    function testSettleAuction() public {
        // Start auction
        hook.startAuction(poolId);

        // Fast forward past reveal period
        vm.warp(block.timestamp + 1 hours + 30 minutes + 1);

        // Settle auction
        hook.settleAuction(poolId);

        AuctionTypes.AuctionState memory auction = hook.getAuctionState(poolId);
        assertEq(uint256(auction.phase), uint256(AuctionTypes.Phase.Settled));
    }

    function testInvalidCommitment() public {
        hook.startAuction(poolId);

        uint128 amount = 100e18;
        uint128 price = 1.1e18;
        bytes32 nonce = keccak256("alice-nonce-1");
        bytes32 commitment = keccak256(abi.encodePacked(amount, price, nonce, alice));

        InEuint128 memory encryptedAmount = CFT.createInEuint128(amount, alice);
        InEuint128 memory encryptedPrice = CFT.createInEuint128(price, alice);

        vm.startPrank(alice);
        uint256 bidId = hook.submitBid(
            poolId,
            FHE.asEuint128(encryptedAmount),
            FHE.asEuint128(encryptedPrice),
            false,
            commitment
        );
        vm.stopPrank();

        // Fast forward past bidding period
        vm.warp(block.timestamp + 1 hours + 1);

        // Try to reveal with wrong values
        vm.prank(alice);
        vm.expectRevert(SealedBidAuctionHook.InvalidCommitment.selector);
        hook.revealBid(poolId, bidId, amount + 1, price, nonce); // Wrong amount
    }

    //
    // Helper Functions
    //
    function mintAndApprove2Currencies(address tokenA, address tokenB) internal returns (Currency, Currency) {
        Currency _currencyA = mintAndApproveCurrency(tokenA);
        Currency _currencyB = mintAndApproveCurrency(tokenB);

        (currency0, currency1) = SortTokens.sort(Currency.unwrap(_currencyA), Currency.unwrap(_currencyB));
        return (currency0, currency1);
    }

    function mintAndApproveCurrency(address token) internal returns (Currency currency) {
        IFHERC20(token).mint(msg.sender, 2 ** 250);
        IFHERC20(token).mint(address(this), 2 ** 250);

        InEuint128 memory amountUser = CFT.createInEuint128(2 ** 120, msg.sender);
        IFHERC20(token).mintEncrypted(msg.sender, amountUser);

        address[9] memory toApprove = [
            address(swapRouter),
            address(swapRouterNoChecks),
            address(modifyLiquidityRouter),
            address(modifyLiquidityNoChecks),
            address(donateRouter),
            address(takeRouter),
            address(claimsRouter),
            address(nestedActionRouter.executor()),
            address(actionsRouter)
        ];

        for (uint256 i = 0; i < toApprove.length; i++) {
            IFHERC20(token).approve(toApprove[i], Constants.MAX_UINT256);
        }

        return Currency.wrap(token);
    }
}

