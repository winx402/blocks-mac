import BlocksCore
import Security
import XCTest

final class BrokerIdentityTests: XCTestCase {
    private typealias Validator = ActionBrokerIdentityValidator<Int, Int>

    func testOwnIdentityIsEagerAndReadOnlyOnceWhileEveryPeerIsCheckedAgain() throws {
        let probe = BrokerIdentitySecurityProbe()
        let validator = Validator(operations: probe.operations)
        XCTAssertEqual(probe.selfReadCount, 1, "must run before the listener's first connection")
        XCTAssertEqual(try validator.ownIdentity.get(), probe.ownIdentity)
        XCTAssertEqual(probe.validations.first?.requirement, Validator.ownRequirement)
        XCTAssertEqual(Validator.ownRequirement,
            "anchor apple generic and identifier \"\(Validator.expectedBrokerIdentifier)\"")

        // A replaced on-disk self must not become a new trust anchor or prevent
        // future connections after a successful startup identity snapshot.
        probe.failureCode = 1
        probe.failureStage = .copySelf
        probe.ownIdentity = .init(teamID: "ZZZZZZZZZZ", identifier: "changed")
        for _ in 0..<3 {
            XCTAssertEqual(try authorize(validator).get().role, .appHost)
        }
        XCTAssertEqual(probe.selfReadCount, 1)
        XCTAssertEqual(probe.peerReadCount, 3)
        XCTAssertEqual(probe.validations.filter { $0.code == 1 }.count, 1)
        XCTAssertEqual(probe.validations.filter { $0.code == 2 }.count, 3)
        XCTAssertTrue(probe.validations.filter { $0.code == 2 }.allSatisfy { $0.requirement == nil })
        XCTAssertTrue(probe.validations.allSatisfy { $0.flags.rawValue == kSecCSStrictValidate })
    }

    func testInitialOwnFailureIsCachedAndNeverFallsBackToPeerOrLaterSelfSuccess() {
        let probe = BrokerIdentitySecurityProbe()
        probe.failureCode = 1
        probe.failureStage = .validity
        let validator = Validator(operations: probe.operations)
        probe.failureStage = nil
        for _ in 0..<3 {
            assertFailure(authorize(validator), subject: .own, stage: .validity, reason: .securityError, status: probe.failureStatus)
        }
        XCTAssertEqual(probe.selfReadCount, 1)
        XCTAssertEqual(probe.peerReadCount, 0)
    }

    func testEveryOwnSecurityStagePreservesLowSensitivityFailureAndStatus() {
        for stage in [ActionBrokerIdentityFailure.Stage.copySelf, .requirement, .validity, .copyStatic, .signingInformation] {
            let probe = BrokerIdentitySecurityProbe()
            probe.failureCode = 1
            probe.failureStage = stage
            let validator = Validator(operations: probe.operations)
            assertFailure(validator.ownIdentity, subject: .own, stage: stage, reason: .securityError, status: probe.failureStatus)
        }
    }

    func testEveryPeerSecurityStagePreservesSubjectAndStatus() {
        for stage in [ActionBrokerIdentityFailure.Stage.copyGuest, .validity, .copyStatic, .signingInformation] {
            let probe = BrokerIdentitySecurityProbe()
            let validator = Validator(operations: probe.operations)
            probe.failureCode = 2
            probe.failureStage = stage
            assertFailure(authorize(validator), subject: .peer, stage: stage, reason: .securityError, status: probe.failureStatus)
        }
    }

    func testSuccessfulStatusWithMissingSecurityOutputIsNotReportedAsAPIFailure() {
        let cases: [(Int, [ActionBrokerIdentityFailure.Stage])] = [
            (1, [.copySelf, .requirement, .copyStatic, .signingInformation]),
            (2, [.copyGuest, .copyStatic, .signingInformation]),
        ]
        for (code, stages) in cases {
            for stage in stages {
                let probe = BrokerIdentitySecurityProbe()
                if code == 1 { probe.failureCode = code; probe.failureStage = stage; probe.missingOutput = true }
                let validator = Validator(operations: probe.operations)
                if code == 2 { probe.failureCode = code; probe.failureStage = stage; probe.missingOutput = true }
                assertFailure(authorize(validator), subject: code == 1 ? .own : .peer,
                    stage: stage, reason: .missingValue, status: errSecSuccess)
            }
        }
    }

