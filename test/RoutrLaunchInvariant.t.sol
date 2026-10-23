// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {RoutrHook} from "../src/RoutrHook.sol";
import {RoutrToken} from "../src/RoutrToken.sol";
import {LaunchRouter, SwitchableRecipient, RoutrLaunchKit} from "./helpers/RoutrLaunchKit.sol";

/// @dev Drives the launch-shape pool (seeded with ROUTR only, fresh manager) with random trades of all four
///      kinds, recipient outages, flushes, withdrawals, fee collection and removal attempts.
contract LaunchHandler is Test {
    using StateLibrary for IPoolManager;

    uint256 public constant TRADER_ETH = 100_000 ether;
    /// @dev ROUTR the trader keeps aside to settle exact-output sells; only bought ROUTR is sold exact-input.
    uint256 public constant TRADER_RESERVE = 10_000_000 ether;

    PoolManager public immutable manager;
    RoutrToken public immutable token;
    RoutrHook public immutable hook;
    LaunchRouter public immutable launcher;
    LaunchRouter public immutable trader;
    SwitchableRecipient public immutable vault;
    SwitchableRecipient public immutable wallet;
    address payable public immutable sink;
    PoolKey internal key;

    uint256 public ghostResearch;
    uint256 public ghostTeam;
    uint256 public ghostTrades;
    uint256 public ghostWithdrawn;
    uint256 public removalSuccesses;
    uint128 public initialLiquidity;

    constructor() {
        manager = new PoolManager(address(this));
        token = new RoutrToken();
        vault = new SwitchableRecipient();
        wallet = new SwitchableRecipient();
        sink = payable(address(uint160(uint256(keccak256("routr invariant sink")))));
        hook = RoutrLaunchKit.deployHook(manager, address(token), payable(address(vault)), payable(address(wallet)));
        key = RoutrLaunchKit.keyFor(token, hook);
        launcher = new LaunchRouter(manager);
        trader = new LaunchRouter(manager);
        token.transfer(address(trader), TRADER_RESERVE);
        token.transfer(address(launcher), token.totalSupply() - TRADER_RESERVE);
        vm.deal(address(trader), TRADER_ETH);
        manager.initialize(key, RoutrLaunchKit.SQRT_PRICE_1_1);
        launcher.modify(key, ModifyLiquidityParams(-6000, 0, 1_000_000 ether, bytes32(0)));
        initialLiquidity = positionLiquidity();
        require(initialLiquidity == 1_000_000 ether, "seeded");
    }

    function positionLiquidity() public view returns (uint128 liquidity) {
        (liquidity,,) = IPoolManager(manager).getPositionInfo(key.toId(), address(launcher), -6000, 0, bytes32(0));
    }

    function poolKey() external view returns (PoolKey memory) {
        return key;
    }

    function buy(uint256 raw, bool exactIn) external {
        uint256 amount = bound(raw, 1, 20 ether);
        _trade(true, exactIn ? -int256(amount) : int256(amount));
    }

    function sell(uint256 raw, bool exactIn) external {
        if (exactIn) {
            uint256 balance = token.balanceOf(address(trader));
            uint256 held = balance > TRADER_RESERVE ? balance - TRADER_RESERVE : 0;
            if (held < 2) return;
            _trade(false, -int256(bound(raw, 1, held / 2)));
        } else {
            // ETH the pool can pay out: everything the manager holds beyond the hook's claims.
            uint256 poolETH = address(manager).balance - manager.balanceOf(address(hook), 0);
            if (poolETH < 4) return;
            _trade(false, int256(bound(raw, 1, poolETH / 4)));
        }
    }

    function _trade(bool isBuy, int256 amount) private {
        uint256 researchBefore = _accrued(address(vault));
        uint256 teamBefore = _accrued(address(wallet));
        (BalanceDelta delta, int128 core0, int128 core1) = trader.swap(key, RoutrLaunchKit.params(isBuy, amount));
        uint256 gross;
        uint256 fee;
        if (isBuy) {
            gross = uint256(-int256(delta.amount0()));
            fee = gross - uint256(-int256(core0));
        } else {
            gross = uint256(int256(core0));
            fee = gross - uint256(int256(delta.amount0()));
        }
        uint256 researchFee = gross * 150 / 10_000;
        assertEq(fee, gross * 200 / 10_000, "fee is 2% of the ETH side");
        assertEq(_accrued(address(vault)) - researchBefore, researchFee, "research share");
        assertEq(_accrued(address(wallet)) - teamBefore, fee - researchFee, "team share");
        assertEq(delta.amount1(), core1, "no token tax");
        ghostResearch += researchFee;
        ghostTeam += fee - researchFee;
        ghostTrades++;
    }

    function setAcceptance(bool vaultRejects, bool walletRejects) external {
        vault.setRejecting(vaultRejects);
        wallet.setRejecting(walletRejects);
    }

    function flush() external {
        hook.flush();
    }

    function withdraw(bool fromVault) external {
        SwitchableRecipient who = fromVault ? vault : wallet;
        uint256 owed = hook.credits(address(who));
        if (owed == 0) return;
        uint256 before = sink.balance;
        who.pull(hook, sink);
        assertEq(sink.balance - before, owed, "withdraws exactly the credit");
        assertEq(hook.credits(address(who)), 0);
        ghostWithdrawn += owed;
    }

    function collectFees() external {
        launcher.modify(key, ModifyLiquidityParams(-6000, 0, 0, bytes32(0)));
    }

    function tryRemove(uint256 raw, bool wholeRange) external {
        int256 liquidity = -int256(bound(raw, 1, initialLiquidity));
        ModifyLiquidityParams memory p = wholeRange
            ? ModifyLiquidityParams(-6000, 0, liquidity, bytes32(0))
            : ModifyLiquidityParams(-600, 0, liquidity, bytes32(0));
        try launcher.modify(key, p) {
            removalSuccesses++;
        } catch {}
    }

    function _accrued(address who) private view returns (uint256) {
        return who.balance + hook.credits(who);
    }
}

