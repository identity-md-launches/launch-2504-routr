// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {HookTestBase} from "./helpers/HookTestBase.sol";
import {PoolHarness} from "./helpers/PoolHarness.sol";
import {Recipient} from "./helpers/Recipients.sol";
import {RoutrHook} from "../src/RoutrHook.sol";
import {RoutrToken} from "../src/RoutrToken.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";

contract RoutrHandler {
    RoutrHook public immutable hook;
    PoolHarness public immutable router;
    Recipient public immutable research;
    Recipient public immutable team;
    PoolKey private key;
    uint256 public totalFees;
    uint256 public totalResearch;
    uint256 public totalTeam;

    constructor(RoutrHook hook_, PoolKey memory key_, Recipient research_, Recipient team_) {
        hook = hook_;
        key = key_;
        research = research_;
        team = team_;
        router = new PoolHarness(hook_.poolManager());
    }

    function trade(uint96 raw, bool buy, bool exactInput) external {
        uint256 size = uint256(raw) % 1 ether + 10_000;
        uint256 beforeAccrued = address(research).balance + address(team).balance + hook.totalCredits();
        int256 amount = exactInput ? -int256(size) : int256(size);
        BalanceDelta delta = router.swap(
            key, SwapParams(buy, amount, buy ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1), false
        );
        uint256 charged = address(research).balance + address(team).balance + hook.totalCredits() - beforeAccrued;
        uint256 gross = buy ? uint256(-int256(delta.amount0())) : uint256(int256(delta.amount0())) + charged;
        uint256 expectedFee = gross * 200 / 10_000;
        require(charged == expectedFee, "fee conservation");
        uint256 researchFee = gross * 150 / 10_000;
        totalFees += expectedFee;
        totalResearch += researchFee;
        totalTeam += expectedFee - researchFee;
    }

    function changeAcceptance(bool rejectResearch, bool rejectTeam) external {
        research.setReject(rejectResearch);
        team.setReject(rejectTeam);
    }

    function flush() external {
        hook.flush();
    }

    function withdraw(bool fromResearch) external {
        Recipient recipient = fromResearch ? research : team;
        if (hook.credits(address(recipient)) == 0) return;
        recipient.setReject(false);
        recipient.withdraw(hook, payable(address(recipient)));
    }
}

contract RoutrInvariantTest is StdInvariant, HookTestBase {
    using TransientStateLibrary for IPoolManager;
    RoutrHandler private handler;
    uint256 private nativeTotal;

    function setUp() public {
        _deploy();
        _fundedPool();
        handler = new RoutrHandler(hook, key, research, team);
        token.transfer(address(handler.router()), 1_000_000 ether);
        vm.deal(address(handler.router()), 1_000_000 ether);
        nativeTotal = address(manager).balance + address(router).balance + address(handler.router()).balance;
        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = RoutrHandler.trade.selector;
        selectors[1] = RoutrHandler.changeAcceptance.selector;
        selectors[2] = RoutrHandler.flush.selector;
        selectors[3] = RoutrHandler.withdraw.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_allCreditsAreFullyBacked() public view {
        assertEq(hook.totalCredits(), hook.credits(address(research)) + hook.credits(address(team)));
        assertEq(hook.totalCredits(), address(hook).balance + manager.balanceOf(address(hook), 0));
    }

    function invariant_recipientsReceiveExactlyTheirShares() public view {
        assertEq(address(research).balance + hook.credits(address(research)), handler.totalResearch());
        assertEq(address(team).balance + hook.credits(address(team)), handler.totalTeam());
        assertEq(handler.totalResearch() + handler.totalTeam(), handler.totalFees());
    }

    function invariant_nativeETHAndTokenSupplyAreConserved() public view {
        assertEq(
            address(manager).balance + address(router).balance + address(handler.router()).balance
                + address(research).balance + address(team).balance + address(hook).balance,
            nativeTotal
        );
        assertEq(
            token.balanceOf(address(this)) + token.balanceOf(address(router))
                + token.balanceOf(address(handler.router())) + token.balanceOf(address(manager)),
            token.totalSupply()
        );
        assertEq(token.totalSupply(), 1_000_000_000 ether);
    }

    function invariant_managerHasNoUnsettledDeltas() public view {
        assertEq(IPoolManager(manager).getNonzeroDeltaCount(), 0);
        assertEq(IPoolManager(manager).currencyDelta(address(hook), Currency.wrap(address(0))), 0);
        assertEq(IPoolManager(manager).currencyDelta(address(hook), Currency.wrap(address(token))), 0);
        assertFalse(IPoolManager(manager).isUnlocked());
    }
}
