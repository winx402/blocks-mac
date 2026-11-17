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

    func testAppRequirementSnapshotRetainsStrictAppleRoleAndTeamPolicy() throws {
        let probe = BrokerIdentitySecurityProbe()
        probe.ownIdentity = .init(teamID: probe.team, identifier: BlocksActionBrokerXPC.appBundleIdentifier)
        let requirement = try Validator.hostConnectionRequirement(operations: probe.operations).get()
        XCTAssertEqual(requirement,
            "anchor apple generic and identifier \"\(Validator.expectedBrokerIdentifier)\" and certificate leaf[subject.OU] = \"\(probe.team)\"")
        XCTAssertEqual(probe.validations.first?.requirement,
            "anchor apple generic and identifier \"\(BlocksActionBrokerXPC.appBundleIdentifier)\"")
        XCTAssertEqual(probe.validations.first?.flags.rawValue, kSecCSStrictValidate)
        probe.ownIdentity = .init(teamID: probe.team, identifier: "blocks")
        assertFailure(Validator.hostConnectionRequirement(operations: probe.operations),
            subject: .own, stage: .identifier, reason: .identifierNotAllowed)
        probe.ownIdentity = .init(teamID: "", identifier: BlocksActionBrokerXPC.appBundleIdentifier)
        assertFailure(Validator.hostConnectionRequirement(operations: probe.operations),
            subject: .own, stage: .team, reason: .missingTeam)
    }

    func testIdentityWorkerSnapshotsOnceAndChecksEveryPeerOffMainThread() async {
        let probe = BrokerIdentitySecurityProbe()
        let worker = ActionBrokerIdentityWorker(operations: probe.operations)
        let completed = expectation(description: "utility identity results")
        completed.expectedFulfillmentCount = 4
        for _ in 0..<2 {
            worker.prepare { result in
                if case .failure = result { XCTFail("unexpected own rejection") }
                XCTAssertFalse(Thread.isMainThread)
                completed.fulfill()
            }
        }
        for _ in 0..<2 {
            worker.authorizeCandidate(processID: 99, effectiveUserID: 501, currentUserID: 501) { result in
                XCTAssertEqual(try? result.get().role, .appHost)
                XCTAssertFalse(Thread.isMainThread)
                completed.fulfill()
            }
        }
        await fulfillment(of: [completed], timeout: 2)
        XCTAssertEqual(probe.selfReadCount, 1)
        XCTAssertEqual(probe.peerReadCount, 2)
        XCTAssertTrue(probe.workWasOnMain.allSatisfy { !$0 })
    }

    func testIdentityWorkerCachesOwnFailureAndNeverFallsBackToPeer() async {
        let probe = BrokerIdentitySecurityProbe()
        probe.failureCode = 1
        probe.failureStage = .validity
        let worker = ActionBrokerIdentityWorker(operations: probe.operations)
        let completed = expectation(description: "cached worker failure")
        completed.expectedFulfillmentCount = 3
        worker.prepare { result in
            guard case let .failure(failure) = result else { XCTFail("unexpected startup trust"); completed.fulfill(); return }
            XCTAssertEqual(failure.stage, .validity)
            completed.fulfill()
        }
        for _ in 0..<2 {
            worker.authorizeCandidate(processID: 99, effectiveUserID: 501, currentUserID: 501) { result in
                guard case let .failure(failure) = result else { XCTFail("unexpected peer trust"); completed.fulfill(); return }
                XCTAssertEqual(failure.subject, .own)
                XCTAssertEqual(failure.stage, .validity)
                completed.fulfill()
            }
        }
        await fulfillment(of: [completed], timeout: 2)
        XCTAssertEqual(probe.selfReadCount, 1)
        XCTAssertEqual(probe.peerReadCount, 0)
        XCTAssertTrue(probe.workWasOnMain.allSatisfy { !$0 })
    }

    func testRequirementWorkerCachesBothSuccessAndFailureOffMainThread() async {
        let failure = ActionBrokerIdentityFailure(subject: .own, stage: .validity, reason: .securityError, osStatus: -50)
        for result in [Result<String, ActionBrokerIdentityFailure>.success("fixed-role-requirement"), .failure(failure)] {
            let probe = BrokerRequirementWorkerProbe(result: result)
            let worker = ActionBrokerRequirementWorker(resolve: probe.resolve)
            let completed = expectation(description: "cached requirement")
            completed.expectedFulfillmentCount = 3
            for _ in 0..<3 {
                worker.load { value in
                    XCTAssertEqual(value, result)
                    XCTAssertFalse(Thread.isMainThread)
                    completed.fulfill()
                }
            }
            await fulfillment(of: [completed], timeout: 2)
            XCTAssertEqual(probe.count, 1)
            XCTAssertFalse(probe.ranOnMain)
        }
    }

    func testReverseEndpointTimeoutAndInterruptionCannotClearNewRegistration() {
        var lifecycle = ActionBrokerEndpointLifecycle()
        let firstOwner = UUID()
        let first = lifecycle.register(ownerID: firstOwner)
        XCTAssertTrue(lifecycle.isCurrent(first))
        let replacement = lifecycle.register(ownerID: UUID())
        XCTAssertFalse(lifecycle.isCurrent(first))
        XCTAssertFalse(lifecycle.clear(first), "old interruption or timeout cannot remove the replacement")
        XCTAssertTrue(lifecycle.isCurrent(replacement))
        XCTAssertTrue(lifecycle.clear(replacement))
        XCTAssertFalse(lifecycle.clear(replacement), "loss is consumed once")
        XCTAssertNil(lifecycle.current)
        let sameOwnerReplacement = lifecycle.register(ownerID: firstOwner)
        XCTAssertNotEqual(sameOwnerReplacement, first, "PID/owner reuse does not resurrect an old endpoint")
        XCTAssertFalse(lifecycle.clear(first))
    }

    func testSecurityAdmissionCancellationKeepsCapacityUntilWorkerActuallyFinishes() throws {
        let admission = ActionBrokerSecurityWorkAdmission(capacity: 2)
        let first = try XCTUnwrap(admission.reserve())
        let second = try XCTUnwrap(admission.reserve())
        XCTAssertNil(admission.reserve())
        XCTAssertTrue(first.cancel())
        XCTAssertEqual(admission.inFlightCount, 2, "timeout is not native completion")
        XCTAssertNil(admission.reserve(), "cancelled native work must still occupy capacity")
        XCTAssertFalse(first.claimResult(), "a late native result cannot authorize")
        first.finish()
        first.finish()
        XCTAssertEqual(admission.inFlightCount, 1)
        let replacement = try XCTUnwrap(admission.reserve())
        XCTAssertTrue(second.claimResult())
        XCTAssertFalse(second.cancel(), "publication and timeout have one winner")
        XCTAssertFalse(second.claimResult())
        second.finish()
        replacement.finish()
        XCTAssertEqual(admission.inFlightCount, 0)
    }

    func testCancelledQueuedSecurityWorkIsSkippedAndNativeWorkHoldsItsPermit() async throws {
        let probe = BrokerIdentitySecurityProbe()
        let base = probe.operations
        let entered = expectation(description: "native snapshot entered")
        let release = DispatchSemaphore(value: 0)
        let operations = ActionBrokerSigningOperations<Int, Int>(copySelf: {
            entered.fulfill()
            _ = release.wait(timeout: .now() + 3)
            return base.copySelf()
        }, copyGuest: base.copyGuest, checkValidity: base.checkValidity,
            copyStatic: base.copyStatic, signingInformation: base.signingInformation)
        let worker = ActionBrokerIdentityWorker(operations: operations, authorizationCapacity: 2)
        let first = try XCTUnwrap(worker.reserveAuthorization())
        let completed = expectation(description: "cancelled work completed")
        completed.expectedFulfillmentCount = 2
        let callback: @Sendable (Result<ActionBrokerPeerAuthorization, ActionBrokerIdentityFailure>) -> Void = { result in
            guard case let .failure(failure) = result else { XCTFail("late work authorized"); completed.fulfill(); return }
            XCTAssertEqual(failure.reason, .cancelled)
            completed.fulfill()
        }
        worker.authorizeCandidate(processID: 99, effectiveUserID: 501, currentUserID: 501,
            reservation: first, completion: callback)
        await fulfillment(of: [entered], timeout: 1)
        let queued = try XCTUnwrap(worker.reserveAuthorization())
        worker.authorizeCandidate(processID: 99, effectiveUserID: 501, currentUserID: 501,
            reservation: queued, completion: callback)
        first.cancel()
        queued.cancel()
        XCTAssertEqual(worker.pendingAuthorizationCount, 2)
        XCTAssertNil(worker.reserveAuthorization())
        let rejected = expectation(description: "over-cap work fails closed")
        worker.authorizeCandidate(processID: 99, effectiveUserID: 501, currentUserID: 501) { result in
            guard case let .failure(failure) = result else { XCTFail("over-cap work authorized"); rejected.fulfill(); return }
            XCTAssertEqual(failure.reason, .capacityExceeded)
            rejected.fulfill()
        }
        let drained = expectation(description: "worker passed cancelled queue entries")
        worker.prepare { _ in drained.fulfill() }
        release.signal()
        await fulfillment(of: [completed, rejected, drained], timeout: 2)
        XCTAssertEqual(probe.selfReadCount, 1)
        XCTAssertEqual(probe.peerReadCount, 0, "cancelled queued work must not execute any guest Security call")
        XCTAssertEqual(worker.pendingAuthorizationCount, 0)
        XCTAssertFalse(first.claimResult())
        XCTAssertFalse(queued.claimResult())
    }

    func testRetiringReverseRoutePreservesEveryAdmittedReplyUntilLastOnceRelease() throws {
        var old = ActionBrokerRouteLeaseLifecycle()
        let request = try XCTUnwrap(old.acquire())
        let listing = try XCTUnwrap(old.acquire())
        old.retire()
        XCTAssertNil(old.acquire())
        XCTAssertFalse(old.mayInvalidate, "health timeout must not disconnect pending business replies")
        XCTAssertTrue(old.release(request))
        XCTAssertFalse(old.release(request), "duplicate terminal callbacks cannot release a second lease")
        XCTAssertEqual(old.activeCount, 1)
        XCTAssertFalse(old.mayInvalidate)
        var replacement = ActionBrokerRouteLeaseLifecycle()
        let replacementRequest = try XCTUnwrap(replacement.acquire())
        XCTAssertTrue(old.release(listing))
        XCTAssertTrue(old.mayInvalidate)
        XCTAssertFalse(replacement.isRetired, "old timeout/reply cleanup must not retire the replacement")
        XCTAssertEqual(replacement.activeCount, 1)
        replacement.release(replacementRequest)
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
    var workWasOnMain: [Bool] = []

    var operations: ActionBrokerSigningOperations<Int, Int> {
        .init(copySelf: {
            self.selfReadCount += 1
            return self.copy(code: 1, stage: .copySelf)
        }, copyGuest: { _ in
            self.peerReadCount += 1
            return self.copy(code: 2, stage: .copyGuest)
        }, checkValidity: { code, flags, requirement in
            self.workWasOnMain.append(Thread.isMainThread)
            self.validations.append((code, flags, requirement))
            if self.fails(code: code, stage: .requirement) {
                return .requirementFailure(self.missingOutput ? errSecSuccess : self.failureStatus)
            }
            if self.fails(code: code, stage: .validity) { return .invalid(self.failureStatus) }
            return .valid
        }, copyStatic: { self.copy(code: $0, stage: .copyStatic) }, signingInformation: { code in
            self.workWasOnMain.append(Thread.isMainThread)
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
        workWasOnMain.append(Thread.isMainThread)
        return fails(code: code, stage: stage) ? (missingOutput ? errSecSuccess : failureStatus, nil) : (errSecSuccess, code)
    }
}

private final class BrokerRequirementWorkerProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let result: Result<String, ActionBrokerIdentityFailure>
    private var calls = 0
    private var mainThread = false
    init(result: Result<String, ActionBrokerIdentityFailure>) { self.result = result }
    var count: Int { lock.withLock { calls } }
    var ranOnMain: Bool { lock.withLock { mainThread } }
    func resolve() -> Result<String, ActionBrokerIdentityFailure> {
        lock.withLock { calls += 1; mainThread = Thread.isMainThread; return result }
    }
}
