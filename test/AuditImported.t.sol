// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture} from "./utils/Fixture.sol";
import {CabalGate} from "../src/CabalGate.sol";
import {MockIMD} from "./utils/Mocks.sol";

/// Regressions for the audit supplied with this assignment, including lazy expiry and balance growth.
contract AuditImportedTest is Fixture {
    function setUp() public virtual override {
        super.setUp();
        buy(alice, 50e18);
        buy(bob, 50e18);
        skip(1 days);
    }

    function _letter(string memory text) internal returns (uint256) {
        vm.prank(alice);
        letterbox.letter(text);
        return gate.lastPleaOf(alice);
    }

    function _deniedLetter() internal returns (uint256 id) {
        id = _letter("A fifth for rent; the rest stays with me all season.");
        assertTrue(answer(id, 0));
    }

    function _assertRetry(uint256 original, uint256 stale) internal {
        uint256 refund = imd.balanceOf(alice);
        uint256 retry = _letter("APPEAL Once more: rent is due on Friday; the rest stays.");
        CabalGate.Plea memory p = gate.getPlea(retry);
        assertTrue(p.isAppeal);
        assertEq(p.originalId, original);
        assertEq(uint8(p.status), uint8(CabalGate.Status.Pending));
        assertEq(uint8(gate.getPlea(stale).status), uint8(CabalGate.Status.Expired));
        (, bool open,,) = letterbox.escrowOf(stale);
        assertFalse(open, "the stale escrow was returned before retrying");
        assertEq(imd.balanceOf(alice) - refund, 0.25e18, "the old runner tip was returned");
        assertEq(plea.balanceOf(address(letterbox)), p.amount);
        assertEq(imd.balanceOf(address(letterbox)), 0.25e18);
    }

    function test_appealLetterRetriesLazyTimeoutWithoutSeparateSettlement() public {
        uint256 original = _deniedLetter();
        uint256 stale = _letter("APPEAL Plainly: rent is due on Friday; I keep the rest.");
        skip(gate.PENDING_EXPIRY() + 1);
        assertEq(uint8(gate.getPlea(stale).status), uint8(CabalGate.Status.Pending));
        _assertRetry(original, stale);
    }

    function test_appealLetterRetriesCompletedRequestWithFailedCallback() public {
        uint256 original = _deniedLetter();
        uint256 stale = _letter("APPEAL Plainly: rent is due on Friday; I keep the rest.");
        // Intake completes, but the malformed callback cannot deliver a verdict.
        assertFalse(intake.complete(intakeIdOf(stale), 0, hex"00"));
        assertEq(uint8(gate.getPlea(stale).status), uint8(CabalGate.Status.Pending));
        _assertRetry(original, stale);
    }

    function test_siteAppealSurvivesBalanceGrowthAtOriginalMinimum() public {
        uint256 amount = plea.balanceOf(alice) * gate.MIN_SHARE_BPS() / 10_000;
        uint256 original = plead(alice, amount);
        assertTrue(answer(original, 0));
        buy(alice, 1e18);
        assertGt(plea.balanceOf(alice) / 100, amount);
        vm.prank(alice);
        uint256 retry = gate.appeal(original, amount, "The rent is still due; my new purchase stays.");
        assertEq(gate.getPlea(retry).amount, amount);
        assertEq(gate.getPlea(retry).originalId, original);
    }

    function test_growingBalanceDoesNotEnableDustOrLargerAppeals() public {
        uint256 minimum = plea.balanceOf(alice) * gate.MIN_SHARE_BPS() / 10_000;
        uint256 original = plead(alice, minimum * 2);
        assertTrue(answer(original, 0));
        buy(alice, 1e18);
        vm.startPrank(alice);
        vm.expectRevert(CabalGate.AmountTooSmall.selector);
        gate.appeal(original, 0, "Zero tokens cannot earn points.");
        vm.expectRevert(CabalGate.AmountTooSmall.selector);
        gate.appeal(original, minimum - 1, "Below the original minimum.");
        vm.expectRevert(CabalGate.AmountTooLarge.selector);
        gate.appeal(original, minimum * 2 + 1, "Above the original amount.");
        uint256 retry = gate.appeal(original, minimum, "The original minimum is still valid.");
        vm.stopPrank();
        assertEq(gate.getPlea(retry).amount, minimum);
    }

    function test_shrinkingBalanceStillUsesCurrentMinimumAndMaximum() public {
        uint256 original = plead(alice, small(alice));
        assertTrue(answer(original, 0));
        vm.prank(OWNER);
        plea.allow(alice);
        uint256 balance = plea.balanceOf(alice);
        vm.prank(alice);
        plea.transfer(bob, balance * 99 / 100);
        balance = plea.balanceOf(alice);
        uint256 minimum = balance * gate.MIN_SHARE_BPS() / 10_000;
        vm.startPrank(alice);
        vm.expectRevert(CabalGate.AmountTooLarge.selector);
        gate.appeal(original, balance / 2 + 1, "Above half of the current balance.");
        vm.expectRevert(CabalGate.AmountTooSmall.selector);
        gate.appeal(original, minimum - 1, "Below one percent of the current balance.");
        uint256 retry = gate.appeal(original, minimum, "One percent of the smaller balance.");
        vm.stopPrank();
        assertEq(gate.getPlea(retry).amount, minimum);
    }

    function test_rawAppealLetterSurvivesBalanceGrowth() public {
        uint256 original = _deniedLetter();
        uint256 amount = gate.getPlea(original).amount;
        buy(alice, 5_000e18);
        assertGt((plea.balanceOf(alice) + amount) / 100, amount);
        vm.prank(alice);
        (bool ok, bytes memory ret) = address(letterbox).call("APPEAL My new purchase stays; I still need rent.");
        if (!ok) {
            assembly { revert(add(ret, 32), mload(ret)) }
        }
        uint256 retry = gate.lastPleaOf(alice);
        assertEq(gate.getPlea(retry).amount, amount);
        assertEq(gate.getPlea(retry).originalId, original);
        assertEq(plea.balanceOf(address(letterbox)), amount);
    }

    function test_autoAppealSurvivesBalanceGrowth() public {
        uint256 original = _deniedLetter();
        uint256 amount = gate.getPlea(original).amount;
        buy(alice, 5_000e18);
        assertGt((plea.balanceOf(alice) + amount) / 100, amount);
        vm.prank(alice);
        uint256 retry = letterbox.appealAuto(original, "My new purchase stays; I still need rent.");
        assertEq(gate.getPlea(retry).amount, amount);
        assertEq(gate.getPlea(retry).originalId, original);
    }
}

/// The same custody regressions with the oracle fee bought from the real pool currency.
contract AuditImportedPaidFeeTest is AuditImportedTest {
    function oracleFeeToken() internal view override returns (MockIMD) {
        return imd;
    }
}
