// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPoolManager}     from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback}  from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {IHooks}           from "v4-core/interfaces/IHooks.sol";
import {PoolKey}          from "v4-core/types/PoolKey.sol";
import {Currency}         from "v4-core/types/Currency.sol";
import {BalanceDelta}     from "v4-core/types/BalanceDelta.sol";
import {TickMath}         from "v4-core/libraries/TickMath.sol";
import {SwapParams}       from "v4-core/types/PoolOperation.sol";

interface IERC20Min {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

interface IWETH9 {
    function deposit() external payable;
    function withdraw(uint256) external;
    function transfer(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

/// @notice Minimal swap router for the uSlugg / WETH v4 pool.
///
/// Wraps/unwraps WETH so users transact in native ETH. Single pool, single hook —
/// no command encoding, no path-finding, no multi-hop. Just buy() and sell()
/// with slippage + deadline. Quotes happen frontend-side.
///
/// Note: uSlugg is a 404 hybrid with 3 decimals. The "whole tokens" the buy
/// path forces are 1.000 USLUG (= 1e3 raw units) — every unit of that
/// corresponds to one Slugg NFT mint, exactly like BCC at 18 decimals.
contract USluggSwap is IUnlockCallback {
    IPoolManager public immutable poolManager;
    IWETH9       public immutable weth;
    IERC20Min    public immutable slugg;
    PoolKey      public key;

    error Expired();
    error InsufficientOutput();   // sell: ETH out < minEthOut
    error MaxInputExceeded();     // buy: ETH in > maxEthIn
    error UnexpectedDelta();      // pool returned wrong-sign delta
    error WrongCallback();
    error EthRefundFailed();

    struct CB {
        address sender;
        bool    isBuy;
        uint256 amountSpec;   // buy: usluggOut (exact-output); sell: usluggIn (exact-input), in raw units (3 decimals)
        uint256 limit;        // buy: maxEthIn;                 sell: minEthOut
    }

    constructor(IPoolManager _pm, IWETH9 _weth, IERC20Min _slugg, PoolKey memory _key) {
        poolManager = _pm;
        weth = _weth;
        slugg = _slugg;
        key = _key;
        require(address(_slugg) < address(_weth), "USLUG must be token0");
    }

    /// @notice Buy an EXACT amount of USLUG (raw units, 3 decimals), pay up to maxEthIn. Refund the rest.
    function buy(uint256 usluggOut, uint256 maxEthIn, uint256 deadline) external payable returns (uint256 ethSpent) {
        if (block.timestamp > deadline) revert Expired();
        require(msg.value >= maxEthIn, "msg.value < maxEthIn");
        ethSpent = abi.decode(
            poolManager.unlock(abi.encode(CB(msg.sender, true, usluggOut, maxEthIn))),
            (uint256)
        );
    }

    /// @notice Sell USLUG for ETH. User must approve this contract for `usluggAmount`.
    function sell(uint256 usluggAmount, uint256 minEthOut, uint256 deadline) external returns (uint256 ethOut) {
        if (block.timestamp > deadline) revert Expired();
        require(slugg.transferFrom(msg.sender, address(this), usluggAmount), "USLUG transferFrom");
        ethOut = abi.decode(
            poolManager.unlock(abi.encode(CB(msg.sender, false, usluggAmount, minEthOut))),
            (uint256)
        );
    }

    function unlockCallback(bytes calldata raw) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert WrongCallback();
        CB memory p = abi.decode(raw, (CB));

        // USLUG=token0, WETH=token1.
        // Buy:  zeroForOne=false, EXACT-OUTPUT (positive amountSpecified = uslugg target)
        // Sell: zeroForOne=true,  EXACT-INPUT  (negative amountSpecified = uslugg paid)
        bool zeroForOne = !p.isBuy;
        SwapParams memory sp = SwapParams({
            zeroForOne:        zeroForOne,
            amountSpecified:   p.isBuy ? int256(p.amountSpec) : -int256(p.amountSpec),
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        BalanceDelta delta = poolManager.swap(key, sp, "");
        int256 d0 = int256(delta.amount0());
        int256 d1 = int256(delta.amount1());

        if (p.isBuy) {
            // Exact-output: pool gave us +d0 USLUG, we owe -d1 WETH.
            if (d0 <= 0 || d1 >= 0) revert UnexpectedDelta();
            uint256 wethOwed = uint256(-d1);
            if (wethOwed > p.limit) revert MaxInputExceeded();

            // v4 settle pattern: sync(), transfer to PM, settle()
            poolManager.sync(key.currency1);
            weth.deposit{value: wethOwed}();
            require(weth.transfer(address(poolManager), wethOwed), "weth.transfer");
            poolManager.settle();

            uint256 usluggOut = uint256(d0);
            poolManager.take(key.currency0, p.sender, usluggOut);

            if (address(this).balance > 0) {
                (bool ok,) = p.sender.call{value: address(this).balance}("");
                if (!ok) revert EthRefundFailed();
            }
            return abi.encode(wethOwed);
        } else {
            // Exact-input sell: we owe -d0 USLUG, pool gives us +d1 WETH.
            if (d0 >= 0 || d1 <= 0) revert UnexpectedDelta();
            uint256 usluggOwed = uint256(-d0);

            poolManager.sync(key.currency0);
            require(slugg.transfer(address(poolManager), usluggOwed), "slugg.transfer");
            poolManager.settle();

            uint256 wethRecv = uint256(d1);
            if (wethRecv < p.limit) revert InsufficientOutput();
            poolManager.take(key.currency1, address(this), wethRecv);
            weth.withdraw(wethRecv);

            (bool ok,) = p.sender.call{value: wethRecv}("");
            if (!ok) revert EthRefundFailed();
            return abi.encode(wethRecv);
        }
    }

    receive() external payable {}
}
