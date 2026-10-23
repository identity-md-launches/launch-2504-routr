// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {RoutrHook} from "../../src/RoutrHook.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";

contract Recipient {
    bool public reject;

    function setReject(bool reject_) external {
        reject = reject_;
    }

    function withdraw(RoutrHook hook, address payable to) external {
        hook.withdraw(to);
    }

    receive() external payable {
        require(!reject, "reject ETH");
    }
}

contract GasBurningRecipient {
    function withdraw(RoutrHook hook, address payable to) external {
        hook.withdraw(to);
    }

    receive() external payable {
        assembly ("memory-safe") {
            invalid()
        }
    }
}

contract ReenteringRecipient {
    RoutrHook public hook;
    PoolKey private key;
    bool public enabled;
    bool public withdrew;
    bool public flushed;
    bool public swapped;

    function configure(RoutrHook hook_, PoolKey memory key_) external {
        hook = hook_;
        key = key_;
        enabled = true;
    }

    function withdraw() external {
        hook.withdraw(payable(address(this)));
    }

    receive() external payable {
        if (!enabled) revert("create credit first");
        (withdrew,) = address(hook).call(abi.encodeCall(RoutrHook.withdraw, (payable(address(this)))));
        (flushed,) = address(hook).call(abi.encodeCall(RoutrHook.flush, ()));
        try hook.poolManager().swap(key, SwapParams(true, -1, 4295128740), "") {
            swapped = true;
        } catch {}
    }
}
