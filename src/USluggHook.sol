// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IHooks}        from "v4-core/interfaces/IHooks.sol";
import {IPoolManager}  from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey}       from "v4-core/types/PoolKey.sol";
import {BalanceDelta}  from "v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol";
import {Currency}      from "v4-core/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";

import {ISeedSource} from "./ISeedSource.sol";

/// @notice Re-rolls an on-chain seed every time the v4 PoolManager calls afterSwap.
/// Captures a small protocol fee (default 0.1%) on every swap, taken in the
/// unspecified output currency. Fee accumulates as real tokens inside the hook
/// and is withdrawable by the owner (multisig at mainnet launch).
///
/// REQUIRED ADDRESS BITS: afterSwap (1<<6) + afterSwapReturnsDelta (1<<2) = 0x44.
/// Mine via HookMiner before deploy (CREATE2 salt).
contract USluggHook is IHooks, ISeedSource {
    /// @dev Bumped each redeploy to force fresh CREATE2 bytecode → fresh address.
    uint256 public constant DEPLOY_REVISION = 1;

    IPoolManager public immutable poolManager;

    bytes32 public override currentSeed;
    uint64  public override swapCount;

    address public owner;
    /// @dev Fee in basis points (10000 = 100%). Default 10 = 0.1%. Hard-capped at 100 = 1%.
    uint16  public feeBps = 10;

    error NotPoolManager();
    error NotOwner();
    error HookNotImplemented();
    error FeeTooHigh();

    event FeeBpsSet(uint16 bps);
    event FeesWithdrawn(Currency indexed currency, address indexed to, uint256 amount);

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }
    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(IPoolManager _pm) {
        poolManager = _pm;
        owner = msg.sender;
        currentSeed = keccak256(abi.encode(block.prevrandao, block.timestamp, block.number, address(this)));
    }

    // -------- admin --------

    function setFeeBps(uint16 bps) external onlyOwner {
        if (bps > 100) revert FeeTooHigh();
        feeBps = bps;
        emit FeeBpsSet(bps);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        owner = newOwner;
    }

    /// @notice Withdraw accumulated fees. Hook holds real tokens (taken inline
    /// during afterSwap), so this is a simple transfer.
    function withdrawFees(Currency currency, address to, uint256 amount) external onlyOwner {
        if (Currency.unwrap(currency) == address(0)) {
            (bool ok, ) = to.call{value: amount}("");
            require(ok, "ETH transfer failed");
        } else {
            (bool ok, bytes memory ret) = Currency.unwrap(currency).call(
                abi.encodeWithSignature("transfer(address,uint256)", to, amount)
            );
            require(ok && (ret.length == 0 || abi.decode(ret, (bool))), "ERC20 transfer failed");
        }
        emit FeesWithdrawn(currency, to, amount);
    }

    receive() external payable {}

    // -------- hook entry point --------

    function afterSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) external override onlyPoolManager returns (bytes4, int128) {
        unchecked { swapCount++; }
        currentSeed = keccak256(
            abi.encode(currentSeed, swapCount, block.prevrandao, block.timestamp, block.number)
        );

        // Canonical Uniswap pattern (FeeTakingHook). Fee is taken on the unspecified
        // currency = the side opposite the amountSpecified argument.
        bool specifiedTokenIs0 = (params.amountSpecified < 0 == params.zeroForOne);
        (Currency feeCurrency, int128 swapAmount) = specifiedTokenIs0
            ? (key.currency1, delta.amount1())
            : (key.currency0, delta.amount0());

        // Promote to int256 before negating so |INT128_MIN| can't overflow.
        int256 absSwap = int256(swapAmount);
        if (absSwap < 0) absSwap = -absSwap;

        uint256 feeAmount = uint256(absSwap) * uint256(feeBps) / 10_000;
        if (feeAmount == 0) return (IHooks.afterSwap.selector, int128(0));

        poolManager.take(feeCurrency, address(this), feeAmount);
        return (IHooks.afterSwap.selector, _toInt128(feeAmount));
    }

    /// @dev SafeCast for fee → int128.
    function _toInt128(uint256 v) private pure returns (int128) {
        require(v <= uint128(type(int128).max), "fee too large");
        return int128(uint128(v));
    }

    // -------- disabled hooks --------

    function beforeInitialize(address, PoolKey calldata, uint160) external pure returns (bytes4) {
        revert HookNotImplemented();
    }
    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure returns (bytes4) {
        revert HookNotImplemented();
    }
    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external pure returns (bytes4) { revert HookNotImplemented(); }
    function afterAddLiquidity(
        address, PoolKey calldata, ModifyLiquidityParams calldata,
        BalanceDelta, BalanceDelta, bytes calldata
    ) external pure returns (bytes4, BalanceDelta) { revert HookNotImplemented(); }
    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external pure returns (bytes4) { revert HookNotImplemented(); }
    function afterRemoveLiquidity(
        address, PoolKey calldata, ModifyLiquidityParams calldata,
        BalanceDelta, BalanceDelta, bytes calldata
    ) external pure returns (bytes4, BalanceDelta) { revert HookNotImplemented(); }
    function beforeSwap(address, PoolKey calldata, SwapParams calldata, bytes calldata)
        external pure returns (bytes4, BeforeSwapDelta, uint24) { revert HookNotImplemented(); }
    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external pure returns (bytes4) { revert HookNotImplemented(); }
    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external pure returns (bytes4) { revert HookNotImplemented(); }
}
