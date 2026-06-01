import Foundation

/// Listens for Logic Pro's MCU device-query sysex and replies through the MIDI engine.
/// Logic sends `F0 00 00 66 14 00 F7` shortly after detecting our virtual surface;
/// we respond with a Host Connection Query, then await its Host Connection Reply
/// and finalise with a Connection Confirmation.
actor MCUHandshake {
    private let engine: MIDIEngine
    private var handshakeDone = false
    private var listenerTask: Task<Void, Never>?

    init(engine: MIDIEngine) {
        self.engine = engine
    }

    var isHandshakeComplete: Bool { handshakeDone }

    /// Begin listening for inbound MCU sysex. Idempotent.
    func start() async {
        guard listenerTask == nil else { return }
        let stream = await engine.subscribe()
        listenerTask = Task { [weak self] in
            for await event in stream {
                await self?.handle(event: event)
            }
        }
    }

    /// Stop listening.
    func stop() {
        listenerTask?.cancel()
        listenerTask = nil
    }

    /// Force the handshake to be considered complete (used by tests / mcu-verify when
    /// Logic has already cached the surface and won't re-query on reconnect).
    func markHandshakeComplete() {
        handshakeDone = true
    }

    // MARK: - Private

    private func handle(event: MIDIFeedback.Event) async {
        guard case .sysEx(let bytes) = event else { return }
        // MCU sysex: F0 00 00 66 <devId> <cmd> ... F7
        guard bytes.count >= 7,
              bytes[0] == 0xF0,
              bytes[1] == 0x00,
              bytes[2] == 0x00,
              bytes[3] == 0x66,
              ServerConfig.mcuAcceptedDeviceIDs.contains(bytes[4]) else {
            return
        }
        let devId = bytes[4]
        let cmd = bytes[5]
        switch cmd {
        case 0x00:
            // Device Query → respond with Host Connection Query, mirroring Logic's device id.
            let challenge: [UInt8] = [0x12, 0x34, 0x56, 0x78]
            var msg: [UInt8] = [0xF0, 0x00, 0x00, 0x66, devId, 0x01]
            msg += ServerConfig.mcuSerialBytes
            msg += challenge
            msg.append(0xF7)
            await engine.sendSysEx(msg)
            Log.info("MCU device query (devId=\(String(format: "0x%02X", devId))); sent host connection query", subsystem: "mcu")
        case 0x02:
            // Host Connection Reply (Logic → us): F0 00 00 66 <devId> 02 <S0..S6> <R0..R3> F7
            // We sent a known challenge so the response is predictable; treat any reply with
            // the correct framing as success and reply with confirmation in kind.
            var msg: [UInt8] = [0xF0, 0x00, 0x00, 0x66, devId, 0x03]
            msg += ServerConfig.mcuSerialBytes
            msg.append(0xF7)
            await engine.sendSysEx(msg)
            handshakeDone = true
            Log.info("MCU handshake complete (devId=\(String(format: "0x%02X", devId)))", subsystem: "mcu")
        default:
            // Other MCU sysex (LCD, meters, etc.) — ignored here; MCUBankState handles LCD.
            Log.debug("MCU sysex devId=\(String(format: "0x%02X", devId)) cmd=\(String(format: "0x%02X", cmd))", subsystem: "mcu")
        }
    }
}
