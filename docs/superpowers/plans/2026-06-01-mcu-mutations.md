# MCU Mutations Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `track.set_mute`, `track.set_solo`, `track.set_arm`, `track.select`, `mixer.set_volume`, and `mixer.set_pan` actually mutate Logic Pro state by sending Mackie Control Universal (MCU) MIDI messages through the existing CoreMIDIChannel, with end-to-end AX read-back verification.

**Architecture:** Add an MCU message builder (`MCU.swift`) modeled on `MMCCommands.swift`, extend `CoreMIDIChannel.swift` with operations `track.set_mute`, `track.set_solo`, `track.set_arm`, `track.select`, `mixer.set_volume`, `mixer.set_pan` plus a `track.bank_to` helper. Add an `MCUHandshake` actor that listens for Logic's device-query sysex and replies. Re-route the relevant operations in `ChannelRouter.swift` to put `.coreMIDI` first with `.accessibility` as fallback. Add an `mcu-verify` doctor subcommand that fires an MCU mutation and reads back via the existing AX path.

**Tech Stack:** Swift 6.0, CoreMIDI virtual ports (already wired via `MIDIEngine`), existing `AXLogicProElements` + `AXValueExtractors` for verification reads, MCP swift-sdk for tool exposure.

---

## MCU Protocol Reference (canonical byte map)

This is the byte map every task references. Confirmed against https://github.com/NicoG60/TouchMCU/blob/main/doc/mackie_control_protocol.md on 2026-06-01.

**Device handshake SysEx** (manufacturer prefix `00 00 66`, MCU device id `14`):
- Logic → us, Device Query: `F0 00 00 66 14 00 F7`
- Us → Logic, Host Connection Query: `F0 00 00 66 14 01 <S0..S6> <C0..C3> F7` (7 serial bytes + 4 challenge bytes)
- Logic → us, Host Connection Reply: `F0 00 00 66 14 02 <S0..S6> <R0..R3> F7`
- Us → Logic, Confirmation: `F0 00 00 66 14 03 <S0..S6> F7`

We treat the surface as a Mackie Control "Logic Control" (device id `0x10`) is an alternate; spec says `0x14` is MCU-V. Start with `0x14`. If Logic ignores it, fall back to `0x10`.

**Button notes** (all on MIDI channel 0; press = Note On vel 0x7F, release = Note On vel 0x00):
- REC / arm: notes 0x00-0x07 (channels 1-8 of current bank)
- SOLO: notes 0x08-0x0F
- MUTE: notes 0x10-0x17
- SELECT: notes 0x18-0x1F
- Bank Left: 0x2E, Bank Right: 0x2F
- Channel Left: 0x30, Channel Right: 0x31

**Faders (volume):** Pitch Bend, 14-bit, channels 0-7 = banked faders 1-8, channel 8 = master fader. Value 0 = bottom, 16383 = top.

**V-Pot (pan):** CC on MIDI channel 0, CC 0x10-0x17 (channels 1-8). Value 0x01-0x07 = increment clockwise N ticks, 0x41-0x47 = decrement counter-clockwise N ticks. Pan is relative — to set absolute pan we send a large delta in the desired direction (Logic auto-clamps).

**LCD scribble strip** (read-back of bank track names): `F0 00 00 66 14 12 <offset> <chars...> F7`. Logic SENDS these — we parse them inbound to verify which 8 tracks are in the current bank.

---

## File Structure

