// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {IPLEA, IGate} from "./interfaces/IPleaParts.sol";

/// @title Laureates — the five best pleas of each PLEA season, as tradable ERC-721s
/// @notice Minted by Seasons when a season closes, to each plea's author. The token renders the
/// plea text, its score and its season on chain (JSON + SVG, no external files). Also holds the
/// display names PLEA's site shows instead of addresses.
contract Laureates is ERC721 {
    error NotSeasons();
    error BadName();
    error NameTaken();
    error NotLetterbox();

    event NameSet(address indexed wallet, string name);

    struct Laureate {
        uint64 pleaId;
        uint32 seasonKey;
        uint8 rank;
    }

    IPLEA public immutable plea;
    uint256 public totalSupply;
    mapping(uint256 => Laureate) public laureate;

    mapping(address => string) internal _names;
    mapping(bytes32 => address) public nameOwner;

    constructor(address plea_) ERC721("PLEA Laureates", "LAUREATE") {
        plea = IPLEA(plea_);
    }

    function mint(address to, uint256 seasonKey, uint8 rank, uint256 pleaId) external returns (uint256 id) {
        if (msg.sender != plea.seasons()) revert NotSeasons();
        id = ++totalSupply;
        laureate[id] = Laureate({pleaId: uint64(pleaId), seasonKey: uint32(seasonKey), rank: rank});
        _mint(to, id);
    }

    // ================================================================ names

    /// @notice Sets the caller's display name: 3-20 characters of a-z, 0-9 and _, unique. An empty
    /// string clears it. Reserved: cabal, admin, imd, plea, owner.
    function setName(string calldata name) external {
        _setName(msg.sender, name);
    }

    /// @notice A `NAME <name>` letter: the Letterbox sets the name of the wallet that sent it.
    function setNameFor(address wallet, string calldata name) external {
        address lb = plea.letterbox();
        if (lb == address(0) || msg.sender != lb) revert NotLetterbox();
        _setName(wallet, name);
    }

    function _setName(address wallet, string calldata name) internal {
        string memory old = _names[wallet];
        if (bytes(old).length != 0) delete nameOwner[keccak256(bytes(old))];
        if (bytes(name).length == 0) {
            delete _names[wallet];
            emit NameSet(wallet, "");
            return;
        }
        _checkName(bytes(name));
        bytes32 h = keccak256(bytes(name));
        if (nameOwner[h] != address(0)) revert NameTaken();
        nameOwner[h] = wallet;
        _names[wallet] = name;
        emit NameSet(wallet, name);
    }

    function nameOf(address wallet) public view returns (string memory) {
        return _names[wallet];
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

    // ================================================================ metadata

    function tokenURI(uint256 id) public view override returns (string memory) {
        _requireOwned(id);
        Laureate memory l = laureate[id];
        IGate g = IGate(plea.gate());
        (address seller, uint8 score,,) = g.result(l.pleaId);
        string memory text = g.pleaText(l.pleaId);
        string memory who = bytes(_names[seller]).length != 0 ? _names[seller] : Strings.toHexString(seller);
        bool byLetter = g.pleaFlags(l.pleaId) & 1 != 0;
        string memory json = string.concat(
            _head(id, l, score, who, text),
            Base64.encode(bytes(_svg(l, score, who, text, _season(l.seasonKey), byLetter))),
            _attributes(l, score, byLetter)
        );
        return string.concat("data:application/json;base64,", Base64.encode(bytes(json)));
    }

    function _season(uint256 key) internal pure returns (string memory) {
        return string.concat("Season ", Strings.toString(key + 1));
    }

    function _head(uint256 id, Laureate memory l, uint8 score, string memory who, string memory text)
        internal
        pure
        returns (string memory)
    {
        string memory d = string.concat(
            _season(l.seasonKey),
            ", rank ",
            Strings.toString(l.rank),
            ": plea #",
            Strings.toString(l.pleaId),
            " by ",
            _escapeJson(who),
            ", scored ",
            Strings.toString(score),
            "/45 by the Cabal. "
        );
        return string.concat(
            '{"name":"PLEA Laureate #',
            Strings.toString(id),
            '","description":"',
            d,
            _escapeJson(text),
            '","image":"data:image/svg+xml;base64,'
        );
    }

    function _attributes(Laureate memory l, uint8 score, bool byLetter) internal pure returns (string memory) {
        return string.concat(
            '","attributes":[{"trait_type":"Season","value":',
            Strings.toString(uint256(l.seasonKey) + 1),
            '},{"trait_type":"Rank","value":',
            Strings.toString(l.rank),
            '},{"trait_type":"Score","value":',
            Strings.toString(score),
            byLetter ? '},{"trait_type":"Seal","value":"By letter"}]}' : "}]}"
        );
    }

    function _svg(
        Laureate memory l,
        uint8 score,
        string memory who,
        string memory text,
        string memory season,
        bool byLetter
    ) internal pure returns (string memory s) {
        s = string.concat(
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 600 600"><rect width="600" height="600" fill="#14110f"/>',
            '<rect x="20" y="20" width="560" height="560" fill="none" stroke="#c9a227" stroke-width="2"/>',
            '<text x="300" y="72" fill="#c9a227" font-family="Georgia,serif" font-size="30" text-anchor="middle">PLEA LAUREATE</text>',
            '<text x="300" y="106" fill="#e8e0d0" font-family="Georgia,serif" font-size="18" text-anchor="middle">',
            season,
            " - rank ",
            Strings.toString(l.rank),
            " - ",
            Strings.toString(score),
            "/45</text>"
        );
        bytes memory b = bytes(text);
        uint256 i;
        uint256 y = 160;
        while (i < b.length && y <= 500) {
            uint256 end = _lineEnd(b, i, 40);
            s = string.concat(
                s,
                '<text x="48" y="',
                Strings.toString(y),
                '" fill="#e8e0d0" font-family="Georgia,serif" font-size="20">',
                _escapeXml(_slice(b, i, end)),
                "</text>"
            );
            i = end;
            while (i < b.length && b[i] == " ") ++i;
            y += 30;
        }
        s = string.concat(
            s,
            '<text x="300" y="556" fill="#9c9488" font-family="Georgia,serif" font-size="16" text-anchor="middle">plea #',
            Strings.toString(l.pleaId),
            " by ",
            _escapeXml(bytes(who)),
            "</text>",
            byLetter ? _seal() : "",
            "</svg>"
        );
    }

    /// @dev A red wax seal in the bottom-right corner for a plea sent by letter.
    function _seal() internal pure returns (string memory) {
        return string.concat(
            '<circle cx="520" cy="500" r="40" fill="#8e1b1b" stroke="#5c0f0f" stroke-width="4"/>',
            '<circle cx="520" cy="500" r="30" fill="none" stroke="#c94a3a" stroke-width="1.5"/>',
            '<text x="520" y="497" fill="#f2d7c9" font-family="Georgia,serif" font-size="11" text-anchor="middle">BY</text>',
            '<text x="520" y="511" fill="#f2d7c9" font-family="Georgia,serif" font-size="11" text-anchor="middle">LETTER</text>'
        );
    }

    /// @dev End of a line of at most `max` bytes from `start`: the last space if there is one,
    /// otherwise a hard cut on a UTF-8 character boundary.
    function _lineEnd(bytes memory b, uint256 start, uint256 max) internal pure returns (uint256) {
        if (b.length - start <= max) return b.length;
        uint256 cut = start + max;
        for (uint256 j = cut; j > start; --j) {
            if (b[j] == " ") return j;
        }
        while (cut > start + 1 && uint8(b[cut]) & 0xc0 == 0x80) --cut;
        return cut;
    }

    function _slice(bytes memory b, uint256 from, uint256 to) internal pure returns (bytes memory out) {
        out = new bytes(to - from);
        for (uint256 i; i < out.length; ++i) {
            out[i] = b[from + i];
        }
    }

    function _escapeXml(bytes memory b) internal pure returns (string memory) {
        bytes memory out;
        for (uint256 i; i < b.length; ++i) {
            bytes1 c = b[i];
            if (c == "&") out = bytes.concat(out, "&amp;");
            else if (c == "<") out = bytes.concat(out, "&lt;");
            else if (c == ">") out = bytes.concat(out, "&gt;");
            else if (c == '"') out = bytes.concat(out, "&quot;");
            else if (c == "'") out = bytes.concat(out, "&apos;");
            else out = bytes.concat(out, c);
        }
        return string(out);
    }

    function _escapeJson(string memory s) internal pure returns (string memory) {
        bytes memory b = bytes(s);
        bytes memory out;
        for (uint256 i; i < b.length; ++i) {
            if (b[i] == '"' || b[i] == "\\") out = bytes.concat(out, "\\");
            out = bytes.concat(out, b[i]);
        }
        return string(out);
    }
}
