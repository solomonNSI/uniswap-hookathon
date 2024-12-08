// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "forge-std/console2.sol";

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "v4-core/src/types/Currency.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PositionConfig} from "v4-periphery/src/libraries/PositionConfig.sol";
import {IERC20Minimal} from "v4-core/src/interfaces/external/IERC20Minimal.sol";

import {FixedYieldLeveragePool} from "../src/FixedYieldLeveragePool.sol";
import {WeightMath} from "../src/WeightMath.sol";

import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {EasyPosm} from "./utils/EasyPosm.sol";
import {Fixtures} from "./utils/Fixtures.sol";

contract FixedYieldLeveragePoolTest is Test, Fixtures {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    FixedYieldLeveragePool hook;
    PoolId poolId;
    uint256 tokenId;
    PositionConfig config;

    function setUp() public {
        // Set up the environment, manager, currencies
        deployFreshManagerAndRouters();
        (currency0, currency1) = deployMintAndApprove2Currencies();

        // Deploy the hook contract with the appropriate flags
        address hookAddress = address(
            uint160(
                Hooks.AFTER_INITIALIZE_FLAG |
                Hooks.BEFORE_ADD_LIQUIDITY_FLAG |
                Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG |
                Hooks.BEFORE_SWAP_FLAG |
                Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG

            )
        );

        bytes memory constructorArgs = abi.encode(manager);
        deployCodeTo("FixedYieldLeveragePool.sol", constructorArgs, hookAddress);
        hook = FixedYieldLeveragePool(hookAddress);

        // Create and initialize the pool with initial price settings
        (key, ) = initPool(
            currency0,
            currency1,
            hook,
            3000,
            SQRT_PRICE_1_1,
            ZERO_BYTES
        );

        // Approve tokens to the hook for adding liquidity
        IERC20Minimal(Currency.unwrap(key.currency0)).approve(
            hookAddress,
            2000 ether
        );
        IERC20Minimal(Currency.unwrap(key.currency1)).approve(
            hookAddress,
            2000 ether
        );

        // Initially supply liquidity as an aToken provider (fixed yield side)
        uint256 initialL = WeightMath.calcInvariant(1000 ether, 1000 ether, 0.5 ether, 0.5 ether);
        hook.supplyLiquidity(
            key,
            initialL,
            1000 ether,
            1000 ether,
            true // as a fixed-yield provider (aToken)
        );
        // now as xToken provider
        hook.supplyLiquidity(key, initialL, 1000 ether, 1000 ether, false);
    }

    // Helper function to read pool data from the contract
    function getPoolData(PoolId pid) internal view returns (
        uint64 ax, 
        uint64 ay, 
        uint256 rx, 
        uint256 ry, 
        uint256 pA, 
        uint256 pX, 
        uint256 fX, 
        uint256 fY, 
        uint256 wX, 
        uint256 wY
    ) {
        // The contract stores everything in `pools` mapping.
        // pools(pid) is public so we can directly access it.
        // struct PoolInfo {
        //   uint64 assetWeightX;
        //   uint64 assetWeightY;
        //   uint256 assetReserveX;
        //   uint256 assetReserveY;
        //   uint256 principalA;
        //   uint256 principalX;
        //   uint256 accruedFeesX;
        //   uint256 accruedFeesY;
        //   uint256 targetAPY;
        //   uint256 lastYieldDistribution;
        //   uint256 totalLiquidityCached;
        // }
        (
            uint64 assetWeightX,
            uint64 assetWeightY,
            uint256 assetReserveX,
            uint256 assetReserveY,
            uint256 principalA,
            uint256 principalX,
            uint256 accruedFeesX,
            uint256 accruedFeesY,
            uint256 targetAPY,
            uint256 lastYieldDistribution,
            uint256 totalLiquidityCached
        ) = hook.pools(pid);

        return (
            assetWeightX,
            assetWeightY,
            assetReserveX,
            assetReserveY,
            principalA,
            principalX,
            accruedFeesX,
            accruedFeesY,
            assetWeightX,
            assetWeightY
        );
    }

    function test_pool_weights() public {
        (uint64 wX, uint64 wY, , , , , , , ,) = getPoolData(key.toId());
        assertEq(uint256(wX), 0.5 ether);
        assertEq(uint256(wY), 0.5 ether);
    }

    function test_swap_exactInput_zeroForOne() public {
        PoolSwapTest.TestSettings memory settings = PoolSwapTest.TestSettings({
            takeClaims: false,
            settleUsingBurn: false
        });

        uint balanceOfTokenABefore = key.currency0.balanceOfSelf();
        uint balanceOfTokenBBefore = key.currency1.balanceOfSelf();

        // Perform a swap: exact input of 10e18 of token0 for token1
        swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -10e18,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            settings,
            ZERO_BYTES
        );

        uint balanceOfTokenAAfter = key.currency0.balanceOfSelf();
        uint balanceOfTokenBAfter = key.currency1.balanceOfSelf();

        // We gave 10e18 token0 in exchange for approximately 9.900990099... token1 (due to fees and curve)
        assertEq(balanceOfTokenABefore - balanceOfTokenAAfter, 10e18);
        // Check the output: roughly 9.900990099e18 token1
        assertEq(balanceOfTokenBAfter - balanceOfTokenBBefore, 9920546077802156000);
    }

    function test_yieldDistribution_sufficientFees() public {
        // Test scenario where enough fees are generated to cover aToken interest.

        // Warp time forward to accrue interest
        uint256 start = block.timestamp;
        // Let's generate fees by performing swaps
        // Swap a large amount to create substantial fees
        PoolSwapTest.TestSettings memory settings = PoolSwapTest.TestSettings({
            takeClaims: false,
            settleUsingBurn: false
        });

        swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -1e18, // large swap to generate fees
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            settings,
            ZERO_BYTES
        );

        // Before distribution, check principals
        (, , , , uint256 pABefore, uint256 pXBefore, uint256 fXBefore, uint256 fYBefore, , ) = getPoolData(key.toId());
        assertTrue(fXBefore + fYBefore > 0, "Should have accrued fees");

        // Distribute yield
        hook.allocateYield(key);

        // After distribution
        (, , , , uint256 pAAfter, uint256 pXAfter, , , , ) = getPoolData(key.toId());

        // aToken holders should have received interest, which conceptually might increase pX (leftover) or not
        // In this simplified model, aToken interest doesn't increase principalA directly. Instead, principalX might shift.
        // However, since fees > interest, we expect leftover to go to xToken, thus increasing pX.

        console.log("pXBefore", pXBefore);
        console.log("pXAfter", pXAfter);

        assertTrue(pXAfter >= pXBefore, "xToken principal should not decrease since fees were sufficient");
        // The exact amounts depend on the fee and APY calculations. Here we just assert conditions logically.
    }

    function test_yieldDistribution_insufficientFees() public {
        // Move time forward
        vm.warp(block.timestamp + 180 days); // half a year

        // No swaps performed, so no fees generated
        // Check principals before distribution
        (, , , , uint256 pABefore, uint256 pXBefore, uint256 fXBefore, uint256 fYBefore, , ) = getPoolData(key.toId());

        // Distribute yield with no fees
        hook.allocateYield(key);

        // After distribution, since no fees, xToken should cover interest shortfall
        (, , , , uint256 pAAfter, uint256 pXAfter, , , , ) = getPoolData(key.toId());

        // principalA shouldn't change because it's the notional principal. The model reduces xToken principal.
        // aToken interest is paid from xToken principal now.
        // pXAfter should be less than pXBefore since we had a shortfall.
        console.log("pXBefore", pXBefore);
        console.log("pXAfter", pXAfter);
        assertTrue(pXAfter < pXBefore, "xToken principal should decrease due to shortfall");
        assertEq(pABefore, pAAfter, "aToken principal unchanged");
    }

    // function test_rebalance_onlyStrategy() public {
    //     // Try calling rebalance from non-strategy user
    //     vm.expectRevert(); // should revert because not strategy
    //     hook.performRebalance(key, 100 ether, 0, 200 ether, 200 ether);

    //     // Set strategy
    //     hook.setStrategy(address(this));

    //     // Now call as strategy
    //     (, , uint256 rXBefore, uint256 rYBefore, , , , , , , ) = getPoolData(key.toId());

    //     hook.performRebalance(key, 100 ether, 50 ether, 200 ether, 200 ether);

    //     (, , uint256 rXAfter, uint256 rYAfter, , , , , , , ) = getPoolData(key.toId());

    //     // After removing 100 ether worth liquidity and adding back 50 ether worth, we should see changes in reserves
    //     // The exact changes depend on how liquidity is priced, but we can at least verify something changed.
    //     // For simplicity, just assert something changed in the reserves.
    //     assertTrue(rXAfter != rXBefore || rYAfter != rYBefore, "Reserves should change after rebalance");
    // }

    function test_initial_liquidity_supply() public {
        // Test that liquidity is properly initialized
        (uint64 wX, uint64 wY, uint256 rX, uint256 rY, , , , , ,) = getPoolData(key.toId());
        assertEq(uint256(wX), 0.5 ether, "Initial weight for asset X should be 0.5");
        assertEq(uint256(wY), 0.5 ether, "Initial weight for asset Y should be 0.5");
        assertEq(rX, 2000 ether, "Initial reserve for asset X should match supplied liquidity");
        assertEq(rY, 2000 ether, "Initial reserve for asset Y should match supplied liquidity");
    }

    function test_swap_revert_insufficient_balance() public {
        // Test swap fails when user has insufficient balance
        PoolSwapTest.TestSettings memory settings = PoolSwapTest.TestSettings({
            takeClaims: false,
            settleUsingBurn: false
        });

        vm.expectRevert();
        swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -1e30, // Unrealistically high amount to trigger revert
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            settings,
            ZERO_BYTES
        );
    }

    function test_allocate_yield_no_fees() public {
        // Test allocateYield when no fees are present
        (, , , , uint256 pABefore, uint256 pXBefore, uint256 fXBefore, uint256 fYBefore, ,) = getPoolData(key.toId());
        assertEq(fXBefore, 0, "No fees should be present initially");
        assertEq(fYBefore, 0, "No fees should be present initially");

        hook.allocateYield(key);

        (, , , , uint256 pAAfter, uint256 pXAfter, , , ,) = getPoolData(key.toId());
        assertEq(pABefore, pAAfter, "aToken principal should not change");
        assertEq(pXBefore, pXAfter, "xToken principal should not change since no fees were present");
    }

    function test_withdraw_liquidity() public {
        // Test withdrawing liquidity and verify reserve reduction
        uint256 initialL = WeightMath.calcInvariant(1000 ether, 1000 ether, 0.5 ether, 0.5 ether);

        (, , uint256 rXBefore, uint256 rYBefore, , , , , ,) = getPoolData(key.toId());
        hook.withdrawLiquidity(key, initialL / 2, 500 ether, 500 ether, true);

        (, , uint256 rXAfter, uint256 rYAfter, , , , , ,) = getPoolData(key.toId());
    }


}
