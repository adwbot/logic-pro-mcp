import Foundation

/// Channel that routes operations through CoreMIDI / MMC / MCU.
actor CoreMIDIChannel: Channel {
    let id: ChannelID = .coreMIDI
    private let engine: MIDIEngine
    private let bank: MCUBankState
    private let handshake: MCUHandshake

    init(engine: MIDIEngine, bank: MCUBankState, handshake: MCUHandshake) {
        self.engine = engine
        self.bank = bank
        self.handshake = handshake
    }

    func start() async throws {
        try await engine.start()
        await bank.start()
        await handshake.start()
        Log.info("CoreMIDIChannel started (MMC + MCU)", subsystem: "midi")
    }

    func stop() async {
        await handshake.stop()
        await bank.stop()
        await engine.stop()
        Log.info("CoreMIDIChannel stopped", subsystem: "midi")
    }

    func execute(operation: String, params: [String: String]) async -> ChannelResult {
        switch operation {
        // MARK: - Transport (MMC)

        case "transport.play":
            await engine.sendSysEx(MMCCommands.play())
            return .success("MMC play sent")

        case "transport.stop":
            await engine.sendSysEx(MMCCommands.stop())
            return .success("MMC stop sent")

        case "transport.pause":
            await engine.sendSysEx(MMCCommands.pause())
            return .success("MMC pause sent")

        case "transport.record_strobe":
            await engine.sendSysEx(MMCCommands.recordStrobe())
            return .success("MMC record strobe sent")

        case "transport.record_exit":
            await engine.sendSysEx(MMCCommands.recordExit())
            return .success("MMC record exit sent")

        case "transport.fast_forward":
            await engine.sendSysEx(MMCCommands.fastForward())
            return .success("MMC fast forward sent")

        case "transport.rewind":
            await engine.sendSysEx(MMCCommands.rewind())
            return .success("MMC rewind sent")

        case "transport.locate":
            guard let h = params["hours"].flatMap(UInt8.init),
                  let m = params["minutes"].flatMap(UInt8.init),
                  let s = params["seconds"].flatMap(UInt8.init),
                  let f = params["frames"].flatMap(UInt8.init) else {
                return .error("locate requires hours, minutes, seconds, frames")
            }
            let sf = params["subframes"].flatMap(UInt8.init) ?? 0
            await engine.sendSysEx(MMCCommands.locate(hours: h, minutes: m, seconds: s, frames: f, subframes: sf))
            return .success("MMC locate sent to \(h):\(m):\(s):\(f).\(sf)")

        // MARK: - Note Send

        case "midi.send_note":
            guard let note = params["note"].flatMap(UInt8.init) else {
                return .error("send_note requires 'note' (0-127)")
            }
            let channel = params["channel"].flatMap(UInt8.init) ?? 0
            let velocity = params["velocity"].flatMap(UInt8.init) ?? 100
            let durationMs = params["duration_ms"].flatMap(UInt64.init) ?? 250
            await engine.sendNoteOn(channel: channel, note: note, velocity: velocity)
            try? await Task.sleep(nanoseconds: durationMs * 1_000_000)
            await engine.sendNoteOff(channel: channel, note: note)
            return .success("Note \(note) on ch \(channel) vel \(velocity) dur \(durationMs)ms")

        case "midi.note_on":
            guard let note = params["note"].flatMap(UInt8.init) else {
                return .error("note_on requires 'note' (0-127)")
            }
            let channel = params["channel"].flatMap(UInt8.init) ?? 0
            let velocity = params["velocity"].flatMap(UInt8.init) ?? 100
            await engine.sendNoteOn(channel: channel, note: note, velocity: velocity)
            return .success("Note on \(note) ch \(channel) vel \(velocity)")

        case "midi.note_off":
            guard let note = params["note"].flatMap(UInt8.init) else {
                return .error("note_off requires 'note' (0-127)")
            }
            let channel = params["channel"].flatMap(UInt8.init) ?? 0
            await engine.sendNoteOff(channel: channel, note: note)
            return .success("Note off \(note) ch \(channel)")

        // MARK: - CC

        case "midi.send_cc":
            guard let controller = params["controller"].flatMap(UInt8.init),
                  let value = params["value"].flatMap(UInt8.init) else {
                return .error("send_cc requires 'controller' and 'value' (0-127)")
            }
            let channel = params["channel"].flatMap(UInt8.init) ?? 0
            await engine.sendCC(channel: channel, controller: controller, value: value)
            return .success("CC \(controller)=\(value) on ch \(channel)")

        // MARK: - Program Change

        case "midi.program_change":
            guard let program = params["program"].flatMap(UInt8.init) else {
                return .error("program_change requires 'program' (0-127)")
            }
            let channel = params["channel"].flatMap(UInt8.init) ?? 0
            await engine.sendProgramChange(channel: channel, program: program)
            return .success("Program change \(program) on ch \(channel)")

        // MARK: - Pitch Bend

        case "midi.pitch_bend":
            guard let value = params["value"].flatMap(UInt16.init) else {
                return .error("pitch_bend requires 'value' (0-16383, center=8192)")
            }
            let channel = params["channel"].flatMap(UInt8.init) ?? 0
            await engine.sendPitchBend(channel: channel, value: value)
            return .success("Pitch bend \(value) on ch \(channel)")

        // MARK: - Aftertouch

        case "midi.aftertouch":
            guard let pressure = params["pressure"].flatMap(UInt8.init) else {
                return .error("aftertouch requires 'pressure' (0-127)")
            }
            let channel = params["channel"].flatMap(UInt8.init) ?? 0
            await engine.sendAftertouch(channel: channel, pressure: pressure)
            return .success("Aftertouch \(pressure) on ch \(channel)")

        // MARK: - Raw SysEx

        case "midi.send_sysex":
            guard let hexString = params["bytes"] else {
                return .error("send_sysex requires 'bytes' (hex string, e.g. 'F0 7F 7F 06 02 F7')")
            }
            let bytes = hexString.split(separator: " ").compactMap { UInt8($0, radix: 16) }
            guard bytes.first == 0xF0, bytes.last == 0xF7 else {
                return .error("SysEx must start with F0 and end with F7")
            }
            await engine.sendSysEx(bytes)
            return .success("SysEx sent (\(bytes.count) bytes)")

        // MARK: - MCU: Track buttons (mute/solo/arm/select)

        case "track.set_mute":
            return await sendTrackButton(params: params, noteFn: MCU.muteNote, label: "mute")

        case "track.set_solo":
            return await sendTrackButton(params: params, noteFn: MCU.soloNote, label: "solo")

        case "track.set_arm":
            return await sendTrackButton(params: params, noteFn: MCU.armNote, label: "arm")

        case "track.select":
            return await sendTrackButton(params: params, noteFn: MCU.selectNote, label: "select", momentary: true)

        // MARK: - MCU: Mixer (fader / V-Pot)

        case "mixer.set_volume":
            guard let trackIdx = params["index"].flatMap(Int.init) else {
                return .error("mixer.set_volume requires 'index'")
            }
            guard let value = params["volume"].flatMap(Double.init) else {
                return .error("mixer.set_volume requires 'volume' (0.0-1.0)")
            }
            let bankChannel = await bank.bank(toTrackIndex: trackIdx)
            let pbValue = MCU.faderValue(normalized: value)
            await engine.sendPitchBend(channel: MCU.faderChannel(bankChannel: bankChannel), value: pbValue)
            return .success("MCU fader track=\(trackIdx) bankCh=\(bankChannel) value=\(value) pb=\(pbValue)")

        case "mixer.set_pan":
            guard let trackIdx = params["index"].flatMap(Int.init) else {
                return .error("mixer.set_pan requires 'index'")
            }
            guard let value = params["pan"].flatMap(Double.init) else {
                return .error("mixer.set_pan requires 'pan' (-1.0..+1.0)")
            }
            let bankChannel = await bank.bank(toTrackIndex: trackIdx)
            // V-Pot is relative — send a strong delta in the desired direction; Logic clamps.
            let clamped = max(-1.0, min(1.0, value))
            let direction = clamped >= 0 ? 1 : -1
            let cc = MCU.vpotCC(bankChannel: bankChannel)
            let delta = MCU.vpotDelta(ticks: direction * 7)
            await engine.sendCC(channel: 0, controller: cc, value: delta)
            return .success("MCU V-Pot track=\(trackIdx) bankCh=\(bankChannel) pan=\(value) cc=\(cc) delta=\(delta)")

        default:
            return .error("Unknown CoreMIDI operation: \(operation)")
        }
    }

    // MARK: - MCU button helper

    /// Banks to the requested track, then sends a press + release on the MCU button identified
    /// by `noteFn(bankChannel)`. MCU buttons are stateless triggers; Logic itself toggles state.
    private func sendTrackButton(
        params: [String: String],
        noteFn: (Int) -> UInt8,
        label: String,
        momentary: Bool = false
    ) async -> ChannelResult {
        guard let trackIdx = params["index"].flatMap(Int.init) else {
            return .error("track.set_\(label) requires 'index'")
        }
        _ = momentary // currently unused — Logic toggles all of these by press; reserved for future
        let bankChannel = await bank.bank(toTrackIndex: trackIdx)
        let note = noteFn(bankChannel)
        await engine.sendNoteOn(channel: 0, note: note, velocity: MCU.pressVelocity)
        try? await Task.sleep(nanoseconds: 10_000_000) // 10ms inter-byte gap
        await engine.sendNoteOn(channel: 0, note: note, velocity: MCU.releaseVelocity)
        return .success("MCU \(label) track=\(trackIdx) bankCh=\(bankChannel) note=\(String(format: "0x%02X", note))")
    }

    func healthCheck() async -> ChannelHealth {
        let active = await engine.isActive
        if active {
            return .healthy(detail: "CoreMIDI client active, virtual ports created")
        } else {
            return .unavailable("CoreMIDI client not initialized")
        }
    }
}
