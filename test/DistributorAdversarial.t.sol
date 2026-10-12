// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {PLEA} from "src/PLEA.sol";
import {CabalGate} from "src/CabalGate.sol";
import {Seasons} from "src/Seasons.sol";
import {PleaDistributor} from "src/PleaDistributor.sol";
import {MockIMD, MockIntake} from "./utils/Mocks.sol";
import {ClaimTree} from "./utils/ClaimTree.sol";

/// @dev Isolated token/distributor tests: no AMM calls, but a real gate drives the transfer clock.
abstract contract DistributionFixture is Test {
    PLEA internal token;
    CabalGate internal cabal;
    PleaDistributor internal drop;
    Seasons internal seasons;
    address[4] internal actors;
    address internal treasury;
    address internal manager;
    bytes32 internal root;

    function setUp() public virtual {
        vm.chainId(11155111);
        vm.warp(1791817200);
        for (uint256 i; i < 4; ++i) {
            actors[i] = makeAddr(string.concat("claimant ", vm.toString(i)));
        }
        treasury = makeAddr("isolated hook treasury");
        manager = makeAddr("isolated pool manager");
        token = new PLEA(address(this));
        MockIMD quote = new MockIMD();
        MockIntake intake = new MockIntake(quote);
        cabal = new CabalGate(
            address(token), address(intake), address(quote), address(quote), makeAddr("signer"), 18000, 118800
        );
        seasons = new Seasons(address(token), address(cabal), address(quote));
        drop = new PleaDistributor(address(token), address(this));
        token.setLauncher(address(cabal), address(seasons), address(drop));
        token.init(treasury, manager);
        cabal.begin();
        root = ClaimTree.tree(actors)[0];
    }

    function claim(uint256 position) internal {
        drop.claim(
            ClaimTree.index(position),
            actors[position % 4],
            ClaimTree.amount(position),
            ClaimTree.proof(actors, position)
        );
    }
}

/// forge-config: default.fuzz.runs = 256
contract DistributorAdversarialTest is DistributionFixture {
    function test_unsetRootAndUnauthorizedRootDoNotConsumeClaims() public {
        vm.expectRevert(PleaDistributor.RootNotSet.selector);
        claim(0);
        vm.prank(actors[0]);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, actors[0]));
        drop.setMerkleRoot(root);
        assertEq(drop.merkleRoot(), bytes32(0));
        assertFalse(drop.isClaimed(0));
        drop.setMerkleRoot(root);
        claim(0);
        assertEq(token.balanceOf(actors[0]), ClaimTree.amount(0));
    }

    function test_rootCannotChangeAfterCommitmentEvenBeforeFirstClaim() public {
        drop.setMerkleRoot(root);
        vm.expectRevert(PleaDistributor.RootAlreadySet.selector);
        drop.setMerkleRoot(keccak256("another allocation"));
        vm.expectRevert(PleaDistributor.RootAlreadySet.selector);
        drop.setMerkleRoot(bytes32(0));
        assertEq(drop.merkleRoot(), root);
    }

    function test_claimsCrossBitmapWordsAndCannotBeClaimedTwice() public {
        drop.setMerkleRoot(root);
        uint256 paid;
        for (uint256 i; i < 8; ++i) {
            vm.prank(actors[(i + 1) % 4]); // anyone may relay; the leaf fixes the recipient
            claim(i);
            paid += ClaimTree.amount(i);
            for (uint256 j; j < 8; ++j) {
                assertEq(drop.isClaimed(ClaimTree.index(j)), j <= i);
            }
            vm.expectRevert(PleaDistributor.AlreadyClaimed.selector);
            claim(i);
        }
        assertEq(token.balanceOf(address(drop)), 100_000_000e18 - paid);
        assertEq(token.balanceOf(treasury), 870_000_000e18);
        assertEq(token.balanceOf(address(seasons)), 30_000_000e18);
        assertEq(token.totalSupply(), 1_000_000_000e18);
    }

    function testFuzz_modifiedLeafOrProofCannotRedirectFunds(uint8 rawPosition, uint8 rawField, uint256 salt) public {
        uint256 position = bound(rawPosition, 0, 7);
        uint256 field = bound(rawField, 0, 3);
        drop.setMerkleRoot(root);
        uint256 index = ClaimTree.index(position);
        address recipient = actors[position % 4];
        uint256 amount = ClaimTree.amount(position);
        bytes32[] memory path = ClaimTree.proof(actors, position);
        if (field == 0) recipient = actors[(position + 1) % 4];
        if (field == 1) amount += bound(salt, 1, type(uint128).max);
        if (field == 2) index ^= 1;
        if (field == 3) path[salt % 3] ^= bytes32(uint256(1));
        vm.expectRevert(PleaDistributor.InvalidProof.selector);
        drop.claim(index, recipient, amount, path);
        assertEq(token.balanceOf(address(drop)), 100_000_000e18);
        assertFalse(drop.isClaimed(index));
        claim(position); // failed validation left the correct claim usable
        assertEq(token.balanceOf(actors[position % 4]), ClaimTree.amount(position));
    }

    function test_failedTokenTransferRollsBackBitmapAndCanBeRetried() public {
        // A valid commitment can exceed current funding; a failed payout must remain claimable.
        uint256 amount = 100_000_000e18 + 1;
        drop.setMerkleRoot(keccak256(abi.encodePacked(uint256(255), actors[0], amount)));
        bytes32[] memory empty = new bytes32[](0);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, address(drop), 100_000_000e18, amount
            )
        );
        drop.claim(255, actors[0], amount, empty);
        assertFalse(drop.isClaimed(255));
        assertEq(token.balanceOf(actors[0]), 0);
        vm.prank(treasury);
        token.transfer(address(drop), 1);
        drop.claim(255, actors[0], amount, empty);
        assertTrue(drop.isClaimed(255));
        assertEq(token.balanceOf(actors[0]), amount);
        assertEq(token.balanceOf(address(drop)), 0);
    }

    function test_fullAllocationAndZeroAmountLeavesDoNotCorruptAdjacentBits() public {
        bytes32 full = keccak256(abi.encodePacked(uint256(256), actors[0], uint256(100_000_000e18)));
        bytes32 zero = keccak256(abi.encodePacked(uint256(255), actors[1], uint256(0)));
        drop.setMerkleRoot(ClaimTree.pair(full, zero));
        bytes32[] memory path = new bytes32[](1);
        path[0] = zero;
        drop.claim(256, actors[0], 100_000_000e18, path);
        assertFalse(drop.isClaimed(255));
        path[0] = full;
        drop.claim(255, actors[1], 0, path);
        assertTrue(drop.isClaimed(255));
        assertTrue(drop.isClaimed(256));
        assertEq(token.balanceOf(address(drop)), 0);
        assertEq(token.balanceOf(actors[0]), 100_000_000e18);
    }
}

