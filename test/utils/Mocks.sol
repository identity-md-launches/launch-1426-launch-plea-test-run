// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {PleaHook} from "../../src/PleaHook.sol";

contract MockIMD is ERC20 {
    constructor() ERC20("TestIMD", "IMD") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Stacked IMD: records the project a credit came from.
contract MockSIMD is ERC20 {
    bool public paused;
    mapping(address => mapping(address => uint256)) public byProject;

    constructor() ERC20("TestSIMD", "sIMD") {}

    function setPaused(bool p) external {
        paused = p;
    }

    function mintFor(address to, uint256 amount, address project) external {
        require(!paused, "sIMD paused");
        byProject[to][project] += amount;
        _mint(to, amount);
    }
}

/// @dev imd/acc Stacker: pulls IMD from the caller and credits sIMD under project = caller.
contract MockStacker {
    IERC20 public imd;
    MockSIMD public simd;
    bool public burnAllGas;
    uint256 public padGas;

    constructor(IERC20 imd_, MockSIMD simd_) {
        imd = imd_;
        simd = simd_;
    }

    function setBurnAllGas(bool b) external {
        burnAllGas = b;
    }

    function setPadGas(uint256 g) external {
        padGas = g;
    }

    function credit(address to, uint256 amount) external {
        if (burnAllGas) {
            assembly {
                invalid()
            }
        }
        uint256 target = gasleft() > padGas ? gasleft() - padGas : 0;
        while (gasleft() > target) {}
        imd.transferFrom(msg.sender, address(this), amount);
        simd.mintFor(to, amount, msg.sender);
    }
}

/// @dev A plain v4 router: buys (and attempts sells) against the hook's pool.
contract BuyRouter {
    IPoolManager public pm;
    PleaHook public hook;
    IERC20 public imd;
    IERC20 public plea;

    constructor(IPoolManager pm_, PleaHook hook_, IERC20 imd_, IERC20 plea_) {
        pm = pm_;
        hook = hook_;
        imd = imd_;
        plea = plea_;
    }

    /// @return pleaOut PLEA the payer ended up with (the hook delivers it as ERC-20; the swapper's own
    /// PLEA delta is zero while the Cabal lives).
    function buyExactIn(uint256 imdIn, bytes memory hookData) external returns (uint256 pleaOut) {
        uint256 before = plea.balanceOf(msg.sender);
        pm.unlock(abi.encode(msg.sender, true, -int256(imdIn), hookData, uint160(0)));
        return plea.balanceOf(msg.sender) - before;
    }

    /// @dev Exact-input buy that stops at `sqrtPriceLimitX96` (a partial fill when the limit is near spot).
    function buyExactInLimit(uint256 imdIn, bytes memory hookData, uint160 sqrtPriceLimitX96)
        external
        returns (uint256 pleaOut)
    {
        uint256 before = plea.balanceOf(msg.sender);
        pm.unlock(abi.encode(msg.sender, true, -int256(imdIn), hookData, sqrtPriceLimitX96));
        return plea.balanceOf(msg.sender) - before;
    }

    /// @return imdIn IMD the payer spent (gross, fees included).
    function buyExactOut(uint256 pleaWanted, bytes memory hookData) external returns (uint256 imdIn) {
        uint256 before = imd.balanceOf(msg.sender);
        pm.unlock(abi.encode(msg.sender, true, int256(pleaWanted), hookData, uint160(0)));
        return before - imd.balanceOf(msg.sender);
    }

    function sellExactIn(uint256 pleaIn, bytes memory hookData) external returns (uint256 imdOut) {
        return abi.decode(pm.unlock(abi.encode(msg.sender, false, -int256(pleaIn), hookData, uint160(0))), (uint256));
    }

    /// @dev Exact-input sell that stops at the seller's own `sqrtPriceLimitX96`, as a plain v4 router lets it.
    function sellExactInLimit(uint256 pleaIn, bytes memory hookData, uint160 sqrtPriceLimitX96)
        external
        returns (uint256 imdOut)
    {
        return abi.decode(
            pm.unlock(abi.encode(msg.sender, false, -int256(pleaIn), hookData, sqrtPriceLimitX96)), (uint256)
        );
    }

    /// @dev A router's sweep: moves tokens it ended up holding to `to`.
    function forward(IERC20 token, address to) external {
        token.transfer(to, token.balanceOf(address(this)));
    }

    function unlockCallback(bytes calldata raw) external returns (bytes memory) {
        require(msg.sender == address(pm), "pm");
        (address payer, bool buy, int256 amountSpecified, bytes memory hookData, uint160 limit) =
            abi.decode(raw, (address, bool, int256, bytes, uint160));
        PoolKey memory key = hook.poolKey();
        bool pleaIsZero = hook.pleaIsZero();
        bool zeroForOne = buy ? !pleaIsZero : pleaIsZero;
        if (limit == 0) limit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        BalanceDelta d = pm.swap(
            key,
            SwapParams({zeroForOne: zeroForOne, amountSpecified: amountSpecified, sqrtPriceLimitX96: limit}),
            hookData
        );
        (int128 pleaDelta, int128 imdDelta) = pleaIsZero ? (d.amount0(), d.amount1()) : (d.amount1(), d.amount0());
        (IERC20 tokenIn, int128 inDelta, IERC20 tokenOut, int128 outDelta) =
            buy ? (imd, imdDelta, plea, pleaDelta) : (plea, pleaDelta, imd, imdDelta);
        uint256 amountIn = uint256(uint128(-inDelta));
        uint256 amountOut = uint256(uint128(outDelta));
        pm.sync(Currency.wrap(address(tokenIn)));
        tokenIn.transferFrom(payer, address(pm), amountIn);
        pm.settle();
        pm.take(Currency.wrap(address(tokenOut)), payer, amountOut);
        return abi.encode(buy ? (amountSpecified < 0 ? amountOut : amountIn) : amountOut);
    }
}

/// @dev The Intake's shape: request records the callback and forwards the fee; complete marks the
/// request done and calls the callback once with a fixed 200k stipend, recording whether it worked.
contract MockIntake {
    struct Callback {
        address target;
        bytes4 selector;
    }

    struct Req {
        address payer;
        address target;
        bytes4 selector;
        bool completed;
    }

    mapping(bytes32 => bytes4) public failureOf;
    /// @dev Off: behave like Intake v1 (no failure call), to test the `expire` fallback.
    bool public failureHooks = true;

    function setFailureHooks(bool on) external {
        failureHooks = on;
    }

    uint256 public constant CALLBACK_GAS = 200_000;
    address public constant PAY_TO = address(0xFEE);
    IERC20 public immutable asset;
    uint256 public nonce;
    bytes32 public lastId;
    bytes public lastBody;
    mapping(bytes32 => Req) public requests;
    mapping(bytes32 => bytes) public bodyOf;
    uint256 public lastCallbackGasUsed;

    constructor(IERC20 asset_) {
        asset = asset_;
    }

    function request(bytes32, bytes calldata body, Callback calldata cb, address asset_, uint256 amount)
        external
        returns (bytes32 id)
    {
        require(asset_ == address(asset) && amount >= 0.5e18, "price");
        id = keccak256(abi.encode(block.chainid, address(this), ++nonce));
        requests[id] = Req(msg.sender, cb.target, cb.selector, false);
        bodyOf[id] = body;
        lastId = id;
        lastBody = body;
        asset.transferFrom(msg.sender, PAY_TO, amount);
    }

    function requestWithFailure(
        bytes32 action,
        bytes calldata body,
        Callback calldata cb,
        bytes4 onFailure,
        address asset_,
        uint256 amount
    ) external returns (bytes32 id) {
        id = this.requestFor(msg.sender, action, body, cb, asset_, amount);
        failureOf[id] = onFailure;
    }

    /// @dev `request` on behalf of `payer` (the fee is pulled from the payer).
    function requestFor(
        address payer,
        bytes32,
        bytes calldata body,
        Callback calldata cb,
        address asset_,
        uint256 amount
    ) external returns (bytes32 id) {
        require(msg.sender == address(this), "self");
        require(asset_ == address(asset) && amount >= 0.5e18, "price");
        id = keccak256(abi.encode(block.chainid, address(this), ++nonce));
        requests[id] = Req(payer, cb.target, cb.selector, false);
        bodyOf[id] = body;
        lastId = id;
        lastBody = body;
        asset.transferFrom(payer, PAY_TO, amount);
    }

    /// @dev Status 1 or 2 with the writer's arguments, like `complete` on Intake v2.
    function fail(bytes32 id, uint8 status, bytes32 reason, uint16 agreed, uint16 answered)
        external
        returns (bool delivered)
    {
        return this.complete(id, status, abi.encode(id, status, reason, agreed, answered, bytes("")));
    }

    function complete(bytes32 id, uint8 status, bytes calldata args) external returns (bool delivered) {
        Req storage r = requests[id];
        require(r.payer != address(0), "unknown");
        require(!r.completed, "completed");
        r.completed = true;
        bytes4 sel = status == 0 ? r.selector : failureOf[id];
        bytes memory payload = args;
        if (status != 0 && args.length == 0) {
            payload = abi.encode(id, status, bytes32("failed"), uint16(0), uint16(0), bytes(""));
        }
        if (r.target != address(0) && (status == 0 || (failureHooks && sel != bytes4(0)))) {
            bytes memory data = bytes.concat(sel, payload);
            address t = r.target;
            uint256 g = gasleft();
            assembly {
                delivered := call(CALLBACK_GAS, t, 0, add(data, 0x20), mload(data), 0, 0)
            }
            lastCallbackGasUsed = g - gasleft();
        }
    }
}
