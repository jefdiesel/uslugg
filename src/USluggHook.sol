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

/// @notice Captures a small protocol fee (default 0.1%) on every swap, taken in
/// the unspecified output currency. Fee accumulates as real tokens inside the
/// hook and is withdrawable by the owner (multisig at mainnet launch).
///
/// Sets a transient `swapFiredThisTx` flag so USlugg404._move knows that
/// receive-side auto-minting is allowed in this tx (the only path that should
/// auto-mint sluggs is a swap through the locked pool).
///
/// NOTE on randomness: this hook is intentionally NOT a randomness oracle.
/// Earlier versions mixed `block.prevrandao` into a `currentSeed` here — that
/// is predictable to block builders and exposed mints to MEV grinding.
/// Post-hardening (no-prevrandao redesign), randomness is deferred to a
/// future-block blockhash at reveal time inside USlugg404 (unpredictable to
/// the builder of the mint block, since they cannot control the next block's
/// hash unless they win two consecutive slots — extremely rare).
///
/// REQUIRED ADDRESS BITS: afterSwap (1<<6) + afterSwapReturnsDelta (1<<2) = 0x44.
/// Mine via HookMiner before deploy (CREATE2 salt).
contract USluggHook is IHooks, ISeedSource {
    /// @dev Bumped each redeploy to force fresh CREATE2 bytecode → fresh address.
    uint256 public constant DEPLOY_REVISION = 2;

    IPoolManager public immutable poolManager;

    address public owner;
    /// @dev Pending owner — the address proposed via transferOwnership() that
    /// must call acceptOwnership() to actually take control. Two-step handoff
    /// prevents a typo'd multisig address from permanently bricking governance.
    address public pendingOwner;
    /// @dev Fee in basis points (10000 = 100%). Default 10 = 0.1%. Hard-capped at 100 = 1%.
    uint16  public feeBps = 10;

    /// @dev keccak256(abi.encode(legitimatePoolKey)). Set ONCE via lockPool.
    /// Until set, every afterSwap call mutates currentSeed (legacy / pre-lock).
    /// After set, only the matching pool's afterSwap calls mutate seed and pay
    /// fees — calls from any other pool short-circuit to zero. This closes the
    /// "attacker creates a fake pool with our hook and grinds the seed" vector.
    bytes32 public lockedPoolHash;

    /// @dev Transient storage slot for the "swap fired on locked pool this tx"
    /// flag. EIP-1153 tload/tstore at slot 0. Auto-clears at end of tx.
    /// USlugg404._move reads this through ISeedSource.swapFiredThisTx() to
    /// gate receive-side auto-minting — only seed-rolled USLUG (path A or
    /// callHook path C) materializes sluggs.
    uint256 private constant _SWAP_FIRED_SLOT = 0;

    error NotPoolManager();
    error NotOwner();
    error NotPendingOwner();
    error HookNotImplemented();
    error FeeTooHigh();
    error AlreadyLocked();

    event FeeBpsSet(uint16 bps);
    event FeesWithdrawn(Currency indexed currency, address indexed to, uint256 amount);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event PoolLocked(bytes32 indexed poolHash);

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
    }

    // -------- admin --------

    function setFeeBps(uint16 bps) external onlyOwner {
        if (bps > 100) revert FeeTooHigh();
        feeBps = bps;
        emit FeeBpsSet(bps);
    }

    /// @notice Step 1 of two-step ownership handoff: current owner proposes
    /// `newOwner`. No effect on `owner` until acceptOwnership() runs. Pass
    /// address(0) to cancel a previously-proposed transfer.
    function transferOwnership(address newOwner) external onlyOwner {
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    /// @notice Step 2: pendingOwner claims ownership. This is what guards
    /// against typos in HOOK_OWNER on the deploy script — a wrong address
    /// can never accept, so the original owner retains control until a
    /// reachable address actually takes it.
    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotPendingOwner();
        address previous = owner;
        owner = pendingOwner;
        delete pendingOwner;
        emit OwnershipTransferred(previous, owner);
    }

    /// @notice One-shot pin of the legitimate pool key. Without this, anyone
    /// can deploy a Uniswap v4 pool with this hook attached (hooks are
    /// permissionless — only their flag bits gate what they're allowed to
    /// do), trigger afterSwap with a 1-wei swap on their attacker pool, and
    /// arbitrarily mutate currentSeed. That breaks the seed-rarity assumption
    /// the art depends on.
    ///
    /// Lock the pool at deploy time (DeployUslugg sets this before handing
    /// ownership off to the multisig). After lock, afterSwap calls from any
    /// other pool short-circuit: no seed mutation, no fee, no take.
    function lockPool(PoolKey calldata key) external onlyOwner {
        if (lockedPoolHash != 0) revert AlreadyLocked();
        lockedPoolHash = keccak256(abi.encode(key));
        emit PoolLocked(lockedPoolHash);
    }

    /// @notice Withdraw accumulated fees. Hook holds real tokens (taken inline
    /// during afterSwap), so this is a simple transfer.
    function withdrawFees(Currency currency, address to, uint256 amount) external onlyOwner {
        require(to != address(0), "to=0");
        // CEI: emit before the external transfer. On revert the event is wiped
        // along with the rest of the tx, so observable behavior is identical.
        emit FeesWithdrawn(currency, to, amount);
        if (Currency.unwrap(currency) == address(0)) {
            (bool ok, ) = to.call{value: amount}("");
            require(ok, "ETH transfer failed");
        } else {
            (bool ok, bytes memory ret) = Currency.unwrap(currency).call(
                abi.encodeWithSignature("transfer(address,uint256)", to, amount)
            );
            require(ok && (ret.length == 0 || abi.decode(ret, (bool))), "ERC20 transfer failed");
        }
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
        // Gate: once locked, only swaps on the legitimate pool mutate seed
        // and pay fees. Calls from attacker-created pools short-circuit to a
        // zero-fee no-op so they can't touch our state.
        bytes32 lock = lockedPoolHash;
        if (lock != 0 && keccak256(abi.encode(key)) != lock) {
            return (IHooks.afterSwap.selector, int128(0));
        }

        // Set transient flag so any reader within this tx (USlugg404._move on
        // the receive branch) sees `swapFiredThisTx()==true` and is permitted
        // to mint. We deliberately do NOT mix prevrandao into a stored seed
        // here — that would be predictable to builders. The actual per-mint
        // randomness is computed at reveal() time in USlugg404 from a future
        // block's hash, which the builder of the mint block cannot control.
        assembly { tstore(_SWAP_FIRED_SLOT, 1) }

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

    /// @notice ISeedSource: true iff afterSwap fired on the locked pool earlier
    /// in this same tx. Backed by EIP-1153 transient storage; auto-clears at
    /// end of tx, so subsequent txs always start at false.
    function swapFiredThisTx() external view override returns (bool flag) {
        assembly { flag := tload(_SWAP_FIRED_SLOT) }
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
