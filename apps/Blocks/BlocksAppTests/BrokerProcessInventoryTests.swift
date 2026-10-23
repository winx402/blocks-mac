import Darwin
import XCTest
@testable import Blocks

final class BrokerProcessInventoryTests: XCTestCase {
    private typealias Inventory = BrokerProcessInventory
    private let selfPID: Int32 = 42
    private var stride: Int { MemoryLayout<kinfo_proc>.stride }

    private struct Step {
        let sizing: Bool
        var processIDs: [Int32] = []
        var length: Int?
        var full = false
        var status: Int32 = 0
        var errorNumber: Int32 = 0
    }

    private final class Script {
        var steps: [Step]
        var callCount = 0
        var readCapacities: [Int] = []

        init(_ steps: [Step]) { self.steps = steps }

        func call(_ buffer: UnsafeMutableRawPointer?, _ capacity: Int) -> Inventory.SysctlResult {
            guard callCount < steps.count else {
                XCTFail("Unexpected syscall beyond the scripted inventory")
                return .init(status: -1, errorNumber: EIO, length: 0)
            }
            let step = steps[callCount]
            callCount += 1
            XCTAssertEqual(buffer == nil, step.sizing)
            if step.sizing { XCTAssertEqual(capacity, 0) }
            else {
                let recordStride = MemoryLayout<kinfo_proc>.stride
                readCapacities.append(capacity)
                XCTAssertEqual(capacity % recordStride, 0)
                if let buffer {
                    XCTAssertEqual(Int(bitPattern: buffer) % MemoryLayout<kinfo_proc>.alignment, 0)
                    XCTAssertLessThanOrEqual(step.processIDs.count, capacity / recordStride)
                    for (index, processID) in step.processIDs.prefix(capacity / recordStride).enumerated() {
                        buffer.assumingMemoryBound(to: kinfo_proc.self)[index].kp_proc.p_pid = processID
                    }
                }
            }
            return .init(status: step.status, errorNumber: step.errorNumber,
                length: step.full ? capacity : step.length ?? step.processIDs.count * MemoryLayout<kinfo_proc>.stride)
        }
    }

    private func assertFailure(
        _ steps: [Step], stage: Inventory.Stage, failure: Inventory.Failure,
        errorNumber: Int32? = nil, currentProcessID: Int32 = 42,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let script = Script(steps)
        XCTAssertThrowsError(try Inventory.processIDs(currentProcessID: currentProcessID, sysctlCall: script.call),
            "An invalid inventory must throw, never return an empty success", file: file, line: line) { error in
            XCTAssertEqual(error as? Inventory.InventoryError,
                .init(stage, failure, errorNumber: errorNumber), file: file, line: line)
        }
        XCTAssertEqual(script.callCount, steps.count, file: file, line: line)
    }

    func testSuccessfulReadUsesOnlyReturnedPrefixAndDiscardsKernelPID() throws {
        // Sizing deliberately exceeds the response. The unused zero-filled
        // capacity must not be decoded as duplicate kernel records.
        let script = Script([.init(sizing: true, length: 8 * stride),
            .init(sizing: false, processIDs: [0, 900, selfPID, 7])])
        XCTAssertEqual(try Inventory.processIDs(currentProcessID: selfPID, sysctlCall: script.call), [900, selfPID, 7])
        XCTAssertEqual(script.callCount, 2)
        XCTAssertGreaterThan(script.readCapacities[0], 8 * stride)
    }

    func testSizingEPERMDoesNotProduceEmptyInventory() {
        assertFailure([.init(sizing: true, length: 0, status: -1, errorNumber: EPERM)],
            stage: .sizing, failure: .syscallFailed, errorNumber: EPERM)
    }

    func testReadEPERMDoesNotProduceEmptyInventory() {
        assertFailure([.init(sizing: true, length: stride),
            .init(sizing: false, status: -1, errorNumber: EPERM)],
            stage: .read, failure: .syscallFailed, errorNumber: EPERM)
    }

