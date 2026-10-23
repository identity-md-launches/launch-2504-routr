// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {RoutrHook} from "../src/RoutrHook.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";

/// @notice Offline CREATE2 salt search for the launch factory. Does not deploy or broadcast.
contract MineRoutrHook {
    address payable public constant RESEARCH_VAULT = payable(0x087C0CF0A103acA2c487c5017DbC121ad6C5afEE);
    address payable public constant TEAM_WALLET = payable(0x5Cf44fb6a49156125b5f9Dfea73E4011534C7944);
    uint160 public constant FLAGS = 0x12cc;

    error InvalidInput();
    error SaltNotFound();

    /// @param factory The actual address that executes CREATE2, supplied by the launch system.
    /// @param manager The actual chain's PoolManager, supplied by the launch system.
    /// @param token The launch's deployed/predicted RoutrToken address.
    /// @param start First integer salt to try. Retry the next interval if none is found.
    /// @param attempts Number of salts to inspect (suggested: 200,000).
    function run(address factory, IPoolManager manager, address token, uint256 start, uint256 attempts)
        external
        pure
        returns (address predicted, bytes32 salt, bytes32 initCodeHash)
    {
        if (
            factory == address(0) || address(manager) == address(0) || token == address(0) || attempts == 0
                || attempts > 1_000_000 || start > type(uint256).max - attempts
        ) revert InvalidInput();
        initCodeHash = keccak256(
            bytes.concat(type(RoutrHook).creationCode, abi.encode(manager, token, RESEARCH_VAULT, TEAM_WALLET))
        );
        for (uint256 i = start; i < start + attempts; i++) {
            salt = bytes32(i);
            predicted =
                address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), factory, salt, initCodeHash)))));
            if (uint160(predicted) & Hooks.ALL_HOOK_MASK == FLAGS) return (predicted, salt, initCodeHash);
        }
        revert SaltNotFound();
    }
}
