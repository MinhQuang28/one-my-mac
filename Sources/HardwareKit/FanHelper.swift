import CryptoKit
import Foundation
import OneMacUI

/// Talks to the root fan helper through `sudo -n` and installs it on request.
///
/// Install layout: the binary at `installedPath` (root:wheel, 755) and a sudoers rule that lets only
/// the current user run exactly that path without a password. Nothing else gains root.
public enum FanHelper {
    public static let installedPath = "/Library/PrivilegedHelperTools/com.onemac.fan"
    static let sudoersPath = "/etc/sudoers.d/onemac-fan"
    static let requiredVersion = 1

    public enum Status: Equatable, Sendable { case ready, missing, outdated }

    /// Blocking; call off the main thread.
    public static func status() -> Status {
        guard FileManager.default.isExecutableFile(atPath: installedPath) else { return .missing }
        let (out, code) = run(installedPath, ["version"])
        guard code == 0, let v = Int(out.split(separator: " ").last ?? "") else { return .outdated }
        guard v >= requiredVersion else { return .outdated }
        // The sudoers rule must exist too: probe with a harmless no-password sudo call.
        let (_, sudoCode) = run("/usr/bin/sudo", ["-n", installedPath, "version"])
        return sudoCode == 0 ? .ready : .missing
    }

    /// Runs a privileged command; returns an error message on failure. Blocking.
    @discardableResult
    public static func invoke(_ args: [String]) -> String? {
        let (out, code) = run("/usr/bin/sudo", ["-n", installedPath] + args)
        return code == 0 ? nil : (out.isEmpty ? "exit \(code)" : out)
    }

    /// The helper shipped inside the app bundle (Contents/MacOS), or next to the dev binary.
    static var bundledHelperURL: URL? {
        let candidates = [
            Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/onemac-fan"),
            Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("onemac-fan"),
        ].compactMap { $0 }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// Asks for the admin password once and installs the helper + sudoers rule. Blocking.
    public static func install() -> String? {
        guard let source = bundledHelperURL, let data = try? Data(contentsOf: source) else {
            return tr("onemac-fan was not found in the app bundle.", "Không tìm thấy onemac-fan trong gói ứng dụng.")
        }
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let user = NSUserName()
        guard user.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil else {
            return tr("The user name is not valid for sudoers.", "Tên người dùng không hợp lệ cho sudoers.")
        }
        // Stage in a private temp dir: root cannot read files under TCC-protected folders.
        let stage = FileManager.default.temporaryDirectory.appendingPathComponent("onemac-fan-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            try data.write(to: stage.appendingPathComponent("onemac-fan"))
        } catch {
            return tr("Couldn't prepare the install file: \(error.localizedDescription)",
                      "Không chuẩn bị được file cài: \(error.localizedDescription)")
        }
        defer { try? FileManager.default.removeItem(at: stage) }

        let staged = stage.appendingPathComponent("onemac-fan").path
        let rule = "\(user) ALL=(root) NOPASSWD: \(installedPath)"
        // The hash check runs after the copy, as root, so a swapped staging file is never installed.
        let script = """
        set -e
        install -d -o root -g wheel -m 755 /Library/PrivilegedHelperTools
        install -o root -g wheel -m 755 '\(staged)' '\(installedPath).new'
        [ "$(/usr/bin/shasum -a 256 '\(installedPath).new' | cut -d' ' -f1)" = '\(hash)' ] || { rm -f '\(installedPath).new'; exit 9; }
        mv -f '\(installedPath).new' '\(installedPath)'
        printf '%s\\n' '\(rule)' > '\(sudoersPath).new'
        chown root:wheel '\(sudoersPath).new'; chmod 440 '\(sudoersPath).new'
        /usr/sbin/visudo -cf '\(sudoersPath).new' >/dev/null || { rm -f '\(sudoersPath).new'; exit 8; }
        mv -f '\(sudoersPath).new' '\(sudoersPath)'
        """
        let escaped = script.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let apple = "do shell script \"\(escaped)\" with administrator privileges"
        var error: NSDictionary?
        guard let appleScript = NSAppleScript(source: apple) else {
            return tr("AppleScript error.", "AppleScript lỗi.")
        }
        appleScript.executeAndReturnError(&error)
        if let error {
            let code = error[NSAppleScript.errorNumber] as? Int ?? 0
            if code == -128 { return tr("Cancelled.", "Đã huỷ.") }
            return tr("Helper install failed: \(error[NSAppleScript.errorMessage] ?? code)",
                      "Cài helper thất bại: \(error[NSAppleScript.errorMessage] ?? code)")
        }
        return nil
    }

    static func run(_ path: String, _ args: [String]) -> (String, Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (error.localizedDescription, -1) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return (text, process.terminationStatus)
    }
}
