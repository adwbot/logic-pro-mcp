import Foundation

/// Tracks which 8 tracks are currently visible in Logic's MCU bank.
///
/// MCU only addresses 8 channels at a time. To mutate track N we must first
/// send Bank Left / Bank Right notes until N is in-bank, then address it via
/// `bankChannel = N - bankOffset`.
///
/// We learn Logic's actual bank position by parsing inbound LCD scribble-strip
/// sysex (`F0 00 00 66 14 12 <offset> <chars> F7`) — Logic transmits this whenever
/// the bank changes. Until we've observed one, we assume bank offset 0.
actor MCUBankState {
    private let engine: MIDIEngine
    private(set) var bankOffset: Int = 0
    /// Most-recently-decoded scribble strip names (length up to 8).
    private(set) var lastKnownBankNames: [String] = []
    private var listenerTask: Task<Void, Never>?

    init(engine: MIDIEngine) {
        self.engine = engine
    }

    /// Start parsing inbound LCD sysex.
    func start() async {
        guard listenerTask == nil else { return }
        let stream = engine.inboundMessages
        listenerTask = Task { [weak self] in
            for await event in stream {
                await self?.handle(event: event)
            }
        }
    }

    func stop() {
        listenerTask?.cancel()
        listenerTask = nil
    }

    /// Send Bank Left/Right messages until `trackIndex` is within the current bank.
    /// Returns the bank-channel (0-7) the track now sits on.
    ///
    /// Logic doesn't echo a "bank changed" confirmation as a single event — it sends a
    /// fresh LCD update. We optimistically update `bankOffset` here, then let the LCD
    /// parser correct it if Logic actually settled somewhere else (e.g. clamped at the
    /// end of the track list).
    func bank(toTrackIndex trackIndex: Int) async -> Int {
        guard trackIndex >= 0 else { return 0 }
        let bankSize = ServerConfig.mcuBankSize
        while trackIndex < bankOffset {
            await engine.sendNoteOn(channel: 0, note: MCU.bankLeftNote, velocity: MCU.pressVelocity)
            await engine.sendNoteOn(channel: 0, note: MCU.bankLeftNote, velocity: MCU.releaseVelocity)
            bankOffset = max(0, bankOffset - bankSize)
            try? await Task.sleep(nanoseconds: 30_000_000) // 30ms — give Logic time to apply
        }
        while trackIndex >= bankOffset + bankSize {
            await engine.sendNoteOn(channel: 0, note: MCU.bankRightNote, velocity: MCU.pressVelocity)
            await engine.sendNoteOn(channel: 0, note: MCU.bankRightNote, velocity: MCU.releaseVelocity)
            bankOffset += bankSize
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        return trackIndex - bankOffset
    }

    // MARK: - Private

    private func handle(event: MIDIFeedback.Event) async {
        guard case .sysEx(let bytes) = event else { return }
        // LCD update: F0 00 00 66 14 12 <offset> <chars...> F7
        guard bytes.count >= 8,
              bytes[0] == 0xF0,
              bytes[1] == 0x00,
              bytes[2] == 0x00,
              bytes[3] == 0x66,
              bytes[4] == ServerConfig.mcuDeviceID,
              bytes[5] == MCU.lcdCommand,
              bytes.last == 0xF7 else {
            return
        }
        let offset = bytes[6]
        // Only re-derive bank names from upper-line writes covering the full row.
        guard offset == MCU.lcdUpperLineStart else { return }
        let payload = Array(bytes[7..<(bytes.count - 1)])
        let chars = payload.compactMap { byte -> Character? in
            byte < 0x80 ? Character(UnicodeScalar(byte)) : nil
        }
        let line = String(chars)
        let stripWidth = MCU.lcdStripWidth
        var names: [String] = []
        var i = line.startIndex
        while i < line.endIndex {
            let end = line.index(i, offsetBy: stripWidth, limitedBy: line.endIndex) ?? line.endIndex
            names.append(String(line[i..<end]).trimmingCharacters(in: .whitespaces))
            i = end
        }
        lastKnownBankNames = names
    }
}
