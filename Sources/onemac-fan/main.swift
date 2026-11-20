// onemac-fan — the only part of OneMac that runs as root. It is invoked through a sudoers rule
// limited to this exact path, so every argument is validated against what the SMC itself reports.
//
//   onemac-fan version                → prints "ONEMAC_FAN <version>"
//   onemac-fan set <fan> <rpm> <pid>  → manual mode at <rpm>; fan in 0..<FNum, rpm within [min, max].
//                                       A detached watchdog hands every fan back to macOS when
//                                       process <pid> (the app) is gone, or the chip overheats.
//   onemac-fan auto <fan>             → hand the fan back to macOS
//   onemac-fan auto-all               → every fan back to macOS
//   onemac-fan watch <pid>            → the watchdog itself (started by `set`)
import Darwin
import Foundation
import SMCBridge

/// Holds the pid of the current watchdog. An older watchdog exits when it no longer finds its own
/// pid here, so a new `set` replaces it and `auto-all` (which removes the file) cancels it.
let pidFile = "/var/run/onemac-fan.pid"
/// The watchdog's own heat limit, above the app's 90 °C so the app (which can explain itself) acts first.
let watchdogCutoff = 95.0
/// A manual target at or above this share of the fan's maximum is cooling, never cut off for heat.
let coolingFloor = 0.8

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

func write(_ key: String, _ bytes: [UInt8]) -> Bool {
    bytes.withUnsafeBufferPointer { om_smc_write(key, $0.baseAddress, UInt32($0.count)) } == 0
}

func writeFloat(_ key: String, _ value: Float) -> Bool {
    withUnsafeBytes(of: value.bitPattern.littleEndian) { write(key, Array($0)) }
}

func fanCount() -> Int { min(max(Int(number("FNum") ?? 0), 0), 4) }

func manualFans() -> [Int] { (0..<fanCount()).filter { number("F\($0)Md") == 1 } }

/// Strict decimal parse: digits only, no sign, no whitespace, bounded length.
func parseInt(_ text: String, maxDigits: Int) -> Int? {
    guard !text.isEmpty, text.count <= maxDigits, text.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
    return Int(text)
}

func parseFan(_ text: String) -> Int {
    guard let fan = parseInt(text, maxDigits: 1), fan < fanCount() else { fail("invalid fan index", code: 2) }
    return fan
}

func parsePid(_ text: String) -> pid_t {
    guard let pid = parseInt(text, maxDigits: 7), pid > 1 else { fail("invalid pid", code: 2) }
    return pid_t(pid)
}

func isAlive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 || errno != ESRCH }

func requireRoot() {
    guard geteuid() == 0 else { fail("must run as root", code: 4) }
}

/// Some chips (M3 and later) only honour manual mode while the `Ftst` unlock key is set.
func setUnlock(_ on: Bool) {
    if number("Ftst") != nil { _ = write("Ftst", [on ? 1 : 0]) }
}

/// True when the fan is back on automatic; the target reset is only tidying up.
func setAuto(_ fan: Int) -> Bool {
    let ok = write("F\(fan)Md", [0])
    _ = writeFloat("F\(fan)Tg", 0)
    return ok
}

/// Every fan back to macOS; on success the unlock key is cleared and any watchdog is cancelled.
func setAllAuto() -> Bool {
    var ok = true
    for fan in 0..<fanCount() where !setAuto(fan) { ok = false }
    guard ok else { return false }
    setUnlock(false)
    unlink(pidFile)
    return true
}

/// Hottest CPU die sensor, or every non-battery sensor when the chip names none (as the app does).
func hottestCPU() -> Double? {
    var buffer = [OMTemperature](repeating: OMTemperature(), count: 96)
    let count = Int(om_hid_read_temperatures(&buffer, Int32(buffer.count)))
    let sensors: [(name: String, celsius: Double)] = buffer.prefix(count).map { item in
        var copy = item
        let name = withUnsafeBytes(of: &copy.name) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return (name.lowercased(), item.celsius)
    }
    let die = sensors.filter { $0.name.contains("tdie") }
    return (die.isEmpty ? sensors.filter { !$0.name.contains("battery") } : die).map(\.celsius).max()
}

