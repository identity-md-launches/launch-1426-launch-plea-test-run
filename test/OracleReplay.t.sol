// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture} from "./utils/Fixture.sol";
import {CabalGate} from "../src/CabalGate.sol";
import {OracleAttestation} from "../src/OracleAttestation.sol";

contract OracleReplayTest is Fixture {
    function setUp() public override {
        super.setUp();
        buy(alice, 50e18);
        buy(bob, 50e18);
    }

    /// @dev Reproduces the imported audit: the Intake can present one signed answer under two ids.
    /// Request binding still belongs to the Intake; either delivery order must consume the answer once.
    function testFuzz_oneSignedRequestCannotSettleTwoPleas(bool bobFirst, bool approved) public {
        uint256 first = plead(alice, plea.balanceOf(alice) / 10);
        uint256 second = plead(bob, plea.balanceOf(bob) / 10);
        if (bobFirst) (first, second) = (second, first);
        OracleAttestation.Attestation memory a = attestation(approved ? 45 : 0, keccak256("oracle request"));
        assertTrue(deliver(intakeIdOf(first), a));
        uint256 verdictAt = gate.lastVerdictAt();
        skip(1);
        assertFalse(deliver(intakeIdOf(second), a), "one signed request settled two pleas");
        assertTrue(gate.consumed(a.requestId));
        assertEq(uint8(gate.getPlea(second).status), uint8(CabalGate.Status.Pending));
        assertEq(gate.getPlea(second).verdictAt, 0);
        assertEq(gate.lastVerdictAt(), verdictAt, "replay extended the Cabal's life");
        assertEq(gate.pleaOfIntake(intakeIdOf(second)), second);
        gate.expire(second); // failed completion retains the existing no-verdict recovery path
        assertEq(uint8(gate.getPlea(second).status), uint8(CabalGate.Status.Expired));
    }

    function test_invalidCallbackDoesNotConsumeTheRequest() public {
        uint256 first = plead(alice, plea.balanceOf(alice) / 10);
        uint256 second = plead(bob, plea.balanceOf(bob) / 10);
        OracleAttestation.Attestation memory a = attestation(45, keccak256("rejected request"));
        a.agreed = 16;
        assertFalse(deliver(intakeIdOf(first), a));
        assertFalse(gate.consumed(a.requestId), "reverted validation consumed the request");
        a.agreed = 20;
        assertTrue(deliver(intakeIdOf(second), a));
        assertTrue(gate.consumed(a.requestId));
    }

    function test_deniedRequestCannotBeResignedToApproveItsAppeal() public {
        uint256 id = plead(alice, plea.balanceOf(alice) / 10);
        OracleAttestation.Attestation memory a = attestation(0, keccak256("denied request"));
        assertTrue(deliver(intakeIdOf(id), a));
        uint256 amt1 = small(alice);
        vm.prank(alice);
        uint256 appealId = gate.appeal(id, amt1, "Please reconsider this smaller sale.");
        a.answer = abi.encode(uint256(45));
        a.figure = 45;
        a.questionHash = keccak256("another question");
        assertFalse(deliver(intakeIdOf(appealId), a), "request id reused with a new signature");
        assertEq(uint8(gate.getPlea(appealId).status), uint8(CabalGate.Status.Pending));
    }
}