contract DistributionHandler is Test {
    PLEA public immutable token;
    CabalGate public immutable cabal;
    PleaDistributor public immutable drop;
    address public immutable owner;
    address public immutable treasury;
    address[4] public actors;
    bool[8] public claimed;
    uint256 public paid;
    uint256 public donated;
    uint256 public burned;
    bool public dead;

    constructor(PLEA token_, CabalGate cabal_, PleaDistributor drop_, address treasury_, address[4] memory actors_) {
        token = token_;
        cabal = cabal_;
        drop = drop_;
        treasury = treasury_;
        actors = actors_;
        owner = token_.owner();
    }

    function claimAllocation(uint256 seed) external {
        uint256 p = seed % 8;
        uint256 before = token.balanceOf(actors[p % 4]);
        // Evaluate proof before the prank: the relayer is deliberately not the leaf's beneficiary.
        bytes32[] memory path = ClaimTree.proof(actors, p);
        if (claimed[p]) vm.expectRevert(PleaDistributor.AlreadyClaimed.selector);
        vm.prank(actors[(p + 1) % 4]);
        drop.claim(ClaimTree.index(p), actors[p % 4], ClaimTree.amount(p), path);
        if (!claimed[p]) {
            assertEq(token.balanceOf(actors[p % 4]) - before, ClaimTree.amount(p));
            claimed[p] = true;
            paid += ClaimTree.amount(p);
        }
    }

    function transferTokens(uint256 fromSeed, uint256 toSeed, uint256 raw) external {
        address from = account(fromSeed);
        address to = account(toSeed);
        uint256 fromBefore = token.balanceOf(from);
        uint256 toBefore = token.balanceOf(to);
        uint256 amount = bound(raw, 0, fromBefore);
        bool refused = cabal.cabalAlive() && from != treasury && !token.allowed(from);
        if (refused) vm.expectRevert(PLEA.CabalIsWatching.selector);
        vm.prank(from);
        token.transfer(to, amount);
        assertEq(token.balanceOf(from), refused || from == to ? fromBefore : fromBefore - amount);
        assertEq(token.balanceOf(to), refused || from == to ? toBefore : toBefore + amount);
    }

    function approveAndSpend(uint256 fromSeed, uint256 spenderSeed, uint256 raw, bool infinite) external {
        address from = account(fromSeed);
        address spender = account(spenderSeed);
        uint256 fromBefore = token.balanceOf(from);
        uint256 spenderBefore = token.balanceOf(spender);
        uint256 amount = bound(raw, 0, fromBefore);
        uint256 allowance = infinite ? type(uint256).max : amount;
        vm.prank(from);
        token.approve(spender, allowance);
        bool refused = cabal.cabalAlive() && from != treasury && !token.allowed(from);
        if (refused) vm.expectRevert(PLEA.CabalIsWatching.selector);
        vm.prank(spender);
        token.transferFrom(from, spender, amount);
        assertEq(token.allowance(from, spender), refused || infinite ? allowance : 0);
        assertEq(token.balanceOf(from), refused || from == spender ? fromBefore : fromBefore - amount);
        assertEq(token.balanceOf(spender), refused || from == spender ? spenderBefore : spenderBefore + amount);
    }

    function burnTokens(uint256 seed, uint256 raw) external {
        address from = account(seed);
        uint256 before = token.balanceOf(from);
        uint256 amount = bound(raw, 0, before);
        bool refused = cabal.cabalAlive() && from != treasury && !token.allowed(from);
        if (refused) vm.expectRevert(PLEA.CabalIsWatching.selector);
        vm.prank(from);
        token.burn(amount);
        if (!refused) burned += amount;
        assertEq(token.balanceOf(from), refused ? before : before - amount);
    }

    function donate(uint256 raw) external {
        uint256 amount = bound(raw, 0, token.balanceOf(treasury));
        vm.prank(treasury);
        token.transfer(address(drop), amount);
        donated += amount;
    }

    function allowSender(uint256 seed) external {
        address who = actors[seed % 4];
        vm.prank(owner);
        token.allow(who);
        assertTrue(token.allowed(who));
    }

    function unauthorizedAdministration(uint256 seed) external {
        address who = actors[seed % 4];
        vm.startPrank(who);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, who));
        token.allow(who);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, who));
        drop.setMerkleRoot(keccak256("attacker root"));
        vm.expectRevert(PLEA.NotLauncher.selector);
        token.init(who, who);
        vm.stopPrank();
    }

    function advance(uint256 raw) external {
        vm.warp(vm.getBlockTimestamp() + bound(raw, 1, 6 hours));
        if (dead) assertFalse(cabal.cabalAlive(), "death must be irreversible");
        dead = !cabal.cabalAlive();
    }

    function account(uint256 seed) public view returns (address) {
        return seed % 5 == 4 ? treasury : actors[seed % 5];
    }
}

