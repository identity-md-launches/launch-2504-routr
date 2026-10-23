// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {RoutrHook} from "../../src/RoutrHook.sol";
import {RoutrToken} from "../../src/RoutrToken.sol";

/// @dev A self-contained router for the launch-shape tests: one unlock per call, settles every delta it owes,
///      and reports the PoolManager's own (pre-hook) swap delta so fees can be measured independently.
contract LaunchRouter is IUnlockCallback {
    using TransientStateLibrary for IPoolManager;

    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    bytes32 private constant SWAP_TOPIC = keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");

    IPoolManager public immutable manager;
    address public immutable owner;

    constructor(IPoolManager manager_) {
        manager = manager_;
        owner = msg.sender;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "owner only");
        _;
    }

    /// @return delta What the caller settled (hook deltas included).
    /// @return core0 The AMM's ETH delta from the PoolManager's Swap event (no hook fee in it).
    /// @return core1 The AMM's token delta from the same event.
    function swap(PoolKey memory key, SwapParams memory params)
        external
        onlyOwner
        returns (BalanceDelta delta, int128 core0, int128 core1)
    {
        vm.recordLogs();
        delta = abi.decode(manager.unlock(abi.encode(uint8(0), key, abi.encode(params))), (BalanceDelta));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == address(manager) && logs[i].topics[0] == SWAP_TOPIC) {
                (core0, core1,,,,) = abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
                return (delta, core0, core1);
            }
        }
        revert("Swap event missing");
    }

    function modify(PoolKey memory key, ModifyLiquidityParams memory params) external onlyOwner returns (BalanceDelta) {
        return abi.decode(manager.unlock(abi.encode(uint8(1), key, abi.encode(params))), (BalanceDelta));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "manager only");
        (uint8 action, PoolKey memory key, bytes memory inner) = abi.decode(data, (uint8, PoolKey, bytes));
        BalanceDelta delta;
        if (action == 0) {
            delta = manager.swap(key, abi.decode(inner, (SwapParams)), "");
        } else {
            (delta,) = manager.modifyLiquidity(key, abi.decode(inner, (ModifyLiquidityParams)), "");
        }
        _settle(key.currency0);
        _settle(key.currency1);
        return abi.encode(delta);
    }

    function _settle(Currency currency) private {
        int256 owed = manager.currencyDelta(address(this), currency);
        if (owed < 0) {
            manager.sync(currency);
            if (currency.isAddressZero()) {
                manager.settle{value: uint256(-owed)}();
            } else {
                require(RoutrToken(Currency.unwrap(currency)).transfer(address(manager), uint256(-owed)));
                manager.settle();
            }
        } else if (owed > 0) {
            manager.take(currency, address(this), uint256(owed));
        }
    }

    receive() external payable {}
}

/// @dev A fee recipient whose acceptance of ETH can be switched, and which can pull its own credit.
contract SwitchableRecipient {
    bool public rejecting;

    function setRejecting(bool rejecting_) external {
        rejecting = rejecting_;
    }

    function pull(RoutrHook hook, address payable to) external {
        hook.withdraw(to);
    }

    receive() external payable {
        require(!rejecting, "rejecting");
    }
}

/// @dev Rejects every ETH transfer; used to stand in for a vault whose receive fails.
contract AlwaysRejects {
    receive() external payable {
        revert("no ETH");
    }
}

library RoutrLaunchKit {
    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint160 internal constant FLAGS = 0x12cc;
    address payable internal constant RESEARCH_VAULT = payable(0x087C0CF0A103acA2c487c5017DbC121ad6C5afEE);
    address payable internal constant TEAM_WALLET = payable(0x5Cf44fb6a49156125b5f9Dfea73E4011534C7944);

    /// @dev CREATE2-mines a salt for the hook's permission bits from the calling contract.
    function deployHook(IPoolManager manager, address token, address payable research, address payable team)
        internal
        returns (RoutrHook)
    {
        bytes memory code = bytes.concat(type(RoutrHook).creationCode, abi.encode(manager, token, research, team));
        bytes32 hash = keccak256(code);
        for (uint256 i; i < 300_000; i++) {
            bytes32 salt = bytes32(i);
            address predicted =
                address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, hash)))));
            if (uint160(predicted) & Hooks.ALL_HOOK_MASK != FLAGS || predicted.code.length != 0) continue;
            address at;
            assembly ("memory-safe") {
                at := create2(0, add(code, 32), mload(code), salt)
            }
            require(at == predicted, "create2 failed");
            return RoutrHook(payable(at));
        }
        revert("no salt");
    }

    function keyFor(RoutrToken token, RoutrHook hook) internal pure returns (PoolKey memory) {
        return PoolKey(Currency.wrap(address(0)), Currency.wrap(address(token)), 12_500, 60, IHooks(address(hook)));
    }

    function params(bool buy, int256 amount) internal pure returns (SwapParams memory) {
        return SwapParams(buy, amount, buy ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1);
    }
}
