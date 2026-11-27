import XCTest
@testable import HiDisplayKit

/// The support trace has to tell apart the faults that look identical from the slider: a monitor
/// that cannot be reached, one that declines, and one that answers reads while ignoring writes.
final class DDCTraceTests: XCTestCase {

    /// A monitor with a brightness register, and the ways real ones misbehave.
    private final class SimulatedMonitor: DDCTransport, @unchecked Sendable {
        enum Fault { case none, ignoresWrites, answersNull, busError, repliesNeverCome }

        let name = "simulated-monitor"
        var isUsable: Bool { true }

        private let answers: DDC.FrameShape
        private let fault: Fault
        private let maximum: UInt16
        private let lock = NSLock()
        private var stored: UInt16
        private var lastRequestMatched = false
        private var frames: [[UInt8]] = []

        init(brightness: UInt16, maximum: UInt16 = 100,
             answers: DDC.FrameShape = .withHostAddress, fault: Fault = .none) {
            stored = brightness
            self.maximum = maximum
            self.answers = answers
            self.fault = fault
        }

        var brightness: UInt16 { lock.withLock { stored } }
        var setFrames: [[UInt8]] { lock.withLock { frames.filter { $0[opcodeIndex($0)] == 0x03 } } }

        private func opcodeIndex(_ frame: [UInt8]) -> Int { frame.first == DDC.hostAddress ? 2 : 1 }

        func write(_ bytes: [UInt8]) async throws {
            if fault == .busError { throw DDCError.ioError(code: -536_854_528) }
            let shape: DDC.FrameShape =
                bytes.first == DDC.hostAddress ? .withHostAddress : .withoutHostAddress
            lock.withLock {
                frames.append(bytes)
                lastRequestMatched = shape == answers
                let opcode = opcodeIndex(bytes)
                if bytes[opcode] == 0x03, lastRequestMatched, fault == .none {
                    stored = UInt16(bytes[opcode + 2]) << 8 | UInt16(bytes[opcode + 3])
                }
            }
        }

        func read(length: Int) async throws -> [UInt8] {
            if fault == .repliesNeverCome { throw DDCError.timeout }
            let (matched, current) = lock.withLock { (lastRequestMatched, stored) }
            guard matched, fault != .answersNull else {
                return Array(repeating: VCPCodec.nullMessage, count: 4).flatMap { $0 }
            }
            var frame: [UInt8] = [
                0x6E, 0x88, 0x02, 0x00, 0x10, 0x00,
                UInt8(maximum >> 8), UInt8(maximum & 0xFF), UInt8(current >> 8), UInt8(current & 0xFF),
            ]
            frame.append(frame.reduce(DDC.replyChecksumSeed) { $0 ^ $1 })
            return frame
        }
    }

    func testAWorkingMonitorIsReportedAsAcceptingWritesAndIsLeftAsItWasFound() async {
        let monitor = SimulatedMonitor(brightness: 40)

        let conversation = await DDCTracer.run(on: monitor)

        XCTAssertEqual(conversation.verdict, .writeAccepted)
        XCTAssertEqual(conversation.answeredShape, .withHostAddress)
        XCTAssertEqual(monitor.brightness, 40, "the nudge must be undone before returning")
        XCTAssertEqual(conversation.steps.map(\.outcome), ["40/100", "ok", "41/100", "ok", "40/100"])
        XCTAssertEqual(conversation.steps.first?.sent, "51 82 01 10 AC")
        XCTAssertEqual(conversation.steps.first?.received, "6E 88 02 00 10 00 00 64 00 28 E8")
    }

    func testAtTheMaximumTheNudgeGoesDownInsteadOfPastTheRange() async {
        let monitor = SimulatedMonitor(brightness: 100)

        let conversation = await DDCTracer.run(on: monitor)

        XCTAssertEqual(conversation.verdict, .writeAccepted)
        XCTAssertEqual(conversation.steps[2].outcome, "99/100")
        XCTAssertEqual(monitor.brightness, 100)
    }

    /// The Dell-under-HDR case: reads answer, writes return success, and nothing changes.
    func testAMonitorThatIgnoresWritesIsToldApartFromOneThatCannotBeReached() async {
        let monitor = SimulatedMonitor(brightness: 40, fault: .ignoresWrites)

        let conversation = await DDCTracer.run(on: monitor)

        XCTAssertEqual(conversation.verdict, .writeIgnored)
        XCTAssertEqual(conversation.steps[1].outcome, "ok", "the write itself reported success")
        XCTAssertEqual(conversation.steps[2].outcome, "40/100", "the read-back shows the old value")
    }

