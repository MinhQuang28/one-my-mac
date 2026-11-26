import Darwin
import Foundation

/// Bytes received and sent since boot, summed over the physical network interfaces.
struct NetworkCounters: Equatable {
    var received: UInt32
    var sent: UInt32
}

/// Reads network byte counters and free disk space (no shell, no subprocess).
enum NetworkDiskReader {

    /// Sum over `en*` interfaces only — Wi-Fi, Ethernet, USB tethering. A VPN tunnel carries the
    /// same bytes a second time, and loopback / AirDrop links are not "the network" to a user.
    static func networkCounters() -> NetworkCounters? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }

        var total = NetworkCounters(received: 0, sent: 0)
        var found = false
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = entry.pointee
            // Only the link-level entry carries the counters; the IPv4/IPv6 ones repeat the name.
            guard let address = interface.ifa_addr, address.pointee.sa_family == UInt8(AF_LINK),
                  let data = interface.ifa_data,
                  String(cString: interface.ifa_name).hasPrefix("en") else { continue }
            let stats = data.assumingMemoryBound(to: if_data.self).pointee
            total.received &+= stats.ifi_ibytes
            total.sent &+= stats.ifi_obytes
            found = true
        }
        return found ? total : nil
    }

    /// Bytes per second between two readings. The counters are 32-bit and wrap every 4 GB, hence `&-`.
    static func rate(from old: UInt32, to new: UInt32, elapsed: TimeInterval) -> Double? {
        guard elapsed > 0 else { return nil }
        return Double(new &- old) / elapsed
    }

    /// Free space on the startup volume as Finder reports it, counting what macOS can purge.
    static func diskFreeBytes() -> Int64? {
        let values = try? URL(fileURLWithPath: "/")
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    /// A rate in at most four characters, so the menu bar does not jump around: `0K`, `87K`, `1.2M`, `24M`.
    static func compact(bytes: Double) -> String {
        let kilo = bytes / 1000
        if kilo < 999.5 { return "\(Int(kilo.rounded()))K" }
        let mega = kilo / 1000
        if mega < 9.95 { return String(format: "%.1fM", mega) }
        if mega < 999.5 { return "\(Int(mega.rounded()))M" }
        return String(format: "%.1fG", mega / 1000)
    }
}