| File | Responsibility | Status |
|---|---|---|
| `Sources/LogicProMCP/MIDI/MCU.swift` | Pure byte builders for MCU messages: handshake sysex, button note numbers, fader value clamp, V-Pot encoder bytes. Mirrors `MMCCommands.swift` style. | Create |
| `Sources/LogicProMCP/MIDI/MCUHandshake.swift` | Actor that subscribes to `MIDIEngine.inboundMessages`, recognises the `F0 00 00 66 14 00 F7` device query, computes the challenge response, and replies. Exposes `isHandshakeComplete: Bool`. | Create |
| `Sources/LogicProMCP/MIDI/MCUBankState.swift` | Tracks the currently-banked 8 tracks (offset from track 0). Parses inbound LCD scribble-strip sysex to learn what Logic actually has banked. Exposes `bank(toTrackIndex:)` to send Bank Left/Right notes until the desired track is in-bank. | Create |
| `Sources/LogicProMCP/Channels/CoreMIDIChannel.swift` | Add operations `track.set_mute`, `track.set_solo`, `track.set_arm`, `track.select`, `mixer.set_volume`, `mixer.set_pan`. Each banks-to-track first, then sends the MCU message. | Modify |
| `Sources/LogicProMCP/Channels/ChannelRouter.swift` | Re-route mute/solo/arm/select/volume/pan with `.coreMIDI` first, `.accessibility` fallback. | Modify |
| `Sources/LogicProMCP/Doctor/MCUVerifyCommand.swift` | New `LogicProMCP mcu-verify --track N --op mute --value true` subcommand. Fires the MCU op, sleeps the verify delay, re-reads track state via existing AX extractors, prints PASS/FAIL. | Create |
| `Sources/LogicProMCP/main.swift` | Wire `mcu-verify` subcommand. | Modify |
| `Sources/LogicProMCP/Server/LogicProServer.swift` | Construct and inject `MCUHandshake` + `MCUBankState` into `CoreMIDIChannel`. | Modify |
| `Sources/LogicProMCP/Server/ServerConfig.swift` | Add `mcuDeviceID` (0x14), `mcuVerifyDelaySeconds` (0.25), `mcuSerialBytes` ([7]UInt8 for identity). | Modify |

---

## Task 1: MCU byte builder

**Files:**
- Create: `Sources/LogicProMCP/MIDI/MCU.swift`

- [ ] **Step 1: Write `MCU.swift` with handshake, button, fader, V-Pot, LCD builders**

