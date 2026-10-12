// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev Controllable external verdict source. It has no ranking or payout logic.
contract SeasonResults {
    uint256 public constant SEASON = 18000;
    uint64 public constant startedAt = 1791817200;
    uint64 public diedAt;

    struct Result {
        address seller;
        uint8 score;
        bool approved;
        uint64 verdictAt;
    }

    mapping(uint256 => Result) public result;
    mapping(uint256 => string) public pleaText;
    mapping(uint256 => uint8) public pleaFlags;

    function setResult(uint256 id, address seller, uint8 score, bool approved, uint64 at) external {
        result[id] = Result(seller, score, approved, at);
        pleaText[id] = 'I said "please", used a \\ and kept <half> & more.';
    }

    function setFlags(uint256 id, uint8 flags) external {
        pleaFlags[id] = flags;
    }

    function die() external {
        require(diedAt == 0);
        diedAt = uint64(block.timestamp);
    }

    function cabalAlive() external view returns (bool) {
        return diedAt == 0;
    }

    function restricted() external view returns (bool) {
        return diedAt == 0;
    }
}

/// @dev Isolates Seasons' final payout from the AMM; actual hook accounting has its own campaign.
contract SeasonWallSink {
    IERC20 public immutable quote;
    uint256 public received;

    constructor(IERC20 quote_) {
        quote = quote_;
    }

    function fundWall(uint256 amount) external {
        require(quote.transferFrom(msg.sender, address(this), amount));
        received += amount;
    }
}

/// @dev Independent batch oracle: sort all recorded approvals, then select each wallet's first
/// three. This does not reproduce Seasons' incremental replacement/insertion algorithm.
library SeasonModel {
    struct Approval {
        uint256 id;
        uint256 season;
        uint256 actor;
        uint8 score;
        bool recorded;
    }

    struct Wallet {
        uint256 actor;
        uint256 points;
        uint256 newest;
        uint256 count;
    }

    function sorted(Approval[] memory all, uint256 season) internal pure returns (Approval[] memory list, uint256 n) {
        list = new Approval[](all.length);
        for (uint256 i; i < all.length; ++i) {
            if (!all[i].recorded || all[i].season != season) continue;
            list[n++] = all[i];
        }
        for (uint256 i; i < n; ++i) {
            for (uint256 j = i + 1; j < n; ++j) {
                if (list[j].score > list[i].score || (list[j].score == list[i].score && list[j].id < list[i].id)) {
                    (list[i], list[j]) = (list[j], list[i]);
                }
            }
        }
    }

    function wallets(Approval[] memory list, uint256 n) internal pure returns (Wallet[12] memory ranked) {
        for (uint256 i; i < 12; ++i) {
            ranked[i].actor = i;
        }
        for (uint256 i; i < n; ++i) {
            Wallet memory w = ranked[list[i].actor];
            if (w.count == 3) continue;
            ++w.count;
            w.points += list[i].score;
            if (list[i].id > w.newest) w.newest = list[i].id;
            ranked[list[i].actor] = w;
        }
        for (uint256 i; i < 12; ++i) {
            for (uint256 j = i + 1; j < 12; ++j) {
                if (
                    ranked[j].points > ranked[i].points
                        || (ranked[j].points == ranked[i].points && ranked[j].newest < ranked[i].newest)
                ) {
                    (ranked[i], ranked[j]) = (ranked[j], ranked[i]);
                }
            }
        }
    }
}
