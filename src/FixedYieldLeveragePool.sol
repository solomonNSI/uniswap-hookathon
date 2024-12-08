// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {ERC6909} from "v4-core/src/ERC6909.sol";
import {CurrencySettler} from "v4-core/test/utils/CurrencySettler.sol";
import {WeightMath} from "./WeightMath.sol";

contract FixedYieldLeveragePool is BaseHook, ERC6909 {
    using PoolIdLibrary for PoolKey;
    using CurrencySettler for Currency;
    using SafeCast for *;
    using FullMath for *;

    error OperationNotSupported();
    error UnauthorizedStrategy();
    error UnauthorizedOwner();

    address public ownerAddress;
    address public strategyAddress;

    // This struct represents the state of each pool, storing:
    // - Weights and reserves of assets
    // - Principals for fixed-rate (aToken) and leveraged (xToken) providers
    // - Accumulated fees and configuration for promised APY
    // - A timestamp for tracking yield distribution intervals
    struct PoolInfo {
        uint64 assetWeightX;
        uint64 assetWeightY;
        uint256 assetReserveX;
        uint256 assetReserveY;

        uint256 principalA; // aToken principal
        uint256 principalX; // xToken principal

        uint256 accruedFeesX;
        uint256 accruedFeesY;

        uint256 targetAPY; // promised APY (scaled by 1e18)
        uint256 lastYieldDistribution;

        uint256 totalLiquidityCached;
    }

    mapping(PoolId => PoolInfo) public pools;

    modifier onlyOwner() {
        if (msg.sender != ownerAddress) revert UnauthorizedOwner();
        _;
    }

    modifier onlyStrategy() {
        if (msg.sender != strategyAddress) revert UnauthorizedStrategy();
        _;
    }

    constructor(IPoolManager _manager) BaseHook(_manager) {
        ownerAddress = msg.sender;
    }

    function setStrategy(address newStrategy) external onlyOwner {
        strategyAddress = newStrategy;
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true,
            beforeAddLiquidity: true,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: true,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // Two-token system: aToken and xToken represented via ERC6909 slots.
    // aToken slot = poolId * 2
    // xToken slot = poolId * 2 + 1
    function slotForAToken(PoolId pid) internal pure returns (uint256) {
        return uint256(PoolId.unwrap(pid)) * 2;
    }

    function slotForXToken(PoolId pid) internal pure returns (uint256) {
        return uint256(PoolId.unwrap(pid)) * 2 + 1;
    }

    struct LiquidityCallbackData {
        PoolId pid;
        int256 liquidityChange;
        uint256 maxTokenX;
        uint256 maxTokenY;
        Currency token0;
        Currency token1;
        address initiator;
    }

    function afterInitialize(address, PoolKey calldata key, uint160, int24, bytes calldata)
        external
        override
        returns (bytes4)
    {
        PoolId pid = key.toId();
        PoolInfo storage p = pools[pid];
        p.assetWeightX = 0.5 ether;
        p.assetWeightY = 0.5 ether;
        p.lastYieldDistribution = block.timestamp;
        p.targetAPY = 0.2e18; // example 20% APY

        return BaseHook.afterInitialize.selector;
    }

    // Add liquidity specifying if it's for fixed-rate (aToken) or leveraged (xToken) position
    function supplyLiquidity(PoolKey calldata key, uint256 deltaLiquidity, uint256 maxX, uint256 maxY, bool asAProvider) external {
        poolManager.unlock(
            abi.encode(
                LiquidityCallbackData(
                    key.toId(),
                    int256(deltaLiquidity),
                    maxX,
                    maxY,
                    key.currency0,
                    key.currency1,
                    msg.sender
                )
            )
        );

        PoolId pid = key.toId();
        if (asAProvider) {
            pools[pid].principalA += deltaLiquidity;
            _mint(msg.sender, slotForAToken(pid), deltaLiquidity);
        } else {
            pools[pid].principalX += deltaLiquidity;
            _mint(msg.sender, slotForXToken(pid), deltaLiquidity);
        }
    }

    // Remove liquidity from aToken or xToken holdings
    function withdrawLiquidity(PoolKey calldata key, uint256 deltaLiquidity, uint256 maxX, uint256 maxY, bool fromAProvider) external {
        PoolId pid = key.toId();
        uint256 slot = fromAProvider ? slotForAToken(pid) : slotForXToken(pid);
        _burn(msg.sender, slot, deltaLiquidity);

        if (fromAProvider) {
            pools[pid].principalA -= deltaLiquidity;
        } else {
            pools[pid].principalX -= deltaLiquidity;
        }

        poolManager.unlock(
            abi.encode(
                LiquidityCallbackData(
                    pid,
                    -int256(deltaLiquidity),
                    maxX,
                    maxY,
                    key.currency0,
                    key.currency1,
                    msg.sender
                )
            )
        );
    }

    function _unlockCallback(
        bytes calldata data
    ) internal override returns (bytes memory) {
        LiquidityCallbackData memory cb = abi.decode(data, (LiquidityCallbackData));
        PoolInfo storage p = pools[cb.pid];

        uint256 amtX;
        uint256 amtY;
        int256 liqChange = cb.liquidityChange;

        if (liqChange > 0) {
            // Add liquidity
            if (p.assetReserveX > 0 && p.assetReserveY > 0) {
                (amtX, amtY) = _amountsForLiquidity(uint256(liqChange), p);
            } else {
                // If no initial reserves, initialize with provided max amounts
                amtX = cb.maxTokenX;
                amtY = cb.maxTokenY;
                liqChange = int256(WeightMath.calcInvariant(amtX, amtY, p.assetWeightX, p.assetWeightY));
            }

            cb.token0.settle(poolManager, cb.initiator, amtX, false);
            cb.token1.settle(poolManager, cb.initiator, amtY, false);

            cb.token0.take(poolManager, address(this), amtX, true);
            cb.token1.take(poolManager, address(this), amtY, true);

            p.assetReserveX += amtX;
            p.assetReserveY += amtY;
            p.totalLiquidityCached += uint256(liqChange);

        } else {
            // Remove liquidity
            (amtX, amtY) = _amountsForLiquidity(uint256(-liqChange), p);

            cb.token0.settle(poolManager, address(this), amtX, true);
            cb.token1.settle(poolManager, address(this), amtY, true);

            cb.token0.take(poolManager, cb.initiator, amtX, false);
            cb.token1.take(poolManager, cb.initiator, amtY, false);

            p.assetReserveX -= amtX;
            p.assetReserveY -= amtY;
            p.totalLiquidityCached -= uint256(-liqChange);
        }

        return "";
    }

    function _amountsForLiquidity(uint256 liquidityUnits, PoolInfo memory p) internal pure returns (uint256 deltaX, uint256 deltaY) {
        uint256 invariantVal = WeightMath.calcInvariant(p.assetReserveX, p.assetReserveY, p.assetWeightX, p.assetWeightY);
        deltaX = p.assetReserveX.mulDiv(liquidityUnits, invariantVal);
        deltaY = p.assetReserveY.mulDiv(liquidityUnits, invariantVal);
    }

    uint256 public constant SAMPLE_FEE_NUMERATOR = 3000; 
    uint256 public constant SAMPLE_FEE_DENOMINATOR = 1_000_000;

    function beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata)
        external
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId pid = key.toId();
        PoolInfo memory p = pools[pid];

        uint256 absAmount = params.amountSpecified > 0 ? uint256(params.amountSpecified) : uint256(-params.amountSpecified);
        uint256 feePortion = (absAmount * SAMPLE_FEE_NUMERATOR) / SAMPLE_FEE_DENOMINATOR;
        uint256 tradePortion = absAmount - feePortion;

        BeforeSwapDelta swapDelta;

        if (params.zeroForOne) {
            if (params.amountSpecified > 0) revert OperationNotSupported();

            uint256 outAmt = WeightMath.calcAmountOut(
                tradePortion,
                p.assetReserveX,
                p.assetReserveY,
                p.assetWeightX,
                p.assetWeightY
            );

            p.assetReserveX += tradePortion;
            p.assetReserveY -= outAmt;
            p.accruedFeesX += feePortion;

            key.currency0.take(poolManager, address(this), absAmount, true);
            key.currency1.settle(poolManager, address(this), outAmt, true);

            swapDelta = toBeforeSwapDelta(int128(-(params.amountSpecified)), -outAmt.toInt128());
        } else {
            if (params.amountSpecified > 0) revert OperationNotSupported();

            uint256 outAmt = WeightMath.calcAmountOut(
                tradePortion,
                p.assetReserveY,
                p.assetReserveX,
                p.assetWeightX,
                p.assetWeightY
            );

            p.assetReserveY += tradePortion;
            p.assetReserveX -= outAmt;
            p.accruedFeesY += feePortion;

            key.currency1.take(poolManager, address(this), tradePortion + feePortion, true);
            key.currency0.settle(poolManager, address(this), outAmt, true);

            swapDelta = toBeforeSwapDelta(int128(-(params.amountSpecified)), -outAmt.toInt128());
        }

        pools[pid] = p;
        return (BaseHook.beforeSwap.selector, swapDelta, 0);
    }

    function afterSwap(address, PoolKey calldata, IPoolManager.SwapParams calldata, BalanceDelta, bytes calldata)
        external
        pure
        override
        returns (bytes4, int128)
    {
        return (BaseHook.afterSwap.selector, 0);
    }

    function beforeAddLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external pure override returns (bytes4) {
        revert OperationNotSupported();
    }

    function beforeRemoveLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external pure override returns (bytes4) {
        revert OperationNotSupported();
    }

    /// @notice Distribute fixed yield to aToken holders:
    /// - Compute owed interest from APY and elapsed time.
    /// - If fees cover interest, pay from fees; excess goes to xToken holders.
    /// - If fees are insufficient, xToken principal covers the deficit.
    function allocateYield(PoolKey calldata key) external {
        PoolId pid = key.toId();
        PoolInfo storage p = pools[pid];

        uint256 elapsed = block.timestamp - p.lastYieldDistribution;
        p.lastYieldDistribution = block.timestamp;

        if (p.principalA == 0) {
            // No aToken principal => no interest owed
            return;
        }

        uint256 oneYearSec = 31536000;
        uint256 interestDue = (p.principalA * p.targetAPY * elapsed) / (oneYearSec * 1e18);

        uint256 totalAvailableFees = p.accruedFeesX + p.accruedFeesY;
        p.accruedFeesX = 0;
        p.accruedFeesY = 0;

        if (totalAvailableFees >= interestDue) {
            // Sufficient fees to cover interest
            uint256 leftoverFees = totalAvailableFees - interestDue;
            p.principalX += leftoverFees; // xToken side gains extra yield
        } else {
            // Not enough fees
            uint256 shortage = interestDue - totalAvailableFees;
            if (p.principalX >= shortage) {
                p.principalX -= shortage;
            } else {
                // If xToken cannot fully cover, it might lose all principal
                p.principalX = 0;
            }
        }
    }

    // /// @notice Let the strategy address rebalance the position by removing and/or adding liquidity.
    // function performRebalance(PoolKey calldata key, uint256 removeAmount, uint256 addAmount, uint256 maxX, uint256 maxY) external onlyStrategy {
    //     PoolId pid = key.toId();
    //     if (removeAmount > 0) {
    //         poolManager.unlock(
    //             abi.encode(
    //                 LiquidityCallbackData(
    //                     pid,
    //                     -int256(removeAmount),
    //                     maxX,
    //                     maxY,
    //                     key.currency0,
    //                     key.currency1,
    //                     address(this)
    //                 )
    //             )
    //         );
    //     }
    //     if (addAmount > 0) {
    //         poolManager.unlock(
    //             abi.encode(
    //                 LiquidityCallbackData(
    //                     pid,
    //                     int256(addAmount),
    //                     maxX,
    //                     maxY,
    //                     key.currency0,
    //                     key.currency1,
    //                     address(this)
    //                 )
    //             )
    //         );
    //     }
    // }
}
