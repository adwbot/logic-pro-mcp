import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// `LogicProMCP mcu-verify --track N --op <mute|solo|arm|select|volume|pan> [--value V]`
///
/// End-to-end verification primitive for the MCU mutation path. Fires the operation
/// against live Logic Pro via CoreMIDIChannel, sleeps a verification window, then
/// re-reads track state via the existing AX extractors and prints whether the state
/// actually changed.
///
/// READ-ONLY observation: the verification path uses `AXLogicProElements.allTrackHeaders()`
/// + `AXValueExtractors.extractTrackState`. We never AXPress the AX widgets here.
enum MCUVerifyCommand {
    static func run(args: [String]) async -> Int {
        setvbuf(stdout, nil, _IOLBF, 0)

        // Parse flags.
        var trackIndex: Int = 0
        var op: String = ""
        var valueArg: String = ""
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--track":
                if i + 1 < args.count, let n = Int(args[i + 1]) { trackIndex = n; i += 2; continue }
            case "--op":
                if i + 1 < args.count { op = args[i + 1]; i += 2; continue }
            case "--value":
                if i + 1 < args.count { valueArg = args[i + 1]; i += 2; continue }
            default:
                break
            }
            i += 1
        }

        guard !op.isEmpty else {
            print("usage: LogicProMCP mcu-verify --track N --op <mute|solo|arm|select|volume|pan> [--value V]")
            return 2
        }

        guard ProcessUtils.isLogicProRunning else {
            print("Logic Pro is not running. mcu-verify needs a running Logic to read state back.")
            return 1
        }

        // Read BEFORE state.
        let before = readTrackState(index: trackIndex)
        print("BEFORE track[\(trackIndex)]: name=\"\(before.name)\" muted=\(before.isMuted) soloed=\(before.isSoloed) armed=\(before.isArmed) selected=\(before.isSelected)")

        // Build server + register channels (so CoreMIDIChannel is live).
        let server = LogicProServer()
        await server.setupChannels()

        // Build operation/params from --op.
        let operation: String
        var params: [String: String] = ["index": String(trackIndex)]
        switch op {
        case "mute":   operation = "track.set_mute"
        case "solo":   operation = "track.set_solo"
        case "arm":    operation = "track.set_arm"
        case "select": operation = "track.select"
        case "volume":
            operation = "mixer.set_volume"
            params["volume"] = valueArg.isEmpty ? "0.5" : valueArg
        case "pan":
            operation = "mixer.set_pan"
            params["pan"] = valueArg.isEmpty ? "0.0" : valueArg
        default:
            print("Unknown op '\(op)'. Allowed: mute, solo, arm, select, volume, pan")
            await server.stop()
            return 2
        }

        // Force CoreMIDI path — verifying MCU specifically, not the router fallback.
        let router = server.channelRouter
        guard let midi = await router.channel(for: .coreMIDI) else {
            print("CoreMIDI channel not registered.")
            await server.stop()
            return 1
        }
        let result = await midi.execute(operation: operation, params: params)
        print("FIRE: \(result.message)")

        // Sleep then re-read.
        try? await Task.sleep(nanoseconds: UInt64(ServerConfig.mcuVerifyDelaySeconds * 1_000_000_000))
        let after = readTrackState(index: trackIndex)
        print("AFTER  track[\(trackIndex)]: name=\"\(after.name)\" muted=\(after.isMuted) soloed=\(after.isSoloed) armed=\(after.isArmed) selected=\(after.isSelected)")

        // Decide pass/fail.
        let changed: Bool
        switch op {
        case "mute":   changed = before.isMuted != after.isMuted
        case "solo":   changed = before.isSoloed != after.isSoloed
        case "arm":    changed = before.isArmed != after.isArmed
        case "select": changed = before.isSelected != after.isSelected
        case "volume", "pan":
            // AX read of volume/pan via current extractors is always 0.0 (extractTrackState
            // sets them to 0.0). For volume/pan we report the fire as "code-complete" and
            // print a manual check instruction.
            print("NOTE: volume/pan AX read is unimplemented in current TrackState extractors.")
            print("  Manual check: look at Logic's mixer fader for track \(trackIndex).")
            await server.stop()
            return 0
        default:
            changed = false
        }

        await server.stop()

        if changed {
            print("PASS — state changed via MCU.")
            return 0
        } else {
            print("FAIL — Logic received the MIDI but didn't apply the state change.")
            print("")
            print("  Most likely cause on Logic 12.2: the Mackie Control surface is not")
            print("  registered. Apple's 'auto-detect' applies only to physical USB MCU")
            print("  devices; virtual ports require manual setup. To fix:")
            print("")
            print("    1. In Logic Pro: Logic Pro > Settings > Control Surfaces > Setup")
            print("    2. New > Install... > Mackie Designs > Mackie Control > Add")
            print("    3. Set Input Port = LogicProMCP-Out, Output Port = LogicProMCP-In")
            print("    4. Close Settings. Re-run this command.")
            print("")
            print("  If still failing after the surface is added, the handshake or device")
            print("  id is wrong. Run with LOG_LEVEL=debug to see inbound sysex from Logic.")
            return 1
        }
    }

    private static func readTrackState(index: Int) -> TrackState {
        let headers = AXLogicProElements.allTrackHeaders()
        guard index >= 0, index < headers.count else {
            return TrackState(
                id: index, name: "<out-of-range>", type: .unknown,
                isMuted: false, isSoloed: false, isArmed: false, isSelected: false,
                volume: 0.0, pan: 0.0, color: nil
            )
        }
        return AXValueExtractors.extractTrackState(from: headers[index], index: index)
    }
}
