import BlocksCore
import Darwin
import Foundation
import XCTest

final class FeedbackTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        // Foundation deliberately prettifies /private/var back to /var on macOS.
        // The secure store rejects every symlink component, so use POSIX realpath.
        let resolved = try XCTUnwrap(realpath(FileManager.default.temporaryDirectory.path, nil))
        defer { free(resolved) }
        directory = URL(fileURLWithPath: String(cString: resolved)).appendingPathComponent("feedback-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }
    private func store() -> FeedbackStore { FeedbackStore(directory: directory.appendingPathComponent("store"), appVersion: "1.2.3") }
    private func event(id: UUID = UUID(), phase: String = "failed", participant: String = "database", code: String = "timeout") -> FeedbackShutdownEvent {
        FeedbackShutdownEvent(attemptID: id, phase: phase, participant: participant, code: code,
                              elapsedMS: 20, forced: phase.hasPrefix("forced"), activeOperations: 1)
    }

    func testDefaultOffAndNormalExitStaysLocal() throws {
        let store = store()
        let client = FakeFeedbackGitHub()
        try store.recordShutdownEvent(event(phase: "graceful", code: "none"))
        XCTAssertFalse(try store.consent().enabled)
        FeedbackService(store: store, client: client).processAutomaticQueue()
        XCTAssertEqual(client.creates, 0)
        XCTAssertEqual(try store.list().first?.status, "local")
        XCTAssertEqual(client.doctors, 0, "default-off startup must not contact gh")
    }

    func testAllowlistEliminatesFreeText() throws {
        let store = store()
        try store.recordShutdownEvent(event(phase: "/Users/person/private", participant: "secret pasted text", code: "raw error token"))
        let report = try store.report(id: nil)
        XCTAssertEqual(report.events.first?.phase, "unknown")
        XCTAssertFalse(report.publicBody.contains("/Users"))
        XCTAssertFalse(report.publicBody.contains("secret"))
        XCTAssertFalse(report.publicBody.contains("raw error"))
    }

    func testUnknownActiveOperationsIsNotRepresentedAsZero() {
        let event = FeedbackShutdownEvent(attemptID: UUID(), phase: "forced_timeout", participant: "app",
            code: "timeout", elapsedMS: 12_000, forced: true, activeOperations: -1)
        XCTAssertEqual(event.activeOperations, -1)
    }

    func testManualCredentialGuard() {
        XCTAssertThrowsError(try FeedbackCredentialGuard.validate(title: "bug", body: "api_key=fixture-credential-value"))
        XCTAssertThrowsError(try FeedbackCredentialGuard.validate(title: "bug", body: "-----BEGIN PRIVATE KEY-----"))
        XCTAssertNoThrow(try FeedbackCredentialGuard.validate(title: "UI bug", body: "The password settings label is truncated."))
    }

    func testRetentionCapsAtTwentyAndPrunesSevenDays() throws {
        let clock = FeedbackTestClock()
        let store = FeedbackStore(directory: directory.appendingPathComponent("store"), appVersion: "1", now: { clock.date })
        for _ in 0..<25 { try store.recordShutdownEvent(event()) }
        XCTAssertEqual(try store.list().count, 20)
        clock.date = clock.date.addingTimeInterval(FeedbackPolicy.retention + 1)
        XCTAssertTrue(try store.list().isEmpty)
    }

    func testDuplicateAutomaticFingerprintSuppressed() throws {
        let store = store()
        let client = FakeFeedbackGitHub()
        try store.setConsent(enabled: true, account: "fixture-user")
        try store.recordShutdownEvent(event())
        try store.recordShutdownEvent(event())
        FeedbackService(store: store, client: client).processAutomaticQueue()
        XCTAssertEqual(client.creates, 1)
        XCTAssertEqual(try store.list().filter { $0.status == "deduplicated" }.count, 1)
    }

    func testAutomaticDailyLimit() throws {
        let store = store()
        let client = FakeFeedbackGitHub()
        try store.setConsent(enabled: true, account: "fixture-user")
        for participant in ["database", "clipboard", "plugins", "translation"] { try store.recordShutdownEvent(event(participant: participant)) }
        FeedbackService(store: store, client: client).processAutomaticQueue()
        XCTAssertEqual(client.creates, 3)
    }

    func testChangedAccountPausesAutomatic() throws {
        let store = store()
        let client = FakeFeedbackGitHub()
        try store.setConsent(enabled: true, account: "previous-user")
        try store.recordShutdownEvent(event())
        FeedbackService(store: store, client: client).processAutomaticQueue()
        XCTAssertEqual(client.creates, 0)
        XCTAssertEqual(try store.consent().pausedCode, "account_changed")
    }

    func testUncertainSubmissionReconcilesWithoutNewPost() throws {
        let store = store()
        let client = FakeFeedbackGitHub()
        client.failCreate = true
        try store.recordShutdownEvent(event())
        let service = FeedbackService(store: store, client: client)
        XCTAssertThrowsError(try service.submit(id: nil))
        XCTAssertThrowsError(try service.submit(id: nil))
        XCTAssertEqual(client.creates, 1)
        XCTAssertEqual(client.finds, 1)
        client.foundURL = "https://github.com/winx402/blocks-mac/issues/42"
        XCTAssertEqual(try service.submit(id: nil), client.foundURL)
        XCTAssertEqual(client.creates, 1)
    }

    func testManualDoesNotRequireAutomaticConsentAndDoesNotPersistBody() throws {
        let store = store()
        let client = FakeFeedbackGitHub()
        let service = FeedbackService(store: store, client: client)
        _ = try service.create(title: "fixture manual title", body: "fixture manual private draft")
        XCTAssertEqual(client.creates, 1)
        XCTAssertFalse(try store.consent().enabled)
        let data = try String(contentsOf: directory.appendingPathComponent("store/state.json"), encoding: .utf8)
        XCTAssertFalse(data.contains("fixture manual title"))
        XCTAssertFalse(data.contains("private draft"))
    }

    func testRejectsSymlinkAndPublicDirectory() throws {
        let target = directory.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let link = directory.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertThrowsError(try FeedbackStore(directory: link).list())
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
        XCTAssertThrowsError(try FeedbackStore(directory: target).list())
    }

    func testIssueURLIsFixedRepositoryAndHTTPS() {
        XCTAssertTrue(FeedbackGitHubClient.validIssueURL("https://github.com/winx402/blocks-mac/issues/1"))
        XCTAssertFalse(FeedbackGitHubClient.validIssueURL("https://github.com/other/repo/issues/1"))
        XCTAssertFalse(FeedbackGitHubClient.validIssueURL("javascript:alert(1)"))
    }

    func testStartupRecoveryOnlyInfersMissingTerminalAndSkipsCurrentRun() throws {
        let clock = FeedbackTestClock()
        let store = FeedbackStore(directory: directory.appendingPathComponent("store"), now: { clock.date })
        let previous = UUID()
        try store.recordShutdownEvent(event(id: previous, phase: "requested", code: "none"))
        let graceful = UUID()
        try store.recordShutdownEvent(event(id: graceful, phase: "requested", code: "none"))
        try store.recordShutdownEvent(event(id: graceful, phase: "graceful", code: "none"))
        clock.date = clock.date.addingTimeInterval(60)
        let boundary = clock.date
        clock.date = clock.date.addingTimeInterval(1)
        let current = UUID()
        try store.recordShutdownEvent(event(id: current, phase: "requested", code: "none"))
        try store.recoverIncompleteAttempts(before: boundary)
        XCTAssertEqual(try store.report(id: previous).events.last?.code, "incomplete_shutdown")
        XCTAssertEqual(try store.report(id: previous).events.last?.forced, false)
        XCTAssertFalse(try store.report(id: current).isAbnormal)
        XCTAssertFalse(try store.report(id: graceful).isAbnormal)
    }

    func testQuitDuringDoctorPreventsPostAndNextQueueDoctor() throws {
        let store = store()
        let client = FeedbackBarrierGitHub(pause: .doctor)
        let service = FeedbackService(store: store, client: client)
        try store.setConsent(enabled: true, account: "fixture-user")
        try store.recordShutdownEvent(event(participant: "database"))
        try store.recordShutdownEvent(event(participant: "clipboard"))
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { service.processAutomaticQueue(); done.signal() }
        XCTAssertEqual(client.entered.wait(timeout: .now() + 3), .success)
        let start = Date()
        service.stopForQuit()
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.1, "quit must not wait for doctor")
        client.release.signal()
        XCTAssertEqual(done.wait(timeout: .now() + 3), .success)
        XCTAssertEqual(client.creates, 0)
        XCTAssertEqual(client.doctors, 1)
        _ = service.doctor()
        XCTAssertEqual(client.doctors, 1, "permanent stop must reject later requests")
        XCTAssertThrowsError(try service.create(title: "manual", body: "fixture"))
        XCTAssertEqual(client.creates, 0)
    }

    func testAutomaticRevocationAtPostBoundaryPreventsPostButAllowsManual() throws {
        let store = store()
        let client = FeedbackBarrierGitHub(pause: .beforeCreate)
        let service = FeedbackService(store: store, client: client)
        try store.setConsent(enabled: true, account: "fixture-user")
        try store.recordShutdownEvent(event())
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { service.processAutomaticQueue(); done.signal() }
        XCTAssertEqual(client.entered.wait(timeout: .now() + 3), .success)
        service.suspendAutomatic()
        try store.setConsent(enabled: false)
        client.release.signal()
        XCTAssertEqual(done.wait(timeout: .now() + 3), .success)
        XCTAssertEqual(client.creates, 0)
        XCTAssertEqual(try store.report(id: nil).status, "pending", "revoked before admission is known not sent")
        _ = try service.create(title: "manual independent of auto", body: "fixture")
        XCTAssertEqual(client.creates, 1)
    }

    func testQuitAtPostBoundaryPreventsPost() throws {
        let store = store()
        let client = FeedbackBarrierGitHub(pause: .beforeCreate)
        let service = FeedbackService(store: store, client: client)
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            _ = try? service.create(title: "manual", body: "fixture")
            done.signal()
        }
        XCTAssertEqual(client.entered.wait(timeout: .now() + 3), .success)
        service.stopForQuit()
        client.release.signal()
        XCTAssertEqual(done.wait(timeout: .now() + 3), .success)
        XCTAssertEqual(client.creates, 0)
    }

    func testUnknownManualTombstoneSurvivesReportRetention() throws {
        let clock = FeedbackTestClock()
        let store = FeedbackStore(directory: directory.appendingPathComponent("store"), now: { clock.date })
        let client = FakeFeedbackGitHub()
        client.failCreate = true
        let service = FeedbackService(store: store, client: client, now: { clock.date })
        XCTAssertThrowsError(try service.create(title: "uncertain manual", body: "fixture"))
        clock.date = clock.date.addingTimeInterval(FeedbackPolicy.retention + 60)
        client.failCreate = false
        XCTAssertThrowsError(try service.create(title: "uncertain manual", body: "fixture"))
        XCTAssertEqual(client.creates, 1)
        XCTAssertEqual(client.finds, 1)
    }
}

