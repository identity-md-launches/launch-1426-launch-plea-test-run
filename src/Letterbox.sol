// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {FixedPoint96} from "v4-core/libraries/FixedPoint96.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {CabalGate} from "./CabalGate.sol";
import {IPLEA, IPleaHook} from "./interfaces/IPleaParts.sol";

interface ISeasonsForLetters {
    function record(uint256 pleaId) external;
    function recorded(uint256 pleaId) external view returns (bool);
    function currentSeason() external view returns (bool live, uint256 season, uint64 endsAt);
    function topOf(uint256 season) external view returns (Entry[10] memory);
    function seasonFees(uint256 season) external view returns (uint256);
    function rollover() external view returns (uint256);
    function BONUS_SEASONS() external view returns (uint256);
    function BONUS_PER_SEASON() external view returns (uint256);

    struct Entry {
        address wallet;
        uint16 points;
        uint64 pleaId;
    }
}

/// @dev PleaLaunch, which deploys the Letterbox after the launch and holds its settings.
interface ILetterboxLaunch {
    function plea() external view returns (address);
    function gate() external view returns (address);
    function seasons() external view returns (address);
    function imd() external view returns (address);
    function oracleAsset() external view returns (address);
    function mintOracleFee() external view returns (bool);
}

interface IMintable {
    function mint(address to, uint256 amount) external;
}