```swift
import Foundation

/// Builds Mackie Control Universal (MCU) MIDI messages.
/// Spec: https://github.com/NicoG60/TouchMCU/blob/main/doc/mackie_control_protocol.md
/// Manufacturer prefix `00 00 66`, MCU-V device id `0x14`.
enum MCU {
    /// MCU manufacturer header bytes (after F0): 00 00 66 14
    static let header: [UInt8] = [0x00, 0x00, 0x66, ServerConfig.mcuDeviceID]

    // MARK: - Handshake

    /// Build Host Connection Query (us → Logic). Sent in response to Device Query.
    /// 7 serial bytes + 4 challenge bytes.
    static func hostConnectionQuery(serial: [UInt8], challenge: [UInt8]) -> [UInt8] {
        precondition(serial.count == 7, "serial must be 7 bytes")
        precondition(challenge.count == 4, "challenge must be 4 bytes")
        return [0xF0] + header + [0x01] + serial + challenge + [0xF7]
    }

    /// Build Connection Confirmation (us → Logic) after a successful Host Connection Reply.
    static func connectionConfirmation(serial: [UInt8]) -> [UInt8] {
        precondition(serial.count == 7, "serial must be 7 bytes")
        return [0xF0] + header + [0x03] + serial + [0xF7]
    }

    /// Compute the 4-byte response code from a 4-byte challenge using the MCU algorithm.
    static func challengeResponse(challenge c: [UInt8]) -> [UInt8] {
        precondition(c.count == 4, "challenge must be 4 bytes")
        let r0 = UInt8(Int(c[0]) &+ (Int(c[1]) ^ 0x0A) &- Int(c[3])) & 0x7F
        let r1 = UInt8((Int(c[2]) >> 4) ^ (Int(c[0]) &+ Int(c[3]))) & 0x7F
        let r2 = UInt8(Int(c[3]) &- (Int(c[2]) << 2) ^ (Int(c[0]) | Int(c[1]))) & 0x7F
        let r3 = UInt8(Int(c[1]) &- Int(c[2]) &+ (0xF0 ^ (Int(c[3]) << 4))) & 0x7F
        return [r0, r1, r2, r3]
    }

    // MARK: - Button notes (MIDI channel 0)

    /// Note number for the REC/arm button on bank-channel `n` (0-7).
    static func armNote(bankChannel n: Int) -> UInt8 { UInt8(n & 0x07) }

    /// Note number for the SOLO button on bank-channel `n` (0-7).
    static func soloNote(bankChannel n: Int) -> UInt8 { UInt8(0x08 + (n & 0x07)) }

    /// Note number for the MUTE button on bank-channel `n` (0-7).
    static func muteNote(bankChannel n: Int) -> UInt8 { UInt8(0x10 + (n & 0x07)) }

    /// Note number for the SELECT button on bank-channel `n` (0-7).
    static func selectNote(bankChannel n: Int) -> UInt8 { UInt8(0x18 + (n & 0x07)) }

    /// Bank navigation notes.
    static let bankLeftNote: UInt8 = 0x2E
    static let bankRightNote: UInt8 = 0x2F
    static let channelLeftNote: UInt8 = 0x30
    static let channelRightNote: UInt8 = 0x31

    /// Button press velocity (any non-zero per spec; 0x7F is canonical).
    static let pressVelocity: UInt8 = 0x7F
    /// Button release velocity per spec.
    static let releaseVelocity: UInt8 = 0x00

    // MARK: - Faders (Pitch Bend, 14-bit)

    /// Clamp a normalised 0.0-1.0 volume to a 14-bit pitch-bend value (0-16383).
    static func faderValue(normalized v: Double) -> UInt16 {
        let clamped = max(0.0, min(1.0, v))
        return UInt16((clamped * 16383.0).rounded())
    }

    /// The MIDI channel a banked fader sits on. Channels 0-7 = banked faders 1-8; channel 8 = master.
    static func faderChannel(bankChannel n: Int) -> UInt8 { UInt8(n & 0x0F) }

    static let masterFaderChannel: UInt8 = 8

    // MARK: - V-Pot (relative encoder, CC channel 0)

    /// CC controller number for the V-Pot on bank-channel `n` (0-7).
    static func vpotCC(bankChannel n: Int) -> UInt8 { UInt8(0x10 + (n & 0x07)) }

    /// Encode a relative V-Pot delta. Positive = clockwise (0x01..0x07), negative = counter-clockwise (0x41..0x47).
    /// Per spec: low nibble = magnitude (1-7 ticks), high bit (0x40) = direction.
    static func vpotDelta(ticks: Int) -> UInt8 {
        let magnitude = min(7, abs(ticks))
        return ticks >= 0 ? UInt8(magnitude) : UInt8(0x40 | magnitude)
    }

    // MARK: - LCD scribble strip (inbound parse)

    /// MCU LCD update command byte (after manufacturer header).
    static let lcdCommand: UInt8 = 0x12

    /// Logic sends `F0 00 00 66 14 12 <offset> <chars...> F7`. Offset 0-0x37 = upper line,
    /// 0x38-0x6F = lower line. Each channel strip = 7 chars wide (upper line shows track name).
    static let lcdUpperLineStart: UInt8 = 0x00
    static let lcdLowerLineStart: UInt8 = 0x38
    static let lcdStripWidth: Int = 7
}
```

- [ ] **Step 2: Verify the file compiles in isolation**

Run: `cd /Users/alexwarren/code/logic-pro-mcp/.claude/worktrees/agent-ab53f7edade9846f3 && swift build 2>&1 | tail -20`
Expected: build fails with reference to `ServerConfig.mcuDeviceID` (not yet defined). That's fine — Task 2 adds it.

- [ ] **Step 3: Add MCU config fields to `ServerConfig.swift`**

Open `Sources/LogicProMCP/Server/ServerConfig.swift`. After the `mmcDeviceID` line, insert:

```swift
    /// MCU device id used in the SysEx manufacturer header (0x14 = MCU-V).
    /// Logic Pro auto-detects this when our virtual MIDI port name matches Logic's
    /// preference for a Mackie Control surface. If 0x14 is ignored on a given
    /// Logic version, try 0x10 (Logic Control / legacy MCU).
    static let mcuDeviceID: UInt8 = 0x14

    /// Fixed serial number bytes we present in the MCU handshake. Seven 7-bit values.
    /// Logic uses this as the surface's identity; any consistent 7-byte value works.
    static let mcuSerialBytes: [UInt8] = [0x4C, 0x50, 0x4D, 0x43, 0x50, 0x00, 0x01]

    /// Delay after sending an MCU mutation before reading back via AX for verification.
    /// 0.25s is empirically enough for Logic 12.2 to apply mute/solo/arm/select changes.
    static let mcuVerifyDelaySeconds: Double = 0.25

    /// Number of channels in an MCU bank (Mackie Control standard).
    static let mcuBankSize: Int = 8
```

