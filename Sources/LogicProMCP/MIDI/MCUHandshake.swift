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
        let stream = engine.inboundMessages
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
        // MCU sysex: F0 00 00 66 14 <cmd> ... F7
        guard bytes.count >= 7,
              bytes[0] == 0xF0,
              bytes[1] == 0x00,
              bytes[2] == 0x00,
              bytes[3] == 0x66,
              bytes[4] == ServerConfig.mcuDeviceID else {
            return
        }
        let cmd = bytes[5]
        switch cmd {
        case 0x00:
            // Device Query → respond with Host Connection Query.
            let challenge: [UInt8] = [0x12, 0x34, 0x56, 0x78]
            let msg = MCU.hostConnectionQuery(serial: ServerConfig.mcuSerialBytes, challenge: challenge)
            await engine.sendSysEx(msg)
            Log.info("MCU device query received; sent host connection query", subsystem: "mcu")
        case 0x02:
            // Host Connection Reply (Logic → us): F0 00 00 66 14 02 <S0..S6> <R0..R3> F7
            // We sent a known challenge so the response is predictable; treat any reply with
            // the correct framing as success.
            await engine.sendSysEx(MCU.connectionConfirmation(serial: ServerConfig.mcuSerialBytes))
            handshakeDone = true
            Log.info("MCU handshake complete", subsystem: "mcu")
        default:
            // Other MCU sysex (LCD, meters, etc.) — ignored here; MCUBankState handles LCD.
            break
        }
    }
}
