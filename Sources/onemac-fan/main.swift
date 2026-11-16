// onemac-fan — the only part of OneMac that runs as root. It is invoked through a sudoers rule
// limited to this exact path, so every argument is validated against what the SMC itself reports.
//
//   onemac-fan version            → prints "ONEMAC_FAN 1"
//   onemac-fan set <fan> <rpm>    → manual mode at <rpm>; fan in 0..<FNum, rpm within [min, max]
//   onemac-fan auto <fan>         → hand the fan back to macOS
//   onemac-fan auto-all           → every fan back to macOS
import Foundation
import SMCBridge

let helperVersion = 1

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("onemac-fan: \(message)\n".utf8))
    exit(code)
}

func number(_ key: String) -> Double? {
    var value = OMSMCValue()
    guard om_smc_read(key, &value) == 0 else { return nil }
    let n = om_smc_value_as_double(&value)
    return n.isFinite ? n : nil
}

func write(_ key: String, _ bytes: [UInt8]) {
    let rc = bytes.withUnsafeBufferPointer { om_smc_write(key, $0.baseAddress, UInt32($0.count)) }
    if rc != 0 { fail("write \(key) failed (\(rc))", code: 3) }
}

func writeFloat(_ key: String, _ value: Float) {
    withUnsafeBytes(of: value.bitPattern.littleEndian) { write(key, Array($0)) }
}

func fanCount() -> Int { Int(number("FNum") ?? 0) }

/// Strict decimal parse: digits only, no sign, no whitespace, bounded length.
func parseInt(_ text: String, maxDigits: Int) -> Int? {
    guard !text.isEmpty, text.count <= maxDigits, text.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
    return Int(text)
}

func parseFan(_ text: String) -> Int {
    guard let fan = parseInt(text, maxDigits: 1), fan < min(fanCount(), 4) else { fail("invalid fan index", code: 2) }
    return fan
}

func setAuto(_ fan: Int) {
    write("F\(fan)Md", [0])
    writeFloat("F\(fan)Tg", 0)
}

/// Some chips (M3 and later) only honour manual mode while the `Ftst` unlock key is set.
func setUnlock(_ on: Bool) {
    if number("Ftst") != nil { write("Ftst", [on ? 1 : 0]) }
}

let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { fail("missing command", code: 2) }

switch (command, args.count) {
case ("version", 1):
    print("ONEMAC_FAN \(helperVersion)")

case ("set", 3):
    guard geteuid() == 0 else { fail("must run as root", code: 4) }
    let fan = parseFan(args[1])
    guard let rpm = parseInt(args[2], maxDigits: 5),
          let low = number("F\(fan)Mn"), let high = number("F\(fan)Mx"), high > 0,
          Double(rpm) >= low.rounded(.down), Double(rpm) <= high.rounded(.up) else {
        fail("rpm out of range", code: 2)
    }
    setUnlock(true)
    write("F\(fan)Md", [1])
    writeFloat("F\(fan)Tg", Float(rpm))

case ("auto", 2):
    guard geteuid() == 0 else { fail("must run as root", code: 4) }
    setAuto(parseFan(args[1]))
    if (0..<fanCount()).allSatisfy({ (number("F\($0)Md") ?? 0) == 0 }) { setUnlock(false) }

case ("auto-all", 1):
    guard geteuid() == 0 else { fail("must run as root", code: 4) }
    for fan in 0..<min(fanCount(), 4) { setAuto(fan) }
    setUnlock(false)

default:
    fail("usage: onemac-fan version | set <fan> <rpm> | auto <fan> | auto-all", code: 2)
}