    func testUIDAndPIDChecksDoNotReadOrGrantPeerIdentity() {
        let probe = BrokerIdentitySecurityProbe()
        let validator = Validator(operations: probe.operations)
        assertFailure(validator.authorizeCandidate(processID: 99, effectiveUserID: 502, currentUserID: 501),
            subject: .policy, stage: .user, reason: .userMismatch)
        for pid in [Int32(0), -1] {
            assertFailure(validator.authorizeCandidate(processID: pid, effectiveUserID: 501, currentUserID: 501),
                subject: .policy, stage: .process, reason: .invalidProcess)
        }
        XCTAssertEqual(probe.peerReadCount, 0)
    }

    func testOwnEmptyMalformedTeamOrUnexpectedBrokerIdentifierFailsClosed() {
        let teams: [(String, ActionBrokerIdentityFailure.Reason)] = [
            ("", .missingTeam), ("short", .invalidTeam), ("KF86YN2F\"J", .invalidTeam),
        ]
        for (team, reason) in teams {
            let probe = BrokerIdentitySecurityProbe()
            probe.ownIdentity = .init(teamID: team, identifier: Validator.expectedBrokerIdentifier)
            let validator = Validator(operations: probe.operations)
            assertFailure(authorize(validator), subject: .own, stage: .team, reason: reason)
            XCTAssertEqual(probe.peerReadCount, 0)
        }
        let probe = BrokerIdentitySecurityProbe()
        probe.ownIdentity = .init(teamID: probe.team, identifier: BlocksActionBrokerXPC.appBundleIdentifier)
        assertFailure(authorize(Validator(operations: probe.operations)), subject: .own, stage: .identifier, reason: .identifierNotAllowed)
    }

    func testPeerEmptyOrDifferentTeamAndUnknownIdentifierAreRejected() {
        let probe = BrokerIdentitySecurityProbe()
        let validator = Validator(operations: probe.operations)
        probe.peerIdentity = .init(teamID: "", identifier: BlocksActionBrokerXPC.appBundleIdentifier)
        assertFailure(authorize(validator), subject: .peer, stage: .team, reason: .missingTeam)
        probe.peerIdentity = .init(teamID: "ZZZZZZZZZZ", identifier: BlocksActionBrokerXPC.appBundleIdentifier)
        assertFailure(authorize(validator), subject: .policy, stage: .team, reason: .teamMismatch)
        for identifier in ["", "unrelated.app", Validator.expectedBrokerIdentifier, "app.blocks.cli\" or true"] {
            probe.peerIdentity = .init(teamID: probe.team, identifier: identifier)
            assertFailure(authorize(validator), subject: .policy, stage: .identifier, reason: .identifierNotAllowed)
        }
    }

    func testExactRoleRequirementsCannotAuthorizeClientAsAppHost() throws {
        let probe = BrokerIdentitySecurityProbe()
        let validator = Validator(operations: probe.operations)
        let host = try authorize(validator).get()
        XCTAssertEqual(host.role, .appHost)
        XCTAssertEqual(host.connectionRequirement,
            "anchor apple generic and identifier \"\(BlocksActionBrokerXPC.appBundleIdentifier)\" and certificate leaf[subject.OU] = \"\(probe.team)\"")
        XCTAssertFalse(host.connectionRequirement.contains(" or "))
        XCTAssertFalse(host.connectionRequirement.contains("app.blocks.cli"))
        var hostRequirement: SecRequirement?
        XCTAssertEqual(SecRequirementCreateWithString(host.connectionRequirement as CFString, [], &hostRequirement), errSecSuccess)
        XCTAssertNotNil(hostRequirement)

        for identifier in ["app.blocks.cli", "blocks"] {
            probe.peerIdentity = .init(teamID: probe.team, identifier: identifier)
            let client = try authorize(validator).get()
            XCTAssertEqual(client.role, .client)
            XCTAssertEqual(client.connectionRequirement,
                "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"\(probe.team)\"")
            XCTAssertFalse(client.connectionRequirement.contains(BlocksActionBrokerXPC.appBundleIdentifier))
            XCTAssertFalse(client.connectionRequirement.contains(" or "))
            var requirement: SecRequirement?
            XCTAssertEqual(SecRequirementCreateWithString(client.connectionRequirement as CFString, [], &requirement), errSecSuccess)
            XCTAssertNotNil(requirement)
        }
    }

