// Compiled only by script/test_local_action_transport.sh; never app sources.
#if LOCAL_ACTION_TRANSPORT_FIXTURE
import Foundation
import Darwin

#if !LOCAL_ACTION_SIGNED_FIXTURE
enum BlocksLocalBuildTrust {
    static func accepts(connectedSocket: Int32, role: String) -> Bool {
        var uid: uid_t = 0; var gid: gid_t = 0
        guard getpeereid(connectedSocket, &uid, &gid) == 0,
              uid == getuid(), !CommandLine.arguments.contains("--wrong-user") else { return false }
        return !CommandLine.arguments.contains("--reject-" + role)
    }
}
#endif

@main struct Fixture {
    static func main() throws {
        let args = CommandLine.arguments
        let path = args[2]
        if args[1] == "server" {
            let server = LocalActionTransport.Server(directoryPathForTesting: path)
            guard server.start(handler: { operation, data, output, reply in
                if data == Data("stall".utf8) { return }
                if data == Data("late-write".utf8), let output {
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) {
                        try? output.write(contentsOf: Data("retained-after-timeout".utf8))
                        reply(Data("finished".utf8))
                    }
                    return
                }
                if data == Data("fds".utf8) {
                    let count = (0..<1_024).filter { fcntl(Int32($0), F_GETFD) >= 0 }.count
                    reply(Data(String(count).utf8)); return
                }
                if operation == .submit, let output { try? output.write(contentsOf: data) }
                reply(data.isEmpty ? Data(operation.rawValue.utf8) : data)
                reply(Data("duplicate-must-not-win".utf8))
            }) else { print("refused"); exit(2) }
            print("ready"); fflush(stdout)
            dispatchMain()
        } else if args[1] == "client" {
            do {
                #if LOCAL_ACTION_SIGNED_FIXTURE
                let timeout: TimeInterval = 3
                #else
                let timeout: TimeInterval = 0.3
                #endif
                let data = try LocalActionTransport.fixtureRequest(path: path, operation: .probe,
                    payload: Data(args[3].utf8), timeout: timeout)
                print(String(decoding: data, as: UTF8.self))
            } catch { print(String(describing: error)); exit(3) }
        } else if args[1] == "lifecycle" {
            let server = LocalActionTransport.Server(directoryPathForTesting: path)
            let second = LocalActionTransport.Server(directoryPathForTesting: path)
            for _ in 0..<5 {
                precondition(server.start { _, _, _, reply in reply(Data("ok".utf8)) })
                precondition(server.start { _, _, _, reply in reply(Data("must-not-replace".utf8)) })
                precondition(!second.start { _, _, _, _ in })
                let response = try LocalActionTransport.fixtureRequest(path: path, operation: .probe)
                precondition(response == Data("ok".utf8))
                server.stop()
                Thread.sleep(forTimeInterval: 0.1)
            }
            print("lifecycle-ok")
        }
    }
}
#endif
