// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {RoutrToken} from "../../src/RoutrToken.sol";
import {RoutrHook} from "../../src/RoutrHook.sol";

/// @dev Test-only funded router; settles real deltas against the real PoolManager.
contract PoolHarness is IUnlockCallback {
    using TransientStateLibrary for IPoolManager;

    IPoolManager public immutable manager;
    address public immutable controller;

    constructor(IPoolManager manager_) {
        manager = manager_;
        controller = msg.sender;
    }

    function swap(PoolKey memory key, SwapParams memory params, bool flushAfter) external returns (BalanceDelta) {
        require(msg.sender == controller, "controller only");
        return abi.decode(manager.unlock(abi.encode(uint8(0), key, abi.encode(params, flushAfter))), (BalanceDelta));
    }

    function modify(PoolKey memory key, ModifyLiquidityParams memory params) external returns (BalanceDelta) {
        require(msg.sender == controller, "controller only");
        return abi.decode(manager.unlock(abi.encode(uint8(1), key, abi.encode(params))), (BalanceDelta));
    }

    function swapTwice(PoolKey memory key, SwapParams memory a, SwapParams memory b) external {
        require(msg.sender == controller, "controller only");
        manager.unlock(abi.encode(uint8(2), key, abi.encode(a, b)));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "manager only");
        (uint8 action, PoolKey memory key, bytes memory params) = abi.decode(data, (uint8, PoolKey, bytes));
        BalanceDelta delta;
        bool flushAfter;
        if (action == 0) {
            SwapParams memory swapParams;
            (swapParams, flushAfter) = abi.decode(params, (SwapParams, bool));
            delta = manager.swap(key, swapParams, "");
        } else if (action == 1) {
            (delta,) = manager.modifyLiquidity(key, abi.decode(params, (ModifyLiquidityParams)), "");
        } else {
            (SwapParams memory a, SwapParams memory b) = abi.decode(params, (SwapParams, SwapParams));
            manager.swap(key, a, "");
            manager.swap(key, b, "");
        }
        _settle(key.currency0);
        _settle(key.currency1);
        if (flushAfter) RoutrHook(payable(address(key.hooks))).flush();
        return abi.encode(delta);
    }

    function _settle(Currency currency) private {
        int256 delta = manager.currencyDelta(address(this), currency);
        if (delta < 0) {
            uint256 owed = uint256(-delta);
            manager.sync(currency);
            if (currency.isAddressZero()) {
                manager.settle{value: owed}();
            } else {
                require(RoutrToken(Currency.unwrap(currency)).transfer(address(manager), owed));
                manager.settle();
            }
        } else if (delta > 0) {
            manager.take(currency, address(this), uint256(delta));
        }
    }

    receive() external payable {}
}
