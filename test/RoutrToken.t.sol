// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {RoutrToken} from "../src/RoutrToken.sol";
import {Recipient} from "./helpers/Recipients.sol";

contract RoutrTokenTest is Test {
    RoutrToken internal token;
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        token = new RoutrToken();
    }

    function test_metadataAndFixedSupply() public view {
        assertEq(token.name(), "Routr");
        assertEq(token.symbol(), "ROUTR");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), 1_000_000_000 ether);
        assertEq(token.balanceOf(address(this)), token.totalSupply());
        assertEq(token.WEBSITE(), "https://imdroutr.network");
        assertEq(token.TWITTER(), "https://x.com/routr_network");
        assertEq(
            token.DESCRIPTION(),
            "routr/ funds open research through a token. Trades feed a vault, and specialized agents from the imd.fun swarm take paid jobs in cancer, disease, medicine, robotics and AI. Every job, result and payment is public."
        );
    }

    function test_walletAndContractTransfersHaveNoTax() public {
        Recipient a = new Recipient();
        Recipient b = new Recipient();
        token.transfer(alice, 100 ether);
        vm.prank(alice);
        token.transfer(bob, 60 ether);
        token.transfer(address(a), 70 ether);
        vm.prank(address(a));
        token.transfer(address(b), 70 ether);
        assertEq(token.balanceOf(alice), 40 ether);
        assertEq(token.balanceOf(bob), 60 ether);
        assertEq(token.balanceOf(address(a)), 0);
        assertEq(token.balanceOf(address(b)), 70 ether);
        assertEq(token.totalSupply(), 1_000_000_000 ether);
    }

    function test_approvalAndTransferFrom() public {
        token.transfer(alice, 100);
        vm.prank(alice);
        assertTrue(token.approve(bob, 80));
        vm.prank(bob);
        assertTrue(token.transferFrom(alice, bob, 50));
        assertEq(token.allowance(alice, bob), 30);
        assertEq(token.balanceOf(alice), 50);
        assertEq(token.balanceOf(bob), 50);
        vm.prank(bob);
        vm.expectRevert(RoutrToken.InsufficientAllowance.selector);
        token.transferFrom(alice, bob, 31);
        vm.prank(alice);
        token.approve(bob, type(uint256).max);
        vm.prank(bob);
        token.transferFrom(alice, bob, 50);
        assertEq(token.allowance(alice, bob), type(uint256).max);
    }

    function test_invalidTransfersRevertWithoutChangingState() public {
        vm.expectRevert(RoutrToken.InvalidAddress.selector);
        token.transfer(address(0), 1);
        vm.expectRevert(RoutrToken.InvalidAddress.selector);
        token.approve(address(0), 1);
        vm.prank(alice);
        vm.expectRevert(RoutrToken.InsufficientBalance.selector);
        token.transfer(bob, 1);
        vm.prank(bob);
        vm.expectRevert(RoutrToken.InsufficientAllowance.selector);
        token.transferFrom(address(this), bob, 1);
        assertEq(token.balanceOf(address(this)), token.totalSupply());
    }

    function test_noAdministrativeOrSupplyChangingEntryPoints() public {
        string[10] memory signatures = [
            "mint(address,uint256)",
            "burn(uint256)",
            "burnFrom(address,uint256)",
            "pause()",
            "blacklist(address)",
            "owner()",
            "transferOwnership(address)",
            "initialize(address)",
            "upgradeTo(address)",
            "setTax(uint256)"
        ];
        for (uint256 i; i < signatures.length; ++i) {
            (bool ok,) = address(token).call(abi.encodeWithSignature(signatures[i], alice, 1 ether));
            assertFalse(ok, signatures[i]);
        }
        assertEq(token.totalSupply(), 1_000_000_000 ether);
    }

    function testFuzz_conservationAndSelfTransfer(uint256 amount) public {
        amount = bound(amount, 0, token.totalSupply());
        token.transfer(alice, amount);
        vm.prank(alice);
        token.transfer(alice, amount);
        assertEq(token.balanceOf(alice), amount);
        vm.prank(alice);
        token.transfer(bob, amount);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob) + token.balanceOf(address(this)), token.totalSupply());
    }
}
