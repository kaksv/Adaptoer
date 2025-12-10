// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolDonateTest} from "@uniswap/v4-core/src/test/PoolDonateTest.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Constants} from "@uniswap/v4-core/src/../test/utils/Constants.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SealedBidAuctionHook} from "../src/SealedBidAuctionHook.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {PositionManager} from "v4-periphery/src/PositionManager.sol";
import {EasyPosm} from "../test/utils/EasyPosm.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {DeployPermit2} from "../test/utils/forks/DeployPermit2.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IPositionDescriptor} from "v4-periphery/src/interfaces/IPositionDescriptor.sol";
import {IWETH9} from "v4-periphery/src/interfaces/external/IWETH9.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

/// @notice Comprehensive deployment script for Sealed Bid Auction Hook
/// @dev Supports deployment to Anvil (local), testnets, and mainnet
/// 
/// Usage:
///   forge script script/DeploySealedBidAuction.s.sol:SealedBidAuctionScript --rpc-url <RPC_URL> --broadcast
///
/// Environment Variables (optional):
///   DEPLOY_POOL_MANAGER=true    - Deploy new PoolManager (default: true)
///   DEPLOY_POSM=true            - Deploy PositionManager (default: true)
///   DEPLOY_ROUTERS=true         - Deploy test routers (default: true)
///   CREATE_POOL=true            - Create test pool (default: true)
///   ADD_LIQUIDITY=true          - Add liquidity to pool (default: true)
///   START_AUCTION=true          - Start auction after setup (default: true)
///   POOL_MANAGER_ADDRESS=0x...  - Use existing PoolManager (if DEPLOY_POOL_MANAGER=false)
contract SealedBidAuctionScript is Script, DeployPermit2 {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;

    address constant CREATE2_DEPLOYER = address(0x4e59b44847b379578588920cA78FbF26c0B4956C);
    
    // Deployment addresses
    IPoolManager public manager;
    SealedBidAuctionHook public hook;
    IPositionManager public posm;
    PoolModifyLiquidityTest public lpRouter;
    PoolSwapTest public swapRouter;
    
    // Configuration
    bool public deployPoolManager = true;
    bool public deployPosm = true;
    bool public deployRouters = true;
    bool public createPool = true;
    bool public addLiquidity = true;
    bool public startAuction = true;

    function setUp() public {
        // Read configuration from environment or use defaults
        deployPoolManager = vm.envOr("DEPLOY_POOL_MANAGER", true);
        deployPosm = vm.envOr("DEPLOY_POSM", true);
        deployRouters = vm.envOr("DEPLOY_ROUTERS", true);
        createPool = vm.envOr("CREATE_POOL", true);
        addLiquidity = vm.envOr("ADD_LIQUIDITY", true);
        startAuction = vm.envOr("START_AUCTION", true);
    }

    /// @notice Main deployment function
    /// @dev Deploys hook, pool manager, and optionally sets up a test pool
    function run() public {
        console.log("=== Sealed Bid Auction Hook Deployment ===");
        console.log("Deployer:", msg.sender);
        console.log("Chain ID:", block.chainid);
        
        // Step 1: Deploy Pool Manager (if needed)
        if (deployPoolManager) {
            deployPoolManagerContract();
        } else {
            // Use existing pool manager from environment
            manager = IPoolManager(vm.envAddress("POOL_MANAGER_ADDRESS"));
            console.log("Using existing PoolManager at:", address(manager));
        }

        // Step 2: Deploy Hook
        deployHook();

        // Step 3: Deploy Position Manager and Routers (if needed)
        if (deployPosm || deployRouters) {
            deploySupportingContracts();
        }

        // Step 4: Create pool and setup (optional, for testing)
        if (createPool) {
            setupTestPool();
        }

        // Print summary
        printDeploymentSummary();
    }

    /// @notice Deploy the Pool Manager contract
    function deployPoolManagerContract() internal {
        console.log("\n--- Deploying Pool Manager ---");
        vm.broadcast();
        manager = IPoolManager(address(new PoolManager(address(0))));
        console.log("PoolManager deployed at:", address(manager));
    }

    /// @notice Deploy the Sealed Bid Auction Hook
    function deployHook() internal {
        console.log("\n--- Deploying Sealed Bid Auction Hook ---");
        
        // Hook contracts must have specific flags encoded in the address
        uint160 permissions = uint160(
            Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
        );

        console.log("Mining salt for hook address...");
        // Mine a salt that will produce a hook address with the correct permissions
        (address hookAddress, bytes32 salt) = HookMiner.find(
            CREATE2_DEPLOYER,
            permissions,
            type(SealedBidAuctionHook).creationCode,
            abi.encode(address(manager))
        );

        console.log("Expected hook address:", hookAddress);
        console.log("Salt:", vm.toString(salt));

        // Deploy the hook using CREATE2
        vm.broadcast();
        hook = new SealedBidAuctionHook{salt: salt}(manager);
        
        require(address(hook) == hookAddress, "Hook address mismatch");
        console.log("SealedBidAuctionHook deployed at:", address(hook));
        
        // Verify hook permissions
        Hooks.Permissions memory perms = hook.getHookPermissions();
        require(perms.beforeSwap == true, "beforeSwap not enabled");
        require(perms.afterSwap == true, "afterSwap not enabled");
        console.log("Hook permissions verified");
    }

    /// @notice Deploy supporting contracts (Position Manager and Routers)
    function deploySupportingContracts() internal {
        console.log("\n--- Deploying Supporting Contracts ---");
        
        if (deployPosm) {
            vm.broadcast();
            posm = deployPosmContract(manager);
            console.log("PositionManager deployed at:", address(posm));
        }

        if (deployRouters) {
            vm.broadcast();
            (lpRouter, swapRouter,) = deployRouters(manager);
            console.log("Liquidity Router deployed at:", address(lpRouter));
            console.log("Swap Router deployed at:", address(swapRouter));
        }
    }

    /// @notice Setup a test pool with liquidity (for testing purposes)
    function setupTestPool() internal {
        console.log("\n--- Setting up Test Pool ---");
        
        (MockERC20 token0, MockERC20 token1) = deployTokens();
        console.log("Token0 deployed at:", address(token0));
        console.log("Token1 deployed at:", address(token1));

        // Mint tokens to deployer
        token0.mint(msg.sender, 100_000 ether);
        token1.mint(msg.sender, 100_000 ether);
        console.log("Tokens minted to deployer");

        // Initialize the pool
        int24 tickSpacing = 60;
        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 3000,
            tickSpacing: tickSpacing,
            hooks: IHooks(address(hook))
        });
        
        vm.broadcast();
        manager.initialize(poolKey, Constants.SQRT_PRICE_1_1);
        console.log("Pool initialized");

        // Approve tokens
        if (deployRouters) {
            token0.approve(address(lpRouter), type(uint256).max);
            token1.approve(address(lpRouter), type(uint256).max);
            token0.approve(address(swapRouter), type(uint256).max);
            token1.approve(address(swapRouter), type(uint256).max);
        }
        
        if (deployPosm) {
            approvePosmCurrency(posm, Currency.wrap(address(token0)));
            approvePosmCurrency(posm, Currency.wrap(address(token1)));
        }

        // Add liquidity if requested
        if (addLiquidity) {
            int24 tickLower = TickMath.minUsableTick(tickSpacing);
            int24 tickUpper = TickMath.maxUsableTick(tickSpacing);
            addLiquidityToPool(poolKey, tickLower, tickUpper);
            console.log("Liquidity added to pool");
        }

        // Start auction if requested
        if (startAuction) {
            vm.broadcast();
            PoolId poolId = poolKey.toId();
            hook.startAuction(poolId);
            console.log("Auction started for pool");
        }
    }

    /// @notice Print deployment summary
    function printDeploymentSummary() internal view {
        console.log("\n=== Deployment Summary ===");
        console.log("PoolManager:", address(manager));
        console.log("SealedBidAuctionHook:", address(hook));
        if (deployPosm) {
            console.log("PositionManager:", address(posm));
        }
        if (deployRouters) {
            console.log("LiquidityRouter:", address(lpRouter));
            console.log("SwapRouter:", address(swapRouter));
        }
        console.log("========================\n");
    }

    // -----------------------------------------------------------
    // Helper Functions
    // -----------------------------------------------------------

    function deployRouters(IPoolManager _manager)
        internal
        returns (PoolModifyLiquidityTest _lpRouter, PoolSwapTest _swapRouter, PoolDonateTest _donateRouter)
    {
        _lpRouter = new PoolModifyLiquidityTest(_manager);
        _swapRouter = new PoolSwapTest(_manager);
        _donateRouter = new PoolDonateTest(_manager);
    }

    function deployPosmContract(IPoolManager poolManager) internal returns (IPositionManager) {
        // Deploy Permit2 if on Anvil (local testing)
        if (block.chainid == 31337 || block.chainid == 1) {
            anvilPermit2();
        }
        return IPositionManager(
            new PositionManager(poolManager, permit2, 300_000, IPositionDescriptor(address(0)), IWETH9(address(0)))
        );
    }

    function approvePosmCurrency(IPositionManager _posm, Currency currency) internal {
        // Because POSM uses permit2, we must execute 2 permits/approvals.
        // 1. First, the caller must approve permit2 on the token.
        IERC20(Currency.unwrap(currency)).approve(address(permit2), type(uint256).max);
        // 2. Then, the caller must approve POSM as a spender of permit2
        permit2.approve(Currency.unwrap(currency), address(_posm), type(uint160).max, type(uint48).max);
    }

    function deployTokens() internal returns (MockERC20 token0, MockERC20 token1) {
        MockERC20 tokenA = new MockERC20("MockA", "A", 18);
        MockERC20 tokenB = new MockERC20("MockB", "B", 18);
        if (uint160(address(tokenA)) < uint160(address(tokenB))) {
            token0 = tokenA;
            token1 = tokenB;
        } else {
            token0 = tokenB;
            token1 = tokenA;
        }
    }

    function addLiquidityToPool(PoolKey memory poolKey, int24 tickLower, int24 tickUpper) internal {
        // Add liquidity using router if available
        if (address(lpRouter) != address(0)) {
            ModifyLiquidityParams memory liqParams =
                ModifyLiquidityParams(tickLower, tickUpper, 100 ether, 0);
            lpRouter.modifyLiquidity(poolKey, liqParams, "");
        }

        // Add liquidity using Position Manager if available
        if (address(posm) != address(0)) {
            posm.mint(
                poolKey,
                tickLower,
                tickUpper,
                100e18,
                10_000e18,
                10_000e18,
                msg.sender,
                block.timestamp + 300,
                ""
            );
        }
    }
}

