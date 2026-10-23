// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {RoutrToken} from "../src/RoutrToken.sol";

/// @dev Random transfers, approvals and transferFroms between a few holders; each call checks its own effect.
contract TokenHandler is Test {
    RoutrToken public immutable token;
    address[4] public actors;

    constructor() {
        token = new RoutrToken();
        actors = [makeAddr("a0"), makeAddr("a1"), makeAddr("a2"), makeAddr("a3")];
        uint256 quarter = token.totalSupply() / 4;
        for (uint256 i; i < 4; i++) {
            token.transfer(actors[i], quarter);
        }
    }

    function transfer(uint8 fromSeed, uint8 toSeed, uint256 raw) external {
        address from = actors[fromSeed % 4];
        address to = actors[toSeed % 4];
        uint256 amount = bound(raw, 0, token.balanceOf(from));
        uint256 fromBefore = token.balanceOf(from);
        uint256 toBefore = token.balanceOf(to);
        vm.prank(from);
        assertTrue(token.transfer(to, amount));
        if (from == to) {
            assertEq(token.balanceOf(from), fromBefore, "self transfer is a no-op");
        } else {
            assertEq(token.balanceOf(from), fromBefore - amount, "exact debit");
            assertEq(token.balanceOf(to), toBefore + amount, "exact credit, no tax");
        }
    }

    function overspend(uint8 fromSeed, uint8 toSeed, uint256 raw) external {
        address from = actors[fromSeed % 4];
        uint256 balance = token.balanceOf(from);
        uint256 amount = bound(raw, balance + 1, type(uint256).max);
        vm.prank(from);
        vm.expectRevert(RoutrToken.InsufficientBalance.selector);
        token.transfer(actors[toSeed % 4], amount);
    }

    function approve(uint8 ownerSeed, uint8 spenderSeed, uint256 amount) external {
        address owner = actors[ownerSeed % 4];
        address spender = actors[spenderSeed % 4];
        vm.prank(owner);
        token.approve(spender, amount);
        assertEq(token.allowance(owner, spender), amount);
    }

    function transferFrom(uint8 ownerSeed, uint8 spenderSeed, uint8 toSeed, uint256 raw) external {
        address owner = actors[ownerSeed % 4];
        address spender = actors[spenderSeed % 4];
        address to = actors[toSeed % 4];
        uint256 allowed = token.allowance(owner, spender);
        uint256 balance = token.balanceOf(owner);
        uint256 amount = bound(raw, 0, allowed < balance ? allowed : balance);
        vm.prank(spender);
        assertTrue(token.transferFrom(owner, to, amount));
        uint256 expected = allowed == type(uint256).max ? allowed : allowed - amount;
        assertEq(token.allowance(owner, spender), expected, "allowance spent exactly once");
    }

    function transferFromBeyondAllowance(uint8 ownerSeed, uint8 spenderSeed, uint256 raw) external {
        address owner = actors[ownerSeed % 4];
        address spender = actors[spenderSeed % 4];
        uint256 allowed = token.allowance(owner, spender);
        if (allowed == type(uint256).max) return;
        uint256 amount = bound(raw, allowed + 1, type(uint256).max);
        vm.prank(spender);
        vm.expectRevert();
        token.transferFrom(owner, spender, amount);
    }
}

contract RoutrTokenInvariantTest is StdInvariant, Test {
    TokenHandler internal handler;

    function setUp() public {
        handler = new TokenHandler();
        targetContract(address(handler));
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 50
    function invariant_supplyIsFixedAndFullyHeld() public view {
        RoutrToken token = handler.token();
        assertEq(token.totalSupply(), 1_000_000_000 ether);
        uint256 sum;
        for (uint256 i; i < 4; i++) {
            sum += token.balanceOf(handler.actors(i));
        }
        assertEq(sum, token.totalSupply());
        assertEq(token.balanceOf(address(handler)), 0);
        assertEq(token.balanceOf(address(0)), 0);
    }
}
