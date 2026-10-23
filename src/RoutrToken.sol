// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title Routr
/// @custom:website https://imdroutr.network
/// @custom:twitter https://x.com/routr_network
/// @notice routr/ funds open research through a token. Trades feed a vault, and specialized agents from the imd.fun swarm take paid jobs in cancer, disease, medicine, robotics and AI. Every job, result and payment is public.
contract RoutrToken {
    string public constant name = "Routr";
    string public constant symbol = "ROUTR";
    uint8 public constant decimals = 18;
    uint256 public constant totalSupply = 1_000_000_000 ether;
    string public constant WEBSITE = "https://imdroutr.network";
    string public constant TWITTER = "https://x.com/routr_network";
    string public constant DESCRIPTION =
        "routr/ funds open research through a token. Trades feed a vault, and specialized agents from the imd.fun swarm take paid jobs in cancer, disease, medicine, robotics and AI. Every job, result and payment is public.";

    mapping(address account => uint256) public balanceOf;
    mapping(address account => mapping(address spender => uint256)) public allowance;

    error InvalidAddress();
    error InsufficientBalance();
    error InsufficientAllowance();

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed account, address indexed spender, uint256 value);

    /// @dev The launch factory receives the entire supply and performs the launch allocation.
    constructor() {
        balanceOf[msg.sender] = totalSupply;
        emit Transfer(address(0), msg.sender, totalSupply);
    }

    function transfer(address to, uint256 value) external returns (bool) {
        _transfer(msg.sender, to, value);
        return true;
    }

    function approve(address spender, uint256 value) external returns (bool) {
        if (spender == address(0)) revert InvalidAddress();
        allowance[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    function transferFrom(address from, address to, uint256 value) external returns (bool) {
        uint256 approved = allowance[from][msg.sender];
        if (approved != type(uint256).max) {
            if (approved < value) revert InsufficientAllowance();
            unchecked {
                allowance[from][msg.sender] = approved - value;
            }
        }
        _transfer(from, to, value);
        return true;
    }

    function _transfer(address from, address to, uint256 value) private {
        if (from == address(0) || to == address(0)) revert InvalidAddress();
        uint256 balance = balanceOf[from];
        if (balance < value) revert InsufficientBalance();
        unchecked {
            balanceOf[from] = balance - value;
            // All balances are bounded by the immutable supply, including self transfers.
            balanceOf[to] += value;
        }
        emit Transfer(from, to, value);
    }
}