/// Starts `onemac-fan watch <pid>` in its own session with no inherited files, so neither sudo nor
/// the app's pipe waits on it, and records it as the current watchdog.
func startWatchdog(for pid: pid_t) -> Bool {
    var size = UInt32(0)
    _NSGetExecutablePath(nil, &size)
    var path = [CChar](repeating: 0, count: Int(size))
    guard _NSGetExecutablePath(&path, &size) == 0 else { return false }

    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    for fd in [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO] {
        posix_spawn_file_actions_addopen(&actions, fd, "/dev/null", O_RDWR, 0)
    }
    var attributes: posix_spawnattr_t?
    posix_spawnattr_init(&attributes)
    defer { posix_spawnattr_destroy(&attributes) }
    posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))

    let words = ["onemac-fan", "watch", "\(pid)"]
    var arguments: [UnsafeMutablePointer<CChar>?] = words.map { strdup($0) }
    arguments.append(nil)
    defer { arguments.forEach { free($0) } }
    var environment: [UnsafeMutablePointer<CChar>?] = [nil]
    var child = pid_t(0)
    guard posix_spawn(&child, path, &actions, &attributes, &arguments, &environment) == 0 else { return false }
    // /var/run is root-only, so this file cannot be planted; the write is atomic (temp + rename).
    do {
        try "\(child)\n".write(toFile: pidFile, atomically: true, encoding: .utf8)
        return true
    } catch {
        kill(child, SIGKILL)
        return false
    }
}

/// Runs until replaced or cancelled, or until the fans are back on automatic.
func watch(_ pid: pid_t) -> Never {
    signal(SIGHUP, SIG_IGN)
    let me = "\(getpid())"
    while true {
        // Sleeping first also gives `set` time to record this process in the pid file.
        sleep(2)
        let current = (try? String(contentsOfFile: pidFile, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard current == me else { exit(0) }
        let manual = manualFans()
        if manual.isEmpty {
            unlink(pidFile)
            exit(0)
        }
        var release = !isAlive(pid)
        if !release, let hottest = hottestCPU(), hottest >= watchdogCutoff {
            // Too hot while a fan is held slow: the app missed it (hung, or it was not the one asking).
            release = manual.contains { fan in
                guard let target = number("F\(fan)Tg"), let top = number("F\(fan)Mx"), top > 0 else { return true }
                return target < top * coolingFloor
            }
        }
        // A failed write is tried again on the next round.
        if release, setAllAuto() { exit(0) }
    }
}

let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { fail("missing command", code: 2) }

switch (command, args.count) {
case ("version", 1):
    print("ONEMAC_FAN \(OM_FAN_HELPER_VERSION)")

case ("set", 4):
    requireRoot()
    let fan = parseFan(args[1])
    guard let rpm = parseInt(args[2], maxDigits: 5),
          let low = number("F\(fan)Mn"), let high = number("F\(fan)Mx"), high > 0,
          Double(rpm) >= low.rounded(.down), Double(rpm) <= high.rounded(.up) else {
        fail("rpm out of range", code: 2)
    }
    let pid = parsePid(args[3])
    guard isAlive(pid) else { fail("no such process", code: 2) }
    setUnlock(true)
    // The chip can take a moment to accept manual mode after the unlock: retry for up to 3 s.
    var manual = false
    for _ in 0..<30 {
        if write("F\(fan)Md", [1]) { manual = true; break }
        usleep(100_000)
    }
    // Never leave a fan pinned without its watchdog, nor the unlock key set with nothing manual.
    guard manual, writeFloat("F\(fan)Tg", Float(rpm)), startWatchdog(for: pid) else {
        _ = setAuto(fan)
        if manualFans().isEmpty { setUnlock(false) }
        fail("could not hold fan \(fan) at a manual speed", code: 3)
    }

case ("auto", 2):
    requireRoot()
    guard setAuto(parseFan(args[1])) else { fail("could not return the fan to automatic", code: 3) }
    if manualFans().isEmpty {
        setUnlock(false)
        unlink(pidFile)
    }

case ("auto-all", 1):
    requireRoot()
    guard setAllAuto() else { fail("could not return the fans to automatic", code: 3) }

case ("watch", 2):
    requireRoot()
    watch(parsePid(args[1]))

default:
    fail("usage: onemac-fan version | set <fan> <rpm> <pid> | auto <fan> | auto-all", code: 2)
}
