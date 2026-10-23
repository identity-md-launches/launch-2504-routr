// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {RoutrHook} from "../src/RoutrHook.sol";
import {RoutrToken} from "../src/RoutrToken.sol";
import {LaunchRouter, SwitchableRecipient, AlwaysRejects, RoutrLaunchKit} from "./helpers/RoutrLaunchKit.sol";

/// @dev Shared setup: a fresh PoolManager holding no ETH, the hook bound to the ETH/ROUTR pool.
abstract contract LaunchEdgeBase is Test {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    PoolManager internal manager;
    RoutrToken internal token;
    RoutrHook internal hook;
    LaunchRouter internal launcher;
    LaunchRouter internal trader;
    PoolKey internal key;
    address payable internal research;
    address payable internal team;

    function _setUpWith(address payable research_, address payable team_, bool tokenOnly) internal {
        manager = new PoolManager(address(this));
        token = new RoutrToken();
        research = research_;
        team = team_;
        hook = RoutrLaunchKit.deployHook(manager, address(token), research_, team_);
        key = RoutrLaunchKit.keyFor(token, hook);
        launcher = new LaunchRouter(manager);
        trader = new LaunchRouter(manager);
        token.transfer(address(launcher), 800_000_000 ether);
        token.transfer(address(trader), 100_000_000 ether);
        vm.deal(address(launcher), 5_000 ether);
        vm.deal(address(trader), 10_000 ether);
        manager.initialize(key, RoutrLaunchKit.SQRT_PRICE_1_1);
        if (tokenOnly) {
            // Launch shape: the range ends at the current tick, so only ROUTR is deposited.
            launcher.modify(key, ModifyLiquidityParams(-6000, 0, 1_000_000 ether, bytes32(0)));
            assertEq(address(manager).balance, 0, "launch seeded no ETH");
        } else {
            launcher.modify(key, ModifyLiquidityParams(-6000, 6000, 10_000 ether, bytes32(0)));
        }
    }

    function _accrued(address who) internal view returns (uint256) {
        return who.balance + hook.credits(who);
    }

    /// @dev Swaps through `trader` and checks the fee against the PoolManager's own Swap event.
    function _swapAndCheck(bool buy, int256 amount) internal returns (uint256 gross, uint256 fee) {
        uint256 researchBefore = _accrued(research);
        uint256 teamBefore = _accrued(team);
        (BalanceDelta delta, int128 core0, int128 core1) = trader.swap(key, RoutrLaunchKit.params(buy, amount));
        if (buy) {
            gross = uint256(-int256(delta.amount0()));
            fee = gross - uint256(-int256(core0));
        } else {
            gross = uint256(int256(core0));
            fee = gross - uint256(int256(delta.amount0()));
        }
        assertEq(fee, gross * 200 / 10_000, "2% of the ETH side");
        assertEq(_accrued(research) - researchBefore, gross * 150 / 10_000, "1.5% research");
        assertEq(_accrued(team) - teamBefore, fee - gross * 150 / 10_000, "0.5% team");
        assertEq(delta.amount1(), core1, "token side untouched");
        // The specified amount is honoured exactly.
        if ((amount < 0) == buy) assertEq(int256(delta.amount0()), amount, "specified ETH");
        else assertEq(int256(delta.amount1()), amount, "specified ROUTR");
        assertEq(IPoolManager(manager).getNonzeroDeltaCount(), 0);
        assertEq(hook.totalCredits(), address(hook).balance + manager.balanceOf(address(hook), 0), "credits backed");
    }
}

