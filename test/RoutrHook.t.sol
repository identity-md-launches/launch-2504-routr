// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {HookTestBase} from "./helpers/HookTestBase.sol";
import {Recipient, GasBurningRecipient, ReenteringRecipient} from "./helpers/Recipients.sol";
import {RoutrHook} from "../src/RoutrHook.sol";
import {RoutrToken} from "../src/RoutrToken.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";

contract RoutrHookTest is HookTestBase {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    function setUp() public {
        _deploy();
        _fundedPool();
    }

    function test_exactInputBuy() public {
        _assertSwap(true, -10 ether);
    }

    function test_exactOutputBuy() public {
        _assertSwap(true, 10 ether);
    }

    function test_exactInputSell() public {
        _assertSwap(false, -10 ether);
    }

    function test_exactOutputSell() public {
        _assertSwap(false, 10 ether);
    }

    function testFuzz_allFourSwapModes(uint96 size, bool buy, bool exactInput) public {
        uint256 amount = bound(uint256(size), 10_000, 100 ether);
        _assertSwap(buy, exactInput ? -int256(amount) : int256(amount));
    }

    function _assertSwap(bool buy, int256 amount) internal {
        uint256 beforeVault = address(research).balance;
        uint256 beforeTeam = address(team).balance;
        uint256 beforeETH = address(router).balance;
        uint256 beforeToken = token.balanceOf(address(router));
        uint256 beforeManagerETH = address(manager).balance;
        vm.recordLogs();
        BalanceDelta delta = router.swap(key, _params(buy, amount), false);
        (int128 coreETH, int128 coreToken) = _coreDelta(vm.getRecordedLogs());
        uint256 gross = buy ? uint256(-int256(delta.amount0())) : uint256(int256(coreETH));
        uint256 fee = gross * 200 / 10_000;
        uint256 researchFee = gross * 150 / 10_000;
        uint256 teamFee = fee - researchFee;
        assertEq(address(research).balance - beforeVault, researchFee, "research share");
        assertEq(address(team).balance - beforeTeam, teamFee, "team share");
        assertEq(int256(delta.amount0()), int256(coreETH) - int256(fee), "ETH-only delta");
        assertEq(delta.amount1(), coreToken, "no token tax");
        assertEq(int256(address(router).balance) - int256(beforeETH), delta.amount0(), "settled ETH");
        assertEq(int256(token.balanceOf(address(router))) - int256(beforeToken), delta.amount1(), "settled token");
        assertEq(int256(address(manager).balance) - int256(beforeManagerETH), -int256(coreETH), "manager conservation");
        if ((amount < 0) == buy) assertEq(int256(delta.amount0()), amount, "specified ETH preserved");
        else assertEq(int256(delta.amount1()), amount, "specified tokens preserved");
        assertEq(address(hook).balance, 0);
        assertEq(manager.balanceOf(address(hook), 0), 0);
        assertEq(hook.totalCredits(), 0);
        assertEq(IPoolManager(manager).currencyDelta(address(hook), Currency.wrap(address(0))), 0);
    }

    function _coreDelta(Vm.Log[] memory logs) internal view returns (int128 amount0, int128 amount1) {
        bytes32 topic = keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == address(manager) && logs[i].topics[0] == topic) {
                (amount0, amount1,,,,) = abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
                return (amount0, amount1);
            }
        }
        revert("real PoolManager Swap event missing");
    }

    function test_feeAppliesFromFirstTradeAndNeverDecays() public {
        _assertSwap(true, -10 ether);
        vm.warp(block.timestamp + 1000 days);
        _assertSwap(false, -10 ether);
    }

    function test_rejectingRecipientDoesNotBlockSwapAndCanWithdrawElsewhere() public {
        research.setReject(true);
        router.swap(key, _params(true, -10 ether), false);
        assertEq(hook.credits(address(research)), 0.15 ether);
        assertEq(address(hook).balance, 0.15 ether);
        assertEq(address(team).balance, 0.05 ether);
        address payable destination = payable(makeAddr("research withdrawal"));
        research.withdraw(hook, destination);
        assertEq(destination.balance, 0.15 ether);
        assertEq(hook.totalCredits(), 0);
        assertEq(address(hook).balance, 0);
        vm.expectRevert(RoutrHook.NothingToWithdraw.selector);
        research.withdraw(hook, destination);
    }

    function test_bothRejectAndPermissionlessFlushRetries() public {
        research.setReject(true);
        team.setReject(true);
        router.swap(key, _params(false, 9.8 ether), false);
        assertEq(hook.credits(address(research)), 0.15 ether);
        assertEq(hook.credits(address(team)), 0.05 ether);
        hook.flush();
        assertEq(hook.totalCredits(), 0.2 ether);
        research.setReject(false);
        team.setReject(false);
        vm.prank(makeAddr("keeper"));
        hook.flush();
        assertEq(address(research).balance, 0.15 ether);
        assertEq(address(team).balance, 0.05 ether);
        assertEq(hook.totalCredits(), 0);
        hook.flush();
        assertEq(address(research).balance, 0.15 ether);
    }

    function test_failedWithdrawalRestoresCreditAndStrangerCannotSteal() public {
        research.setReject(true);
        router.swap(key, _params(true, -10 ether), false);
        vm.expectRevert(RoutrHook.ETHTransferFailed.selector);
        research.withdraw(hook, payable(address(research)));
        assertEq(hook.credits(address(research)), 0.15 ether);
        vm.expectRevert(RoutrHook.NothingToWithdraw.selector);
        hook.withdraw(payable(address(this)));
        vm.expectRevert(RoutrHook.InvalidAddress.selector);
        research.withdraw(hook, payable(address(0)));
        assertEq(hook.totalCredits(), 0.15 ether);
    }

    function test_gasExhaustingRecipientCannotBlockSwap() public {
        GasBurningRecipient burner = new GasBurningRecipient();
        hook = _deployHook(payable(address(burner)), payable(address(team)));
        key.hooks = IHooks(address(hook));
        _fundedPool();
        router.swap(key, _params(true, -10 ether), false);
        assertEq(hook.credits(address(burner)), 0.15 ether);
        assertEq(address(team).balance, 0.05 ether);
        address payable destination = payable(makeAddr("burner recovery"));
        burner.withdraw(hook, destination);
        assertEq(destination.balance, 0.15 ether);
    }

    function test_reentrancyCannotWithdrawTwiceOrStartNestedSwap() public {
        ReenteringRecipient attacker = new ReenteringRecipient();
        hook = _deployHook(payable(address(attacker)), payable(address(team)));
        key.hooks = IHooks(address(hook));
        _fundedPool();
        router.swap(key, _params(true, -10 ether), false);
        assertEq(hook.credits(address(attacker)), 0.15 ether);
        attacker.configure(hook, key);
        attacker.withdraw();
        assertFalse(attacker.withdrew());
        assertFalse(attacker.flushed());
        assertFalse(attacker.swapped());
        assertEq(address(attacker).balance, 0.15 ether);
        assertEq(hook.totalCredits(), 0);
        router.swap(key, _params(true, -10 ether), false);
        assertFalse(attacker.swapped());
        assertEq(address(attacker).balance + hook.credits(address(attacker)), 0.3 ether);
    }

    function test_removeLiquidityAlwaysReverts() public {
        uint128 beforeLiquidity = IPoolManager(manager).getLiquidity(key.toId());
        vm.expectRevert();
        router.modify(key, ModifyLiquidityParams(-600, 600, -1 ether, bytes32(0)));
        vm.expectRevert();
        router.modify(key, ModifyLiquidityParams(-600, 600, -1, bytes32(0)));
        assertEq(IPoolManager(manager).getLiquidity(key.toId()), beforeLiquidity);
    }

    function test_zeroDeltaCollectsLPFeesWithoutRemovingPrincipal() public {
        router.swap(key, _params(true, -10 ether), false);
        router.swap(key, _params(false, -10 ether), false);
        uint128 beforeLiquidity = IPoolManager(manager).getLiquidity(key.toId());
        uint256 vaultBefore = address(research).balance;
        BalanceDelta collected = router.modify(key, ModifyLiquidityParams(-600, 600, 0, bytes32(0)));
        assertGt(collected.amount0(), 0, "ETH LP fees");
        assertGt(collected.amount1(), 0, "token LP fees");
        assertEq(IPoolManager(manager).getLiquidity(key.toId()), beforeLiquidity, "principal locked");
        assertEq(address(research).balance, vaultBefore, "collect pays no hook fee");
        // A second collect returns nothing, and removal still reverts afterwards.
        collected = router.modify(key, ModifyLiquidityParams(-600, 600, 0, bytes32(0)));
        assertEq(collected.amount0(), 0);
        assertEq(collected.amount1(), 0);
        vm.expectRevert();
        router.modify(key, ModifyLiquidityParams(-600, 600, -1, bytes32(0)));
    }

    function testFuzz_allRemovalSendersRevert(address sender, int128 liquidity) public {
        vm.assume(liquidity != 0);
        if (liquidity > 0) liquidity = -liquidity;
        vm.prank(address(manager));
        vm.expectRevert(RoutrHook.LiquidityLocked.selector);
        hook.beforeRemoveLiquidity(sender, key, ModifyLiquidityParams(-600, 600, liquidity, bytes32(0)), "");
    }

    function testFuzz_zeroDeltaAllowedForAnySender(address sender) public {
        vm.prank(address(manager));
        bytes4 selector = hook.beforeRemoveLiquidity(sender, key, ModifyLiquidityParams(-600, 600, 0, bytes32(0)), "");
        assertEq(selector, IHooks.beforeRemoveLiquidity.selector);
    }

    function test_callbacksOnlyPoolManager() public {
        SwapParams memory params = _params(true, -1 ether);
        vm.expectRevert(RoutrHook.OnlyPoolManager.selector);
        hook.afterInitialize(address(this), key, SQRT_PRICE_1_1, 0);
        vm.expectRevert(RoutrHook.OnlyPoolManager.selector);
        hook.beforeSwap(address(this), key, params, "");
        vm.expectRevert(RoutrHook.OnlyPoolManager.selector);
        hook.afterSwap(address(this), key, params, BalanceDelta.wrap(0), "");
        vm.expectRevert(RoutrHook.OnlyPoolManager.selector);
        hook.beforeRemoveLiquidity(address(this), key, ModifyLiquidityParams(-60, 60, 0, bytes32(0)), "");
        vm.expectRevert(RoutrHook.OnlyPoolManager.selector);
        hook.unlockCallback("");
        vm.prank(address(manager));
        vm.expectRevert(RoutrHook.UnexpectedUnlock.selector);
        hook.unlockCallback("");
    }

    function test_afterSwapWithoutBeforeSwapReverts() public {
        vm.prank(address(manager));
        vm.expectRevert(RoutrHook.InvalidSwapContext.selector);
        hook.afterSwap(address(router), key, _params(true, -1 ether), BalanceDelta.wrap(0), "");
    }

    function test_poolIsBoundOnceAndAllFieldsAreChecked() public {
        assertEq(PoolId.unwrap(hook.poolId()), PoolId.unwrap(key.toId()));
        vm.prank(address(manager));
        vm.expectRevert(RoutrHook.AlreadyInitialized.selector);
        hook.afterInitialize(address(this), key, SQRT_PRICE_1_1, 0);
        PoolKey memory other = key;
        other.tickSpacing = 120;
        vm.expectRevert();
        manager.initialize(other, SQRT_PRICE_1_1);
        vm.prank(address(manager));
        vm.expectRevert(RoutrHook.InvalidPool.selector);
        hook.beforeSwap(address(router), other, _params(true, -1 ether), "");
        vm.prank(address(manager));
        vm.expectRevert(RoutrHook.InvalidPool.selector);
        hook.afterSwap(address(router), other, _params(true, -1 ether), BalanceDelta.wrap(0), "");
    }

    function test_permissionsAndNoAdmin() public {
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(p.afterInitialize && p.beforeRemoveLiquidity && p.beforeSwap && p.afterSwap);
        assertTrue(p.beforeSwapReturnDelta && p.afterSwapReturnDelta);
        assertFalse(p.beforeInitialize || p.beforeAddLiquidity || p.afterAddLiquidity || p.afterRemoveLiquidity);
        assertFalse(
            p.beforeDonate || p.afterDonate || p.afterAddLiquidityReturnDelta || p.afterRemoveLiquidityReturnDelta
        );
        assertEq(uint160(address(hook)) & Hooks.ALL_HOOK_MASK, FLAGS);
        string[6] memory signatures = [
            "owner()",
            "setFee(uint256)",
            "setRecipients(address,address)",
            "pause()",
            "upgradeTo(address)",
            "transferOwnership(address)"
        ];
        for (uint256 i; i < signatures.length; ++i) {
            (bool ok,) = address(hook).call(abi.encodeWithSignature(signatures[i], address(this), address(this)));
            assertFalse(ok);
        }
    }

    function test_exactInputSellAtPriceLimitPaysOnActualETH() public {
        SwapParams memory params = SwapParams(false, -100 ether, TickMath.getSqrtPriceAtTick(1));
        vm.recordLogs();
        BalanceDelta delta = router.swap(key, params, false);
        (int128 coreETH,) = _coreDelta(vm.getRecordedLogs());
        uint256 gross = uint256(int256(coreETH));
        assertGt(gross, 0);
        assertLt(uint256(-int256(delta.amount1())), 100 ether);
        assertEq(address(research).balance, gross * 150 / 10_000);
        assertEq(address(research).balance + address(team).balance, gross * 200 / 10_000);
        assertEq(uint256(int256(delta.amount0())), gross - gross * 200 / 10_000);
    }

    function test_partialETHSpecifiedBuyRevertsAtomically() public {
        (uint160 priceBefore,,,) = IPoolManager(manager).getSlot0(key.toId());
        vm.expectRevert();
        router.swap(key, SwapParams(true, -100 ether, TickMath.getSqrtPriceAtTick(-1)), false);
        (uint160 priceAfter,,,) = IPoolManager(manager).getSlot0(key.toId());
        assertEq(priceBefore, priceAfter);
        assertEq(address(research).balance, 0);
        assertEq(address(team).balance, 0);
        _assertSwap(true, -1 ether);
    }

    function test_partialExactOutputSellReverts() public {
        vm.expectRevert();
        router.swap(key, SwapParams(false, 100 ether, TickMath.getSqrtPriceAtTick(1)), false);
        assertEq(hook.totalCredits(), 0);
    }

    function test_exactOutputBuyAtPriceLimitPartiallyFillsAndPaysOnActualETH() public {
        vm.recordLogs();
        BalanceDelta delta = router.swap(key, SwapParams(true, 100 ether, TickMath.getSqrtPriceAtTick(-1)), false);
        (int128 coreETH,) = _coreDelta(vm.getRecordedLogs());
        uint256 ammETH = uint256(-int256(coreETH));
        uint256 fee = ammETH * 200 / 9_800;
        uint256 gross = ammETH + fee;
        assertGt(ammETH, 0);
        assertLt(uint256(int256(delta.amount1())), 100 ether);
        assertEq(uint256(-int256(delta.amount0())), gross);
        assertEq(address(research).balance, gross * 150 / 10_000);
        assertEq(address(research).balance + address(team).balance, fee);
    }

    function test_sequentialSwapsInOneUnlockClearTransientState() public {
        router.swapTwice(key, _params(true, -10 ether), _params(false, 9.8 ether));
        assertEq(address(research).balance, 0.3 ether);
        assertEq(address(team).balance, 0.1 ether);
        hook.flush();
        _assertSwap(true, -1 ether);
    }

    function test_invalidAndOversizedAmountsRevert() public {
        vm.expectRevert();
        router.swap(key, _params(true, 0), false);
        vm.expectRevert();
        router.swap(key, _params(true, type(int256).min), false);
        vm.expectRevert();
        router.swap(key, _params(false, type(int128).max), false);
        _assertSwap(true, -1 ether);
    }
}