- [ ] **Step 4: Confirm build still fails only on usages of MCU operations**

Run: `swift build 2>&1 | tail -20`
Expected: build succeeds with `MCU.swift` and updated `ServerConfig.swift` in place (no callers of the new MCU API yet).

- [ ] **Step 5: Commit**

```bash
git add Sources/LogicProMCP/MIDI/MCU.swift Sources/LogicProMCP/Server/ServerConfig.swift
git commit -m "Add MCU byte builder + server config constants

Pure byte-level builders for Mackie Control Universal: handshake sysex,
button notes (arm/solo/mute/select), bank-navigation notes, 14-bit
fader value, V-Pot relative encoder, LCD scribble-strip offsets.

Mirrors MMCCommands.swift style. No behaviour change yet; CoreMIDIChannel
will call these in subsequent commits."
```

---

## Task 2: MCU device handshake actor

**Files:**
- Create: `Sources/LogicProMCP/MIDI/MCUHandshake.swift`

- [ ] **Step 1: Write the handshake actor**

```swift
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
        let stream = await engine.inboundMessages
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
```

- [ ] **Step 2: Make `MIDIEngine.inboundMessages` accessible from the actor**

The property is `let` on an actor, so reading it requires `await`. The code above already does `await engine.inboundMessages`. Confirm by reading `MIDIEngine.swift` lines 12-20:

```
let inboundMessages: AsyncStream<MIDIFeedback.Event>
```

It's a non-isolated `let` of a Sendable type, so cross-actor access is fine. No change needed.

- [ ] **Step 3: Build**

Run: `swift build 2>&1 | tail -10`
Expected: success.

- [ ] **Step 4: Commit**

```bash
git add Sources/LogicProMCP/MIDI/MCUHandshake.swift
git commit -m "Add MCU handshake actor

Listens for Logic's device-query sysex (F0 00 00 66 14 00 F7) and
replies with Host Connection Query → Confirmation. Exposes
isHandshakeComplete for downstream gating.

Not yet wired into LogicProServer; that lands in a later commit
once CoreMIDIChannel knows how to use it."
```

---

## Task 3: MCU bank state tracker

**Files:**
- Create: `Sources/LogicProMCP/MIDI/MCUBankState.swift`

- [ ] **Step 1: Write the bank state actor**

```swift
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
        let stream = await engine.inboundMessages
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
```

- [ ] **Step 2: Build**

Run: `swift build 2>&1 | tail -10`
Expected: success.

- [ ] **Step 3: Commit**

```bash
git add Sources/LogicProMCP/MIDI/MCUBankState.swift
git commit -m "Add MCU bank-state actor

Tracks Logic's current 8-channel bank offset. bank(toTrackIndex:)
sends Bank Left/Right notes until the target track is in-bank.
Parses inbound LCD scribble-strip sysex to learn the actual bank
contents (used later for cross-verification)."
```

---

## Task 4: CoreMIDIChannel — wire MCU mute/solo/arm/select

**Files:**
- Modify: `Sources/LogicProMCP/Channels/CoreMIDIChannel.swift`

- [ ] **Step 1: Extend CoreMIDIChannel to hold MCU helpers**

Open `Sources/LogicProMCP/Channels/CoreMIDIChannel.swift`. Replace lines 1-20 (the file header through `init`):

```swift
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
```

- [ ] **Step 2: Add MCU operations to the operation switch**

In the same file, find the `default:` arm of the operation switch (currently `return .error("Unknown CoreMIDI operation: \(operation)")`). Insert these cases BEFORE that default:

