import Foundation
import BlocksCore

enum SourceUpgradeCLI {
    /// Keep protocol encoding value-returning and separate from main's
    /// non-generic process-termination boundary (see issue #46).
    @inline(never)
    static func run(args: [String]) -> CLIExecutionOutput {
        let response: SourceUpgradeProtocol.Response
        #if BLOCKS_LOCAL_DEVELOPMENT
        if args != ["--json"] {
            response = .init(token: UUID(), status: .failed, errorCode: "invalid_arguments")
        } else {
            response = SourceUpgradeTransport.prepareAndQuit()
                ?? .init(token: UUID(), status: .failed, errorCode: "transport_failed")
        }
        #else
        response = .init(token: UUID(), status: .failed, errorCode: "unsupported")
        #endif
        let code: Int32
        switch response.status {
        case .committed: code = 0
        default: code = 1
        }
        return encodeCLIOutput(response, exitCode: code)
    }
}
