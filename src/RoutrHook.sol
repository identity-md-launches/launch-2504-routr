// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";

/// @title Routr research funding hook
/// @notice An immutable 2% fee on gross ETH traded: 1.5% research, 0.5% team.
/// @dev Native ETH is currency0. Callback permissions are encoded in the deployment address.
///      No owner, upgrade path, fee setter, or liquidity withdrawal exception exists.
contract RoutrHook is IUnlockCallback {
    using SafeCast for uint256;
    using TransientStateLibrary for IPoolManager;

    uint256 public constant BPS = 10_000;
    uint256 public constant FEE_BPS = 200;
    uint256 public constant RESEARCH_BPS = 150;
    uint256 public constant TEAM_BPS = 50;
    uint24 public constant POOL_FEE = 12_500;
    int24 public constant TICK_SPACING = 60;
    uint160 public constant HOOK_FLAGS = 0x12cc;
    /// @dev Bound automatic pushes so a reverting or gas-consuming recipient cannot halt swaps.
    uint256 public constant PAYOUT_GAS = 50_000;

    IPoolManager public immutable poolManager;
    address public immutable token;
    address payable public immutable researchVault;
    address payable public immutable teamWallet;

    bool public initialized;
    PoolId public poolId;
    /// @notice Unpaid ETH, backed by this hook's ETH and native ERC-6909 claims on PoolManager.
    mapping(address recipient => uint256 amount) public credits;
    uint256 public totalCredits;

    bytes32 private constant ENTERED_SLOT = keccak256("routr.hook.entered");
    bytes32 private constant CONTEXT_SLOT = keccak256("routr.hook.swap.context");
    bytes32 private constant FEE_SLOT = keccak256("routr.hook.swap.fee");
    bytes32 private constant REDEEM_SLOT = keccak256("routr.hook.redeem.amount");

    error OnlyPoolManager();
    error InvalidAddress();
    error InvalidPool();
    error AlreadyInitialized();
    error PoolNotInitialized();
    error LiquidityLocked();
    error ReentrantCall();
    error InvalidSwapContext();
    error InvalidSwapAmount();
    error PartialFill();
    error NothingToWithdraw();
    error InsufficientNativeLiquidity();
    error ETHTransferFailed();
    error UnexpectedUnlock();

    event PoolBound(PoolId indexed id);
    event FeeCharged(PoolId indexed id, bool buy, uint256 grossETH, uint256 research, uint256 team, bool asClaims);
    event Payment(address indexed recipient, uint256 amount);
    event CreditAccrued(address indexed recipient, uint256 amount);
    event Withdrawal(address indexed recipient, address indexed to, uint256 amount);
    event ClaimsRedeemed(uint256 amount);

    constructor(IPoolManager manager_, address token_, address payable researchVault_, address payable teamWallet_) {
        if (
            address(manager_) == address(0) || token_ == address(0) || token_ == address(manager_)
                || researchVault_ == address(0) || teamWallet_ == address(0) || researchVault_ == address(this)
                || teamWallet_ == address(this) || researchVault_ == address(manager_)
                || teamWallet_ == address(manager_)
        ) revert InvalidAddress();
        poolManager = manager_;
        token = token_;
        researchVault = researchVault_;
        teamWallet = teamWallet_;
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        _;
    }

    modifier nonReentrant() {
        if (_load(ENTERED_SLOT) != 0) revert ReentrantCall();
        _store(ENTERED_SLOT, 1);
        _;
        _store(ENTERED_SLOT, 0);
    }

    function getHookPermissions() public pure returns (Hooks.Permissions memory p) {
        p.afterInitialize = true;
        p.beforeRemoveLiquidity = true;
        p.beforeSwap = true;
        p.afterSwap = true;
        p.beforeSwapReturnDelta = true;
        p.afterSwapReturnDelta = true;
    }

    /// @notice Bind once to the native ETH / ROUTR pool, including fee, spacing, and hook address.
    function afterInitialize(address, PoolKey calldata key, uint160, int24) external onlyPoolManager returns (bytes4) {
        if (initialized) revert AlreadyInitialized();
        if (
            !key.currency0.isAddressZero() || Currency.unwrap(key.currency1) != token
                || address(key.hooks) != address(this) || key.fee != POOL_FEE || key.tickSpacing != TICK_SPACING
        ) revert InvalidPool();
        initialized = true;
        poolId = key.toId();
        emit PoolBound(poolId);
        return IHooks.afterInitialize.selector;
    }

    /// @notice Every removal callback reverts, including zero-liquidity fee collection.
    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        revert LiquidityLocked();
    }

    /// @dev When ETH is specified, charge it here; otherwise its actual amount is known only afterSwap.
    function beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        _checkPool(key);
        if (_load(ENTERED_SLOT) != 0) revert ReentrantCall();
        int256 specified = params.amountSpecified;
        if (specified == 0 || specified > type(int128).max || specified < -int256(type(int128).max)) {
            revert InvalidSwapAmount();
        }
        _store(ENTERED_SLOT, 1);
        _store(CONTEXT_SLOT, uint256(keccak256(abi.encode(sender, key, params))));

        uint256 fee = 0;
        bool ethSpecified = (specified < 0) == params.zeroForOne;
        if (ethSpecified) {
            if (specified < 0) {
                // Exact-input buy: the user's ETH budget includes the fee.
                fee = uint256(-specified) * FEE_BPS / BPS;
            } else {
                // Exact-output sell: request extra ETH from the AMM so the user receives the net target.
                fee = uint256(specified) * FEE_BPS / (BPS - FEE_BPS);
                (uint256(specified) + fee).toInt128();
            }
        }
        _store(FEE_SLOT, fee);
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(fee.toInt128(), 0), 0);
    }

    function afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) external onlyPoolManager returns (bytes4, int128) {
        _checkPool(key);
        if (_load(ENTERED_SLOT) != 1 || _load(CONTEXT_SLOT) != uint256(keccak256(abi.encode(sender, key, params)))) {
            revert InvalidSwapContext();
        }

        bool ethSpecified = (params.amountSpecified < 0) == params.zeroForOne;
        uint256 fee = _load(FEE_SLOT);
        int256 ethDelta = int256(delta.amount0());
        if (params.zeroForOne ? ethDelta > 0 : ethDelta < 0) revert InvalidSwapAmount();
        uint256 ammETH = uint256(ethDelta < 0 ? -ethDelta : ethDelta);
        uint256 grossETH;

        if (ethSpecified) {
            // afterSwap can only adjust the unspecified currency. Never retain a fee on unfilled ETH.
            if (ethDelta != params.amountSpecified + int256(fee)) revert PartialFill();
            grossETH = params.zeroForOne ? ammETH + fee : ammETH;
        } else {
            if (params.zeroForOne) {
                if (int256(delta.amount1()) != params.amountSpecified) revert PartialFill();
                // Exact-output buy: add the fee to actual AMM input, on the same gross-ETH basis.
                fee = ammETH * FEE_BPS / (BPS - FEE_BPS);
                grossETH = ammETH + fee;
                grossETH.toInt128();
            } else {
                // Exact-input sell: use actual ETH output, including partial fills at the price bound.
                grossETH = ammETH;
                fee = grossETH * FEE_BPS / BPS;
            }
        }

        uint256 research = grossETH * RESEARCH_BPS / BPS;
        uint256 team = fee - research; // Assign at most one wei of split-rounding dust to the team.
        bool asClaims = address(poolManager).balance < fee;
        if (fee != 0) {
            if (asClaims) {
                poolManager.mint(address(this), 0, fee);
                _credit(researchVault, research);
                _credit(teamWallet, team);
            } else {
                poolManager.take(Currency.wrap(address(0)), address(this), fee);
                _payOrCredit(researchVault, research);
                _payOrCredit(teamWallet, team);
            }
        }
        emit FeeCharged(poolId, params.zeroForOne, grossETH, research, team, asClaims);
        _store(FEE_SLOT, 0);
        _store(CONTEXT_SLOT, 0);
        _store(ENTERED_SLOT, 0);
        return (IHooks.afterSwap.selector, ethSpecified ? int128(0) : fee.toInt128());
    }

    /// @notice Anyone may redeem available native claims and retry payment to the fixed recipients.
    /// @dev Can be called after a router settles, either inside its unlock or in a later transaction.
    ///      A failed recipient stays credited. No caller-selected address receives these funds.
    function flush() external nonReentrant {
        uint256 claims = poolManager.balanceOf(address(this), 0);
        uint256 available = address(poolManager).balance;
        uint256 redeem = claims < available ? claims : available;
        uint256 maxDelta = uint256(uint128(type(int128).max));
        if (redeem > maxDelta) redeem = maxDelta;
        if (redeem != 0) _redeem(redeem);
        _retry(researchVault);
        _retry(teamWallet);
    }

    /// @notice Withdraw only the caller's credit, optionally to a different address that accepts ETH.
    /// @dev A recipient contract must expose a way to call this, or accept a later flush payment.
    function withdraw(address payable to) external nonReentrant {
        if (to == address(0) || to == address(this) || to == address(poolManager)) revert InvalidAddress();
        uint256 amount = credits[msg.sender];
        if (amount == 0) revert NothingToWithdraw();
        credits[msg.sender] = 0;
        totalCredits -= amount;
        if (address(this).balance < amount) {
            uint256 needed = amount - address(this).balance;
            if (address(poolManager).balance < needed || poolManager.balanceOf(address(this), 0) < needed) {
                revert InsufficientNativeLiquidity();
            }
            _redeem(needed);
        }
        (bool paid,) = to.call{value: amount}("");
        if (!paid) revert ETHTransferFailed();
        emit Withdrawal(msg.sender, to, amount);
    }

    function unlockCallback(bytes calldata) external onlyPoolManager returns (bytes memory) {
        uint256 amount = _load(REDEEM_SLOT);
        if (_load(ENTERED_SLOT) != 1 || amount == 0) revert UnexpectedUnlock();
        _store(REDEEM_SLOT, 0);
        _burnAndTake(amount);
        return "";
    }

    receive() external payable onlyPoolManager {}

    function _checkPool(PoolKey calldata key) private view {
        if (!initialized) revert PoolNotInitialized();
        if (PoolId.unwrap(key.toId()) != PoolId.unwrap(poolId)) revert InvalidPool();
    }

    function _credit(address recipient, uint256 amount) private {
        if (amount == 0) return;
        credits[recipient] += amount;
        totalCredits += amount;
        emit CreditAccrued(recipient, amount);
    }

    function _payOrCredit(address payable recipient, uint256 amount) private {
        if (amount == 0) return;
        // Do not copy recipient-controlled return data, even if it returns/reverts with a large payload.
        bool paid;
        uint256 gasBudget = PAYOUT_GAS;
        assembly ("memory-safe") {
            paid := call(gasBudget, recipient, amount, 0, 0, 0, 0)
        }
        if (paid) emit Payment(recipient, amount);
        else _credit(recipient, amount);
    }

    function _retry(address payable recipient) private {
        uint256 owed = credits[recipient];
        uint256 amount = owed < address(this).balance ? owed : address(this).balance;
        if (amount == 0) return;
        credits[recipient] = owed - amount;
        totalCredits -= amount;
        _payOrCredit(recipient, amount);
    }

    function _redeem(uint256 amount) private {
        if (poolManager.isUnlocked()) {
            _burnAndTake(amount);
        } else {
            _store(REDEEM_SLOT, amount);
            poolManager.unlock("");
        }
        emit ClaimsRedeemed(amount);
    }

    function _burnAndTake(uint256 amount) private {
        poolManager.burn(address(this), 0, amount);
        poolManager.take(Currency.wrap(address(0)), address(this), amount);
    }

    function _load(bytes32 slot) private view returns (uint256 value) {
        assembly ("memory-safe") {
            value := tload(slot)
        }
    }

    function _store(bytes32 slot, uint256 value) private {
        assembly ("memory-safe") {
            tstore(slot, value)
        }
    }
}
