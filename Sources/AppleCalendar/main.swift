import Foundation

func emit(_ result: (stdout: String?, stderr: String?, exitCode: Int32)) -> Never {
    if let out = result.stdout { print(out) }
    if let err = result.stderr { FileHandle.standardError.write((err + "\n").data(using: .utf8)!) }
    exit(result.exitCode)
}

let argv = Array(CommandLine.arguments.dropFirst())

// `ical serve ...` — lifecycle management for the networked HTTP server
// (setup/status/uninstall/token via a user-owned LaunchAgent + token file).
if argv.first == "serve" {
    let serveArgs = Array(argv.dropFirst())
    // `serve token` prints the raw credential with NO trailing newline, so
    // `ical serve token | pbcopy` copies the token exactly — a trailing "\n" would be
    // pasted into the Bearer header and rejected. Other subcommands use emit's newline.
    if serveArgs.first == "token" {
        let r = Serve.token(home: NSHomeDirectory())
        if let out = r.0 { FileHandle.standardOutput.write(Data(out.utf8)) }
        if let err = r.1 { FileHandle.standardError.write(Data((err + "\n").utf8)) }
        exit(r.2)
    }
    emit(Serve.run(serveArgs))
}

// `ical mcp ...` — stdio MCP server (Phase 2) or HTTP (Phase 3 stub).
if argv.first == "mcp" {
    let mcpArgs = Array(argv.dropFirst())
    let sema = DispatchSemaphore(value: 0)
    final class ExitBox: @unchecked Sendable { var code: Int32 = 0 }
    let exitBox = ExitBox()

    if mcpArgs.contains("--http") {
        let config = ServerConfig.fromEnvironment(ProcessInfo.processInfo.environment, argv: mcpArgs)
        do { try config.validate() } catch {
            FileHandle.standardError.write("Refusing to start: set CALENDAR_MCP_TOKEN, or pass --no-auth to run without auth (NOT recommended).\n".data(using: .utf8)!)
            exit(1)
        }
        if config.allowNoAuth {
            FileHandle.standardError.write("⚠️  Running with --no-auth: anyone who can reach \(config.host):\(config.port) can read and modify your calendar.\n".data(using: .utf8)!)
        }
        Task {
            do { try await HTTPRunner.run(store: EventKitStore(), config: config) } catch {
                FileHandle.standardError.write("http error: \(error)\n".data(using: .utf8)!)
                exitBox.code = 1
            }
            sema.signal()
        }
    } else {
        Task {
            do { try await StdioRunner.run(store: EventKitStore()) } catch {
                FileHandle.standardError.write("mcp error: \(error)\n".data(using: .utf8)!)
                exitBox.code = 1
            }
            sema.signal()
        }
    }

    // RunLoop.main.run() keeps the cooperative executor alive so Task{} can execute.
    // The semaphore signals when the MCP session ends (EOF on stdin / server stops) or
    // fails, then we exit with the server's status — non-zero on startup failure so a
    // supervisor can restart.
    DispatchQueue.global().async {
        sema.wait()
        exit(exitBox.code)
    }
    RunLoop.main.run()
}

emit(CLI.run(argv, store: EventKitStore()))
