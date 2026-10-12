// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IGate} from "./interfaces/IPleaParts.sol";

/// @title PLEA — the sell-gated meme token
/// @notice 1e9 supply, 18 decimals, minted once in `init` (87% hook, 3% Seasons' bonus prizes,
/// 10% distributor). While the
/// gate says the Cabal is watching (`restricted()`), transfers are limited: see `_update`. When
/// the Cabal dies the restriction ends for good.
contract PLEA is ERC20, Ownable {
    error CabalIsWatching();
    error NotDeployTx();
    error AlreadySet();
    error NotLauncher();
    error ZeroAddress();
    error NotLetterbox();

    event Launched(address indexed launcher, address gate, address seasons, address laureates, address distributor);
    event Initialized(address indexed hook);
    event Allowed(address indexed account);
    event LetterboxSet(address indexed letterbox);

    uint256 public constant TOTAL_SUPPLY = 1_000_000_000e18;
    // keccak256("plea.deploy-tx") - 1
    uint256 private constant DEPLOY_TX_SLOT = 0x6e1b7d1b1a9e3e1b4d3f8c2a1d0b9e8f7c6b5a4d3e2f1a0b9c8d7e6f5a4b3c2d;

    /// @dev Fallback for the transient flag: the launch rehearsal deploys each contract in its own
    /// call, which clears transient storage, so `setLauncher` also accepts the deployment block.
    uint256 public immutable deployBlock;

    address public launcher;
    address public gate;
    address public seasons;
    address public laureates;
    address public distributor;
    address public hook;
    address public poolManager;
    /// @notice The court's Letterbox: holds plea escrows and tips for pleas sent by letter (or with
    /// the site's auto-sell). It may move a wallet's PLEA only inside that wallet's own transaction.
    address public letterbox;

    /// @notice Add-only allowlist of senders exempt from the Cabal's transfer rule.
    mapping(address => bool) public allowed;

    constructor(address owner_) ERC20("PLEA", "PLEA") Ownable(owner_) {
        deployBlock = block.number;
        assembly ("memory-safe") {
            tstore(DEPLOY_TX_SLOT, 1)
        }
    }

    /// @notice Records the launcher and system contracts once, from PleaLaunch's constructor.
    /// @dev Registration also accepts any first caller in PLEA's deployment block for rehearsals.
    /// The factory must deploy all six contracts atomically to prevent an intervening registration.
    function setLauncher(address gate_, address seasons_, address laureates_, address distributor_) external {
        uint256 flag;
        assembly ("memory-safe") {
            flag := tload(DEPLOY_TX_SLOT)
        }
        if (flag != 1 && block.number != deployBlock) revert NotDeployTx();
        if (launcher != address(0)) revert AlreadySet();
        if (gate_ == address(0) || seasons_ == address(0) || laureates_ == address(0) || distributor_ == address(0)) {
            revert ZeroAddress();
        }
        assembly ("memory-safe") {
            tstore(DEPLOY_TX_SLOT, 0)
        }
        launcher = msg.sender;
        gate = gate_;
        seasons = seasons_;
        laureates = laureates_;
        distributor = distributor_;
        emit Launched(msg.sender, gate_, seasons_, laureates_, distributor_);
    }

    /// @notice Records the Letterbox once, from PleaLaunch's constructor (right after `setLauncher`).
    function setLetterbox(address letterbox_) external {
        if (msg.sender != launcher) revert NotLauncher();
        if (letterbox != address(0)) revert AlreadySet();
        if (letterbox_ == address(0)) revert ZeroAddress();
        letterbox = letterbox_;
        emit LetterboxSet(letterbox_);
    }

    /// @notice The court's entry point: the Letterbox moves `amount` from `from` into escrow, without
    /// an allowance. The Letterbox only ever passes its own caller as `from`, so a wallet's PLEA
    /// moves only inside a letter or site transaction that wallet sent itself.
    function courtTake(address from, uint256 amount) external {
        address lb = letterbox;
        if (lb == address(0) || msg.sender != lb) revert NotLetterbox();
        _transfer(from, lb, amount);
    }

    /// @notice Records the hook and mints the supply: 87% to the hook, 3% to Seasons (the PLEA
    /// bonus prizes of the first six seasons) and 10% to the distributor. Only the launcher,
    /// once (from `deployHook`).
    function init(address hook_, address poolManager_) external {
        if (msg.sender != launcher) revert NotLauncher();
        if (hook != address(0)) revert AlreadySet();
        if (hook_ == address(0) || poolManager_ == address(0)) revert ZeroAddress();
        hook = hook_;
        poolManager = poolManager_;
        _mint(hook_, TOTAL_SUPPLY * 87 / 100);
        _mint(seasons, TOTAL_SUPPLY * 3 / 100);
        _mint(distributor, TOTAL_SUPPLY * 10 / 100);
        emit Initialized(hook_);
    }

    /// @notice Owner adds an address that may send PLEA freely while the Cabal watches. Add-only.
    function allow(address account) external onlyOwner {
        allowed[account] = true;
        emit Allowed(account);
    }

    /// @notice Burns the caller's own tokens (the hook burns trims and the burn fee this way).
    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }

    /// @notice True while sell limits apply: before trading opens, and while the Cabal lives.
    function restricted() public view returns (bool) {
        address g = gate;
        if (g == address(0)) return true;
        return IGate(g).restricted();
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && restricted()) {
            if (to == poolManager) {
                if (from != gate && from != hook) revert CabalIsWatching();
            } else if (to == gate) {
                // Only the gate pulls PLEA (transferFrom in executeSell); direct sends are refused.
                if (msg.sender != gate) revert CabalIsWatching();
            } else if (!_exempt(from) && !(to == letterbox && msg.sender == to && to != address(0))) {
                // Escrow into the Letterbox only through `courtTake`; direct sends are refused.
                revert CabalIsWatching();
            }
        }
        super._update(from, to, value);
    }

    /// @dev Senders that move PLEA freely while the Cabal watches: the pool and the court's own
    /// contracts (the Letterbox returns escrows and pays them into sales), and the owner's allowlist.
    function _exempt(address from) internal view returns (bool) {
        return from == poolManager || from == hook || from == gate || from == distributor || from == seasons
            || (from == letterbox && from != address(0)) || allowed[from];
    }
}