private final class FeedbackTestClock: @unchecked Sendable { var date = Date(timeIntervalSince1970: 1_800_000_000) }
private final class FakeFeedbackGitHub: FeedbackGitHubServing, @unchecked Sendable {
    var creates = 0
    var doctors = 0
    var finds = 0
    var failCreate = false
    var foundURL: String?
    func doctor() -> FeedbackDoctor {
        doctors += 1
        return FeedbackDoctor(ghAvailable: true, account: "fixture-user", code: "ready")
    }
    func create(title: String, body: String) throws -> String {
        creates += 1
        if failCreate { throw FeedbackFailure("gh_timeout") }
        return "https://github.com/winx402/blocks-mac/issues/\(creates)"
    }
    func find(marker: String, account: String) throws -> String? { finds += 1; return foundURL }
}

private final class FeedbackBarrierGitHub: FeedbackGitHubServing, @unchecked Sendable {
    enum Pause { case doctor, beforeCreate }
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    private let pause: Pause
    private let lock = NSLock()
    private var didPause = false
    private var doctorCount = 0
    private var createCount = 0
    var doctors: Int { lock.lock(); defer { lock.unlock() }; return doctorCount }
    var creates: Int { lock.lock(); defer { lock.unlock() }; return createCount }
    init(pause: Pause) { self.pause = pause }
    private func barrier(_ at: Pause) {
        lock.lock()
        let shouldPause = !didPause && pause == at
        if shouldPause { didPause = true }
        lock.unlock()
        if shouldPause { entered.signal(); _ = release.wait(timeout: .now() + 5) }
    }
    func doctor() -> FeedbackDoctor {
        lock.lock(); doctorCount += 1; lock.unlock()
        barrier(.doctor)
        return FeedbackDoctor(ghAvailable: true, account: "fixture-user", code: "ready")
    }
    func create(title: String, body: String) throws -> String {
        lock.lock(); createCount += 1; lock.unlock()
        return "https://github.com/winx402/blocks-mac/issues/101"
    }
    func create(title: String, body: String, authorize: @escaping @Sendable () throws -> Void) throws -> String {
        barrier(.beforeCreate)
        try authorize()
        return try create(title: title, body: body)
    }
    func find(marker: String, account: String) throws -> String? { nil }
}
