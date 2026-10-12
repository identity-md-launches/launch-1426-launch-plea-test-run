// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture} from "./utils/Fixture.sol";
import {CabalGate} from "../src/CabalGate.sol";
import {Seasons} from "../src/Seasons.sol";
import {PleaHook} from "../src/PleaHook.sol";
import {MockIMD} from "./utils/Mocks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Currency} from "v4-core/types/Currency.sol";

/// @dev Standard claim redemption by a holder-approved operator; no privileged hook access.
contract ImdClaimRedeemer {
    IPoolManager immutable pm;
    Currency immutable currency;

    constructor(IPoolManager pm_, address imd_) {
        pm = pm_;
        currency = Currency.wrap(imd_);
    }

    function redeem(uint256 amount) external {
        pm.unlock(abi.encode(msg.sender, amount));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(pm));
        (address holder, uint256 amount) = abi.decode(data, (address, uint256));
        pm.burn(holder, uint256(uint160(Currency.unwrap(currency))), amount);
        pm.take(currency, holder, amount);
        return "";
    }
}

contract AuditRevisionTest is Fixture {
    function deployImd() internal virtual override {
        // Force the IMD-is-currency0 branch; the derived suite forces the other orientation.
        address low = address(0x1000);
        deployCodeTo("Mocks.sol:MockIMD", "", low);
        imd = MockIMD(low);
    }

    function setTimings() internal override {
        SEASON = 18000;
        DEADMAN = 118800;
    }

    function test_lapsedApprovalCannotBypassCooldown() public {
        buy(alice, 50e18);
        uint256 id = approvedPlea(alice, 45);
        uint256 verdictAt = gate.getPlea(id).verdictAt;
        skip(7 minutes + 1);
        uint256 amt101 = small(alice);
        vm.expectRevert(abi.encodeWithSelector(CabalGate.Cooldown.selector, verdictAt + 4 hours));
        plead(alice, amt101);
        vm.warp(verdictAt + 4 hours - 1);
        uint256 amt102 = small(alice);
        vm.expectRevert(abi.encodeWithSelector(CabalGate.Cooldown.selector, verdictAt + 4 hours));
        plead(alice, amt102);
        vm.warp(verdictAt + 4 hours);
        plead(alice, small(alice));
        assertEq(uint8(gate.getPlea(id).status), uint8(CabalGate.Status.Lapsed));
        seasons.record(id); // lapse remains an approval; it just cannot accelerate scoring
        assertEq(seasons.bestOf(0, alice)[0], 45);
    }

    function test_lateCloseDoesNotPayFutureSeasonFees() public {
        // Two legitimate approvals fit in the five-hour season when the first is early.
        vm.warp(gate.startedAt() + 1);
        buy(bob, 10e18);
        buy(alice, 20e18);
        seasons.record(approvedPlea(alice, 45));
        skip(4 hours);
        seasons.record(approvedPlea(alice, 45));
        uint256 earned = seasons.pot();
        vm.warp(gate.startedAt() + SEASON + 1 hours);
        for (uint256 i; i < 10; ++i) {
            buy(carol, 2000e18);
        }
        assertGt(seasons.pot(), earned * 2);
        uint256 before = imd.balanceOf(alice);
        seasons.closeSeason(new uint256[](0));
        assertEq(imd.balanceOf(alice) - before, earned * 2500 / 10000, "later fees paid backwards");
    }

    function test_secondLargeBuyPreservesEveryPayee() public {
        buy(bob, 50e18);
        assertEq(imd.balanceOf(address(pm)), 50e18);
        uint256 ownerBefore = paid(OWNER);
        uint256 prizeBefore = paid(address(seasons));
        uint256 cashbackBefore = simd.balanceOf(alice) + paid(alice);
        uint256 poolBefore = hook.retainClaims();
        uint256 amt = 5000e18;
        uint256 fill = amt - amt * 150 / 10150;
        buy(alice, amt);
        assertEq(paid(OWNER) - ownerBefore, fill * 50 / 10000, "owner fee lost");
        assertEq(paid(address(seasons)) - prizeBefore, fill * 25 / 10000, "season fee lost");
        assertEq(simd.balanceOf(alice) + paid(alice) + amt - cashbackBefore, fill * 50 / 10000, "cashback lost");
        assertApproxEqAbs(hook.retainClaims() - poolBefore, fill * 25 / 10000, 2);
    }

    function test_largeBuyClaimsAreRedeemableAndNextBuyStacksNormally() public {
        buy(bob, 50e18);
        buy(alice, 5000e18);
        uint256 claimId = uint256(uint160(address(imd)));
        ImdClaimRedeemer redeemer = new ImdClaimRedeemer(IPoolManager(address(pm)), address(imd));
        address[2] memory holders = [OWNER, alice];
        for (uint256 i; i < holders.length; ++i) {
            address holder = holders[i];
            uint256 claims = pm.balanceOf(holder, claimId);
            uint256 before = imd.balanceOf(holder);
            assertGt(claims, 0);
            vm.startPrank(holder);
            pm.approve(address(redeemer), claimId, claims);
            redeemer.redeem(claims);
            vm.stopPrank();
            assertEq(imd.balanceOf(holder) - before, claims);
            assertEq(pm.balanceOf(holder, claimId), 0);
        }
        uint256 stacked = simd.balanceOf(alice);
        buy(alice, 10e18);
        assertGt(simd.balanceOf(alice), stacked);
        assertEq(pm.balanceOf(alice, claimId), 0);
    }

    function test_seasonClaimsArePaidAsImdAtClose() public {
        vm.warp(gate.startedAt() + 1);
        buy(bob, 10e18);
        buy(alice, 20e18);
        seasons.record(approvedPlea(alice, 45));
        vm.warp(gate.startedAt() + 91 minutes);
        buy(carol, 5000e18);
        uint256 claimId = uint256(uint160(address(imd)));
        assertGt(pm.balanceOf(address(seasons), claimId), 0);
        vm.warp(gate.startedAt() + 4 hours + 1);
        seasons.record(approvedPlea(alice, 45));
        uint256 earned = seasons.pot();
        vm.warp(gate.startedAt() + SEASON + 1 hours);
        uint256 before = imd.balanceOf(alice);
        seasons.closeSeason(new uint256[](0));
        assertEq(imd.balanceOf(alice) - before, earned * 2500 / 10000);
        assertEq(pm.balanceOf(address(seasons), claimId), 0);
        assertEq(seasons.pot(), earned - earned * 2500 / 10000);
    }

    function test_expiredAppealCanBeRetriedWithoutLiftingDenialCooldown() public {
        buy(alice, 50e18);
        uint256 id = plead(alice, plea.balanceOf(alice) / 10);
        assertTrue(answer(id, 0));
        uint256 amt1 = small(alice);
        vm.prank(alice);
        uint256 a = gate.appeal(id, amt1, "Please reconsider.");
        intake.complete(intakeIdOf(a), 1, ""); // the failure function clears it
        assertEq(uint8(gate.getPlea(a).status), uint8(CabalGate.Status.Expired));
        assertFalse(gate.getPlea(id).appealed, "unjudged appeal consumed the only appeal");
        uint256 until = gate.getPlea(id).verdictAt + 4 hours;
        uint256 amt103 = small(alice);
        vm.expectRevert(abi.encodeWithSelector(CabalGate.Cooldown.selector, until));
        plead(alice, amt103);
        uint256 amt2 = small(alice);
        vm.prank(alice);
        uint256 retry = gate.appeal(id, amt2, "Retry the unanswered appeal.");
        assertTrue(answer(retry, 0));
        uint256 amt3 = small(alice);
        vm.prank(alice);
        vm.expectRevert(CabalGate.AlreadyAppealed.selector);
        gate.appeal(id, amt3, "No third judgment.");
    }

    function test_appealRetryClearsTimedOutPendingAppeal() public {
        buy(alice, 50e18);
        uint256 id = plead(alice, plea.balanceOf(alice) / 10);
        assertTrue(answer(id, 0));
        uint256 amt4 = small(alice);
        vm.prank(alice);
        uint256 a = gate.appeal(id, amt4, "Please reconsider.");
        skip(20 minutes + 1);
        uint256 amt5 = small(alice);
        vm.prank(alice);
        uint256 retry = gate.appeal(id, amt5, "Retry after timeout.");
        assertEq(uint8(gate.getPlea(a).status), uint8(CabalGate.Status.Expired));
        assertEq(gate.pendingOf(alice), retry);
        assertFalse(answer(a, 45));
        assertTrue(answer(retry, 45));
    }

    function test_unansweredAppealDoesNotExtendTheOriginalWindow() public {
        buy(alice, 50e18);
        uint256 id = plead(alice, plea.balanceOf(alice) / 10);
        assertTrue(answer(id, 0));
        uint256 deadline = gate.getPlea(id).verdictAt + 4 hours;
        uint256 amt6 = small(alice);
        vm.prank(alice);
        uint256 a = gate.appeal(id, amt6, "Please reconsider.");
        intake.complete(intakeIdOf(a), 1, ""); // the failure function clears it
        assertEq(uint8(gate.getPlea(a).status), uint8(CabalGate.Status.Expired));
        vm.warp(deadline + 1);
        uint256 amt7 = small(alice);
        vm.prank(alice);
        vm.expectRevert(CabalGate.AppealClosed.selector);
        gate.appeal(id, amt7, "Too late to retry.");
    }

    function test_deadCabalBuyStillRequiresARecipient() public {
        buy(bob, 50e18);
        skip(DEADMAN + 1);
        vm.prank(alice);
        vm.expectRevert(); // v4 wraps the hook's RecipientRequired error
        router.buyExactIn(10e18, "");
        buy(alice, 10e18);
        assertGt(simd.balanceOf(alice), 0);
        assertEq(simd.balanceOf(address(router)), 0);
        (, uint256 held,) = hook.basisOf(alice);
        assertEq(held, plea.balanceOf(alice));
        vm.prank(alice);
        vm.expectRevert();
        router.buyExactOut(1e18, "");
        vm.prank(alice);
        router.buyExactOut(1e18, abi.encode(alice));
        assertEq(simd.balanceOf(address(router)), 0);
    }

    function test_sameSecondCapRatchetsCannotReuseFractionalBudget() public {
        uint256 initialCap = hook.inventoryCap();
        uint256 allowance = hook.capDecayPerDay() * (vm.getBlockTimestamp() - hook.lastCapDecayAt()) / 1 days;
        buy(alice, 1e12);
        buy(alice, 100e18);
        assertLe(initialCap - hook.inventoryCap(), allowance, "cap fell faster than agreed decay");
    }

    function testFuzz_cumulativeCapDecayStaysWithinElapsedBudget(uint256 seed) public {
        uint256 initialCap = hook.inventoryCap();
        uint256 start = hook.lastCapDecayAt();
        uint256 rate = hook.capDecayPerDay();
        buy(alice, 1e12);
        for (uint256 i; i < 8; ++i) {
            uint256 random = uint256(keccak256(abi.encode(seed, i)));
            skip(random % 3);
            buy(alice, 1 + random % 100e18);
            uint256 used = initialCap - hook.inventoryCap();
            assertLe(used, rate * (vm.getBlockTimestamp() - start) / 1 days);
            assertEq(used * 1 days, rate * (hook.lastCapDecayAt() - start) + hook.capDecayRemainder());
        }
    }

    function test_dustBuyDoesNotGiveUntrackedTokensLossOrHoldingPoints() public {
        vm.prank(address(distributor));
        plea.transfer(alice, 1_000_000e18);
        uint256 amount = 1000e18;
        assertEq(gate.factScore(alice, amount), 23);
        buy(alice, 1e12);
        (, uint256 held,) = hook.basisOf(alice);
        assertLt(held, amount);
        assertEq(gate.factScore(alice, amount), 23, "dust basis scored an untracked sale");
        skip(7 days);
        assertEq(gate.factScore(alice, amount), 23, "dust basis granted holding points");
    }

    function paid(address who) internal view returns (uint256) {
        return imd.balanceOf(who) + pm.balanceOf(who, uint256(uint160(address(imd))));
    }
}

contract AuditRevisionPleaZeroTest is AuditRevisionTest {
    function deployImd() internal override {
        address high = address(type(uint160).max);
        deployCodeTo("Mocks.sol:MockIMD", "", high);
        imd = MockIMD(high);
    }
}
