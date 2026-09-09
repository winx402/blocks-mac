import AppKit
import Foundation

private enum FixtureError: Error { case rejected }

@main
struct ApplicationUpdateSafetySelfTest {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw NSError(domain: "ApplicationUpdateSafetySelfTest", code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]) }
    }

    @MainActor
    static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try testCommittedWALBackup(root)
        try testMigrationRollback(root)
        try testFutureSchemaUntouched(root)
        try testSuccessfulMigrationBackup(root)
        try testSameVersionRepairBackup(root)
        try testConnectionFence(root)
        try testAuthenticatedHelperControls()
        try testBrokerIdleProtocolAndRecoveryJournal(root)
        try await testAtomicAdmission()
        try await testLifecycle()
        try await testResumeEnqueuesAfterStorageReopens(root)
        try await testTermination()
        print("PASS: application update storage and lifecycle safety")
    }

    static func testBrokerIdleProtocolAndRecoveryJournal(_ root: URL) throws {
        let broker = ActionBrokerUpdateAdmission()
        let token = UUID().uuidString
        guard let forwarding = broker.begin() else { throw FixtureError.rejected }
        do { try broker.prepare(token: token); throw FixtureError.rejected }
        catch ActionBrokerUpdateError.busy { }
        guard let otherClient = broker.begin() else { throw FixtureError.rejected }
        otherClient.release(); forwarding.release()
        try broker.prepare(token: token)
        try require(broker.begin() == nil, "new CLI request bypassed Broker idle freeze")
        try broker.resume(token: token)
        do { try broker.prepare(token: token); throw FixtureError.rejected }
        catch ActionBrokerUpdateError.invalidRecoveryState { }
        let cancelledBeforeDelivery = UUID().uuidString
        try broker.resume(token: cancelledBeforeDelivery)
        do { try broker.prepare(token: cancelledBeforeDelivery); throw FixtureError.rejected }
        catch ActionBrokerUpdateError.invalidRecoveryState { }

        let url = root.appendingPathComponent("broker-recovery.json")
        let journal = ActionBrokerUpdateRecoveryJournal(url: url)
        let ticket = ActionBrokerUpdateRecoveryTicket(processID: 77)
        try journal.save(ticket)
        let reopened = ActionBrokerUpdateRecoveryJournal(url: url)
        let loaded = try reopened.load()
        try require(loaded == ticket, "enabled-service intent did not survive reopening")
        do { try reopened.save(.init()); throw FixtureError.rejected }
        catch ActionBrokerUpdateError.invalidRecoveryState { }
        var invalid = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        invalid["schemaVersion"] = 999
        let bytes = try JSONSerialization.data(withJSONObject: invalid)
        try bytes.write(to: url)
        do { _ = try reopened.load(); throw FixtureError.rejected }
        catch ActionBrokerUpdateError.invalidRecoveryState { }
        let after = try Data(contentsOf: url)
        try require(after == bytes, "invalid recovery record was discarded")
        print("PASS: Broker-wide idle gate rejects active/late requests; durable recovery ticket is validated")
    }

    static func testSameVersionRepairBackup(_ root: URL) throws {
        let environment = StorageEnvironment(rootDirectory: root.appendingPathComponent("same-version-repair"))
        let original = try AppDatabase.open(environment: environment)
        try original.connection.execute("DROP TRIGGER clipboard_record_tags_content_revision_insert")
        original.close()
        let repaired = try AppDatabase.open(environment: environment)
        defer { repaired.close() }
        let exists = try repaired.connection.firstInt("SELECT COUNT(*) FROM sqlite_master WHERE name='clipboard_record_tags_content_revision_insert'")
        let backupRoot = environment.rootDirectory.appendingPathComponent("MigrationBackups")
        let files = FileManager.default.enumerator(at: backupRoot, includingPropertiesForKeys: nil)!
        let backups = files.compactMap { $0 as? URL }.filter { $0.pathExtension == "sqlite" }
        try require(exists == 1 && backups.count == 1, "same-version schema repair skipped its backup")
        let old = try SQLiteConnection(url: backups[0], readOnly: true)
        defer { old.close() }
        let oldTrigger = try old.firstInt("SELECT COUNT(*) FROM sqlite_master WHERE name='clipboard_record_tags_content_revision_insert'")
        try require(oldTrigger == 0, "repair backup was taken after changing schema")
        print("PASS: same-version schema repair is backed up before modification")
    }

    @MainActor
    static func testResumeEnqueuesAfterStorageReopens(_ root: URL) async throws {
        let database = try SQLiteConnection(url: root.appendingPathComponent("resume-queued.sqlite"))
        defer { database.close(); SQLiteConnection.resumeAfterCancelledApplicationUpdate() }
        try database.execute("CREATE TABLE queued_work(value TEXT)")
        let gate = ApplicationOperationAdmissionGate(name: "coalesced capture restart fixture")
        let lifecycle = ApplicationLifecycleCoordinator(requiredParticipantIDs: ["clipboard", "database"])
        var restartedTask: Task<Void, Never>?
        var failure: Error?
        try lifecycle.register(.init(id: "clipboard", pauseAndDrain: {
            try gate.pauseIfIdle()
        }, resume: {
            gate.resume()
            // Same gate.task enqueue boundary used by OCR/coalesced capture
            // restart: this must not be lost while global admission is closed.
            restartedTask = gate.task {
                do { try database.execute("INSERT INTO queued_work VALUES ('resumed')") }
                catch { failure = error }
            }
        }))
        try lifecycle.register(.init(id: "database", pauseAndDrain: {
            _ = try SQLiteConnection.prepareForApplicationUpdate()
        }, resume: { SQLiteConnection.resumeAfterCancelledApplicationUpdate() }))
        try await lifecycle.prepare()
        await lifecycle.resumeAfterCancelledUpdate()
        try require(restartedTask != nil, "resume dropped queued restart under closed global admission")
        await restartedTask?.value
        let count = try database.firstInt("SELECT COUNT(*) FROM queued_work")
        try require(failure == nil && count == 1, "resumed task ran before database fence reopened")
        print("PASS: resume enqueues real work after global and SQLite admission are open")
    }

    static func testConnectionFence(_ root: URL) throws {
        let directory = root.appendingPathComponent("fenced", isDirectory: true)
        let source = try SQLiteConnection(url: directory.appendingPathComponent("shared.sqlite"))
        let second = try SQLiteConnection(url: source.url)
        defer {
            SQLiteConnection.resumeAfterCancelledApplicationUpdate()
            source.close(); second.close()
        }
        try source.execute("CREATE TABLE values_table(value TEXT); INSERT INTO values_table VALUES ('before')")
        let backups = try SQLiteConnection.prepareForApplicationUpdate()
        try require(backups.count == 1, "same database was not deduplicated across connections")
        do { try second.execute("INSERT INTO values_table VALUES ('forbidden')"); throw FixtureError.rejected }
        catch SQLiteConnectionError.suspendedForApplicationUpdate { }
        do { _ = try SQLiteConnection(url: root.appendingPathComponent("new-during-update.sqlite")); throw FixtureError.rejected }
        catch SQLiteConnectionError.suspendedForApplicationUpdate { }
        SQLiteConnection.resumeAfterCancelledApplicationUpdate()
        try second.execute("INSERT INTO values_table VALUES ('after')")
        let snapshot = try SQLiteConnection(url: backups[0], readOnly: true)
        let count = try snapshot.firstInt("SELECT COUNT(*) FROM values_table")
        snapshot.close()
        try require(count == 1, "update snapshot was not frozen before resume")
        let blockedDirectory = root.appendingPathComponent("backup-failure", isDirectory: true)
        let failing = try SQLiteConnection(url: blockedDirectory.appendingPathComponent("db.sqlite"))
        defer { failing.close() }
        try Data("not a directory".utf8).write(to: blockedDirectory.appendingPathComponent("UpdateBackups"))
        do { _ = try SQLiteConnection.prepareForApplicationUpdate(); throw FixtureError.rejected }
        catch FixtureError.rejected { throw FixtureError.rejected }
        catch { }
        try source.execute("INSERT INTO values_table VALUES ('rollback-restored')")
        try failing.execute("CREATE TABLE recovered(value TEXT)")
        print("PASS: all connection admission is fenced, snapshot deduplicates, backup failure restores access")
    }

    static func testAuthenticatedHelperControls() throws {
        let key = Data(repeating: 7, count: 32)
        for kind: SelectionHelperCommandKind in [
            .prepareForApplicationUpdate, .resumeAfterCancelledApplicationUpdate, .terminateForApplicationUpdate,
        ] {
            let envelope = try SelectionHelperAuthenticatedCodec.seal(
                SelectionHelperCommand(kind: kind), requestID: UUID().uuidString,
                expiresAt: Date().addingTimeInterval(30), keyData: key)
            let decoded = try SelectionHelperAuthenticatedCodec.open(
                SelectionHelperCommand.self, from: envelope, keyData: key)
            try require(decoded.kind == kind, "authenticated lifecycle command did not round-trip")
            do {
                _ = try SelectionHelperAuthenticatedCodec.open(SelectionHelperCommand.self,
                    from: envelope, keyData: Data(repeating: 9, count: 32))
                throw FixtureError.rejected
            } catch FixtureError.rejected { throw FixtureError.rejected }
            catch { }
        }
        print("PASS: Helper lifecycle commands require the authenticated channel key")
    }

    @MainActor
    static func testAtomicAdmission() async throws {
        let parent = ApplicationOperationAdmissionGate(name: "parent")
        let child = ApplicationOperationAdmissionGate(name: "child")
        let lease = try parent.requireLease()
        do { try ApplicationOperationAdmissionGate.pauseAllIfIdle(); throw FixtureError.rejected }
        catch ApplicationOperationAdmissionGate.AdmissionError.busy { }
        let childLease = try child.requireLease()
        childLease.release(); lease.release()
        let queued = parent.task { await Task.yield() }
        do { try ApplicationOperationAdmissionGate.pauseAllIfIdle(); throw FixtureError.rejected }
        catch ApplicationOperationAdmissionGate.AdmissionError.busy { }
        await queued?.value
        // Retain the completed handle: completion, not handle nil, proves idle.
        try ApplicationOperationAdmissionGate.pauseAllIfIdle()
        try require(parent.begin() == nil && child.begin() == nil, "atomic pause left a child gate open")
        let newlyCreated = ApplicationOperationAdmissionGate(name: "new after cutoff")
        try require(newlyCreated.begin() == nil, "new gate bypassed global cutoff")
        ApplicationOperationAdmissionGate.resumeAll()
        let resumed = try parent.requireLease(); resumed.release()
        print("PASS: busy parent never pauses child; queued tasks are busy; global cutoff covers new gates")
    }

    static func testCommittedWALBackup(_ root: URL) throws {
        let source = try SQLiteConnection(url: root.appendingPathComponent("wal.sqlite"))
        defer { source.close() }
        try source.execute("PRAGMA wal_autocheckpoint=0; CREATE TABLE items(value TEXT); INSERT INTO items VALUES ('committed-in-wal')")
        let target = root.appendingPathComponent("snapshot.sqlite")
        try source.backup(to: target)
        let backup = try SQLiteConnection(url: target, readOnly: true)
        defer { backup.close() }
        let value = try backup.firstString("SELECT value FROM items")
        try require(value == "committed-in-wal", "backup lost committed WAL data")
        do { try source.backup(to: target); throw FixtureError.rejected }
        catch SQLiteConnectionError.backupFailed { }
        let unchanged = try backup.firstString("SELECT value FROM items")
        try require(unchanged == value, "existing backup was overwritten")
        print("PASS: SQLite backup observes WAL and rejects overwrite")
    }

    static func testMigrationRollback(_ root: URL) throws {
        let environment = StorageEnvironment(rootDirectory: root.appendingPathComponent("rollback"))
        let source = try SQLiteConnection(url: environment.databaseURL)
        // v1 can succeed; v2's CREATE INDEX will fail against this deliberately
        // incomplete existing table. The outer transaction must undo v1 too.
        try source.execute("CREATE TABLE clipboard_search_documents(sentinel TEXT); INSERT INTO clipboard_search_documents VALUES ('preserve-me')")
        source.close()
        do { _ = try AppDatabase.open(environment: environment); throw FixtureError.rejected }
        catch is SQLiteConnectionError { }
        let inspected = try SQLiteConnection(url: environment.databaseURL, readOnly: true)
        defer { inspected.close() }
        let version = try inspected.firstInt("PRAGMA user_version")
        let value = try inspected.firstString("SELECT sentinel FROM clipboard_search_documents")
        let newTable = try inspected.firstInt("SELECT COUNT(*) FROM sqlite_master WHERE name='clipboard_items'")
        try require(version == 0 && value == "preserve-me" && newTable == 0,
            "failed multi-version migration changed old schema/data/version")
        print("PASS: migration failure rolls back earlier version steps without clearing data")
    }

    static func testFutureSchemaUntouched(_ root: URL) throws {
        let environment = StorageEnvironment(rootDirectory: root.appendingPathComponent("future"))
        let source = try SQLiteConnection(url: environment.databaseURL)
        try source.execute("CREATE TABLE future_data(value TEXT); INSERT INTO future_data VALUES ('future'); PRAGMA user_version=999; PRAGMA wal_checkpoint(TRUNCATE); PRAGMA journal_mode=DELETE")
        source.close()
        let before = try Data(contentsOf: environment.databaseURL)
        do { _ = try AppDatabase.open(environment: environment); throw FixtureError.rejected }
        catch AppDatabaseError.unsupportedSchemaVersion(999) { }
        let after = try Data(contentsOf: environment.databaseURL)
        try require(before == after, "future schema database bytes changed")
        try require(!FileManager.default.fileExists(atPath: environment.rootDirectory.appendingPathComponent("MigrationBackups").path),
            "future schema unexpectedly entered backup/migration flow")
        print("PASS: future schema refusal leaves database bytes untouched")
    }

    static func testSuccessfulMigrationBackup(_ root: URL) throws {
        let environment = StorageEnvironment(rootDirectory: root.appendingPathComponent("success"))
        let source = try SQLiteConnection(url: environment.databaseURL)
        try source.execute("CREATE TABLE user_sentinel(value TEXT); INSERT INTO user_sentinel VALUES ('kept')")
        source.close()
        let migrated = try AppDatabase.open(environment: environment)
        defer { migrated.close() }
        let version = try migrated.userVersion()
        try require(version == AppDatabase.currentSchemaVersion, "fresh schema did not fully migrate")
        let backupRoot = environment.rootDirectory.appendingPathComponent("MigrationBackups")
        let files = FileManager.default.enumerator(at: backupRoot, includingPropertiesForKeys: nil)!
        let backups = files.compactMap { $0 as? URL }.filter { $0.pathExtension == "sqlite" }
        try require(backups.count == 1, "pre-migration backup missing")
        let inspected = try SQLiteConnection(url: backups[0], readOnly: true)
        defer { inspected.close() }
        let oldVersion = try inspected.firstInt("PRAGMA user_version")
        let value = try inspected.firstString("SELECT value FROM user_sentinel")
        try require(oldVersion == 0 && value == "kept", "backup is not the old consistent schema")
        print("PASS: successful migration retains a readable pre-migration snapshot")
    }

    @MainActor
    static func testLifecycle() async throws {
        let lifecycle = ApplicationLifecycleCoordinator(requiredParticipantIDs: ["work", "database"])
        do { try await lifecycle.prepare(); throw FixtureError.rejected }
        catch ApplicationLifecycleCoordinator.SafetyError.missingParticipants { }
        var events: [String] = []
        var failDatabase = true
        try lifecycle.register(.init(id: "database", pauseAndDrain: {
            events.append("pause-db")
            if failDatabase { throw FixtureError.rejected }
        }, resume: { events.append("resume-db") }))
        try lifecycle.register(.init(id: "work", pauseAndDrain: {
            events.append("pause-work")
        }, resume: { events.append("resume-work") }))
        do { try await lifecycle.prepare(); throw FixtureError.rejected }
        catch FixtureError.rejected { }
        try require(events == ["pause-work", "pause-db", "resume-db", "resume-work"],
            "failure did not resume all participants in reverse order")
        try require(lifecycle.state == .active, "failed lifecycle remained paused")
        events.removeAll(); failDatabase = false
        try await lifecycle.prepare()
        try await lifecycle.prepare()
        try require(events == ["pause-work", "pause-db"], "prepare did not remain idempotent")
        await lifecycle.resumeAfterCancelledUpdate()
        try require(lifecycle.state == .active && events.suffix(2) == ["resume-db", "resume-work"],
            "cancelled update did not resume producers after storage")
        print("PASS: incomplete capability fails closed, failed preparation resumes, storage runs last")
    }

    @MainActor
    static func testTermination() async throws {
        var reply: Bool?
        var finalized = false
        var continuation: CheckedContinuation<Void, Never>?
        let coordinator = AppTerminationCoordinator(dispatcher: {
            await withCheckedContinuation { continuation = $0 }
        }, finalizer: { finalized = true }, replyHandler: { reply = $0 })
        try require(coordinator.requestTermination() == .terminateLater, "termination did not defer")
        for _ in 0..<30 { await Task.yield() }
        try require(reply == nil && !finalized, "elapsed timeout forced termination")
        continuation?.resume()
        for _ in 0..<30 { await Task.yield() }
        try require(reply == true && finalized, "completed drain did not authorize termination")
        reply = nil
        let rejecting = AppTerminationCoordinator(dispatcher: { throw FixtureError.rejected }, replyHandler: { reply = $0 })
        _ = rejecting.requestTermination()
        for _ in 0..<30 { await Task.yield() }
        try require(reply == nil && rejecting.isQuitting, "failed quit preparation reopened admission")
        let unconfigured = AppTerminationCoordinator(replyHandler: { _ in })
        try require(unconfigured.requestTermination() == .terminateLater, "unconfigured quit was vetoed")
        print("PASS: graceful finalization waits for drain; committed quit never reports update safety")
    }
}