    func testDiagnosticLimiterIsBoundedByFixedCategoriesRatherThanRawStatus() {
        var uptime: TimeInterval = 100
        let limiter = ActionBrokerIdentityDiagnosticLimiter(interval: 30, now: { uptime })
        let failure = ActionBrokerIdentityFailure(subject: .peer, stage: .validity, reason: .securityError, osStatus: -50)
        XCTAssertTrue(limiter.shouldLog(failure))
        XCTAssertFalse(limiter.shouldLog(failure))
        XCTAssertFalse(limiter.shouldLog(.init(subject: .peer, stage: .validity, reason: .securityError, osStatus: -999)))
        XCTAssertTrue(limiter.shouldLog(.init(subject: .own, stage: .validity, reason: .securityError, osStatus: -50)))
        uptime += 29
        XCTAssertFalse(limiter.shouldLog(failure))
        uptime += 1
        XCTAssertTrue(limiter.shouldLog(failure))
    }

    private func authorize(_ validator: Validator) -> Result<ActionBrokerPeerAuthorization, ActionBrokerIdentityFailure> {
        validator.authorizeCandidate(processID: 99, effectiveUserID: 501, currentUserID: 501)
    }

    private func assertFailure<Value>(
        _ result: Result<Value, ActionBrokerIdentityFailure>,
        subject: ActionBrokerIdentityFailure.Subject,
        stage: ActionBrokerIdentityFailure.Stage,
        reason: ActionBrokerIdentityFailure.Reason,
        status: OSStatus? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case let .failure(failure) = result else { return XCTFail("unexpected authorization", file: file, line: line) }
        XCTAssertEqual(failure, .init(subject: subject, stage: stage, reason: reason, osStatus: status), file: file, line: line)
    }
}

private final class BrokerIdentitySecurityProbe {
    let team = "KF86YN2FLJ"
    var ownIdentity = ActionBrokerSigningIdentity(teamID: "KF86YN2FLJ", identifier: ActionBrokerIdentityValidator<Int, Int>.expectedBrokerIdentifier)
    var peerIdentity = ActionBrokerSigningIdentity(teamID: "KF86YN2FLJ", identifier: BlocksActionBrokerXPC.appBundleIdentifier)
    var failureCode = 0
    var failureStage: ActionBrokerIdentityFailure.Stage?
    let failureStatus: OSStatus = -50
    var missingOutput = false
    var selfReadCount = 0
    var peerReadCount = 0
    var validations: [(code: Int, flags: SecCSFlags, requirement: String?)] = []

    var operations: ActionBrokerSigningOperations<Int, Int> {
        .init(copySelf: {
            self.selfReadCount += 1
            return self.copy(code: 1, stage: .copySelf)
        }, copyGuest: { _ in
            self.peerReadCount += 1
            return self.copy(code: 2, stage: .copyGuest)
        }, checkValidity: { code, flags, requirement in
            self.validations.append((code, flags, requirement))
            if self.fails(code: code, stage: .requirement) {
                return .requirementFailure(self.missingOutput ? errSecSuccess : self.failureStatus)
            }
            if self.fails(code: code, stage: .validity) { return .invalid(self.failureStatus) }
            return .valid
        }, copyStatic: { self.copy(code: $0, stage: .copyStatic) }, signingInformation: { code in
            if self.fails(code: code, stage: .signingInformation) {
                return (self.missingOutput ? errSecSuccess : self.failureStatus, nil)
            }
            return (errSecSuccess, code == 1 ? self.ownIdentity : self.peerIdentity)
        })
    }

    private func fails(code: Int, stage: ActionBrokerIdentityFailure.Stage) -> Bool {
        code == failureCode && stage == failureStage
    }

    private func copy(code: Int, stage: ActionBrokerIdentityFailure.Stage) -> (OSStatus, Int?) {
        fails(code: code, stage: stage) ? (missingOutput ? errSecSuccess : failureStatus, nil) : (errSecSuccess, code)
    }
}
