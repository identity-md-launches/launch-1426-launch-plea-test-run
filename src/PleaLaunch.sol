// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PleaHook} from "./PleaHook.sol";
import {IStacker} from "./interfaces/IStacker.sol";
import {IGate, IPleaHook} from "./interfaces/IPleaParts.sol";

interface IPLEAForLaunch {
    function owner() external view returns (address);
    function setLauncher(address gate, address seasons, address distributor) external;
    function setLetterbox(address letterbox) external;
    function init(address hook, address poolManager) external;
}

/// @title PleaLaunch — wires PLEA at launch and deploys the hook and the Letterbox afterwards
/// @dev Last contract of the launch. Its constructor (inside the launch transaction) registers the
/// system's contracts with PLEA and commits to the hook's and the Letterbox's exact init code, so
/// the launch transaction stays under Ethereum's 16,777,216-gas cap. After launch, anyone calls
/// `deployHook` with a salt mined off chain (script/MineSalt.s.sol): the hook lands on an address
/// carrying its flag bits, and PLEA mints 87% to it, 3% to Seasons and 10% to the distributor. Anyone
/// calls `deployLetterbox` once with the Letterbox's creation code: it reads its settings from this
/// contract and PLEA registers it. Both results are fully determined by the committed code, so
/// front-running either call changes nothing. `seed` opens trading: the owner may call it any
/// time, anyone once `START` has passed.
contract PleaLaunch {
    error WrongInitCode();
    error HookDeployFailed();
    error WrongFlags(address hook);
    error HookAlreadyDeployed();
    error HookNotDeployed();
    error TooEarly(uint256 start);
    error LetterboxAlreadyDeployed();
    error LetterboxDeployFailed();

    event HookDeployed(address indexed hook, bytes32 salt);
    event LetterboxDeployed(address indexed letterbox);
    event TradingOpened(uint256 at);

    uint160 public constant FLAG_MASK = (1 << 14) - 1;
    /// beforeInitialize | beforeAddLiquidity | beforeSwap | afterSwap | beforeSwapReturnDelta | afterSwapReturnDelta
    uint160 public constant FLAGS = (1 << 13) | (1 << 11) | (1 << 7) | (1 << 6) | (1 << 3) | (1 << 2);

    address public immutable plea;
    address public immutable gate;
    address public immutable seasons;
    address public immutable poolManager;
    address public immutable imd;
    address public immutable owner;
    /// @notice Latest time trading opens: from then on anyone may call `seed`.
    uint256 public immutable START;
    bytes32 public immutable hookInitCodeHash;
    /// @notice The Letterbox's settings, read by its constructor: the asset the oracle fee is paid
    /// in, and whether it mints that fee (Sepolia's open-mint test token; refused on chain id 1).
    address public immutable oracleAsset;
    bool public immutable mintOracleFee;
    /// @notice keccak256 of the Letterbox's creation code (it takes no constructor arguments).
    bytes32 public immutable letterboxCodeHash;

    address public hook;
    address public letterbox;
    bool public opened;

    constructor(
        address plea_,
        address gate_,
        address seasons_,
        address distributor_,
        address poolManager_,
        address imd_,
        address stacker_,
        uint256 creditGas_,
        uint256 start_,
        address oracleAsset_,
        bool mintOracleFee_,
        bytes32 letterboxCodeHash_
    ) {
        plea = plea_;
        gate = gate_;
        seasons = seasons_;
        poolManager = poolManager_;
        imd = imd_;
        START = start_;
        oracleAsset = oracleAsset_;
        mintOracleFee = mintOracleFee_;
        letterboxCodeHash = letterboxCodeHash_;
        address owner_ = IPLEAForLaunch(plea_).owner();
        owner = owner_;
        hookInitCodeHash = keccak256(
            abi.encodePacked(
                type(PleaHook).creationCode,
                abi.encode(poolManager_, plea_, imd_, stacker_, owner_, seasons_, creditGas_)
            )
        );
        IPLEAForLaunch(plea_).setLauncher(gate_, seasons_, distributor_);
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

    /// @notice Deploys the Letterbox with CREATE2 (salt 0) and registers it with PLEA, once.
    /// `creationCode` must be the committed one; the Letterbox reads its settings from this contract.
    function deployLetterbox(bytes calldata creationCode) external returns (address deployed) {
        if (letterbox != address(0)) revert LetterboxAlreadyDeployed();
        if (keccak256(creationCode) != letterboxCodeHash) revert WrongInitCode();
        bytes memory code = creationCode;
        assembly ("memory-safe") {
            deployed := create2(0, add(code, 32), mload(code), 0)
        }
        if (deployed == address(0)) revert LetterboxDeployFailed();
        letterbox = deployed;
        IPLEAForLaunch(plea).setLetterbox(deployed);
        emit LetterboxDeployed(deployed);
    }

    /// @notice The address `deployLetterbox` deploys to.
    function predictLetterbox() external view returns (address) {
        return address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), bytes32(0), letterboxCodeHash))))
        );
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