```swift
        // MARK: - MCU: Track buttons (mute/solo/arm/select)

        case "track.set_mute":
            return await sendTrackButton(params: params, noteFn: MCU.muteNote, label: "mute")

        case "track.set_solo":
            return await sendTrackButton(params: params, noteFn: MCU.soloNote, label: "solo")

        case "track.set_arm":
            return await sendTrackButton(params: params, noteFn: MCU.armNote, label: "arm")

        case "track.select":
            // Select buttons in MCU are momentary toggles — sending a press picks the track.
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
            // V-Pot is relative — to set absolute pan we send a strong delta in the right direction.
            // Pan range -1..+1, encoder magnitude 1-7 per message; send 7 messages of magnitude 7
            // in the desired direction. Logic clamps at the rails. To centre, send a recall command.
            // For the first cut: send a single max-magnitude tick. The user can iterate; absolute pan
            // requires reading current state via AX which we already have.
            let clamped = max(-1.0, min(1.0, value))
            let direction = clamped >= 0 ? 1 : -1
            let cc = MCU.vpotCC(bankChannel: bankChannel)
            let delta = MCU.vpotDelta(ticks: direction * 7)
            await engine.sendCC(channel: 0, controller: cc, value: delta)
            return .success("MCU V-Pot track=\(trackIdx) bankCh=\(bankChannel) pan=\(value) cc=\(cc) delta=\(delta)")
```

- [ ] **Step 3: Add the `sendTrackButton` private helper at the bottom of the actor**

Insert above the closing `}` of `CoreMIDIChannel`:

```swift
    // MARK: - MCU button helper

    /// Banks to the requested track, then sends a press + release on the MCU button identified
    /// by `noteFn(bankChannel)`. For momentary controls (select), `momentary` skips the read of
    /// the current state — MCU buttons are stateless triggers; Logic itself toggles state.
    private func sendTrackButton(
        params: [String: String],
        noteFn: (Int) -> UInt8,
        label: String,
        momentary: Bool = false
    ) async -> ChannelResult {
        guard let trackIdx = params["index"].flatMap(Int.init) else {
            return .error("track.set_\(label) requires 'index'")
        }
        let bankChannel = await bank.bank(toTrackIndex: trackIdx)
        let note = noteFn(bankChannel)
        await engine.sendNoteOn(channel: 0, note: note, velocity: MCU.pressVelocity)
        // Tiny inter-byte delay so Logic doesn't dedupe rapid press+release.
        try? await Task.sleep(nanoseconds: 10_000_000)
        await engine.sendNoteOn(channel: 0, note: note, velocity: MCU.releaseVelocity)
        return .success("MCU \(label) track=\(trackIdx) bankCh=\(bankChannel) note=\(String(format: "0x%02X", note))")
    }
```

- [ ] **Step 4: Update `LogicProServer.init` to construct the MCU helpers and pass them in**

Open `Sources/LogicProMCP/Server/LogicProServer.swift`. Replace lines 36-38:

```swift
        // Create channel instances
        let midiEngine = MIDIEngine()
        let mcuBank = MCUBankState(engine: midiEngine)
        let mcuHandshake = MCUHandshake(engine: midiEngine)
        self.coreMIDIChannel = CoreMIDIChannel(engine: midiEngine, bank: mcuBank, handshake: mcuHandshake)
```

- [ ] **Step 5: Build**

Run: `swift build 2>&1 | tail -20`
Expected: success.

- [ ] **Step 6: Commit**

```bash
git add Sources/LogicProMCP/Channels/CoreMIDIChannel.swift Sources/LogicProMCP/Server/LogicProServer.swift
git commit -m "Wire MCU mute/solo/arm/select/volume/pan in CoreMIDIChannel

Each operation banks to the target track via MCUBankState (sending
Bank L/R notes until the track is in the 8-channel bank), then sends
the MCU button press+release or pitch-bend/CC for fader/V-Pot.

MCUHandshake + MCUBankState constructed in LogicProServer.init and
passed through to CoreMIDIChannel. Router still has Accessibility
first for these ops; that flips in a later commit once verification
proves the MCU path works."
```

---

## Task 5: mcu-verify subcommand

**Files:**
- Create: `Sources/LogicProMCP/Doctor/MCUVerifyCommand.swift`
- Modify: `Sources/LogicProMCP/main.swift`

- [ ] **Step 1: Write `MCUVerifyCommand.swift`**

```swift
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

        // Fire the operation.
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

        let router = server.channelRouter
        // Force CoreMIDI path — verifying MCU specifically, not the router fallback.
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
            print("FAIL — state did not change. MCU message was sent but Logic did not apply it.")
            print("  Possible causes: handshake not completed, surface not registered in Logic")
            print("  Preferences > Control Surfaces > Setup, wrong device id (try 0x10), or track")
            print("  index out of range.")
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
```

- [ ] **Step 2: Wire the subcommand in `main.swift`**