/// @title Letterbox — plead to the Cabal by sending a letter
/// @notice A letter is a transaction to this contract whose input data is the plea text (UTF-8),
/// as a wallet's data field or an explorer's message (IDM) page sends it, or the same text passed
/// to `letter(text)` from an explorer's Write Contract tab. The writer is always the sender. The
/// first word decides what it does:
///   any other text   a new plea for 10% of the writer's PLEA, sold automatically if approved;
///   `APPEAL <text>`  an appeal of the writer's latest denied plea, for its original amount;
///   `SELL`           the writer sells their own approved letter plea (if no runner did yet);
///   `NAME <name>`    the writer's display name (3-20 characters a-z 0-9 _, unique; `setName`).
/// Fees are paid in PLEA in the letter's own transaction: the gate sells just enough of the writer's
/// PLEA (at most the hourly snapshot value + 10%) for the oracle fee, a 0.25 IMD runner tip and, for
/// an appeal, the wall share. The plea's PLEA waits here in escrow. An approved plea is sold by
/// anyone through `deliver` (for at least 95% of its snapshot value), who earns the tip; every
/// other ending returns the escrow and the tip to the writer through `settle`. The site's
/// "sell automatically" box uses `plead` / `appealAuto`, with the same escrow and tip.
/// @dev No owner and no admin. No public function's ID can be the start of a valid letter (its four
/// bytes are not the beginning of control-free UTF-8 text), so no letter can call a function by
/// accident; a test checks the whole ABI. `deliver` runs the `SELL` letter's sale too, with the
/// writer as the runner, so the writer gets the tip back.
contract Letterbox is ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    error LetterTooSmall(uint256 amount);
    error FeeTooHigh(uint256 maxFeePlea, uint256 balance);
    error PendingExists(uint256 id);
    error NotOpen(uint256 id);
    error NotSettleable(uint256 id);
    error NothingToAppeal();
    error NoPrice();
    error MintOnMainnet();
    error OracleAssetNotImd();
    error BadName();
    error NameTaken();

    event Escrowed(uint256 indexed id, address indexed writer, uint256 amount, uint256 feePlea, uint8 flags);
    event Delivered(uint256 indexed id, address indexed runner, uint256 imdOut, uint256 tip);
    event Settled(uint256 indexed id, address indexed writer, uint256 amount, uint256 tip);
    event NameSet(address indexed wallet, string name);

    /// @dev One storage slot: `amount` is at most the gate's 2.5M PLEA cap (checked before `_open`).
    struct Escrow {
        address writer;
        bool open;
        uint88 amount;
    }

    // ---------------------------------------------------------------- agreed numbers
    /// @dev A letter pleads 10% of the writer's PLEA (within the gate's 2.5M cap).
    uint256 internal constant LETTER_SHARE_BPS = 1_000;
    /// @dev A letter below this amount is refused (the fees would dwarf it).
    uint256 internal constant MIN_LETTER = 1_000e18;
    /// @dev Paid to whoever delivers an approved plea; refunded when no sale happens.
    uint256 internal constant TIP = 0.25e18;
    /// @dev Auto-sell minimum: 95% of the PLEA's value at the hook's hourly snapshot.
    uint256 internal constant MIN_OUT_BPS = 9_500;
    /// @dev The fee swap may spend at most the snapshot value of the IMD it buys, plus 10%.
    uint256 internal constant FEE_CAP_BPS = 11_000;
    /// @dev The fees may take at most 10% of the writer's PLEA.
    uint256 internal constant MAX_FEE_SHARE_BPS = 1_000;
    uint256 internal constant BPS = 10_000;
    // CabalGate's numbers, repeated for the fee arithmetic and the status text.
    uint256 internal constant ORACLE_FEE = 0.5e18;
    uint256 internal constant APPEAL_FEE = 0.35e18;
    uint256 internal constant MAX_SELL = 2_500_000e18;
    uint256 internal constant MAX_SHARE_BPS = 3_500;
    uint256 internal constant WINDOW = 7 minutes;
    uint256 internal constant COOLDOWN = 4 hours;
    uint8 internal constant BY_LETTER = 1;
    uint8 internal constant AUTO_SELL = 2;

    IPLEA internal immutable plea;
    CabalGate internal immutable gate;
    ISeasonsForLetters internal immutable seasons;
    IERC20 internal immutable imd;
    IERC20 internal immutable oracleAsset;
    /// @dev Sepolia: the oracle fee token is a separate test token anyone can mint, so the Letterbox
    /// mints the 0.5 instead of buying it. Refused on chain id 1.
    bool internal immutable mintOracleFee;

    mapping(uint256 => Escrow) internal _escrow;
    mapping(address => uint256) internal _openOf;
    mapping(uint256 => uint256) internal _soldFor;
    uint256 internal _openCount;

    mapping(address => string) internal _names;
    /// @notice The wallet holding a display name (by the name's keccak256).
    mapping(bytes32 => address) public nameOwner;

    /// @dev Deployed by `PleaLaunch.deployLetterbox` after the launch: it reads its settings from its
    /// deployer, so it takes no constructor arguments and its creation code, committed at launch, is
    /// the same for every deployment.
    constructor() {
        ILetterboxLaunch l = ILetterboxLaunch(msg.sender);
        address imd_ = l.imd();
        address oracleAsset_ = l.oracleAsset();
        bool mint_ = l.mintOracleFee();
        if (mint_ && block.chainid == 1) revert MintOnMainnet();
        if (!mint_ && oracleAsset_ != imd_) revert OracleAssetNotImd();
        plea = IPLEA(l.plea());
        gate = CabalGate(l.gate());
        seasons = ISeasonsForLetters(l.seasons());
        imd = IERC20(imd_);
        oracleAsset = IERC20(oracleAsset_);
        mintOracleFee = mint_;
    }

    // ================================================================ letters

    /// @notice A letter: the input data is the text. ETH is refused (the function is not payable).
    fallback() external nonReentrant {
        _read(msg.data);
    }

    /// @notice The same letter typed into a block explorer's Write Contract tab: `text` is read
    /// exactly like a letter's input data (a plea, `APPEAL <text>`, `SELL` or `NAME <name>`).
    function letter(string calldata text) external nonReentrant {
        _read(bytes(text));
    }

    function _read(bytes calldata d) internal {
        if (_isWord(d, "APPEAL")) {
            _appeal(msg.sender, _appealTarget(msg.sender), string(_after(d, 6)), BY_LETTER | AUTO_SELL);
        } else if (_isWord(d, "NAME")) {
            _setName(msg.sender, _after(d, 4));
        } else if (_isWord(d, "SELL")) {
            uint256 id = _openOf[msg.sender];
            if (id == 0) revert NotOpen(0);
            _deliver(id, msg.sender);
        } else {
            _plead(msg.sender, 0, string(d), BY_LETTER | AUTO_SELL);
        }
    }

    // ================================================================ the site's auto-sell

    /// @notice Plead `amount` with the site's "sell automatically" box: escrow, fees in PLEA and
    /// the tip exactly as a letter, no approvals needed.
    function plead(uint256 amount, string calldata text) external nonReentrant returns (uint256 id) {
        if (amount == 0) revert LetterTooSmall(0);
        return _plead(msg.sender, amount, text, AUTO_SELL);
    }

    /// @notice Appeal a denied plea with auto-sell, for its original amount.
    function appealAuto(uint256 originalId, string calldata text) external nonReentrant returns (uint256 id) {
        return _appeal(msg.sender, originalId, text, AUTO_SELL);
    }

    // ================================================================ names

    /// @notice Sets the caller's display name: 3-20 characters of a-z, 0-9 and _, unique. An empty
    /// name clears it. Reserved: cabal, admin, imd, plea, owner. A `NAME <name>` letter does the same.
    function setName(string calldata name) external {
        _setName(msg.sender, bytes(name));
    }

    function nameOf(address wallet) external view returns (string memory) {
        return _names[wallet];
    }

    function _setName(address wallet, bytes calldata name) internal {
        string memory old = _names[wallet];
        if (bytes(old).length != 0) delete nameOwner[keccak256(bytes(old))];
        if (name.length == 0) {
            delete _names[wallet];
            emit NameSet(wallet, "");
            return;
        }
        _checkName(name);
        bytes32 h = keccak256(name);
        if (nameOwner[h] != address(0)) revert NameTaken();
        nameOwner[h] = wallet;
        _names[wallet] = string(name);
        emit NameSet(wallet, string(name));
    }

    function _checkName(bytes calldata b) internal pure {
        if (b.length < 3 || b.length > 20) revert BadName();
        for (uint256 i; i < b.length; ++i) {
            bytes1 c = b[i];
            if (!((c >= "a" && c <= "z") || (c >= "0" && c <= "9") || c == "_")) revert BadName();
        }
        bytes32 h = keccak256(b);
        if (
            h == keccak256("cabal") || h == keccak256("admin") || h == keccak256("imd") || h == keccak256("plea")
                || h == keccak256("owner")
        ) revert BadName();
    }

    // ================================================================ runners

    /// @notice Anyone sells an approved plea inside its 7-minute window, for at least 95% of its
    /// snapshot value: the IMD goes to the writer, the points are recorded, and the caller earns
    /// the 0.25 IMD tip.
    function deliver(uint256 id) external nonReentrant returns (uint256 out) {
        return _deliver(id, msg.sender);
    }

    /// @notice Anyone ends an escrow that will not be sold (denied, upheld, no verdict, expired or
    /// lapsed): the PLEA and the tip go back to the writer. A lapsed approval is recorded first,
    /// since it still counts for its season.
    function settle(uint256 id) external nonReentrant {
        _settle(id);
    }

    // ================================================================ internals

    function _plead(address writer, uint256 amount, string memory text, uint8 flags) internal returns (uint256 id) {
        _settleOpen(writer);
        uint256 bal = plea.balanceOf(writer);
        if (amount == 0) {
            amount = bal * LETTER_SHARE_BPS / BPS;
            if (amount > MAX_SELL) amount = MAX_SELL;
            if (amount < MIN_LETTER) revert LetterTooSmall(amount);
        }
        (uint256 feeImd, uint256 maxFeePlea) = feesFor(false);
        if (maxFeePlea * BPS > bal * MAX_FEE_SHARE_BPS) revert FeeTooHigh(maxFeePlea, bal);
        plea.courtTake(writer, amount + maxFeePlea);
        _approveGate(maxFeePlea, false);
        uint256 feePlea;
        (id, feePlea) = gate.submitFor(writer, amount, bal, text, flags, feeImd, maxFeePlea);
        _open(id, writer, amount, maxFeePlea - feePlea, feePlea, flags);
    }

    function _appeal(address writer, uint256 originalId, string memory text, uint8 flags)
        internal
        returns (uint256 id)
    {
        if (originalId == 0) revert NothingToAppeal();
        _settleOpen(writer);
        uint256 amount = gate.getPlea(originalId).amount;
        uint256 bal = plea.balanceOf(writer);
        // The original amount, or the gate's 35% of the balance when the fee sales left less.
        if (amount > bal * MAX_SHARE_BPS / BPS) amount = bal * MAX_SHARE_BPS / BPS;
        (uint256 feeImd, uint256 maxFeePlea) = feesFor(true);
        if (maxFeePlea * BPS > bal * MAX_FEE_SHARE_BPS) revert FeeTooHigh(maxFeePlea, bal);
        plea.courtTake(writer, amount + maxFeePlea);
        _approveGate(maxFeePlea, true);
        uint256 feePlea;
        (id, feePlea) = gate.appealFor(writer, originalId, amount, bal, text, flags, feeImd, maxFeePlea);
        _open(id, writer, amount, maxFeePlea - feePlea, feePlea, flags);
    }

    /// @dev Lets the gate pull the fee PLEA, the oracle fee and an appeal's wall share.
    function _approveGate(uint256 maxFeePlea, bool isAppeal) internal {
        IERC20(address(plea)).forceApprove(address(gate), maxFeePlea);
        uint256 wall = isAppeal ? APPEAL_FEE : 0;
        if (mintOracleFee) {
            IMintable(address(oracleAsset)).mint(address(this), ORACLE_FEE);
            oracleAsset.forceApprove(address(gate), ORACLE_FEE);
            imd.forceApprove(address(gate), wall);
        } else {
            imd.forceApprove(address(gate), ORACLE_FEE + wall);
        }
    }

    function _open(uint256 id, address writer, uint256 amount, uint256 unspent, uint256 feePlea, uint8 flags) internal {
        if (unspent != 0) IERC20(address(plea)).safeTransfer(writer, unspent);
        _escrow[id] = Escrow({writer: writer, open: true, amount: SafeCast.toUint88(amount)});
        _openOf[writer] = id;
        ++_openCount;
        emit Escrowed(id, writer, amount, feePlea, flags);
    }

    function _close(uint256 id, Escrow storage e) internal {
        e.open = false;
        if (_openOf[e.writer] == id) _openOf[e.writer] = 0;
        --_openCount;
    }

    function _deliver(uint256 id, address runner) internal returns (uint256 out) {
        Escrow storage e = _escrow[id];
        if (!e.open) revert NotOpen(id);
        uint256 amount = e.amount;
        uint256 minOut = FullMath.mulDiv(amount, _price(), FixedPoint96.Q96) * MIN_OUT_BPS / BPS;
        IERC20(address(plea)).forceApprove(address(gate), amount);
        _close(id, e);
        out = gate.executeSellFor(id, minOut);
        _soldFor[id] = out;
        _record(id);
        imd.safeTransfer(runner, TIP);
        emit Delivered(id, runner, out, TIP);
    }

    function _settle(uint256 id) internal {
        Escrow storage e = _escrow[id];
        if (!e.open) revert NotOpen(id);
        CabalGate.Plea memory p = gate.getPlea(id);
        if (p.status == CabalGate.Status.Pending) {
            gate.expire(id); // reverts while a verdict can still come
        } else if (p.status == CabalGate.Status.Approved) {
            if (block.timestamp <= uint256(p.verdictAt) + WINDOW) revert NotSettleable(id);
            _record(id);
        } else if (p.status == CabalGate.Status.Lapsed) {
            _record(id);
        } else if (p.status != CabalGate.Status.Denied && p.status != CabalGate.Status.Expired) {
            revert NotSettleable(id);
        }
        address writer = e.writer;
        uint256 amount = e.amount;
        _close(id, e);
        IERC20(address(plea)).safeTransfer(writer, amount);
        imd.safeTransfer(writer, TIP);
        emit Settled(id, writer, amount, TIP);
    }

    /// @dev A new letter first ends the writer's previous escrow, so funds never wait for a stranger.
    function _settleOpen(address writer) internal {
        uint256 id = _openOf[writer];
        if (id == 0) return;
        if (!_settleable(id)) revert PendingExists(id);
        _settle(id);
    }

    function _settleable(uint256 id) internal view returns (bool) {
        CabalGate.Plea memory p = gate.getPlea(id);
        if (p.status == CabalGate.Status.Approved) return block.timestamp > uint256(p.verdictAt) + WINDOW;
        if (p.status == CabalGate.Status.Pending) {
            return block.timestamp > uint256(p.submittedAt) + gate.PENDING_EXPIRY() || _intakeDone(p.intakeId);
        }
        return p.status != CabalGate.Status.Executed;
    }

    function _intakeDone(bytes32 intakeId) internal view returns (bool done) {
        (,,, done) = gate.intake().requests(intakeId);
    }

    /// @dev Points for an approval; a failure (already recorded, season closed, the owner) is not
    /// this letter's problem, and anyone can still call `Seasons.record`.
    function _record(uint256 id) internal {
        if (seasons.recorded(id)) return;
        try seasons.record(id) {} catch {}
    }

    function _price() internal view returns (uint256 p) {
        p = IPleaHook(plea.hook()).latestPrice();
        if (p == 0) revert NoPrice();
    }

    /// @dev The text after a command word of `n` bytes and its separator; empty for the bare word.
    function _after(bytes calldata d, uint256 n) internal pure returns (bytes calldata) {
        return d.length > n + 1 ? d[n + 1:] : d[d.length:];
    }

    /// @dev What an APPEAL letter appeals: the writer's newest plea, or, when that is an appeal the
    /// oracle never answered (the gate lets the writer retry it), the denied plea it appealed.
    function _appealTarget(address writer) internal view returns (uint256 id) {
        id = gate.lastPleaOf(writer);
        if (id == 0) return 0;
        CabalGate.Plea memory p = gate.getPlea(id);
        if (p.isAppeal && p.status == CabalGate.Status.Expired) id = p.originalId;
    }

    /// @dev `d` is `word` alone, or `word` followed by a space or a newline.
    function _isWord(bytes calldata d, bytes memory word) internal pure returns (bool) {
        uint256 n = word.length;
        if (d.length < n) return false;
        if (d.length > n && d[n] != " " && d[n] != "\n") return false;
        return keccak256(d[:n]) == keccak256(word);
    }

    // ================================================================ views

    /// @notice What a plea (or an appeal) by letter costs now: the IMD it buys and the most PLEA it
    /// may spend on it (snapshot value + 10%; unspent PLEA goes back).
    function feesFor(bool isAppeal) public view returns (uint256 feeImd, uint256 maxFeePlea) {
        feeImd = TIP + (isAppeal ? APPEAL_FEE : 0) + (mintOracleFee ? 0 : ORACLE_FEE);
        maxFeePlea = FullMath.mulDiv(feeImd * FEE_CAP_BPS / BPS, FixedPoint96.Q96, _price()) + 1;
    }

    /// @notice An escrow: writer, still open, PLEA held; and the IMD its sale paid (0 if unsold).
    function escrowOf(uint256 id) external view returns (address writer, bool open, uint256 amount, uint256 soldFor) {
        Escrow memory e = _escrow[id];
        return (e.writer, e.open, e.amount, _soldFor[id]);
    }

    /// @notice The writer's open escrow (0 if none), and the number of open escrows (each holds a tip).
    function openOf(address writer) external view returns (uint256 id, uint256 openCount) {
        return (_openOf[writer], _openCount);
    }

    /// @notice One sentence about `w`'s latest plea, readable from a block explorer.
    function status(address w) external view returns (string memory) {
        if (gate.startedAt() == 0) return "Trading has not opened yet.";
        if (!gate.cabalAlive()) return "The Cabal is dead. PLEA trades freely.";
        uint256 id = gate.lastPleaOf(w);
        if (id == 0) return string.concat("No plea yet. ", _next(w, 0));
        CabalGate.Plea memory p = gate.getPlea(id);
        string memory head = string.concat(p.isAppeal ? "Appeal #" : "Plea #", Strings.toString(id), unicode" · ");
        string memory vs = string.concat(" (", Strings.toString(p.score), " vs ", Strings.toString(p.need), ")");
        CabalGate.Status s = p.status;
        if (s == CabalGate.Status.Pending) {
            return string.concat(
                head, unicode"PENDING · asked ", Strings.toString((block.timestamp - p.submittedAt) / 60), "m ago"
            );
        }
        bool lapsed = s == CabalGate.Status.Lapsed
            || (s == CabalGate.Status.Approved && block.timestamp > uint256(p.verdictAt) + WINDOW);
        if (s == CabalGate.Status.Approved && !lapsed) {
            return string.concat(
                head,
                "APPROVED",
                vs,
                (p.flags & AUTO_SELL) != 0
                    ? unicode" · selling automatically"
                    : string.concat(unicode" · sell before ", _clock(uint256(p.verdictAt) + WINDOW))
            );
        }
        if (s == CabalGate.Status.Executed) {
            uint256 sold = _soldFor[id];
            return string.concat(
                head,
                "SOLD",
                sold != 0 ? string.concat(" for ", _imd(sold)) : "",
                unicode" · ",
                _points(w, id, p),
                unicode" · ",
                _next(w, id)
            );
        }
        if (s == CabalGate.Status.Denied) {
            if (!p.isAppeal && !p.appealed && block.timestamp <= uint256(p.verdictAt) + COOLDOWN) {
                return string.concat(
                    head,
                    "DENIED",
                    vs,
                    unicode" · send APPEAL <text> before ",
                    _clock(uint256(p.verdictAt) + COOLDOWN),
                    _escrowNote(id)
                );
            }
            return
                string.concat(head, p.isAppeal ? "UPHELD" : "DENIED", vs, _escrowNote(id), unicode" · ", _next(w, id));
        }
        if (lapsed) {
            return string.concat(head, "LAPSED", vs, unicode" · ", _points(w, id, p), unicode" · ", _next(w, id));
        }
        return string.concat(head, "NO VERDICT", _escrowNote(id), unicode" · ", _next(w, id));
    }

    /// @notice The running season's top 10 as text lines: rank, name, points, and the IMD prize and
    /// PLEA bonus each rank would get from the pot as it stands.
    function leaderboard() external view returns (string memory out) {
        (bool live, uint256 key, uint64 endsAt) = seasons.currentSeason();
        if (!live) return "No season is running: the Cabal is dead or trading has not opened.";
        uint256 potNow = seasons.seasonFees(key) + seasons.rollover();
        uint256 bonus = key < seasons.BONUS_SEASONS() ? seasons.BONUS_PER_SEASON() : 0;
        out = string.concat(
            "Season ",
            Strings.toString(key + 1),
            unicode" · ends ",
            _clock(endsAt),
            unicode" · pot ",
            _imd(potNow),
            bonus != 0 ? string.concat(" + ", _thousands(bonus / 1e18), " PLEA") : ""
        );
        ISeasonsForLetters.Entry[10] memory t = seasons.topOf(key);
        for (uint256 i; i < 10; ++i) {
            if (t[i].wallet == address(0)) break;
            uint256 share = _shareBps(i);
            out = string.concat(
                out,
                "\n",
                Strings.toString(i + 1),
                ". ",
                _who(t[i].wallet),
                unicode" · ",
                Strings.toString(t[i].points),
                " pts",
                t[i].points >= 60
                    ? string.concat(
                        unicode" · ",
                        _imd(potNow * share / BPS),
                        bonus != 0 ? string.concat(" + ", _thousands(bonus * share / BPS / 1e18), " PLEA") : ""
                    )
                    : " (needs 60)"
            );
        }
        out =
            string.concat(out, "\nBest 3 approved pleas count. Top 10 with 60+ points share 25/18/14/11/9/7/6/4/3/3%.");
    }

    // ---------------------------------------------------------------- text helpers

    function _next(address w, uint256 lastId) internal view returns (string memory) {
        uint256 until = _max(gate.lastExecutedAt(w), _max(gate.lastDeniedAt(w), gate.lastLapsedAt(w)));
        if (lastId != 0) {
            CabalGate.Plea memory p = gate.getPlea(lastId);
            if (p.status == CabalGate.Status.Approved) until = _max(until, p.verdictAt);
        }
        if (until != 0) until += COOLDOWN;
        if (until > block.timestamp) return string.concat("Cooldown until ", _clock(until));
        return "Next plea possible now.";
    }

    function _escrowNote(uint256 id) internal view returns (string memory) {
        Escrow memory e = _escrow[id];
        if (e.writer == address(0)) return "";
        return
            e.open
                ? unicode" · call settle or send a letter to get your PLEA back"
                : unicode" · PLEA and tip returned";
    }

    function _points(address w, uint256 id, CabalGate.Plea memory p) internal view returns (string memory) {
        if (!seasons.recorded(id)) return string.concat("+", Strings.toString(p.score), " points once recorded");
        uint256 key = (uint256(p.verdictAt) - gate.startedAt()) / gate.SEASON();
        ISeasonsForLetters.Entry[10] memory t = seasons.topOf(key);
        string memory rank = "";
        for (uint256 i; i < 10; ++i) {
            if (t[i].wallet == w) {
                rank = string.concat(", rank ", Strings.toString(i + 1));
                break;
            }
        }
        return string.concat("+", Strings.toString(p.score), " points (season ", Strings.toString(key + 1), rank, ")");
    }

    function _who(address w) internal view returns (string memory) {
        string memory n = _names[w];
        if (bytes(n).length != 0) return n;
        bytes memory h = bytes(Strings.toHexString(w));
        bytes memory s = new bytes(13);
        for (uint256 i; i < 6; ++i) {
            s[i] = h[i];
        }
        s[6] = 0xe2; // U+2026 horizontal ellipsis
        s[7] = 0x80;
        s[8] = 0xa6;
        for (uint256 i; i < 4; ++i) {
            s[9 + i] = h[38 + i];
        }
        return string(s);
    }

    /// @dev "HH:MM UTC".
    function _clock(uint256 t) internal pure returns (string memory) {
        return string.concat(_two((t / 3600) % 24), ":", _two((t / 60) % 60), " UTC");
    }

    function _two(uint256 v) internal pure returns (string memory) {
        return v < 10 ? string.concat("0", Strings.toString(v)) : Strings.toString(v);
    }

    /// @dev An IMD amount with two decimals, rounded down: "1.97 IMD".
    function _imd(uint256 a) internal pure returns (string memory) {
        return string.concat(_thousands(a / 1e18), ".", _two((a % 1e18) / 1e16), " IMD");
    }

    function _thousands(uint256 v) internal pure returns (string memory s) {
        if (v < 1000) return Strings.toString(v);
        s = Strings.toString(v % 1000);
        if (v % 1000 < 10) s = string.concat("00", s);
        else if (v % 1000 < 100) s = string.concat("0", s);
        return string.concat(_thousands(v / 1000), ",", s);
    }

    function _shareBps(uint256 rank) internal pure returns (uint256) {
        if (rank == 0) return 2_500;
        if (rank == 1) return 1_800;
        if (rank == 2) return 1_400;
        if (rank == 3) return 1_100;
        if (rank == 4) return 900;
        if (rank == 5) return 700;
        if (rank == 6) return 600;
        if (rank == 7) return 400;
        return 300;
    }

    function _max(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a : b;
    }
}
