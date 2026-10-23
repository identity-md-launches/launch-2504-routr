// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MineRoutrHook} from "../script/MineRoutrHook.s.sol";
import {RoutrToken} from "../src/RoutrToken.sol";
import {RoutrHook} from "../src/RoutrHook.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";

contract DeploymentTest is Test {
    function test_mineExactCreationCodeAndDeployWithLaunchRecipients() public {
        PoolManager manager = new PoolManager(address(this));
        RoutrToken token = new RoutrToken();
        MineRoutrHook miner = new MineRoutrHook();
        (address predicted, bytes32 salt, bytes32 hash) = miner.run(address(this), manager, address(token), 0, 200_000);
        bytes memory code = bytes.concat(
            type(RoutrHook).creationCode, abi.encode(manager, token, miner.RESEARCH_VAULT(), miner.TEAM_WALLET())
        );
        assertEq(keccak256(code), hash);
        address deployed;
        assembly ("memory-safe") {
            deployed := create2(0, add(code, 32), mload(code), salt)
        }
        assertEq(deployed, predicted);
        assertGt(deployed.code.length, 0);
        assertLe(deployed.code.length, 24_576);
        RoutrHook hook = RoutrHook(payable(deployed));
        assertEq(hook.researchVault(), 0x087C0CF0A103acA2c487c5017DbC121ad6C5afEE);
        assertEq(hook.teamWallet(), 0x5Cf44fb6a49156125b5f9Dfea73E4011534C7944);
        assertEq(uint160(deployed) & Hooks.ALL_HOOK_MASK, hook.HOOK_FLAGS());
        _assertNoEscapeHatch(deployed.code);
        _assertNoEscapeHatch(address(token).code);
    }

    function test_emptyPredictedHookCannotInitializePool() public {
        PoolManager manager = new PoolManager(address(this));
        RoutrToken token = new RoutrToken();
        MineRoutrHook miner = new MineRoutrHook();
        (address predicted,,) = miner.run(address(this), manager, address(token), 0, 200_000);
        assertEq(predicted.code.length, 0);
        PoolKey memory key =
            PoolKey(Currency.wrap(address(0)), Currency.wrap(address(token)), 12_500, 60, IHooks(predicted));
        vm.expectRevert();
        manager.initialize(key, 79228162514264337593543950336);
    }

    function test_hookConstructorRejectsWrongPermissionBits() public {
        PoolManager manager = new PoolManager(address(this));
        RoutrToken token = new RoutrToken();
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        assertTrue(uint160(predicted) & Hooks.ALL_HOOK_MASK != 0x12cc);
        vm.expectRevert(abi.encodeWithSelector(Hooks.HookAddressNotValid.selector, predicted));
        new RoutrHook(manager, address(token), payable(makeAddr("vault")), payable(makeAddr("team")));
    }

    function test_saltMinerValidatesInputs() public {
        MineRoutrHook miner = new MineRoutrHook();
        vm.expectRevert(MineRoutrHook.InvalidInput.selector);
        miner.run(address(0), IPoolManager(address(this)), address(this), 0, 200_000);
        vm.expectRevert(MineRoutrHook.InvalidInput.selector);
        miner.run(address(this), IPoolManager(address(this)), address(this), 0, 0);
        vm.expectRevert(MineRoutrHook.InvalidInput.selector);
        miner.run(address(this), IPoolManager(address(this)), address(this), type(uint256).max, 1);
    }

    /// @dev The protected floor's opcode criterion, applied directly without environment inputs.
    function _assertNoEscapeHatch(bytes memory code) private pure {
        bool reachable = true;
        for (uint256 i; i < code.length; i++) {
            uint8 op = uint8(code[i]);
            if (op == 0x5b) reachable = true;
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x60 + 1;
                continue;
            }
            if (reachable) require(op != 0xff && op != 0xf4 && op != 0xf2, "runtime escape hatch");
            if (op == 0x00 || op == 0x56 || op == 0xf3 || op == 0xfd || op == 0xfe || op == 0xff) reachable = false;
        }
    }
}
