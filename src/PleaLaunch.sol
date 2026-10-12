// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PleaHook} from "./PleaHook.sol";
import {IStacker} from "./interfaces/IStacker.sol";
import {IGate, IPleaHook} from "./interfaces/IPleaParts.sol";

interface IPLEAForLaunch {
    function owner() external view returns (address);
    function setLauncher(address gate, address seasons, address laureates, address distributor) external;
    function setLetterbox(address letterbox) external;
    function init(address hook, address poolManager) external;
}

/// @title PleaLaunch — wires PLEA at launch and deploys the hook afterwards
/// @dev Last contract of the launch. Its constructor (inside the launch transaction) registers the
/// system's contracts with PLEA and commits to the hook's exact init code. After launch, anyone
/// calls `deployHook` with a salt mined off chain (script/MineSalt.s.sol): the hook lands on an
/// address carrying its flag bits, and PLEA mints 87% to it, 3% to Seasons and 10% to the distributor. The result
/// is fully determined by the committed init code, so front-running `deployHook` changes nothing.
/// `seed` opens trading: the owner may call it any time, anyone once `START` has passed.
contract PleaLaunch {
    error WrongInitCode();
    error HookDeployFailed();
    error WrongFlags(address hook);
    error HookAlreadyDeployed();
    error HookNotDeployed();
    error TooEarly(uint256 start);

    event HookDeployed(address indexed hook, bytes32 salt);
    event TradingOpened(uint256 at);

    uint160 public constant FLAG_MASK = (1 << 14) - 1;
    /// beforeInitialize | beforeAddLiquidity | beforeSwap | afterSwap | beforeSwapReturnDelta | afterSwapReturnDelta
    uint160 public constant FLAGS = (1 << 13) | (1 << 11) | (1 << 7) | (1 << 6) | (1 << 3) | (1 << 2);

    address public immutable plea;
    address public immutable gate;
    address public immutable poolManager;
    address public immutable owner;
    /// @notice Latest time trading opens: from then on anyone may call `seed`.
    uint256 public immutable START;
    bytes32 public immutable hookInitCodeHash;

    address public hook;
    bool public opened;

    constructor(
        address plea_,
        address gate_,
        address seasons_,
        address laureates_,
        address distributor_,
        address letterbox_,
        address poolManager_,
        address imd_,
        address stacker_,
        uint256 creditGas_,
        uint256 start_
    ) {
        plea = plea_;
        gate = gate_;
        poolManager = poolManager_;
        START = start_;
        address owner_ = IPLEAForLaunch(plea_).owner();
        owner = owner_;
        hookInitCodeHash = keccak256(
            abi.encodePacked(
                type(PleaHook).creationCode,
                abi.encode(poolManager_, plea_, imd_, stacker_, owner_, seasons_, creditGas_)
            )
        );
        IPLEAForLaunch(plea_).setLauncher(gate_, seasons_, laureates_, distributor_);
        IPLEAForLaunch(plea_).setLetterbox(letterbox_);
    }

    /// @notice Deploys PleaHook with CREATE2 at a flagged address and lets PLEA mint the supply.
    /// `initCode` must be the committed one (PleaHook creation code + its constructor arguments).
    function deployHook(bytes32 salt, bytes calldata initCode) external returns (address deployed) {
        if (hook != address(0)) revert HookAlreadyDeployed();
        if (keccak256(initCode) != hookInitCodeHash) revert WrongInitCode();
        if (uint160(predict(salt)) & FLAG_MASK != FLAGS) revert WrongFlags(predict(salt));
        bytes memory code = initCode;
        assembly ("memory-safe") {
            deployed := create2(0, add(code, 32), mload(code), salt)
        }
        if (deployed == address(0)) revert HookDeployFailed();
        hook = deployed;
        IPLEAForLaunch(plea).init(deployed, poolManager);
        emit HookDeployed(deployed, salt);
    }

    /// @notice The address `deployHook(salt, …)` deploys to.
    function predict(bytes32 salt) public view returns (address) {
        return
            address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, hookInitCodeHash)))));
    }

    /// @notice Opens trading: creates the pool (90-min launch window starts) and the first Cabal's era.
    function seed() external {
        if (hook == address(0)) revert HookNotDeployed();
        if (msg.sender != owner && block.timestamp < START) revert TooEarly(START);
        opened = true;
        IPleaHook(hook).seed();
        IGate(gate).begin();
        emit TradingOpened(block.timestamp);
    }
}