contract RoutrLaunchInvariantTest is StdInvariant, Test {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    LaunchHandler internal handler;
    uint256 internal ethTotal;

    function setUp() public {
        handler = new LaunchHandler();
        ethTotal = _ethEverywhere();
        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = LaunchHandler.buy.selector;
        selectors[1] = LaunchHandler.sell.selector;
        selectors[2] = LaunchHandler.setAcceptance.selector;
        selectors[3] = LaunchHandler.flush.selector;
        selectors[4] = LaunchHandler.withdraw.selector;
        selectors[5] = LaunchHandler.collectFees.selector;
        selectors[6] = LaunchHandler.tryRemove.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function _ethEverywhere() internal view returns (uint256) {
        return address(handler.manager()).balance + address(handler.trader()).balance
            + address(handler.launcher()).balance + address(handler.vault()).balance + address(handler.wallet()).balance
            + address(handler.hook()).balance + handler.sink().balance;
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 40
    function invariant_liquidityNeverLeavesThePool() public view {
        assertEq(handler.positionLiquidity(), handler.initialLiquidity());
        assertEq(handler.removalSuccesses(), 0, "a removal went through");
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 40
    function invariant_creditsAreFullyBacked() public view {
        RoutrHook hook = handler.hook();
        address vault = address(handler.vault());
        address wallet = address(handler.wallet());
        assertEq(hook.totalCredits(), hook.credits(vault) + hook.credits(wallet), "credit bookkeeping");
        assertEq(
            hook.totalCredits(),
            address(hook).balance + handler.manager().balanceOf(address(hook), 0),
            "credits equal ETH + native claims"
        );
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 40
    function invariant_recipientsAreOwedExactlyTheirSplit() public view {
        RoutrHook hook = handler.hook();
        address vault = address(handler.vault());
        address wallet = address(handler.wallet());
        assertEq(
            vault.balance + wallet.balance + hook.totalCredits() + handler.sink().balance,
            handler.ghostResearch() + handler.ghostTeam(),
            "every fee wei is paid, owed, or withdrawn"
        );
        assertLe(vault.balance + hook.credits(vault), handler.ghostResearch());
        assertLe(wallet.balance + hook.credits(wallet), handler.ghostTeam());
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 40
    function invariant_ethAndSupplyConserved() public view {
        assertEq(_ethEverywhere(), ethTotal, "native ETH conserved");
        RoutrToken token = handler.token();
        assertEq(token.totalSupply(), 1_000_000_000 ether);
        assertEq(
            token.balanceOf(address(handler.manager())) + token.balanceOf(address(handler.launcher()))
                + token.balanceOf(address(handler.trader())),
            token.totalSupply(),
            "no ROUTR minted, burned or taxed"
        );
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 40
    function invariant_noLeftoverDeltasOrSwapContext() public view {
        IPoolManager manager = IPoolManager(handler.manager());
        assertEq(manager.getNonzeroDeltaCount(), 0);
        assertFalse(manager.isUnlocked());
        assertEq(manager.currencyDelta(address(handler.hook()), Currency.wrap(address(0))), 0);
    }
}
