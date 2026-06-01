import CoreMIDI
import Foundation

/// Actor wrapping CoreMIDI. Creates a virtual source (for sending MIDI to Logic Pro)
/// and a virtual destination (for receiving MIDI from Logic Pro).
actor MIDIEngine {
    private var client: MIDIClientRef = 0
    private var virtualSource: MIDIEndpointRef = 0
    private var virtualDestination: MIDIEndpointRef = 0
    private var isRunning = false

    /// Primary stream of inbound MIDI packets from Logic Pro via the virtual destination.
    /// Single-consumer. Most callers should use `subscribe()` instead so multiple actors
    /// (handshake, bank-state, future automation) can each get their own copy of events.
    let inboundMessages: AsyncStream<MIDIFeedback.Event>
    private let inboundContinuation: AsyncStream<MIDIFeedback.Event>.Continuation

    /// Fan-out: every continuation registered via `subscribe()` is also yielded each event.
    private var subscribers: [AsyncStream<MIDIFeedback.Event>.Continuation] = []

    /// Background task that drains `inboundMessages` and rebroadcasts to subscribers.
    private var fanOutTask: Task<Void, Never>?

    init() {
        let (stream, continuation) = AsyncStream<MIDIFeedback.Event>.makeStream()
        self.inboundMessages = stream
        self.inboundContinuation = continuation
    }

    deinit {
        inboundContinuation.finish()
        for sub in subscribers { sub.finish() }
    }

    /// Get a fresh subscriber stream. Each subscriber receives a copy of every inbound event
    /// after subscribe() returns. Use this from MCUHandshake, MCUBankState, etc., so multiple
    /// consumers don't compete for events from the single `inboundMessages` stream.
    func subscribe() -> AsyncStream<MIDIFeedback.Event> {
        let (stream, continuation) = AsyncStream<MIDIFeedback.Event>.makeStream()
        subscribers.append(continuation)
        return stream
    }

    // MARK: - Lifecycle

    /// Create the CoreMIDI client, virtual source, and virtual destination.
    func start() throws {
        guard !isRunning else { return }

        var status = noErr

        // Create client.
        let clientName = ServerConfig.virtualMIDISourceName as CFString
        status = MIDIClientCreateWithBlock(clientName, &client) { [weak self] notification in
            self?.handleMIDINotification(notification)
        }
        guard status == noErr else {
            throw MIDIEngineError.clientCreationFailed(status)
        }

        // Virtual source — data we send appears here for Logic to receive.
        let sourceName = ServerConfig.virtualMIDISourceName as CFString
        status = MIDISourceCreate(client, sourceName, &virtualSource)
        guard status == noErr else {
            throw MIDIEngineError.sourceCreationFailed(status)
        }

        // Virtual destination — Logic sends data here for us to receive.
        let sinkName = ServerConfig.virtualMIDISinkName as CFString
        let continuation = self.inboundContinuation
        status = MIDIDestinationCreateWithBlock(client, sinkName, &virtualDestination) { packetList, _ in
            let packets = packetList.pointee
            MIDIFeedback.parse(packetList: packets, into: continuation)
        }
        guard status == noErr else {
            throw MIDIEngineError.destinationCreationFailed(status)
        }

        isRunning = true

        // Start fan-out loop: every event from the receive callback goes through
        // inboundContinuation and gets rebroadcast to all subscribers here.
        let stream = inboundMessages
        fanOutTask = Task { [weak self] in
            for await event in stream {
                await self?.broadcast(event: event)
            }
        }

        Log.info("MIDIEngine started — source: \(ServerConfig.virtualMIDISourceName), sink: \(ServerConfig.virtualMIDISinkName)", subsystem: "midi")
    }

    private func broadcast(event: MIDIFeedback.Event) {
        for sub in subscribers {
            sub.yield(event)
        }
    }

    /// Tear down all CoreMIDI resources.
    func stop() {
        guard isRunning else { return }
        fanOutTask?.cancel()
        fanOutTask = nil
        for sub in subscribers { sub.finish() }
        subscribers.removeAll()
        if virtualSource != 0 { MIDIEndpointDispose(virtualSource) }
        if virtualDestination != 0 { MIDIEndpointDispose(virtualDestination) }
        if client != 0 { MIDIClientDispose(client) }
        virtualSource = 0
        virtualDestination = 0
        client = 0
        isRunning = false
        inboundContinuation.finish()
        Log.info("MIDIEngine stopped", subsystem: "midi")
    }

    var isActive: Bool { isRunning && client != 0 }

    // MARK: - Send: Notes

    func sendNoteOn(channel: UInt8 = 0, note: UInt8, velocity: UInt8 = 100) {
        let status: UInt8 = 0x90 | (channel & 0x0F)
        sendShortMessage([status, note & 0x7F, velocity & 0x7F])
    }

    func sendNoteOff(channel: UInt8 = 0, note: UInt8, velocity: UInt8 = 0) {
        let status: UInt8 = 0x80 | (channel & 0x0F)
        sendShortMessage([status, note & 0x7F, velocity & 0x7F])
    }

    // MARK: - Send: Control Change

    func sendCC(channel: UInt8 = 0, controller: UInt8, value: UInt8) {
        let status: UInt8 = 0xB0 | (channel & 0x0F)
        sendShortMessage([status, controller & 0x7F, value & 0x7F])
    }

    // MARK: - Send: Program Change

    func sendProgramChange(channel: UInt8 = 0, program: UInt8) {
        let status: UInt8 = 0xC0 | (channel & 0x0F)
        sendShortMessage([status, program & 0x7F])
    }

    // MARK: - Send: Pitch Bend

    /// Send pitch bend. `value` is 14-bit (0-16383), center = 8192.
    func sendPitchBend(channel: UInt8 = 0, value: UInt16 = 8192) {
        let clamped = min(value, 16383)
        let lsb = UInt8(clamped & 0x7F)
        let msb = UInt8((clamped >> 7) & 0x7F)
        let status: UInt8 = 0xE0 | (channel & 0x0F)
        sendShortMessage([status, lsb, msb])
    }

    // MARK: - Send: Aftertouch

    /// Channel pressure (mono aftertouch).
    func sendAftertouch(channel: UInt8 = 0, pressure: UInt8) {
        let status: UInt8 = 0xD0 | (channel & 0x0F)
        sendShortMessage([status, pressure & 0x7F])
    }

    /// Polyphonic key pressure.
    func sendPolyAftertouch(channel: UInt8 = 0, note: UInt8, pressure: UInt8) {
        let status: UInt8 = 0xA0 | (channel & 0x0F)
        sendShortMessage([status, note & 0x7F, pressure & 0x7F])
    }

    // MARK: - Send: SysEx

    /// Send a complete SysEx message (must start with 0xF0 and end with 0xF7).
    func sendSysEx(_ bytes: [UInt8]) {
        guard bytes.first == 0xF0, bytes.last == 0xF7 else {
            Log.error("Invalid SysEx: must start with F0 and end with F7", subsystem: "midi")
            return
        }
        sendRawBytes(bytes)
    }

    // MARK: - Send: Raw

    /// Send arbitrary MIDI bytes through the virtual source.
    func sendRawBytes(_ bytes: [UInt8]) {
        guard isRunning else {
            Log.warn("MIDIEngine not running — dropping message", subsystem: "midi")
            return
        }
        bytes.withUnsafeBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            var packetList = MIDIPacketList()
            var packet = MIDIPacketListInit(&packetList)
            packet = MIDIPacketListAdd(&packetList, MemoryLayout<MIDIPacketList>.size, packet, 0, bytes.count, baseAddress)
            let status = MIDIReceived(virtualSource, &packetList)
            if status != noErr {
                Log.error("MIDIReceived failed with status \(status)", subsystem: "midi")
            }
        }
    }

    // MARK: - Private

    private func sendShortMessage(_ bytes: [UInt8]) {
        sendRawBytes(bytes)
        Log.debug("MIDI out: \(bytes.map { String(format: "%02X", $0) }.joined(separator: " "))", subsystem: "midi")
    }

    private nonisolated func handleMIDINotification(_ notification: UnsafePointer<MIDINotification>) {
        let id = notification.pointee.messageID
        switch id {
        case .msgSetupChanged:
            Log.debug("MIDI setup changed", subsystem: "midi")
        case .msgObjectAdded:
            Log.debug("MIDI object added", subsystem: "midi")
        case .msgObjectRemoved:
            Log.debug("MIDI object removed", subsystem: "midi")
        default:
            Log.debug("MIDI notification: \(id.rawValue)", subsystem: "midi")
        }
    }
}

// MARK: - Errors

enum MIDIEngineError: Error, Sendable {
    case clientCreationFailed(OSStatus)
    case sourceCreationFailed(OSStatus)
    case destinationCreationFailed(OSStatus)
}
