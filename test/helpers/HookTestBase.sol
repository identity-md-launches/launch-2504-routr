// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {RoutrHook} from "../../src/RoutrHook.sol";
import {RoutrToken} from "../../src/RoutrToken.sol";
import {PoolHarness} from "./PoolHarness.sol";
import {Recipient} from "./Recipients.sol";

abstract contract HookTestBase is Test {
    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint160 internal constant FLAGS = 0x12cc;
    PoolManager internal manager;
    RoutrToken internal token;
    RoutrHook internal hook;
    PoolHarness internal router;
    Recipient internal research;
    Recipient internal team;
    PoolKey internal key;

    function _deploy() internal {
        manager = new PoolManager(address(this));
        token = new RoutrToken();
        research = new Recipient();
        team = new Recipient();
        hook = _deployHook(payable(address(research)), payable(address(team)));
        key = PoolKey(Currency.wrap(address(0)), Currency.wrap(address(token)), 12_500, 60, IHooks(address(hook)));
        router = new PoolHarness(manager);
        token.transfer(address(router), 900_000_000 ether);
        vm.deal(address(router), 1_000_000 ether);
    }

    function _deployHook(address payable research_, address payable team_) internal returns (RoutrHook deployed) {
        bytes memory code = bytes.concat(type(RoutrHook).creationCode, abi.encode(manager, token, research_, team_));
        bytes32 hash = keccak256(code);
        for (uint256 i; i < 200_000; i++) {
            bytes32 salt = bytes32(i);
            address predicted =
                address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, hash)))));
            if (uint160(predicted) & Hooks.ALL_HOOK_MASK != FLAGS || predicted.code.length != 0) continue;
            address at;
            assembly ("memory-safe") {
                at := create2(0, add(code, 32), mload(code), salt)
            }
            require(at == predicted, "CREATE2 deployment failed");
            return RoutrHook(payable(at));
        }
        revert("salt not found");
    }

    function _fundedPool() internal {
        manager.initialize(key, SQRT_PRICE_1_1);
        router.modify(key, ModifyLiquidityParams(-600, 600, 100_000 ether, bytes32(0)));
    }

    function _tokenOnlyPool() internal {
        manager.initialize(key, SQRT_PRICE_1_1);
        // At the upper edge only currency1 (ROUTR) is needed. A buy moves price down into the range.
        router.modify(key, ModifyLiquidityParams(-600, 0, 100_000 ether, bytes32(0)));
        assertEq(address(manager).balance, 0);
    }

    function _params(bool buy, int256 amount) internal pure returns (SwapParams memory) {
        return SwapParams(buy, amount, buy ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1);
    }
}
