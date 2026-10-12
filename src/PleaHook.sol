// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/*
  PleaHook — a fork of POOL4's CappedBurnHook (Ethereum 0xc6c965bd164c483e87d0b550671798e9a3602840),
  converted to the IMD side: the quote asset is IMD (an ERC-20) instead of ETH, the pool is PLEA/IMD
  with LP fee 0, the hook is the only LP, liquidity is locked forever (no closeMarket, no withdraw),
  trims burn 100% and recovered IMD becomes an IMD-only buy wall below the price.

  Every fee is allocated in the swap that earns it: 0.5% cashback to the
  trader as sIMD through imd/acc's Stacker, 0.5% to the owner, 0.25% to the season's prize pot
  (to pool liquidity once the Cabal is dead), 0.25% to pool liquidity, and 0.25% of the PLEA leg
  burned.
*/

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {SqrtPriceMath} from "v4-core/libraries/SqrtPriceMath.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {FixedPoint96} from "v4-core/libraries/FixedPoint96.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/types/BeforeSwapDelta.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/types/PoolOperation.sol";
import {IStacker} from "./interfaces/IStacker.sol";
import {IPLEA, ISeasons} from "./interfaces/IPleaParts.sol";

contract PleaHook {
    using StateLibrary for IPoolManager;
    using SafeERC20 for IERC20;

    error NotLauncher();
    error NotPoolManager();
    error InvalidPool();
    error AlreadySeeded();
    error NotSeeded();
    error InitializationRestrictedToHook();
    error LiquidityRestrictedToHook();
    error SellsOnlyViaGate();
    error BuyTooLarge(uint256 amount, uint256 maximum);
    error CallbackNotExpected();
    error RebalanceNotNeeded();
    error UnexpectedLiquidityDelta();
    error PriceMoved();
    error InvalidLiquidity();
    error ExactOutputBuyRefused();
    error RecipientRequired();
    error NotEnoughGas(uint256 needed, uint256 left);

    event Seeded(uint160 sqrtPriceX96, int24 tick, uint128 liquidity, uint256 pleaDeposited);
    event FeesTaken(
        address indexed trader, bool buy, uint256 imdBasis, uint256 imdFee, uint256 pleaBurned, uint256 toPrize
    );
    event PayoutsToPool(uint256 amount);
    event FeeRefunded(address indexed trader, address currency, uint256 amount, bool asClaims);
    event CashbackStacked(address indexed trader, uint256 amount);
    event CashbackPaidPlain(address indexed trader, uint256 amount);
    event CashbackPaidClaims(address indexed trader, uint256 amount);
    event CapRatcheted(uint256 previousCap, uint256 newCap);
    event Trimmed(uint128 liquidityRemoved, uint256 pleaBurned, uint256 imdRetained);
    event WallDeployed(int24 tickLower, int24 tickUpper, uint128 liquidity, uint256 imdDeployed);
    event WallSettled(uint128 liquidity, uint256 pleaBurned, uint256 imdReturned);
    event KeeperTipPaid(address indexed keeper, uint256 amount);
    event PriceCheckpoint(uint64 hour, uint256 priceX96);

    uint256 public constant BPS = 10_000;
    uint256 public constant CASHBACK_BPS = 50; // 0.5% of the IMD fill, to the trader as sIMD
    uint256 public constant OWNER_BPS = 50; // 0.5% to the owner
    uint256 public constant PRIZE_BPS = 25; // 0.25% to the season's prize pot
    uint256 public constant POOL_BPS = 25; // 0.25% to pool liquidity (the wall)
    uint256 public constant IMD_FEE_BPS = CASHBACK_BPS + OWNER_BPS + PRIZE_BPS + POOL_BPS;
    uint256 public constant PLEA_BURN_BPS = 25; // 0.25% of the PLEA leg burned every trade
    uint256 public constant LAUNCH_WINDOW = 90 minutes;
    uint256 public constant LAUNCH_EXTRA_BPS = 7_000; // 70% -> 0% linear, to pool liquidity
    uint256 public constant LAUNCH_MAX_BUY = 5_000_000e18;
    uint256 public constant MARKET_CAP_IMD = 5_700e18;
    uint256 public constant CAP_FLOOR = 900_000e18;
    /// @notice The cap may travel from the seeded inventory down to `CAP_FLOOR` in this long at the
    /// fastest; the daily allowance is fixed at seed (`capDecayPerDay`). It only ever follows buys.
    uint256 public constant CAP_DECAY_DAYS = 25;
    uint256 public constant MIN_TRIM = 1e18;
    uint256 public constant WALL_THRESHOLD = 1e18; // retained IMD worth a rebalance
    uint256 public constant WALL_MIN_FILL = 1_000e18; // PLEA bought by the wall worth a settle
    uint256 public constant KEEPER_TIP = 1e16; // 0.01 IMD
    uint256 public constant TIP_MIN_WORK = 100e18; // a tipped rebalance moves at least 100 IMD
    uint256 public constant TIP_INTERVAL = 1 hours;
    /// @notice Gas a swap must still have when it reaches `beforeSwap`, on top of `creditGas`: the
    /// rest of the swap (fees, cap, checkpoints) plus slack. Checked first, so the minimum a gas
    /// estimate finds is set here and small state changes before inclusion only eat slack.
    uint256 public constant SWAP_RESERVE = 1_000_000;
    /// @notice Gas kept back around the credit itself (63/64 rule, event, plain-IMD fallback).
    uint256 public constant CREDIT_RESERVE = 60_000;
    uint24 public constant LP_FEE = 0;
    int24 public constant TICK_SPACING = 60;

    uint8 private constant ACTION_SEED = 1;
    uint8 private constant ACTION_REBALANCE = 3;

    uint256 private constant T_TRADER = 0x01;
    uint256 private constant T_SPEC_FEE = 0x02;
    uint256 private constant T_BUY = 0x03;
    /// @dev The pool's sqrt price before the swap in flight: the hourly checkpoint records it, so the
    /// trade that opens an hour cannot choose the hour's reference price.
    uint256 private constant T_PRICE_BEFORE = 0x04;

    IPoolManager public immutable poolManager;
    address public immutable plea;
    IERC20 public immutable imd;
    IStacker public immutable stacker;
    address public immutable owner;
    /// @notice Seasons: receives the 0.25% prize fee.
    address public immutable seasons;
    /// @notice Gas given to each Stacker credit. A trade that cannot afford it reverts
    /// `NotEnoughGas`, so a gas estimate always includes the credit (Sepolia: a first credit
    /// costs about 1.2M).
    uint256 public immutable creditGas;
    bool public immutable pleaIsZero;
    int24 public immutable minTick;
    int24 public immutable maxTick;

    struct Band {
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
    }

    /// @notice Per-trader cost basis and the buy-weighted average time of their buys.
    struct Basis {
        uint256 imdSpent;
        uint256 pleaHeld;
        uint256 avgBuyTime;
    }

    struct Checkpoint {
        uint64 hour;
        uint256 priceX96;
    }

    bool public seeded;
    uint256 public launchedAt;
    Band public market;
    Band public wall;
    uint256 public inventoryCap;
    uint256 public lastCapDecayAt;
    /// @notice Most PLEA the cap may fall per day: (seeded inventory - CAP_FLOOR) / CAP_DECAY_DAYS.
    uint256 public capDecayPerDay;
    uint256 public capDecayRemainder;
    /// @notice Wall reserve held as IMD by the hook.
    uint256 public retainedImd;
    /// @notice Wall reserve held as ERC-6909 IMD claims (redeemed by `rebalance`).
    uint256 public retainClaims;
    uint256 public totalBurned;
    uint256 public totalOwnerFees;
    uint256 public totalCashback;
    uint256 public totalPrize;
    uint256 public totalPoolFees;
    int24 public refTick;
    int24 private curBlockTick;
    uint64 private refBlock;
    int24 private constant MAX_REF_STEP = 200;
    /// @notice How far the wall's placement guard may move toward a higher PLEA price per day (~4%).
    uint256 public constant WALL_GUARD_TICKS_PER_DAY = 400;
    /// @notice The wall's placement guard (POOL4's deployment floor, mirrored for an IMD bid). It moves
    /// at once to any lower PLEA price the pool trades at, and toward a higher one only at
    /// `WALL_GUARD_TICKS_PER_DAY`, toward `refTick`. The wall is never placed above it, so lifting the
    /// wall to a pumped price means holding that price for days. In raw ticks it is a ceiling on the
    /// band's upper tick when PLEA is token0 and a floor on its lower tick when PLEA is token1.
    int24 public wallGuardTick;
    uint256 private lastGuardAt;
    uint256 private guardRemainder;
    uint256 public lastTipAt;
    /// @notice IMD the current wall was deployed with (what it has spent so far is `wallImd - imdInWall`).
    uint256 public wallImd;
    bool private callbackExpected;
    bool private hasBought;
    /// @dev The hour of the newest checkpoint, so `latestPrice` reads one ring entry, not all 25.
    uint64 private lastCheckpointHour;

    mapping(address => Basis) public basisOf;
    Checkpoint[25] public ring;

    constructor(
        IPoolManager poolManager_,
        address plea_,
        IERC20 imd_,
        IStacker stacker_,
        address owner_,
        address seasons_,
        uint256 creditGas_
    ) {
        poolManager = poolManager_;
        plea = plea_;
        imd = imd_;
        stacker = stacker_;
        owner = owner_;
        seasons = seasons_;
        creditGas = creditGas_;
        pleaIsZero = plea_ < address(imd_);
        minTick = TickMath.minUsableTick(TICK_SPACING);
        maxTick = TickMath.maxUsableTick(TICK_SPACING);
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
    }

    // ------------------------------------------------------------------ views

    function getHookPermissions() public pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: true,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function poolKey() public view returns (PoolKey memory key) {
        (Currency c0, Currency c1) = pleaIsZero
            ? (Currency.wrap(plea), Currency.wrap(address(imd)))
            : (Currency.wrap(address(imd)), Currency.wrap(plea));
        key = PoolKey({
            currency0: c0, currency1: c1, fee: LP_FEE, tickSpacing: TICK_SPACING, hooks: IHooks(address(this))
        });
    }

    function poolId() public view returns (PoolId) {
        return poolKey().toId();
    }

    function currentSqrtPriceX96() public view returns (uint160 sqrtPriceX96) {
        (sqrtPriceX96,,,) = poolManager.getSlot0(poolId());
    }

    function currentTick() public view returns (int24 tick) {
        (, tick,,) = poolManager.getSlot0(poolId());
    }

    /// @notice Spot IMD per PLEA, scaled by 2^96. Fact scores never use it (see `latestPrice`).
    function priceX96() public view returns (uint256) {
        return _priceX96(currentSqrtPriceX96());
    }

    function _priceX96(uint160 sqrtP) internal view returns (uint256) {
        if (sqrtP == 0) return 0;
        uint256 p = FullMath.mulDiv(sqrtP, sqrtP, FixedPoint96.Q96); // token1 per token0, X96
        if (pleaIsZero) return p;
        if (p == 0) return 0;
        return FullMath.mulDiv(FixedPoint96.Q96, FixedPoint96.Q96, p);
    }

    /// @notice The most recent hourly checkpoint (the price at the first trade of that hour).
    function latestPrice() public view returns (uint256 best) {
        // The newest checkpoint is the one `_checkpoint` wrote last (hours only grow); scan the ring
        // only in the corner case where its price rounded to zero.
        best = ring[lastCheckpointHour % 25].priceX96;
        if (best != 0) return best;
        uint64 bestHour;
        for (uint256 i; i < 25; ++i) {
            Checkpoint memory c = ring[i];
            if (c.priceX96 != 0 && c.hour >= bestHour) {
                bestHour = c.hour;
                best = c.priceX96;
            }
        }
    }

    /// @notice The checkpointed price from at least 24 hours ago (0 when none is old enough).
    function price24hAgo() public view returns (uint256 best) {
        uint64 target = uint64(block.timestamp / 1 hours) - 24;
        // A checkpoint from exactly that hour is the answer; otherwise scan the ring.
        Checkpoint storage t = ring[target % 25];
        if (t.hour == target && t.priceX96 != 0) return t.priceX96;
        uint64 bestHour;
        for (uint256 i; i < 25; ++i) {
            Checkpoint memory c = ring[i];
            if (c.priceX96 != 0 && c.hour <= target && c.hour >= bestHour) {
                bestHour = c.hour;
                best = c.priceX96;
            }
        }
    }

    /// @notice Extra buy fee in bps during the launch window: 70% at seed, 0% after 90 minutes.
    function launchExtraBps() public view returns (uint256) {
        if (launchedAt == 0) return 0;
        uint256 elapsed = block.timestamp - launchedAt;
        if (elapsed >= LAUNCH_WINDOW) return 0;
        return LAUNCH_EXTRA_BPS * (LAUNCH_WINDOW - elapsed) / LAUNCH_WINDOW;
    }

    function pleaInMarket() public view returns (uint256) {
        return _pleaIn(market, currentSqrtPriceX96());
    }

    function imdInMarket() public view returns (uint256) {
        return _imdIn(market, currentSqrtPriceX96());
    }

    function pleaInWall() public view returns (uint256) {
        return _pleaIn(wall, currentSqrtPriceX96());
    }

    function pendingTrim() public view returns (uint256) {
        uint256 held = pleaInMarket();
        uint256 excess = held > inventoryCap ? held - inventoryCap : 0;
        return excess < MIN_TRIM ? 0 : excess;
    }

    function pendingRebalance() public view returns (bool) {
        if (!seeded) return false;
        return retainedImd + retainClaims >= WALL_THRESHOLD || pleaInWall() >= WALL_MIN_FILL;
    }

    function _pleaIn(Band memory b, uint160 sqrtP) internal view returns (uint256) {
        if (b.liquidity == 0) return 0;
        uint160 lo = TickMath.getSqrtPriceAtTick(b.tickLower);
        uint160 hi = TickMath.getSqrtPriceAtTick(b.tickUpper);
        if (pleaIsZero) {
            if (sqrtP >= hi) return 0;
            if (sqrtP < lo) sqrtP = lo;
            return SqrtPriceMath.getAmount0Delta(sqrtP, hi, b.liquidity, false);
        }
        if (sqrtP <= lo) return 0;
        if (sqrtP > hi) sqrtP = hi;
        return SqrtPriceMath.getAmount1Delta(lo, sqrtP, b.liquidity, false);
    }

    function _imdIn(Band memory b, uint160 sqrtP) internal view returns (uint256) {
        if (b.liquidity == 0) return 0;
        uint160 lo = TickMath.getSqrtPriceAtTick(b.tickLower);
        uint160 hi = TickMath.getSqrtPriceAtTick(b.tickUpper);
        if (pleaIsZero) {
            if (sqrtP <= lo) return 0;
            if (sqrtP > hi) sqrtP = hi;
            return SqrtPriceMath.getAmount1Delta(lo, sqrtP, b.liquidity, false);
        }
        if (sqrtP >= hi) return 0;
        if (sqrtP < lo) sqrtP = lo;
        return SqrtPriceMath.getAmount0Delta(sqrtP, hi, b.liquidity, false);
    }

    function _alive() internal view returns (bool) {
        return IPLEA(plea).restricted();
    }

    // ------------------------------------------------------------------ seed

    /// @notice Creates the PLEA/IMD pool at a 5,700 IMD market cap with the hook's whole PLEA
    /// balance as the only liquidity. Once, through PleaLaunch.seed (owner any time, anyone after START).
    function seed() external {
        if (msg.sender != IPLEA(plea).launcher()) revert NotLauncher();
        if (seeded) revert AlreadySeeded();
        seeded = true;
        uint256 pleaAmount = IERC20(plea).balanceOf(address(this));
        // sqrt(IMD/PLEA ratio) in the pool's token1/token0 orientation.
        uint256 priceX192 = pleaIsZero
            ? FullMath.mulDiv(MARKET_CAP_IMD, 1 << 192, 1_000_000_000e18)
            : FullMath.mulDiv(1_000_000_000e18, 1 << 192, MARKET_CAP_IMD);
        uint160 sqrtP = uint160(_sqrt(priceX192));
        int24 tick = TickMath.getTickAtSqrtPrice(sqrtP);
        int24 lower;
        int24 upper;
        uint160 initPrice;
        if (pleaIsZero) {
            lower = _alignUp(tick);
            upper = maxTick;
            initPrice = TickMath.getSqrtPriceAtTick(lower) - 1; // tick < lower: PLEA (token0) only
        } else {
            lower = minTick;
            upper = _alignDown(tick);
            initPrice = TickMath.getSqrtPriceAtTick(upper); // tick >= upper: PLEA (token1) only
        }
        uint128 liquidity = _liquidityForSingleSide(lower, upper, pleaAmount, pleaIsZero);
        int24 initTick = poolManager.initialize(poolKey(), initPrice);
        market = Band({tickLower: lower, tickUpper: upper, liquidity: liquidity});
        bytes memory res = _unlock(abi.encode(ACTION_SEED, abi.encode(lower, upper, liquidity)));
        uint256 deposited = abi.decode(res, (uint256));
        inventoryCap = deposited;
        lastCapDecayAt = block.timestamp;
        capDecayPerDay = deposited > CAP_FLOOR ? (deposited - CAP_FLOOR) / CAP_DECAY_DAYS : 0;
        launchedAt = block.timestamp;
        refTick = initTick;
        curBlockTick = initTick;
        refBlock = uint64(block.number);
        wallGuardTick = _guardFor(initTick);
        lastGuardAt = block.timestamp;
        // Any PLEA dust the rounding left behind is burned: the hook holds no inventory of its own.
        uint256 dust = IERC20(plea).balanceOf(address(this));
        if (dust != 0) IPLEA(plea).burn(dust);
        _checkpoint(initPrice);
        emit Seeded(initPrice, initTick, liquidity, deposited);
    }

    // ------------------------------------------------------------------ hooks

    function beforeInitialize(address sender, PoolKey calldata key, uint160) external view returns (bytes4) {
        _requirePoolManagerAndPool(key);
        if (sender != address(this)) revert InitializationRestrictedToHook();
        return IHooks.beforeInitialize.selector;
    }

    function beforeAddLiquidity(address sender, PoolKey calldata key, ModifyLiquidityParams calldata, bytes calldata)
        external
        view
        returns (bytes4)
    {
        _requirePoolManagerAndPool(key);
        if (sender != address(this)) revert LiquidityRestrictedToHook();
        return IHooks.beforeAddLiquidity.selector;
    }

    /// @notice Gates sells, refuses exact-output buys while the Cabal watches and takes the fee on
    /// the specified currency as a share of the fill (settled against the realised fill in `afterSwap`).
    function beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        external
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        _requirePoolManagerAndPool(key);
        if (!seeded) revert NotSeeded();
        _requireGas(creditGas + SWAP_RESERVE);
        bool buy = params.zeroForOne != pleaIsZero;
        bool exactIn = params.amountSpecified < 0;
        bool alive = _alive();
        if (!buy && alive && sender != IPLEA(plea).gate()) revert SellsOnlyViaGate();
        // While the Cabal watches a buyer must never leave the pool with a positive PLEA delta: the
        // PoolManager would let it mint ERC-6909 claims and sell them in a hookless pool. Exact-input
        // buys have their whole PLEA output taken by the hook and delivered as ERC-20 in afterSwap; an
        // exact-output buy fixes the swapper's PLEA delta at the requested amount, so it is refused.
        if (buy && !exactIn && alive) revert ExactOutputBuyRefused();
        // The recipient comes from hookData (abi.encode(address)); otherwise it is the swap sender.
        address trader;
        if (hookData.length == 32) trader = abi.decode(hookData, (address));
        if (trader == address(0)) {
            if (buy) revert RecipientRequired();
            trader = sender;
        }
        uint256 amount = exactIn ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);
        bool specifiedIsImd = buy == exactIn;
        uint256 rate = specifiedIsImd ? _imdRate(buy) : PLEA_BURN_BPS;
        if (!specifiedIsImd && buy) _checkMaxBuy(amount);
        // Exact input: the fee is a share of what reaches the pool (amount - fee), not of the gross input.
        uint256 fee = exactIn ? amount * rate / (BPS + rate) : amount * rate / BPS;
        uint160 priceBefore = currentSqrtPriceX96();
        assembly ("memory-safe") {
            tstore(T_TRADER, trader)
            tstore(T_SPEC_FEE, fee)
            tstore(T_BUY, buy)
            tstore(T_PRICE_BEFORE, priceBefore)
        }
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(int128(int256(fee)), 0), 0);
    }

    function _imdRate(bool buy) internal view returns (uint256) {
        return IMD_FEE_BPS + (buy ? launchExtraBps() : 0);
    }

    /// @notice Settles the specified-side fee against the realised fill (refunding the rest), takes
    /// the fee on the unspecified currency, delivers the PLEA of an exact-input buy as ERC-20, pays
    /// every fee, applies the cap, then pays cashback as the very last step.
    function afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        external
        returns (bytes4, int128)
    {
        _requirePoolManagerAndPool(key);
        address trader;
        uint256 specFee;
        bool buy;
        uint160 priceBefore;
        assembly ("memory-safe") {
            trader := tload(T_TRADER)
            specFee := tload(T_SPEC_FEE)
            buy := tload(T_BUY)
            priceBefore := tload(T_PRICE_BEFORE)
            tstore(T_TRADER, 0)
            tstore(T_SPEC_FEE, 0)
            tstore(T_BUY, 0)
            tstore(T_PRICE_BEFORE, 0)
        }
        bool exactIn = params.amountSpecified < 0;
        bool specifiedIsZero = exactIn == params.zeroForOne;
        int128 sd = specifiedIsZero ? delta.amount0() : delta.amount1();
        int128 ud = specifiedIsZero ? delta.amount1() : delta.amount0();
        // `delta` is the pool's own delta: the realised fill on both sides, before any hook delta.
        uint256 specAmt = sd < 0 ? uint256(uint128(-sd)) : uint256(uint128(sd));
        uint256 unspecAmt = ud < 0 ? uint256(uint128(-ud)) : uint256(uint128(ud));
        bool specifiedIsImd = buy == exactIn;

        // The specified-side fee was taken on the requested amount; charge it on the fill only.
        uint256 specDue = specAmt * (specifiedIsImd ? _imdRate(buy) : PLEA_BURN_BPS) / BPS;
        if (specDue > specFee) specDue = specFee;
        if (specFee > specDue) _refund(trader, specifiedIsImd, specFee - specDue);

        uint256 imdBasis;
        uint256 imdFee;
        uint256 pleaFee;
        uint256 pleaAmt;
        int128 ret;
        if (specifiedIsImd) {
            imdBasis = specAmt;
            imdFee = specDue;
            if (buy) _checkMaxBuy(unspecAmt);
            pleaFee = unspecAmt * PLEA_BURN_BPS / BPS;
            pleaAmt = unspecAmt;
            if (buy && _alive()) {
                // Take the whole PLEA output; the trader receives ERC-20 PLEA from the hook's delta.
                if (unspecAmt - pleaFee != 0) poolManager.take(Currency.wrap(plea), trader, unspecAmt - pleaFee);
                ret = int128(int256(unspecAmt));
            } else {
                // Sells, and buys while the Cabal sleeps: plain v4 accounting, the hook takes its fee.
                ret = int128(int256(pleaFee));
            }
        } else {
            imdBasis = unspecAmt;
            imdFee = unspecAmt * _imdRate(buy) / BPS;
            pleaFee = specDue;
            pleaAmt = specAmt;
            ret = int128(int256(imdFee));
        }
        uint256 cashback = _payFees(trader, buy, imdBasis, imdFee, pleaFee);
        _updateBasis(trader, buy, imdBasis + imdFee, buy ? pleaAmt - pleaFee : pleaAmt + pleaFee);

        _applyCap();
        _updateWallGuard(currentTick());
        _observeTick();
        // The hour's checkpoint is the price this swap found, not the one it made: the first trade of
        // an hour cannot set the reference price the gate scores that hour's pleas against.
        _checkpoint(priceBefore);

        _payCashback(trader, cashback);
        return (IHooks.afterSwap.selector, ret);
    }

    /// @dev Pays the fee deltas the hook holds, in this swap: PLEA burned; IMD to the owner, the prize
    /// pot and the hook (for cashback); the pool share kept as claims for the wall. Only the first
    /// buy may redirect an unfunded payout to liquidity. Later shortages pay ERC-6909 IMD claims
    /// to the same beneficiaries, redeemable once the swapper settles its input.
    /// @return cashback IMD now held by the hook for the trader.
    function _payFees(address trader, bool buy, uint256 imdBasis, uint256 imdFee, uint256 pleaFee)
        internal
        returns (uint256 cashback)
    {
        bool firstBuy = buy && !hasBought;
        if (buy) hasBought = true;
        if (pleaFee != 0) {
            poolManager.take(Currency.wrap(plea), address(this), pleaFee);
            IPLEA(plea).burn(pleaFee);
            totalBurned += pleaFee;
        }
        uint256 toPrize;
        if (imdFee != 0) {
            cashback = imdBasis * CASHBACK_BPS / BPS;
            uint256 toOwner = imdBasis * OWNER_BPS / BPS;
            // No seasons after the Cabal dies: the prize share joins pool liquidity.
            if (_alive()) toPrize = imdBasis * PRIZE_BPS / BPS;
            uint256 out = cashback + toOwner + toPrize;
            bool asClaims = imd.balanceOf(address(poolManager)) < out;
            if (asClaims && firstBuy) {
                emit PayoutsToPool(out);
                (cashback, toOwner, toPrize, out) = (0, 0, 0, 0);
            }
            uint256 toPool = imdFee - out;
            _payImd(owner, toOwner, asClaims);
            _payImd(seasons, toPrize, asClaims);
            if (toPrize != 0) ISeasons(seasons).checkpoint();
            if (cashback != 0) {
                _payImd(asClaims ? trader : address(this), cashback, asClaims);
                if (asClaims) {
                    totalCashback += cashback;
                    emit CashbackPaidClaims(trader, cashback);
                    cashback = 0; // the trader already holds the claim; no Stacker call is due
                }
            }
            if (toPool != 0) {
                poolManager.mint(address(this), _id(address(imd)), toPool);
                retainClaims += toPool;
            }
            totalOwnerFees += toOwner;
            totalPrize += toPrize;
            totalPoolFees += toPool;
        }
        emit FeesTaken(trader, buy, imdBasis, imdFee, pleaFee, toPrize);
    }

    function _payImd(address to, uint256 amount, bool asClaims) internal {
        if (amount == 0) return;
        if (asClaims) poolManager.mint(to, _id(address(imd)), amount);
        else poolManager.take(Currency.wrap(address(imd)), to, amount);
    }

    /// @dev Returns the part of the specified-side fee the fill did not earn. The swapper has not
    /// settled yet, so the PoolManager may hold less IMD than the refund: then the refund is minted to
    /// the trader as an ERC-6909 IMD claim instead of reverting the trade. PLEA refunds (a gate sell)
    /// are always ERC-20: a PLEA claim in a seller's hands could be sold in a hookless pool.
    function _refund(address trader, bool isImd, uint256 amount) internal {
        if (!isImd) {
            poolManager.take(Currency.wrap(plea), trader, amount);
            emit FeeRefunded(trader, plea, amount, false);
        } else if (imd.balanceOf(address(poolManager)) >= amount) {
            poolManager.take(Currency.wrap(address(imd)), trader, amount);
            emit FeeRefunded(trader, address(imd), amount, false);
        } else {
            poolManager.mint(trader, _id(address(imd)), amount);
            emit FeeRefunded(trader, address(imd), amount, true);
        }
    }

    function _checkMaxBuy(uint256 pleaAmount) internal view {
        if (block.timestamp < launchedAt + LAUNCH_WINDOW && pleaAmount > LAUNCH_MAX_BUY) {
            revert BuyTooLarge(pleaAmount, LAUNCH_MAX_BUY);
        }
    }

    /// @dev `grossImd` is what the trader paid or received in IMD including fees; `pleaMoved` is the
    /// PLEA the trader received (buy) or gave up including the burn fee (sell).
    function _updateBasis(address trader, bool buy, uint256 grossImd, uint256 pleaMoved) internal {
        Basis storage b = basisOf[trader];
        if (buy) {
            uint256 held = b.pleaHeld;
            if (held + pleaMoved != 0) {
                b.avgBuyTime = (b.avgBuyTime * held + block.timestamp * pleaMoved) / (held + pleaMoved);
            }
            b.imdSpent += grossImd;
            b.pleaHeld = held + pleaMoved;
        } else {
            if (pleaMoved >= b.pleaHeld) {
                b.imdSpent = 0;
                b.pleaHeld = 0;
                b.avgBuyTime = 0;
            } else {
                b.imdSpent -= FullMath.mulDiv(b.imdSpent, pleaMoved, b.pleaHeld);
                b.pleaHeld -= pleaMoved;
            }
        }
    }

    // ------------------------------------------------------------------ cashback

    /// @dev No gas-dependent path a wallet's estimate could pick: the swap reverts unless it can
    /// afford the credit (checked in `beforeSwap` and again here), and only a credit that reverts
    /// (e.g. a paused vault) pays plain IMD. The Stacker is approved for the cashback being credited
    /// and nothing more: the wall reserve the hook holds between rebalances is never within its reach.
    function _payCashback(address trader, uint256 amount) internal {
        if (amount == 0) return;
        imd.forceApprove(address(stacker), amount);
        _requireGas(creditGas * 64 / 63 + CREDIT_RESERVE);
        totalCashback += amount;
        try stacker.credit{gas: creditGas}(trader, amount) {
            emit CashbackStacked(trader, amount);
            return;
        } catch {}
        imd.forceApprove(address(stacker), 0);
        (bool ok, bytes memory r) = address(imd).call(abi.encodeCall(IERC20.transfer, (trader, amount)));
        if (ok && (r.length == 0 || abi.decode(r, (bool)))) {
            emit CashbackPaidPlain(trader, amount);
        } else {
            totalCashback -= amount;
            retainedImd += amount;
        }
    }

    function _requireGas(uint256 needed) internal view {
        if (gasleft() < needed) revert NotEnoughGas(needed, gasleft());
    }

    // ------------------------------------------------------------------ cap

    function _applyCap() internal {
        Band memory m = market;
        if (m.liquidity == 0) return;
        uint160 priceBefore = currentSqrtPriceX96();
        uint256 held = _pleaIn(m, priceBefore);
        if (held < inventoryCap) {
            uint256 next = held; // full ratchet
            uint256 elapsed = block.timestamp - lastCapDecayAt;
            uint256 rate = capDecayPerDay;
            if (rate == 0) return;
            uint256 budget = rate * elapsed;
            uint256 allowance = budget > capDecayRemainder ? (budget - capDecayRemainder) / 1 days : 0;
            uint256 rateFloor = inventoryCap > allowance ? inventoryCap - allowance : 0;
            if (next < rateFloor) next = rateFloor;
            if (next < CAP_FLOOR) next = CAP_FLOOR;
            if (next < inventoryCap) {
                uint256 used = inventoryCap - next;
                uint256 numerator = used * 1 days + capDecayRemainder;
                lastCapDecayAt += numerator / rate;
                capDecayRemainder = numerator % rate;
                emit CapRatcheted(inventoryCap, next);
                inventoryCap = next;
            }
            return;
        }
        uint256 excess = held - inventoryCap;
        if (excess < MIN_TRIM) return;
        uint256 toRemove = FullMath.mulDiv(m.liquidity, excess, held);
        if (toRemove == 0) return;
        (uint256 pleaOut, uint256 imdOut) = _removeLiquidity(m.tickLower, m.tickUpper, toRemove);
        market.liquidity = m.liquidity - uint128(toRemove);
        if (pleaOut != 0) {
            poolManager.take(Currency.wrap(plea), address(this), pleaOut);
            IPLEA(plea).burn(pleaOut);
            totalBurned += pleaOut;
        }
        if (imdOut != 0) {
            poolManager.mint(address(this), _id(address(imd)), imdOut);
            retainClaims += imdOut;
        }
        if (currentSqrtPriceX96() != priceBefore) revert PriceMoved();
        emit Trimmed(uint128(toRemove), pleaOut, imdOut);
    }

    function _removeLiquidity(int24 lower, int24 upper, uint256 liquidity)
        internal
        returns (uint256 pleaOut, uint256 imdOut)
    {
        (BalanceDelta d,) = poolManager.modifyLiquidity(
            poolKey(),
            ModifyLiquidityParams({tickLower: lower, tickUpper: upper, liquidityDelta: -int256(liquidity), salt: 0}),
            ""
        );
        if (d.amount0() < 0 || d.amount1() < 0) revert UnexpectedLiquidityDelta();
        (uint256 a0, uint256 a1) = (uint256(uint128(d.amount0())), uint256(uint128(d.amount1())));
        (pleaOut, imdOut) = pleaIsZero ? (a0, a1) : (a1, a0);
    }

    // ------------------------------------------------------------------ wall

    /// @notice Permissionless: redeems the pool share's claims, settles a filled wall (burning the
    /// PLEA it bought) and redeploys all retained IMD as one IMD-only band just below the price. Pays
    /// the caller 0.01 IMD at most once an hour, and only when the call moved at least 100 IMD.
    function rebalance() external {
        if (!pendingRebalance()) revert RebalanceNotNeeded();
        (uint256 work, bool acted) = abi.decode(_unlock(abi.encode(ACTION_REBALANCE, "")), (uint256, bool));
        // Nothing settled, no wall closed and none deployed (the band cannot be placed while the
        // price sits at a tick extreme): the call did no work.
        if (work == 0 && !acted) revert RebalanceNotNeeded();
        _payTip(msg.sender, work);
    }

    /// @return work IMD value actually handled: claims redeemed, what the wall spent buying PLEA and
    /// fresh reserve deployed in this call.
    /// @return acted Whether a wall was closed or deployed, or claims redeemed.
    function _rebalance() internal returns (uint256 work, bool acted) {
        uint256 claims = retainClaims;
        if (claims != 0) {
            retainClaims = 0;
            poolManager.burn(address(this), _id(address(imd)), claims);
            poolManager.take(Currency.wrap(address(imd)), address(this), claims);
            retainedImd += claims;
            work += claims;
            acted = true;
        }
        uint256 deployed = wallImd;
        uint256 back = _closeWall();
        if (deployed != 0) acted = true;
        if (deployed > back) work += deployed - back;
        uint256 amount = retainedImd > KEEPER_TIP ? retainedImd - KEEPER_TIP : 0;
        if (amount == 0) return (work, acted);
        int24 spot = currentTick();
        _updateWallGuard(spot);
        int24 guard = wallGuardTick;
        int24 lower;
        int24 upper;
        if (pleaIsZero) {
            // IMD is token1: the band sits below spot (tick >= upper). Use the safest of spot,
            // refTick and the placement guard.
            int24 edge = spot < refTick ? spot : refTick;
            if (guard < edge) edge = guard;
            upper = _alignDown(edge);
            lower = minTick;
            if (upper <= lower) return (work, acted);
        } else {
            // IMD is token0: the band sits above spot (tick < lower).
            int24 edge = spot > refTick ? spot : refTick;
            int24 lo = edge + 1;
            if (guard > lo) lo = guard;
            lower = _alignUp(lo);
            upper = maxTick;
            if (lower >= upper) return (work, acted);
        }
        uint128 liquidity = _liquidityForSingleSide(lower, upper, amount, !pleaIsZero);
        if (liquidity == 0) return (work, acted);
        uint160 priceBefore = currentSqrtPriceX96();
        (BalanceDelta d,) = poolManager.modifyLiquidity(
            poolKey(),
            ModifyLiquidityParams({
                tickLower: lower, tickUpper: upper, liquidityDelta: int256(uint256(liquidity)), salt: 0
            }),
            ""
        );
        if (d.amount0() > 0 || d.amount1() > 0) revert UnexpectedLiquidityDelta();
        (uint256 n0, uint256 n1) = (uint256(uint128(-d.amount0())), uint256(uint128(-d.amount1())));
        (uint256 pleaReq, uint256 imdReq) = pleaIsZero ? (n0, n1) : (n1, n0);
        if (pleaReq != 0) revert InvalidLiquidity();
        if (imdReq > amount) revert InvalidLiquidity();
        _settleImd(imdReq);
        retainedImd -= imdReq;
        wall = Band({tickLower: lower, tickUpper: upper, liquidity: liquidity});
        wallImd = imdReq;
        if (currentSqrtPriceX96() != priceBefore) revert PriceMoved();
        acted = true;
        work += imdReq;
        emit WallDeployed(lower, upper, liquidity, imdReq);
    }

    function _closeWall() internal returns (uint256 imdOut) {
        Band memory w = wall;
        if (w.liquidity == 0) return 0;
        uint256 pleaOut;
        (pleaOut, imdOut) = _removeLiquidity(w.tickLower, w.tickUpper, w.liquidity);
        delete wall;
        wallImd = 0;
        if (pleaOut != 0) {
            poolManager.take(Currency.wrap(plea), address(this), pleaOut);
            IPLEA(plea).burn(pleaOut);
            totalBurned += pleaOut;
        }
        if (imdOut != 0) {
            poolManager.take(Currency.wrap(address(imd)), address(this), imdOut);
            retainedImd += imdOut;
        }
        emit WallSettled(w.liquidity, pleaOut, imdOut);
    }

    /// @notice Anyone may add IMD to the wall's reserve (the gate routes appeal fees here).
    function fundWall(uint256 amount) external {
        imd.safeTransferFrom(msg.sender, address(this), amount);
        retainedImd += amount;
    }

    /// @dev The owner gets no tip: the wall's IMD never comes back to the team.
    function _payTip(address keeper, uint256 work) internal {
        uint256 tip = KEEPER_TIP;
        if (keeper == owner || keeper == IPLEA(plea).owner()) return;
        if (work < TIP_MIN_WORK || block.timestamp < lastTipAt + TIP_INTERVAL || retainedImd < tip) return;
        lastTipAt = block.timestamp;
        retainedImd -= tip;
        (bool ok,) = address(imd).call(abi.encodeCall(IERC20.transfer, (keeper, tip)));
        if (!ok) retainedImd += tip;
        else emit KeeperTipPaid(keeper, tip);
    }

    // ------------------------------------------------------------------ unlock plumbing

    function _unlock(bytes memory data) internal returns (bytes memory) {
        callbackExpected = true;
        return poolManager.unlock(data);
    }

    function unlockCallback(bytes calldata raw) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        if (!callbackExpected) revert CallbackNotExpected();
        callbackExpected = false;
        (uint8 action, bytes memory payload) = abi.decode(raw, (uint8, bytes));
        if (action == ACTION_SEED) {
            (int24 lower, int24 upper, uint128 liquidity) = abi.decode(payload, (int24, int24, uint128));
            (BalanceDelta d,) = poolManager.modifyLiquidity(
                poolKey(),
                ModifyLiquidityParams({
                    tickLower: lower, tickUpper: upper, liquidityDelta: int256(uint256(liquidity)), salt: 0
                }),
                ""
            );
            if (d.amount0() > 0 || d.amount1() > 0) revert UnexpectedLiquidityDelta();
            (uint256 n0, uint256 n1) = (uint256(uint128(-d.amount0())), uint256(uint128(-d.amount1())));
            (uint256 pleaReq, uint256 imdReq) = pleaIsZero ? (n0, n1) : (n1, n0);
            if (imdReq != 0) revert InvalidLiquidity();
            poolManager.sync(Currency.wrap(plea));
            IERC20(plea).safeTransfer(address(poolManager), pleaReq);
            poolManager.settle();
            return abi.encode(pleaReq);
        }
        if (action == ACTION_REBALANCE) {
            (uint256 work, bool acted) = _rebalance();
            return abi.encode(work, acted);
        }
        revert CallbackNotExpected();
    }

    function _settleImd(uint256 amount) internal {
        if (amount == 0) return;
        poolManager.sync(Currency.wrap(address(imd)));
        imd.safeTransfer(address(poolManager), amount);
        poolManager.settle();
    }

    // ------------------------------------------------------------------ helpers

    function _observeTick() internal {
        if (block.number != refBlock) {
            int24 target = curBlockTick;
            int24 d = target - refTick;
            if (d > MAX_REF_STEP) target = refTick + MAX_REF_STEP;
            else if (d < -MAX_REF_STEP) target = refTick - MAX_REF_STEP;
            refTick = target;
            refBlock = uint64(block.number);
        }
        curBlockTick = currentTick();
    }

    /// @dev The guard value an observed tick allows: the tick itself for a band below spot (PLEA is
    /// token0), one tick above it for a band above spot (PLEA is token1).
    function _guardFor(int24 tick) internal view returns (int24) {
        return pleaIsZero ? tick : tick + 1;
    }

    /// @dev Moves the wall guard: at once in the safe direction (a lower PLEA price) to any observed
    /// tick, and back toward `refTick` at most WALL_GUARD_TICKS_PER_DAY, paced by wall-clock time with
    /// the sub-tick remainder carried and idle time capped at one day (as POOL4's deployment floor).
    /// A tick the pool sits at with no active liquidity is where a swap that emptied the pool's IMD
    /// side stopped (the router's default limit at the tick extreme, or any limit the seller chose
    /// inside the liquidity-free region below the market band), not a price PLEA traded at: the guard
    /// ignores it, or the wall would be parked hundreds of thousands of ticks below the market for
    /// years. A tick inside a band with liquidity was paid for in PLEA and counts.
    function _updateWallGuard(int24 observedTick) internal {
        int24 g = wallGuardTick;
        uint256 elapsed = block.timestamp - lastGuardAt;
        if (elapsed != 0) {
            lastGuardAt = block.timestamp;
            int24 target = _guardFor(refTick);
            // Unsafe direction = toward a higher PLEA price: up in raw ticks when PLEA is token0.
            bool behind = pleaIsZero ? target > g : target < g;
            if (behind) {
                if (elapsed > 1 days) elapsed = 1 days;
                uint256 numerator = WALL_GUARD_TICKS_PER_DAY * elapsed + guardRemainder;
                uint256 allowed = numerator / 1 days;
                guardRemainder = numerator % 1 days;
                uint256 gap = pleaIsZero ? uint256(int256(target) - int256(g)) : uint256(int256(g) - int256(target));
                if (allowed >= gap) g = target;
                else g = pleaIsZero ? g + int24(int256(allowed)) : g - int24(int256(allowed));
            } else {
                guardRemainder = 0;
            }
        }
        if (observedTick > minTick && observedTick < maxTick && poolManager.getLiquidity(poolId()) != 0) {
            int24 seen = _guardFor(observedTick);
            if (pleaIsZero ? seen < g : seen > g) g = seen;
        }
        wallGuardTick = g;
    }

    function _checkpoint(uint160 sqrtP) internal {
        uint64 hour = uint64(block.timestamp / 1 hours);
        Checkpoint storage c = ring[hour % 25];
        if (c.hour != hour) {
            uint256 p = _priceX96(sqrtP);
            c.hour = hour;
            c.priceX96 = p;
            lastCheckpointHour = hour;
            emit PriceCheckpoint(hour, p);
        }
    }

    /// @dev Liquidity for an amount of one side only. `isToken0` says which side the amount is.
    function _liquidityForSingleSide(int24 lower, int24 upper, uint256 amount, bool isToken0)
        internal
        pure
        returns (uint128)
    {
        uint160 lo = TickMath.getSqrtPriceAtTick(lower);
        uint160 hi = TickMath.getSqrtPriceAtTick(upper);
        uint256 l;
        if (isToken0) {
            uint256 intermediate = FullMath.mulDiv(lo, hi, FixedPoint96.Q96);
            l = FullMath.mulDiv(amount, intermediate, hi - lo);
        } else {
            l = FullMath.mulDiv(amount, FixedPoint96.Q96, hi - lo);
        }
        l = l - l / 1_000_000; // rounding margin so the add never asks for more than `amount`
        if (l > type(uint128).max) revert InvalidLiquidity();
        return uint128(l);
    }

    function _alignUp(int24 tick) internal pure returns (int24) {
        int24 aligned = (tick / TICK_SPACING) * TICK_SPACING;
        if (aligned < tick) aligned += TICK_SPACING;
        return aligned;
    }

    function _alignDown(int24 tick) internal pure returns (int24) {
        int24 aligned = (tick / TICK_SPACING) * TICK_SPACING;
        if (aligned > tick) aligned -= TICK_SPACING;
        return aligned;
    }

    function _sqrt(uint256 x) internal pure returns (uint256 y) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2;
        y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }

    function _id(address currency) internal pure returns (uint256) {
        return uint256(uint160(currency));
    }

    function _requirePoolManagerAndPool(PoolKey calldata key) internal view {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        if (PoolId.unwrap(key.toId()) != PoolId.unwrap(poolId())) revert InvalidPool();
    }
}