    func testENOMEMRetriesWithFreshSizingAndAcceptsGrowth() throws {
        let script = Script([.init(sizing: true, length: stride),
            .init(sizing: false, length: 100 * stride, status: -1, errorNumber: ENOMEM),
            .init(sizing: true, length: 100 * stride),
            .init(sizing: false, processIDs: [selfPID, 99])])
        XCTAssertEqual(try Inventory.processIDs(currentProcessID: selfPID, sysctlCall: script.call), [selfPID, 99])
        XCTAssertEqual(script.callCount, 4)
        XCTAssertGreaterThan(script.readCapacities[1], script.readCapacities[0])
    }

    func testExactFullSuccessRetriesFreshSizing() throws {
        let script = Script([.init(sizing: true, length: stride),
            .init(sizing: false, full: true),
            .init(sizing: true, length: 100 * stride),
            .init(sizing: false, processIDs: [selfPID])])
        XCTAssertEqual(try Inventory.processIDs(currentProcessID: selfPID, sysctlCall: script.call), [selfPID])
        XCTAssertEqual(script.callCount, 4)
    }

    func testGrowthRetriesAreBounded() {
        var enomem: [Step] = []
        var full: [Step] = []
        for _ in 0..<Inventory.maximumAttempts {
            enomem += [.init(sizing: true, length: stride),
                .init(sizing: false, status: -1, errorNumber: ENOMEM)]
            full += [.init(sizing: true, length: stride), .init(sizing: false, full: true)]
        }
        assertFailure(enomem, stage: .read, failure: .retryLimitReached, errorNumber: ENOMEM)
        assertFailure(full, stage: .read, failure: .retryLimitReached)
    }

    func testSizingENOMEMRetriesAreBounded() {
        let steps = Array(repeating: Step(sizing: true, status: -1, errorNumber: ENOMEM),
            count: Inventory.maximumAttempts)
        assertFailure(steps, stage: .sizing, failure: .retryLimitReached, errorNumber: ENOMEM)
    }

    func testSizingRejectsZeroNegativeAndMisalignedLengths() {
        for length in [0, -stride, stride + 1] {
            assertFailure([.init(sizing: true, length: length)], stage: .sizing, failure: .invalidLength)
        }
    }

    func testSizingRejectsOversizeAndSlackBeyondAllocationLimit() {
        let limit = Inventory.maximumAllocationBytes
        let alignedLimit = limit / stride * stride
        assertFailure([.init(sizing: true, length: alignedLimit + stride)],
            stage: .sizing, failure: .allocationLimit)
        assertFailure([.init(sizing: true, length: alignedLimit)],
            stage: .sizing, failure: .allocationLimit)
        let hugeAlignedLength = Int.max / stride * stride
        assertFailure([.init(sizing: true, length: hugeAlignedLength)],
            stage: .sizing, failure: .allocationLimit)
    }

    func testReadRejectsEmptyNegativeMisalignedAndOverCapacityLengths() {
        // One sized record receives 64 records of slack.
        for length in [0, -stride, stride + 1, 66 * stride] {
            assertFailure([.init(sizing: true, length: stride),
                .init(sizing: false, processIDs: [selfPID], length: length)],
                stage: .read, failure: .invalidLength)
        }
    }

    func testEmptyUserInventoryAndMissingSelfFailClosed() {
        let inventories: [[Int32]] = [[0], [7, 99]]
        for processIDs in inventories {
            assertFailure([.init(sizing: true, length: 2 * stride),
                .init(sizing: false, processIDs: processIDs)],
                stage: .validation, failure: .missingCurrentProcess)
        }
    }

    func testNegativeAndDuplicatePIDsFailClosed() {
        assertFailure([.init(sizing: true, length: 2 * stride),
            .init(sizing: false, processIDs: [selfPID, -1])],
            stage: .validation, failure: .negativeProcessID)
        let inventories: [[Int32]] = [[selfPID, selfPID], [selfPID, 7, 7], [selfPID, 0, 0]]
        for processIDs in inventories {
            assertFailure([.init(sizing: true, length: 3 * stride),
                .init(sizing: false, processIDs: processIDs)],
                stage: .validation, failure: .duplicateProcessID)
        }
    }

    func testExpectedCurrentPIDMustBePositive() {
        let invalidPIDs: [Int32] = [0, -1]
        for processID in invalidPIDs {
            assertFailure([], stage: .validation, failure: .invalidCurrentProcessID, currentProcessID: processID)
        }
    }
}