    func testTheOtherFrameShapeIsTriedBeforeGivingUp() async {
        let monitor = SimulatedMonitor(brightness: 40, answers: .withoutHostAddress)

        let conversation = await DDCTracer.run(on: monitor)

        XCTAssertEqual(conversation.verdict, .writeAccepted)
        XCTAssertEqual(conversation.answeredShape, .withoutHostAddress)
        XCTAssertEqual(monitor.setFrames.map(\.first), [0x84, 0x84],
                       "writes must use the shape that answered — no leading host address")
    }

    func testNullMessagesInBothShapesAreReportedAsDeclinedAndNothingIsWritten() async {
        let monitor = SimulatedMonitor(brightness: 40, fault: .answersNull)

        let conversation = await DDCTracer.run(on: monitor)

        XCTAssertEqual(conversation.verdict, .nullReply)
        XCTAssertEqual(conversation.steps.count, 2, "one get per frame shape")
        XCTAssertEqual(conversation.steps.first?.received?.hasPrefix("6E 80 BE"), true)
        XCTAssertTrue(monitor.setFrames.isEmpty, "no value is known, so none may be written")
    }

    func testABusThatRefusesEveryFrameIsReportedAsNoReplyNamingTheRequest() async {
        let monitor = SimulatedMonitor(brightness: 40, fault: .busError)

        let conversation = await DDCTracer.run(on: monitor)

        XCTAssertEqual(conversation.verdict, .noReply)
        XCTAssertEqual(conversation.steps.count, 2)
        XCTAssertTrue(conversation.steps.allSatisfy { $0.outcome.hasPrefix("request failed: ") })
        XCTAssertNil(conversation.steps.first?.received)
    }

    /// Requests go out, replies never come back: a different fault from a dead bus, and the one
    /// that would make a write-only mode worth building.
    func testALinkThatCarriesRequestsButNoRepliesNamesTheReply() async {
        let monitor = SimulatedMonitor(brightness: 40, fault: .repliesNeverCome)

        let conversation = await DDCTracer.run(on: monitor)

        XCTAssertEqual(conversation.verdict, .noReply)
        XCTAssertTrue(conversation.steps.allSatisfy { $0.outcome == "reply failed: DDC timed out" })
    }

    func testTheControllerTracesThroughTheDisplaysOwnSessionAndReportsNoTransportAsNil() async {
        let display = DisplayDevice(
            identity: DisplayIdentity(
                cgDisplayID: 7, vendorID: 0x10AC, productID: 0xA275,
                serialNumber: 0xABCD, keyTier: .strong),
            name: "TEST S2725QS", isBuiltIn: false, isOnline: true, isMain: false)
        let monitor = SimulatedMonitor(brightness: 62)

        let bound = DDCBrightnessController(makeTransport: { _ in monitor })
        let unbound = DDCBrightnessController(makeTransport: { _ in nil })

        let traced = await bound.trace(display: display)
        let missing = await unbound.trace(display: display)

        XCTAssertEqual(traced?.verdict, .writeAccepted)
        XCTAssertNil(missing)
    }

    /// Against the real unified log: the report is only useful if the lines the display stack
    /// wrote in this process can actually be read back, and only those.
    func testRecentLogReturnsThisProcessDisplayLinesAndNoOtherCategories() {
        let marker = "trace-test-\(UUID().uuidString)"
        Log.ddcTransport.notice("\(marker, privacy: .public)")
        Log.app.notice("\(marker, privacy: .public) from an unrelated category")

        let lines = RecentLog.lines(limit: 10_000).filter { $0.contains(marker) }

        XCTAssertEqual(lines.count, 1, "exactly the display-stack line: \(lines)")
        XCTAssertEqual(lines.first?.contains("[ddc.transport]"), true)
    }

    func testTheReportCarriesTheTraceAndBorrowsItsChipAddress() throws {
        let display = DisplayDevice(
            identity: DisplayIdentity(
                cgDisplayID: 7, vendorID: 0x10AC, productID: 0xA275,
                serialNumber: 0xABCD, keyTier: .strong),
            name: "TEST S2725QS", isBuiltIn: false, isOnline: true, isMain: false)
        let trace = DDCTrace(
            stableKey: display.id, bindFailure: nil, chipAddress: "0xb7", behindMCDP29xxBridge: true,
            link: ["Transport.Downstream": "HDMI"], steps: [], verdict: .noReply, answeredShape: nil)

        let report = DiagnosticsBuilder.build(
            displays: [display], ambiguousKeys: [], brightnessStates: [:], availability: [:],
            probeDetails: [:], warnings: [:], chosenControllers: [:], appVersion: "test",
            ddcTraces: [trace], recentLog: ["line"])

        XCTAssertEqual(report.brightness.first?.ddcChipAddress, "0xb7")
        XCTAssertEqual(report.environment.machineModel?.isEmpty, false)
        let json = String(decoding: try report.jsonData(), as: UTF8.self)
        XCTAssertTrue(json.contains("\"verdict\" : \"noReply\""))
        XCTAssertTrue(json.contains("\"Transport.Downstream\" : \"HDMI\""))
    }
}