contract RoutrLaunchShapeTest is LaunchEdgeBase {
    using StateLibrary for IPoolManager;

    SwitchableRecipient internal vault;
    SwitchableRecipient internal wallet;

    function setUp() public {
        vault = new SwitchableRecipient();
        wallet = new SwitchableRecipient();
        _setUpWith(payable(address(vault)), payable(address(wallet)), true);
    }

    /// @dev On the launch pool the first buy finds no ETH in the manager. Every mode must still pay 2%.
    function test_allFourModesOnTokenOnlyPoolPayExactly() public {
        _swapAndCheck(true, -5 ether);
        _swapAndCheck(true, 3 ether);
        _swapAndCheck(false, -1 ether);
        _swapAndCheck(false, 1 ether);
        hook.flush();
        assertEq(hook.totalCredits(), 0);
        assertEq(manager.balanceOf(address(hook), 0), 0);
    }

    function test_exactOutputBuyIsFirstTradeOnTokenOnlyPool() public {
        (uint256 gross, uint256 fee) = _swapAndCheck(true, 1000 ether);
        assertEq(manager.balanceOf(address(hook), 0), fee, "fee held as a native claim");
        assertEq(address(vault).balance, 0);
        hook.flush();
        assertEq(address(vault).balance, gross * 150 / 10_000);
        assertEq(address(wallet).balance, fee - gross * 150 / 10_000);
    }

    /// forge-config: default.fuzz.runs = 300
    function testFuzz_tinyAndLargeAmountsNeverRevertAndRoundDown(uint256 raw, uint8 mode) public {
        bool buy = mode % 2 == 0;
        bool exactIn = (mode / 2) % 2 == 0;
        // Buys may be any size up to 50 ETH; sells first need ROUTR/ETH in the pool, so buy first.
        if (!buy) _swapAndCheck(true, -60 ether);
        uint256 amount = raw % 3 == 0 ? bound(raw, 1, 200) : bound(raw, 1, 40 ether);
        (uint256 gross, uint256 fee) = _swapAndCheck(buy, exactIn ? -int256(amount) : int256(amount));
        assertLe(fee * 10_000, gross * 200, "never more than 2%");
        if (gross >= 50) assertGt(fee, 0, "any swap of 50 wei or more pays");
    }

    function test_rejectingVaultOnClaimPathKeepsCreditUntilWithdrawn() public {
        vault.setRejecting(true);
        _swapAndCheck(true, -10 ether);
        hook.flush(); // redeems the claim, payment to the vault fails again, credit stays
        assertEq(hook.credits(address(vault)), 0.15 ether);
        assertEq(address(hook).balance, 0.15 ether);
        assertEq(address(wallet).balance, 0.05 ether);
        // Further trades continue to work while the vault still rejects.
        _swapAndCheck(false, -1 ether);
        address payable elsewhere = payable(makeAddr("vault treasury"));
        uint256 owed = hook.credits(address(vault));
        vault.pull(hook, elsewhere);
        assertEq(elsewhere.balance, owed);
        assertEq(hook.credits(address(vault)), 0);
        // The wallet cannot pull what it is not owed, and the vault cannot pull twice.
        vm.expectRevert(RoutrHook.NothingToWithdraw.selector);
        vault.pull(hook, elsewhere);
    }

    function test_withdrawRedeemsOutstandingClaimDirectly() public {
        _swapAndCheck(true, -10 ether);
        assertEq(address(hook).balance, 0);
        assertEq(manager.balanceOf(address(hook), 0), 0.2 ether);
        wallet.pull(hook, payable(address(wallet)));
        assertEq(address(wallet).balance, 0.05 ether);
        assertEq(manager.balanceOf(address(hook), 0), 0.15 ether);
        assertEq(hook.totalCredits(), 0.15 ether);
    }

    function test_withdrawRejectsForbiddenDestinations() public {
        _swapAndCheck(true, -10 ether);
        vm.expectRevert(RoutrHook.InvalidAddress.selector);
        vault.pull(hook, payable(address(hook)));
        vm.expectRevert(RoutrHook.InvalidAddress.selector);
        vault.pull(hook, payable(address(manager)));
        vm.expectRevert(RoutrHook.InvalidAddress.selector);
        vault.pull(hook, payable(address(0)));
        assertEq(hook.credits(address(vault)), 0.15 ether);
    }

    function test_strangersCannotPullOrRedirectRecipientCredit() public {
        _swapAndCheck(true, -10 ether);
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(RoutrHook.NothingToWithdraw.selector);
        hook.withdraw(payable(stranger));
        // flush is permissionless but only ever pays the fixed recipients.
        vm.prank(stranger);
        hook.flush();
        assertEq(stranger.balance, 0);
        assertEq(address(vault).balance, 0.15 ether);
        assertEq(address(wallet).balance, 0.05 ether);
    }

    function test_hookRefusesDirectETH() public {
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(hook).call{value: 1 ether}("");
        assertFalse(ok);
    }

    function test_noLiquidityRemovalOfAnyShape() public {
        uint128 before = IPoolManager(manager).getLiquidity(key.toId());
        vm.expectRevert();
        launcher.modify(key, ModifyLiquidityParams(-6000, 0, -1_000_000 ether, bytes32(0)));
        vm.expectRevert();
        launcher.modify(key, ModifyLiquidityParams(-6000, 0, -1, bytes32(0)));
        // Removing a range that has no position also reverts (in the hook or in core).
        vm.expectRevert();
        launcher.modify(key, ModifyLiquidityParams(-60, 60, -1, bytes32(0)));
        assertEq(IPoolManager(manager).getLiquidity(key.toId()), before);
    }

    /// @dev A third-party LP's deposit is locked as well: nobody gets a removal exception.
    function test_thirdPartyLiquidityIsLockedToo() public {
        trader.modify(key, ModifyLiquidityParams(-120, 120, 10 ether, bytes32("lp")));
        (uint128 liq,,) = IPoolManager(manager).getPositionInfo(key.toId(), address(trader), -120, 120, bytes32("lp"));
        assertEq(liq, 10 ether);
        vm.expectRevert();
        trader.modify(key, ModifyLiquidityParams(-120, 120, -10 ether, bytes32("lp")));
        (liq,,) = IPoolManager(manager).getPositionInfo(key.toId(), address(trader), -120, 120, bytes32("lp"));
        assertEq(liq, 10 ether);
    }

    /// forge-config: default.fuzz.runs = 300
    function testFuzz_removalAlwaysRevertsThroughPoolManager(int24 lowerRaw, uint24 width, uint128 amount, bytes32 salt)
        public
    {
        int24 lower = int24(bound(lowerRaw, -6000, 5940)) / 60 * 60;
        int24 upper = lower + int24(uint24(bound(width, 1, 100))) * 60;
        int256 liquidity = -int256(bound(amount, 1, 1_000_000 ether));
        uint128 before = IPoolManager(manager).getLiquidity(key.toId());
        vm.expectRevert();
        launcher.modify(key, ModifyLiquidityParams(lower, upper, liquidity, salt));
        assertEq(IPoolManager(manager).getLiquidity(key.toId()), before);
    }

    function test_bindingIsFinal() public {
        // Same pool again: core refuses.
        vm.expectRevert();
        manager.initialize(key, RoutrLaunchKit.SQRT_PRICE_1_1);
        // Any other pool on this hook: the hook refuses, even with the correct currencies.
        PoolKey memory other = key;
        other.fee = 3000;
        vm.expectRevert();
        manager.initialize(other, RoutrLaunchKit.SQRT_PRICE_1_1);
        other = key;
        other.tickSpacing = 10;
        vm.expectRevert();
        manager.initialize(other, RoutrLaunchKit.SQRT_PRICE_1_1);
        // A second bind attempt through the callback itself.
        vm.prank(address(manager));
        vm.expectRevert(RoutrHook.AlreadyInitialized.selector);
        hook.afterInitialize(address(this), key, RoutrLaunchKit.SQRT_PRICE_1_1, 0);
    }

    function test_constantsAreTheAdvertisedRates() public view {
        assertEq(hook.FEE_BPS(), 200);
        assertEq(hook.RESEARCH_BPS(), 150);
        assertEq(hook.TEAM_BPS(), 50);
        assertEq(hook.BPS(), 10_000);
        assertEq(hook.RESEARCH_BPS() + hook.TEAM_BPS(), hook.FEE_BPS());
        assertEq(hook.researchVault(), address(vault));
        assertEq(hook.teamWallet(), address(wallet));
        assertEq(address(hook.poolManager()), address(manager));
        assertEq(hook.token(), address(token));
    }
}

