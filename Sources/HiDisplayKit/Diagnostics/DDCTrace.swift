import Foundation

/// A raw DDC/CI conversation with one display, recorded for the support report.
///
/// The brightness probe only says "supported" or not. When a customer's monitor does not respond,
/// that is not enough to tell the three causes apart, and each has a different remedy:
///
/// * the Mac cannot reach the monitor's I2C bus at all (port, cable, dock) — every frame errors;
/// * the monitor hears the request and declines it (DDC/CI off in its menu) — null messages;
/// * the monitor answers reads and silently ignores writes (HDR locks brightness on Dell, or a
///   frame dropped for arriving too soon) — only a write followed by a read-back shows this.
///
/// So the trace records every frame as bytes, and nudges brightness by one raw step to see whether
/// the change is still there when read back. The step is restored before returning.
public struct DDCTrace: Codable, Sendable, Equatable {

    public struct Step: Codable, Sendable, Equatable {
        /// What was attempted, e.g. `get brightness (withHostAddress)`.
        public var action: String
        /// Bytes handed to the transport, as hex.
        public var sent: String?
        /// Bytes read back, as hex. `nil` for a write, or when the read itself failed.
        public var received: String?
        /// `42/100` for a decoded reply, `ok` for a write that returned success, else the error.
        public var outcome: String
        public var milliseconds: Int
    }

    public enum Verdict: String, Codable, Sendable {
        /// No I2C service could be bound for this display; `bindFailure` says why.
        case noTransport
        /// Bound, but every frame failed with an I/O error or timeout: nothing on the bus answers.
        case noReply
        /// The monitor answered with the null message in both frame shapes — DDC/CI is most likely
        /// switched off in its menu.
        case nullReply
        /// The nudged value was read back: reads and writes both work.
        case writeAccepted
        /// The monitor reported the old value after the write: it is ignoring brightness commands.
        case writeIgnored
        /// The first read worked but the read-back did not, so the write could not be judged.
        case readbackFailed
    }

    /// One conversation, independent of where the transport came from.
    public struct Conversation: Codable, Sendable, Equatable {
        public var steps: [Step]
        public var verdict: Verdict
        /// The frame shape that got a reply, if any did.
        public var answeredShape: DDC.FrameShape?
    }

    public var stableKey: String
    /// Why no I2C service could be bound. `nil` when one was.
    public var bindFailure: String?
    /// I2C chip address in use, as hex (`0x37`, or `0xb7` behind an MCDP29xx bridge).
    public var chipAddress: String?
    public var behindMCDP29xxBridge: Bool
    /// How the display is connected, as the registry describes it (`Upstream`, `Downstream`, …).
    public var link: [String: String]
    public var steps: [Step]
    public var verdict: Verdict
    public var answeredShape: DDC.FrameShape?
}

/// Runs the conversation recorded in a `DDCTrace`.
///
/// Byte-level and transport-agnostic, so every branch is testable against a fake monitor. The caller
/// must hold the display's bus for the duration — see `DDCCommandQueue.withExclusiveBus`.
public enum DDCTracer {

    /// Between a write and the read that checks it. Longer than `DDC.writeInterval`: this is a
    /// one-off measurement, and a read-back taken too soon would blame the monitor for our haste.
    static let settle: Duration = .milliseconds(100)