/// forge-config: default.invariant.runs = 128
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract DistributionInvariantTest is DistributionFixture {
    DistributionHandler internal handler;

    function setUp() public override {
        super.setUp();
        drop.setMerkleRoot(root);
        handler = new DistributionHandler(token, cabal, drop, treasury, actors);
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = handler.claimAllocation.selector;
        selectors[1] = handler.transferTokens.selector;
        selectors[2] = handler.approveAndSpend.selector;
        selectors[3] = handler.burnTokens.selector;
        selectors[4] = handler.donate.selector;
        selectors[5] = handler.allowSender.selector;
        selectors[6] = handler.unauthorizedAdministration.selector;
        selectors[7] = handler.advance.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_supplyEqualsAllBalancesAndOnlyBurnsReduceIt() public view {
        uint256 sum = token.balanceOf(treasury) + token.balanceOf(address(drop)) + token.balanceOf(address(seasons));
        for (uint256 i; i < 4; ++i) {
            sum += token.balanceOf(actors[i]);
        }
        assertEq(sum, token.totalSupply());
        assertEq(token.totalSupply() + handler.burned(), 1_000_000_000e18);
    }

    function invariant_distributorPaysEachCommittedLeafAtMostOnce() public view {
        assertEq(drop.merkleRoot(), root);
        assertEq(token.balanceOf(address(drop)) + handler.paid(), 100_000_000e18 + handler.donated());
        uint256 expectedPaid;
        for (uint256 i; i < 8; ++i) {
            assertEq(drop.isClaimed(ClaimTree.index(i)), handler.claimed(i));
            if (handler.claimed(i)) expectedPaid += ClaimTree.amount(i);
        }
        assertEq(handler.paid(), expectedPaid);
    }

    function invariant_deathAndSystemWiringArePermanent() public view {
        assertEq(token.launcher(), address(this));
        assertEq(token.hook(), treasury);
        assertEq(token.poolManager(), manager);
        assertEq(token.distributor(), address(drop));
        assertEq(token.owner(), address(this));
        assertEq(drop.owner(), address(this));
        assertEq(token.restricted(), cabal.cabalAlive());
        if (handler.dead()) assertFalse(token.restricted());
    }
}
