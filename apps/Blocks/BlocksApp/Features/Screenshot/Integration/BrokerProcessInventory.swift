import Darwin

/// Enumerates all kernel-visible processes without libproc's sandbox-denied
/// proc_listallpids call. Classification and Broker lifetime proof stay with
/// the caller; a failed or incomplete inventory must never look like no Broker.
enum BrokerProcessInventory {
    enum Stage: String, Equatable { case sizing, read, validation }
    enum Failure: String, Equatable {
        case syscallFailed
        case invalidLength
        case allocationLimit
        case retryLimitReached
        case invalidCurrentProcessID
        case negativeProcessID
        case duplicateProcessID
        case missingCurrentProcess
    }

    struct InventoryError: Error, Equatable {
        let stage: Stage
        let failure: Failure
        let errorNumber: Int32?

        init(_ stage: Stage, _ failure: Failure, errorNumber: Int32? = nil) {
            self.stage = stage
            self.failure = failure
            self.errorNumber = errorNumber
        }
    }

    /// Capture the syscall's status, errno, and output length together before
    /// any further call can overwrite errno. Tests inject the same boundary.
    struct SysctlResult {
        let status: Int32
        let errorNumber: Int32
        let length: Int
    }

    typealias Sysctl = (UnsafeMutableRawPointer?, Int) -> SysctlResult

    static let maximumAllocationBytes = 16 * 1_024 * 1_024
    static let maximumAttempts = 3

    static func processIDs(
        currentProcessID: Int32 = getpid(),
        sysctlCall: Sysctl = readAllProcesses
    ) throws -> [Int32] {
        guard currentProcessID > 0 else {
            throw InventoryError(.validation, .invalidCurrentProcessID)
        }
        let stride = MemoryLayout<kinfo_proc>.stride
        for attempt in 0..<maximumAttempts {
            let sizing = sysctlCall(nil, 0)
            if sizing.status != 0 {
                if sizing.errorNumber == ENOMEM {
                    guard attempt + 1 < maximumAttempts else {
                        throw InventoryError(.sizing, .retryLimitReached, errorNumber: ENOMEM)
                    }
                    continue
                }
                throw InventoryError(.sizing, .syscallFailed, errorNumber: sizing.errorNumber)
            }
            guard sizing.length > 0, sizing.length % stride == 0 else {
                throw InventoryError(.sizing, .invalidLength)
            }
            guard sizing.length <= maximumAllocationBytes else {
                throw InventoryError(.sizing, .allocationLimit)
            }
            let count = sizing.length / stride
            let slack = max(64, count / 4)
            let (capacity, countOverflow) = count.addingReportingOverflow(slack)
            let (capacityBytes, byteOverflow) = capacity.multipliedReportingOverflow(by: stride)
            guard !countOverflow, !byteOverflow, capacityBytes <= maximumAllocationBytes else {
                throw InventoryError(.sizing, .allocationLimit)
            }

            // Typed storage guarantees kinfo_proc alignment. Only the returned
            // prefix is consumed; unused capacity is not part of the snapshot.
            var records = [kinfo_proc](repeating: kinfo_proc(), count: capacity)
            let read = records.withUnsafeMutableBytes { sysctlCall($0.baseAddress, $0.count) }
            if read.status != 0 {
                if read.errorNumber == ENOMEM {
                    guard attempt + 1 < maximumAttempts else {
                        throw InventoryError(.read, .retryLimitReached, errorNumber: ENOMEM)
                    }
                    continue
                }
                throw InventoryError(.read, .syscallFailed, errorNumber: read.errorNumber)
            }
            guard read.length > 0, read.length <= capacityBytes, read.length % stride == 0 else {
                throw InventoryError(.read, .invalidLength)
            }
            // Exact-full success can hide growth at the boundary. Obtain a new
            // size instead of trusting a potentially truncated snapshot.
            if read.length == capacityBytes {
                guard attempt + 1 < maximumAttempts else {
                    throw InventoryError(.read, .retryLimitReached)
                }
                continue
            }

            var seen = Set<Int32>()
            var result: [Int32] = []
            result.reserveCapacity(read.length / stride)
            for record in records.prefix(read.length / stride) {
                let processID = record.kp_proc.p_pid
                guard processID >= 0 else { throw InventoryError(.validation, .negativeProcessID) }
                guard seen.insert(processID).inserted else {
                    throw InventoryError(.validation, .duplicateProcessID)
                }
                if processID == 0 { continue } // Kernel task is not a user process.
                result.append(processID)
            }
            guard seen.contains(currentProcessID) else {
                throw InventoryError(.validation, .missingCurrentProcess)
            }
            return result
        }
        // Every retry on the final attempt throws above.
        throw InventoryError(.read, .retryLimitReached)
    }

    private static func readAllProcesses(_ buffer: UnsafeMutableRawPointer?, _ capacity: Int) -> SysctlResult {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL]
        var length = capacity
        return mib.withUnsafeMutableBufferPointer { mibBuffer in
            let status = sysctl(mibBuffer.baseAddress, UInt32(mibBuffer.count), buffer, &length, nil, 0)
            let errorNumber = errno
            return SysctlResult(status: status, errorNumber: errorNumber, length: length)
        }
    }
}