contract RoutrLaunchTest is HookTestBase {
    function setUp() public {
        _deploy();
    }

    function test_firstBuyOnTokenOnlyPoolCreditsETHClaimsThenFlushes() public {
        _tokenOnlyPool();
        router.swap(key, _params(true, -10 ether), false);
        assertEq(address(research).balance, 0);
        assertEq(address(team).balance, 0);
        assertEq(hook.credits(address(research)), 0.15 ether);
        assertEq(hook.credits(address(team)), 0.05 ether);
        assertEq(manager.balanceOf(address(hook), 0), 0.2 ether);
        assertEq(address(manager).balance, 10 ether);
        hook.flush();
        assertEq(address(research).balance, 0.15 ether);
        assertEq(address(team).balance, 0.05 ether);
        assertEq(manager.balanceOf(address(hook), 0), 0);
        assertEq(hook.totalCredits(), 0);
        assertEq(address(manager).balance, 9.8 ether);
    }

    function test_firstExactOutputBuyCanFlushInsideRoutersUnlockAfterSettlement() public {
        _tokenOnlyPool();
        BalanceDelta delta = router.swap(key, _params(true, 10 ether), true);
        uint256 gross = uint256(-int256(delta.amount0()));
        assertEq(delta.amount1(), 10 ether);
        assertEq(address(research).balance, gross * 150 / 10_000);
        assertEq(address(research).balance + address(team).balance, gross * 200 / 10_000);
        assertEq(manager.balanceOf(address(hook), 0), 0);
        assertEq(hook.totalCredits(), 0);
    }

    function test_recipientWithdrawsClaimWithoutKeeper() public {
        _tokenOnlyPool();
        router.swap(key, _params(true, -10 ether), false);
        address payable destination = payable(makeAddr("research recipient"));
        research.withdraw(hook, destination);
        assertEq(destination.balance, 0.15 ether);
        assertEq(manager.balanceOf(address(hook), 0), 0.05 ether);
        assertEq(hook.totalCredits(), 0.05 ether);
        hook.flush();
        assertEq(address(team).balance, 0.05 ether);
    }

    function test_rejectedPayoutAfterClaimRedemptionPreservesETHCredit() public {
        research.setReject(true);
        _tokenOnlyPool();
        router.swap(key, _params(true, -10 ether), true);
        assertEq(hook.credits(address(research)), 0.15 ether);
        assertEq(address(hook).balance, 0.15 ether);
        assertEq(manager.balanceOf(address(hook), 0), 0);
        research.setReject(false);
        hook.flush();
        assertEq(address(research).balance, 0.15 ether);
    }

    function test_launchUsesOnlyTokensAndThenAllSwapTypesWork() public {
        uint256 beforeToken = token.balanceOf(address(router));
        uint256 beforeETH = address(router).balance;
        _tokenOnlyPool();
        assertLt(token.balanceOf(address(router)), beforeToken);
        assertEq(address(router).balance, beforeETH);
        router.swap(key, _params(true, -100 ether), true);
        router.swap(key, _params(true, 10 ether), false);
        router.swap(key, _params(false, -10 ether), false);
        BalanceDelta delta = router.swap(key, _params(false, 10 ether), false);
        assertEq(delta.amount0(), 10 ether);
        assertGt(address(research).balance, 1.5 ether);
        assertEq(hook.totalCredits(), 0);
    }

    function test_wrongPoolRejectedBeforeBindingThenValidPoolWorks() public {
        PoolKey memory bad = key;
        bad.currency1 = Currency.wrap(address(new RoutrToken()));
        vm.expectRevert();
        manager.initialize(bad, SQRT_PRICE_1_1);
        bad = key;
        bad.fee = 3000;
        vm.expectRevert();
        manager.initialize(bad, SQRT_PRICE_1_1);
        bad = key;
        bad.tickSpacing = 120;
        vm.expectRevert();
        manager.initialize(bad, SQRT_PRICE_1_1);
        assertFalse(hook.initialized());
        manager.initialize(key, SQRT_PRICE_1_1);
        assertTrue(hook.initialized());
    }

    function test_nonETHPairAndWrongHookRejected() public {
        PoolKey memory bad = key;
        bad.currency0 = Currency.wrap(address(new RoutrToken()));
        vm.prank(address(manager));
        vm.expectRevert(RoutrHook.InvalidPool.selector);
        hook.afterInitialize(address(this), bad, SQRT_PRICE_1_1, 0);
        bad = key;
        bad.hooks = IHooks(address(this));
        vm.prank(address(manager));
        vm.expectRevert(RoutrHook.InvalidPool.selector);
        hook.afterInitialize(address(this), bad, SQRT_PRICE_1_1, 0);
    }

    function test_uninitializedHookRefusesSwapCallback() public {
        vm.prank(address(manager));
        vm.expectRevert(RoutrHook.PoolNotInitialized.selector);
        hook.beforeSwap(address(router), key, _params(true, -1 ether), "");
    }

    function test_constructorRejectsZeroArguments() public {
        vm.expectRevert(RoutrHook.InvalidAddress.selector);
        new RoutrHook(IPoolManager(address(0)), address(token), payable(address(research)), payable(address(team)));
        vm.expectRevert(RoutrHook.InvalidAddress.selector);
        new RoutrHook(manager, address(0), payable(address(research)), payable(address(team)));
        vm.expectRevert(RoutrHook.InvalidAddress.selector);
        new RoutrHook(manager, address(token), payable(address(0)), payable(address(team)));
        vm.expectRevert(RoutrHook.InvalidAddress.selector);
        new RoutrHook(manager, address(token), payable(address(research)), payable(address(0)));
    }
}
