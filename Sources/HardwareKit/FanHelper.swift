import CryptoKit
import Foundation
import OneMacUI
import SMCBridge
import Security

/// Talks to the root fan helper through `sudo -n` and installs it on request.
///
/// Install layout: the binary at `installedPath` (root:wheel, 755) and a sudoers rule that lets only
/// the users who installed it run exactly that path without a password. Nothing else gains root.
public enum FanHelper {
    public static let installedPath = "/Library/PrivilegedHelperTools/com.onemac.fan"
    static let sudoersPath = "/etc/sudoers.d/onemac-fan"
    static let watchdogPidPath = "/var/run/onemac-fan.pid"
    /// The version this build ships; an older installed helper must be reinstalled.
    static let requiredVersion = Int(OM_FAN_HELPER_VERSION)

    public enum Status: Equatable, Sendable { case ready, missing, outdated }

    /// Something of the helper is on disk, so there is something to remove.
    public static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: installedPath) || FileManager.default.fileExists(atPath: sudoersPath)
    }

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
        // The app bundle is writable by the user, so the helper could have been swapped: it must
        // carry the same signature as the running app. (An ad hoc dev build has nothing to compare.)
        let requirement = signerRequirement()
        if let requirement, !satisfies(source, requirement) {
            return tr("The bundled fan helper is not signed like OneMac — not installing it.",
                      "Helper quạt trong gói ứng dụng không cùng chữ ký với OneMac — không cài.")
        }
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let user = NSUserName()
        guard user.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil else {
            return tr("The user name is not valid for sudoers.", "Tên người dùng không hợp lệ cho sudoers.")
        }
        // Stage in a private temp dir: root cannot read files under TCC-protected folders.
        let stage = FileManager.default.temporaryDirectory.appendingPathComponent("onemac-fan-\(UUID().uuidString)")
        let staged = stage.appendingPathComponent("onemac-fan").path
        // The path goes into a root shell script inside single quotes.
        guard !staged.contains("'") else {
            return tr("The temporary folder path is not safe to use.", "Đường dẫn thư mục tạm không an toàn.")
        }
        do {
            try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            try data.write(to: URL(fileURLWithPath: staged))
        } catch {
            return tr("Couldn't prepare the install file: \(error.localizedDescription)",
                      "Không chuẩn bị được file cài: \(error.localizedDescription)")
        }
        defer { try? FileManager.default.removeItem(at: stage) }

        let rule = "\(user) ALL=(root) NOPASSWD: \(installedPath)"
        // Hash and signature are checked after the copy, as root, on root's own copy, so a staging
        // file swapped at any moment is never installed.
        let signatureCheck = requirement.map {
            "/usr/bin/codesign --verify -R '=\($0)' '\(installedPath).new' || { rm -f '\(installedPath).new'; exit 7; }"
        } ?? ":"
        // The rule is added to the ones already there, so a second user installing keeps the first.
        let script = """
        set -e
        install -d -o root -g wheel -m 755 /Library/PrivilegedHelperTools
        install -o root -g wheel -m 755 '\(staged)' '\(installedPath).new'
        [ "$(/usr/bin/shasum -a 256 '\(installedPath).new' | cut -d' ' -f1)" = '\(hash)' ] || { rm -f '\(installedPath).new'; exit 9; }
        \(signatureCheck)
        mv -f '\(installedPath).new' '\(installedPath)'
        { [ -f '\(sudoersPath)' ] && cat '\(sudoersPath)'; printf '%s\\n' '\(rule)'; } | sort -u > '\(sudoersPath).new'
        chown root:wheel '\(sudoersPath).new'; chmod 440 '\(sudoersPath).new'
        /usr/sbin/visudo -cf '\(sudoersPath).new' >/dev/null || { rm -f '\(sudoersPath).new'; exit 8; }
        mv -f '\(sudoersPath).new' '\(sudoersPath)'
        """
        return runAsAdmin(script).map {
            $0.isEmpty ? tr("Cancelled.", "Đã huỷ.") : tr("Helper install failed: \($0)", "Cài helper thất bại: \($0)")
        }
    }

    /// Asks for the admin password once and removes the helper, its sudoers rule and the watchdog's
    /// pid file. The caller returns the fans to System first. Blocking.
    public static func uninstall() -> String? {
        let script = "rm -f '\(installedPath)' '\(sudoersPath)' '\(watchdogPidPath)'"
        return runAsAdmin(script).map {
            $0.isEmpty ? tr("Cancelled.", "Đã huỷ.") : tr("Couldn't remove the helper: \($0)", "Không gỡ được helper: \($0)")
        }
    }

    /// Runs a shell script as root behind the system password prompt. Returns nil on success, an
    /// empty string when the user cancelled, else the error text.
    private static func runAsAdmin(_ script: String) -> String? {
        let escaped = script.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        guard let appleScript = NSAppleScript(source: "do shell script \"\(escaped)\" with administrator privileges") else {
            return tr("AppleScript error.", "AppleScript lỗi.")
        }
        var error: NSDictionary?
        appleScript.executeAndReturnError(&error)
        guard let error else { return nil }
        let code = error[NSAppleScript.errorNumber] as? Int ?? 0
        return code == -128 ? "" : "\(error[NSAppleScript.errorMessage] ?? code)"
    }

    /// `certificate leaf = H"…"` for the certificate the running app is signed with; nil when it
    /// is unsigned or ad hoc signed.
    static func signerRequirement() -> String? {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let certificates = (info as? [String: Any])?[kSecCodeInfoCertificates as String] as? [SecCertificate],
              let leaf = certificates.first else { return nil }
        let digest = Insecure.SHA1.hash(data: SecCertificateCopyData(leaf) as Data)
        return "certificate leaf = H\"\(digest.map { String(format: "%02x", $0) }.joined())\""
    }

    static func satisfies(_ url: URL, _ requirement: String) -> Bool {
        var code: SecStaticCode?
        var parsed: SecRequirement?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(requirement as CFString, [], &parsed) == errSecSuccess, let parsed else {
            return false
        }
        return SecStaticCodeCheckValidity(code, [], parsed) == errSecSuccess
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