    /// Nothing is written unless a read succeeded first: without the current value there is nothing
    /// safe to send, and a report that changes the backlight for good is one people stop exporting.
    /// A link that carries requests but not replies still shows up — each failed step says which
    /// half failed.
    public static func run(on transport: DDCTransport) async -> DDCTrace.Conversation {
        var steps: [DDCTrace.Step] = []
        var answered: (shape: DDC.FrameShape, reply: VCPCodec.Reply)?
        var sawNullMessage = false

        for shape in DDC.FrameShape.allCases {
            let attempt = await get(shape, on: transport)
            steps.append(attempt.step)
            sawNullMessage = sawNullMessage || attempt.isNullMessage
            if let reply = attempt.reply {
                answered = (shape, reply)
                break
            }
            try? await Task.sleep(for: DDC.writeInterval)
        }

        guard let (shape, before) = answered else {
            return DDCTrace.Conversation(
                steps: steps, verdict: sawNullMessage ? .nullReply : .noReply, answeredShape: nil)
        }

        // One raw step is the smallest change a read-back can distinguish, and too small to see.
        let nudged = before.current < before.maximum ? before.current + 1 : before.current - 1
        steps.append(await set(nudged, shape, on: transport, label: "set"))
        try? await Task.sleep(for: settle)
        let after = await get(shape, on: transport)
        steps.append(after.step)

        // Restored unconditionally: a failed read-back says nothing about whether the write landed.
        steps.append(await set(before.current, shape, on: transport, label: "restore"))
        try? await Task.sleep(for: settle)
        steps.append(await get(shape, on: transport).step)

        let verdict: DDCTrace.Verdict
        switch after.reply?.current {
        case .none: verdict = .readbackFailed
        case .some(nudged): verdict = .writeAccepted
        case .some: verdict = .writeIgnored
        }
        return DDCTrace.Conversation(steps: steps, verdict: verdict, answeredShape: shape)
    }

    private static func get(
        _ shape: DDC.FrameShape, on transport: DDCTransport
    ) async -> (step: DDCTrace.Step, reply: VCPCodec.Reply?, isNullMessage: Bool) {
        let frame = VCPCodec.getRequest(code: .brightness, shape: shape)
        let started = ContinuousClock.now
        var step = DDCTrace.Step(
            action: "get brightness (\(shape.rawValue))", sent: hex(frame), received: nil,
            outcome: "", milliseconds: 0)
        var reply: VCPCodec.Reply?
        var isNullMessage = false
        do {
            do {
                try await transport.write(frame)
            } catch {
                throw Failure(half: "request", error: error)
            }
            try? await Task.sleep(for: DDC.replyDelay)
            let bytes: [UInt8]
            do {
                bytes = try await transport.read(length: VCPCodec.replyLength)
            } catch {
                throw Failure(half: "reply", error: error)
            }
            step.received = hex(bytes)
            // Tolerant, so a monitor that miscomputes its checksum still shows its value here — the
            // mismatch is reported alongside rather than hiding the reading.
            let decoded = try VCPCodec.decodeReply(
                bytes, expecting: .brightness, tolerateChecksumMismatch: true)
            reply = decoded
            step.outcome = "\(decoded.current)/\(decoded.maximum)"
                + (decoded.checksumValid ? "" : " (reply checksum wrong)")
        } catch let error as VCPCodec.DecodeError {
            isNullMessage = error == .nullMessage
            step.outcome = "\(error)"
        } catch let failure as Failure {
            step.outcome = "\(failure.half) failed: \(failure.error)"
        } catch {
            step.outcome = "\(error)"
        }
        step.milliseconds = milliseconds(since: started)
        return (step, reply, isNullMessage)
    }

    /// Which half of a get transaction failed. The request going out while the reply never comes is
    /// a different fault from a bus that refuses both, and the transport's error alone does not say.
    private struct Failure: Error {
        let half: String
        let error: Error
    }

    private static func set(
        _ value: UInt16, _ shape: DDC.FrameShape, on transport: DDCTransport, label: String
    ) async -> DDCTrace.Step {
        let frame = VCPCodec.setRequest(code: .brightness, value: value, shape: shape)
        let started = ContinuousClock.now
        var outcome = "ok"
        do {
            try await transport.write(frame)
        } catch {
            outcome = "\(error)"
        }
        return DDCTrace.Step(
            action: "\(label) brightness \(value) (\(shape.rawValue))", sent: hex(frame),
            received: nil, outcome: outcome, milliseconds: milliseconds(since: started))
    }

    static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    private static func milliseconds(since start: ContinuousClock.Instant) -> Int {
        let elapsed = start.duration(to: .now).components
        return Int(elapsed.seconds) * 1000 + Int(elapsed.attoseconds / 1_000_000_000_000_000)
    }
}
