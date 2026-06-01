import Foundation

// Handle --check-permissions flag
if CommandLine.arguments.contains("--check-permissions") {
    let status = PermissionChecker.check()
    FileHandle.standardError.write(Data((status.summary + "\n").utf8))
    if status.allGranted {
        exit(0)
    } else {
        exit(1)
    }
}

// Handle `doctor` subcommand
if CommandLine.arguments.contains("doctor") {
    let code = await DoctorCommand.run()
    exit(Int32(code))
}

// Handle `dump-tracks` subcommand — AX archaeology utility
if CommandLine.arguments.contains("dump-tracks") {
    exit(Int32(DumpTracksCommand.run()))
}

// Handle `mcu-verify` subcommand — fires an MCU mutation and reads back via AX.
if let idx = CommandLine.arguments.firstIndex(of: "mcu-verify") {
    let rest = Array(CommandLine.arguments.dropFirst(idx + 1))
    let code = await MCUVerifyCommand.run(args: rest)
    exit(Int32(code))
}

// Start the MCP server
let server = LogicProServer()
do {
    try await server.start()
} catch {
    Log.error("Server failed: \(error)", subsystem: "main")
    exit(1)
}