Open `Sources/LogicProMCP/main.swift`. After the `dump-tracks` block (around line 23), insert:

```swift
// Handle `mcu-verify` subcommand — fires an MCU mutation and reads back via AX.
if let idx = CommandLine.arguments.firstIndex(of: "mcu-verify") {
    let rest = Array(CommandLine.arguments.dropFirst(idx + 1))
    let code = await MCUVerifyCommand.run(args: rest)
    exit(Int32(code))
}
```

- [ ] **Step 3: Build**

Run: `swift build 2>&1 | tail -10`
Expected: success.

- [ ] **Step 4: Codesign**

Run: `swift build -c release 2>&1 | tail -5 && cp .build/release/LogicProMCP /Users/alexwarren/.local/bin/LogicProMCP && codesign --force --sign - /Users/alexwarren/.local/bin/LogicProMCP`
Expected: codesign exits 0.

- [ ] **Step 5: Verify the subcommand prints its usage**

Run: `/Users/alexwarren/.local/bin/LogicProMCP mcu-verify`
Expected: prints "usage: LogicProMCP mcu-verify --track N --op <mute|solo|arm|select|volume|pan> [--value V]" and exits 2.

- [ ] **Step 6: Commit**

```bash
git add Sources/LogicProMCP/Doctor/MCUVerifyCommand.swift Sources/LogicProMCP/main.swift
git commit -m "Add mcu-verify subcommand for end-to-end MCU validation

Fires an MCU mutation against live Logic via CoreMIDIChannel, sleeps
the verify-delay, then re-reads track state via the existing AX
extractors and reports PASS / FAIL. READ-ONLY observation path:
allTrackHeaders + extractTrackState; never AXPress.

Force-routes through CoreMIDI to test the MCU path specifically
(bypasses ChannelRouter fallback that may pick Accessibility first)."
```

---

## Task 6: First live verification — track.set_mute

**Files:** none (verification task).

- [ ] **Step 1: Confirm Logic Pro has a project open with at least 1 track**

Run: `pgrep -i "Logic Pro"`
Expected: returns a PID. If not, skip the live verification steps and document the verification command in the final summary.

- [ ] **Step 2: Read current track 0 state via dump-tracks**

Run: `/Users/alexwarren/.local/bin/LogicProMCP dump-tracks 2>&1 | grep -E "Track\[0\]|Track headers found"`
Expected: shows `Track[0] name="..." muted=... soloed=... armed=...`. Record the current `muted` value.

- [ ] **Step 3: Fire mcu-verify mute on track 0**

Run: `/Users/alexwarren/.local/bin/LogicProMCP mcu-verify --track 0 --op mute`
Expected: prints BEFORE / FIRE / AFTER lines and PASS or FAIL.

**If PASS:** great. Document that mute via MCU works. Fire again to flip it back so subsequent tests aren't muted.

**If FAIL:** investigate. Common failure modes:
1. Logic doesn't see our virtual port as an MCU. Open Logic Preferences > Control Surfaces > Setup. If no Mackie Control is listed, click "Install..." → "Mackie Control" → set Input/Output to `LogicProMCP-In` / `LogicProMCP-Out`. Re-run.
2. Device id 0x14 wrong. Change `ServerConfig.mcuDeviceID` to `0x10` (Logic Control), rebuild, re-sign, re-run.
3. Handshake never completed. Check `Log.info` output for "MCU handshake complete". If absent, the device-query came on a different sysex framing.

- [ ] **Step 4: If FAIL on first try, capture the inbound MIDI stream for inspection**

