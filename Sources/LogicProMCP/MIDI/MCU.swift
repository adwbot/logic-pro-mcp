import Foundation

/// Builds Mackie Control Universal (MCU) MIDI messages.
/// Spec: https://github.com/NicoG60/TouchMCU/blob/main/doc/mackie_control_protocol.md
/// Manufacturer prefix `00 00 66`, MCU-V device id `0x14`.
enum MCU {
    /// MCU manufacturer header bytes (after F0): 00 00 66 14
    static var header: [UInt8] { [0x00, 0x00, 0x66, ServerConfig.mcuDeviceID] }

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
    /// Note: this is the response Logic computes; we use it locally only if we want to
    /// verify Logic's reply matches the expected derivation of our challenge.
    static func challengeResponse(challenge c: [UInt8]) -> [UInt8] {
        precondition(c.count == 4, "challenge must be 4 bytes")
        let r0 = UInt8(truncatingIfNeeded: Int(c[0]) &+ (Int(c[1]) ^ 0x0A) &- Int(c[3])) & 0x7F
        let r1 = UInt8(truncatingIfNeeded: (Int(c[2]) >> 4) ^ (Int(c[0]) &+ Int(c[3]))) & 0x7F
        let r2 = UInt8(truncatingIfNeeded: Int(c[3]) &- (Int(c[2]) << 2) ^ (Int(c[0]) | Int(c[1]))) & 0x7F
        let r3 = UInt8(truncatingIfNeeded: Int(c[1]) &- Int(c[2]) &+ (0xF0 ^ (Int(c[3]) << 4))) & 0x7F
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