/// @dev The hook built with the launch's real recipients, the vault's code replaced by one that rejects ETH.
contract RoutrRealRecipientsTest is LaunchEdgeBase {
    function setUp() public {
        _setUpWith(RoutrLaunchKit.RESEARCH_VAULT, RoutrLaunchKit.TEAM_WALLET, false);
    }

    function test_realRecipientsReceiveTheSplitOnEveryMode() public {
        _swapAndCheck(true, -10 ether);
        _swapAndCheck(true, 10 ether);
        _swapAndCheck(false, -10 ether);
        _swapAndCheck(false, 10 ether);
        assertEq(hook.totalCredits(), 0, "funded pool pays directly");
        assertGt(RoutrLaunchKit.RESEARCH_VAULT.balance, 0);
        assertGt(RoutrLaunchKit.TEAM_WALLET.balance, 0);
    }

    function test_rejectingVaultCodeIsCreditedAndCanWithdraw() public {
        vm.etch(RoutrLaunchKit.RESEARCH_VAULT, address(new AlwaysRejects()).code);
        _swapAndCheck(true, -10 ether);
        _swapAndCheck(false, -10 ether);
        uint256 owed = hook.credits(RoutrLaunchKit.RESEARCH_VAULT);
        assertGt(owed, 0.15 ether);
        assertEq(hook.credits(RoutrLaunchKit.TEAM_WALLET), 0);
        // Still rejecting: an attempted withdrawal to itself fails and keeps the credit.
        vm.prank(RoutrLaunchKit.RESEARCH_VAULT);
        vm.expectRevert(RoutrHook.ETHTransferFailed.selector);
        hook.withdraw(RoutrLaunchKit.RESEARCH_VAULT);
        assertEq(hook.credits(RoutrLaunchKit.RESEARCH_VAULT), owed);
        address payable treasury = payable(makeAddr("research treasury"));
        vm.prank(RoutrLaunchKit.RESEARCH_VAULT);
        hook.withdraw(treasury);
        assertEq(treasury.balance, owed);
        assertEq(hook.totalCredits(), 0);
        assertEq(address(hook).balance, 0);
    }
}