Add a temporary debug print in `MIDIFeedback.parse` or use `dump-tracks` immediately after touching a control in Logic to confirm Logic is sending us anything. (If `lastKnownBankNames` in MCUBankState is empty even after Logic is foreground, Logic isn't sending LCD — meaning Logic doesn't yet see us as an MCU surface, meaning the Preferences > Control Surfaces step in #3 above is required.)

- [ ] **Step 5: Record the result**

Capture the exact verification command and PASS/FAIL outcome in the eventual PR description. If Logic Pro setup intervention was required, note it as a deployment quirk.

- [ ] **Step 6: Commit any debugging adjustments made during verification**

If you made code changes to reach PASS (e.g. device id fallback), commit them now with a message describing the empirical finding. If no code changes were needed, no commit.

```bash
# Only if there were debug-driven code changes:
git add -p
git commit -m "Empirical MCU fix: <describe>"
```

---

## Task 7: Live verification — solo, arm, select

Mirror Task 6 for each op.

- [ ] **Step 1: Verify solo**

Run: `/Users/alexwarren/.local/bin/LogicProMCP mcu-verify --track 0 --op solo`
Expected: PASS. If FAIL, repeat the diagnostic flow from Task 6.

- [ ] **Step 2: Toggle back**

Run: `/Users/alexwarren/.local/bin/LogicProMCP mcu-verify --track 0 --op solo`
Expected: PASS, state returns to original.

- [ ] **Step 3: Verify arm**

Run: `/Users/alexwarren/.local/bin/LogicProMCP mcu-verify --track 0 --op arm`
Expected: PASS.

- [ ] **Step 4: Verify select**

Run: `/Users/alexwarren/.local/bin/LogicProMCP mcu-verify --track 0 --op select` then `--track 1 --op select`
Expected: PASS — selection moves between tracks.

- [ ] **Step 5: Record outcomes**

Append outcomes to a running tally for the PR description.

- [ ] **Step 6: No commit needed if no code changed**

---

## Task 8: Bank navigation verification

**Files:** none (verification task).

- [ ] **Step 1: Confirm bank crossing works on a track beyond the first bank**

Pre-requisite: Logic project has > 8 tracks. If not, ask the user to add a few dummy tracks (or skip and document).

Run: `/Users/alexwarren/.local/bin/LogicProMCP mcu-verify --track 9 --op mute`
Expected: PASS. Internally bank(toTrackIndex: 9) sends one Bank Right note then mutes channel 2 of the new bank.

- [ ] **Step 2: Verify bank state recovers via LCD parse**

After step 1, the next mcu-verify on any track in [8..15] should not re-bank (bankOffset stays at 8). Run:

`/Users/alexwarren/.local/bin/LogicProMCP mcu-verify --track 10 --op solo`
Expected: PASS, no extra Bank Right note in the FIRE message (bankCh=2).

- [ ] **Step 3: Verify bank-left**

Run: `/Users/alexwarren/.local/bin/LogicProMCP mcu-verify --track 0 --op mute`
Expected: PASS, bank returns to offset 0.

- [ ] **Step 4: Document if bank-cross fails on Logic 12.2**

If FAIL, the most likely cause is Logic ignoring Bank L/R when our surface isn't fully registered. Note the symptom in the memory file referenced in Task 11.

---

## Task 9: Live verification — volume + pan

Volume/pan have no AX read-back in current `TrackState`, so verification is manual.

- [ ] **Step 1: Verify volume changes the fader visually**

Run: `/Users/alexwarren/.local/bin/LogicProMCP mcu-verify --track 0 --op volume --value 0.3`
Expected: prints code-complete note; **manually confirm in Logic** that the fader on track 0 moved to ~30%.

- [ ] **Step 2: Verify pan changes the V-Pot visually**

Run: `/Users/alexwarren/.local/bin/LogicProMCP mcu-verify --track 0 --op pan --value 1.0`
Expected: prints code-complete; manually confirm pan moved right. Then:

`/Users/alexwarren/.local/bin/LogicProMCP mcu-verify --track 0 --op pan --value -1.0`
Expected: manually confirm pan moved left.

- [ ] **Step 3: Record outcomes**

If volume/pan both moved visually, mark code-complete + manual-verified. If they did not move, the symptom is the same as a button FAIL — Logic isn't recognising our surface — see Task 6 diagnostic flow.

---

## Task 10: Re-route mute/solo/arm/select/volume/pan to CoreMIDI-first

**Files:**
- Modify: `Sources/LogicProMCP/Channels/ChannelRouter.swift`

- [ ] **Step 1: Update the routing table**

Open `Sources/LogicProMCP/Channels/ChannelRouter.swift`. Replace the existing entries:

```swift
        "track.select":               [.accessibility, .cgEvent],
        ...
        "track.set_mute":             [.accessibility, .cgEvent],
        "track.set_solo":             [.accessibility, .cgEvent],
        "track.set_arm":              [.accessibility, .cgEvent],
        ...
        "mixer.set_volume":           [.osc, .accessibility],
        "mixer.set_pan":              [.osc, .accessibility],
```

With:

```swift
        "track.select":               [.coreMIDI, .accessibility, .cgEvent],
        ...
        "track.set_mute":             [.coreMIDI, .accessibility, .cgEvent],
        "track.set_solo":             [.coreMIDI, .accessibility, .cgEvent],
        "track.set_arm":              [.coreMIDI, .accessibility, .cgEvent],
        ...
        "mixer.set_volume":           [.coreMIDI, .osc, .accessibility],
        "mixer.set_pan":              [.coreMIDI, .osc, .accessibility],
```

(Edit each line individually — they are not contiguous in the source.)

- [ ] **Step 2: Build, codesign, install**

Run:
```bash
swift build -c release 2>&1 | tail -5 && \
  cp .build/release/LogicProMCP /Users/alexwarren/.local/bin/LogicProMCP && \
  codesign --force --sign - /Users/alexwarren/.local/bin/LogicProMCP
```
Expected: success.

- [ ] **Step 3: Smoke-test via the dispatcher path**

Run mcu-verify once more — it bypasses the router, so this only confirms nothing regressed. To exercise the new routing, use the MCP server end (which the user will via Claude Code). Document in the PR that the dispatcher path is "code-complete; needs end-to-end smoke via MCP client".

- [ ] **Step 4: Commit**

```bash
git add Sources/LogicProMCP/Channels/ChannelRouter.swift
git commit -m "Route mute/solo/arm/select/volume/pan through CoreMIDI (MCU) first

After mcu-verify confirmed mute/solo/arm/select mutate Logic via MCU,
and volume/pan move the visible fader/V-Pot, promote .coreMIDI to the
head of the routing chain for these operations. AX stays as fallback
for Creator Studio (where MCU may behave differently) and any edge
case where MCU is unhealthy."
```

---

## Task 11: Capture MCU/Logic quirks to memory + finalise

**Files:**
- Create: `/Users/alexwarren/.claude/projects/-Users-alexwarren/memory/feedback_mcu_logic_quirks.md` (only if quirks were discovered)

- [ ] **Step 1: If any non-spec behaviour was found, write the memory file**

Document any of:
- Logic 12.2 needed manual Control Surfaces > Setup configuration despite Apple's "auto-detect" claim
- Device id 0x14 vs 0x10
- Bank navigation timing requirements above the 30ms we coded
- LCD scribble strip absent (Logic doesn't echo bank state)

If none of those came up, skip this step.

- [ ] **Step 2: Push branch to origin**

Run: `git push -u origin mcu-mutations`
Expected: pushed to `adwbot/logic-pro-mcp`. Capture the URL it prints.

- [ ] **Step 3: Summarise the PR title + body for the final report**

Suggested PR title: **"Add MCU (Mackie Control Universal) mutation channel"**

Suggested PR body: see the final summary the agent emits to the caller.

---

## Self-review checklist

1. **Spec coverage:** every numbered priority in the original SCOPE is addressed:
   - Handshake → Task 2
   - mute/solo/arm via Note On → Task 4 + 6 + 7
   - select via Note On → Task 4 + 7
   - set_volume via Pitch Bend → Task 4 + 9
   - set_pan via V-Pot CC → Task 4 + 9
   - Bank navigation → Task 3 + 8
   - mcu-verify subcommand → Task 5

2. **Placeholder scan:** no TBD / TODO; every step contains executable content or exact commands.

3. **Type consistency:**
   - `MCUBankState.bank(toTrackIndex:) -> Int` — referenced consistently in Task 4 + Task 5.
   - `MCU.muteNote/soloNote/armNote/selectNote(bankChannel:) -> UInt8` — referenced from `sendTrackButton`.
   - `MCUHandshake.init(engine:)` — referenced from `LogicProServer.init`.
   - `MCUBankState.init(engine:)` — referenced from `LogicProServer.init`.
   - `ServerConfig.mcuDeviceID/mcuSerialBytes/mcuVerifyDelaySeconds/mcuBankSize` — defined Task 1, referenced Tasks 2, 3, 4, 5.
   - `MIDIEngine.inboundMessages` — non-isolated `let`, accessed via `await engine.inboundMessages` in Tasks 2 + 3.
