// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "v4-core/types/PoolKey.sol";

/// @notice IdentityMD Intake v2 (same address on every chain). `requestWithFailure` pays for an oracle
/// question and names a callback plus a failure function, called on a refusal (status 1) or no answer
/// (status 2); `requests(id).completed` is set on every completion, answered or not.
interface IIntake {
    struct Callback {
        address target;
        bytes4 selector;
    }

    function request(bytes32 action, bytes calldata body, Callback calldata callback, address asset, uint256 amount)
        external
        payable
        returns (bytes32 requestId);

    function requestWithFailure(
        bytes32 action,
        bytes calldata body,
        Callback calldata callback,
        bytes4 onFailure,
        address asset,
        uint256 amount
    ) external returns (bytes32 requestId);

    function requests(bytes32 requestId)
        external
        view
        returns (address payer, address callbackTarget, bytes4 callbackSelector, bool completed);
}

interface IPLEA {
    function owner() external view returns (address);
    function launcher() external view returns (address);
    function hook() external view returns (address);
    function gate() external view returns (address);
    function seasons() external view returns (address);
    function poolManager() external view returns (address);
    function letterbox() external view returns (address);
    function courtTake(address from, uint256 amount) external;
    function restricted() external view returns (bool);
    function balanceOf(address) external view returns (uint256);
    function burn(uint256 amount) external;
}

interface IGate {
    function restricted() external view returns (bool);
    function cabalAlive() external view returns (bool);
    function startedAt() external view returns (uint64);
    function diedAt() external view returns (uint64);
    function SEASON() external view returns (uint256);
    function begin() external;
    function result(uint256 id) external view returns (address seller, uint8 score, bool approved, uint64 verdictAt);
    function pleaText(uint256 id) external view returns (string memory);
    function pleaFlags(uint256 id) external view returns (uint8);
}

interface IPleaHook {
    function poolManager() external view returns (address);
    function poolKey() external view returns (PoolKey memory);
    function pleaIsZero() external view returns (bool);
    function latestPrice() external view returns (uint256);
    function price24hAgo() external view returns (uint256);
    function basisOf(address) external view returns (uint256 imdSpent, uint256 pleaHeld, uint256 avgBuyTime);
    function fundWall(uint256 amount) external;
    function seed() external;
}

interface ISeasons {
    function checkpoint() external;
}
