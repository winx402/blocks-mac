// Standalone fixture only; not a member of the Xcode app test target.
#if SOURCE_UPGRADE_CLI_FIXTURE
import Foundation
import BlocksCore
import Darwin

struct CLIExecutionOutput { let data: Data?; let exitCode: Int32 }
@inline(never)
func encodeCLIOutput<T: Encodable>(_ value: T, exitCode: Int32 = 0) -> CLIExecutionOutput {
    CLIExecutionOutput(data: try? JSONEncoder().encode(value), exitCode: exitCode)
}

@main
struct SourceUpgradeCLIFixtureMain {
    static func main() throws {
        // Do not send a valid local request: tests must never quit an installed app.
        for args in [[], ["--help"], ["--json", "--path", "/tmp/arbitrary"], ["--json", "--json"]] {
            let result = SourceUpgradeCLI.run(args: args)
            guard result.exitCode != 0, let data = result.data else { exit(1) }
            let response = try JSONDecoder().decode(SourceUpgradeProtocol.Response.self, from: data)
            guard response.version == 1, response.status == .failed else { exit(1) }
            #if BLOCKS_LOCAL_DEVELOPMENT
            guard response.errorCode == "invalid_arguments" else { exit(1) }
            #else
            guard response.errorCode == "unsupported" else { exit(1) }
            #endif
        }
        #if !BLOCKS_LOCAL_DEVELOPMENT
        let result = SourceUpgradeCLI.run(args: ["--json"])
        guard result.exitCode != 0, let data = result.data else { exit(1) }
        let response = try JSONDecoder().decode(SourceUpgradeProtocol.Response.self, from: data)
        guard response.status == .failed, response.errorCode == "unsupported" else { exit(1) }
        #endif
        print("Source-upgrade CLI fixture passed")
    }
}
#endif
