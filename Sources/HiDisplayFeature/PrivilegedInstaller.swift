import Foundation
import HiDisplayKit
import OneMacUI

/// Installs a generated override into `/Library/Displays`, which needs root.
///
/// ## Why this shape
///
/// The intended end state is a signed helper registered through `SMAppService` with a narrow XPC
/// contract. That needs a Developer ID and notarization, which this build does not have — so the
/// fallback the plan anticipated is used instead: a single system authorization prompt.
///
/// ## The safety rules this obeys, because it runs a shell string as root
///
/// The project's own security rules say never to build a privileged command out of user input. That
/// rule is kept literally here:
///
/// * The only variable parts of the command are paths and a SHA-256 hex digest.
/// * The destination is derived from the display's vendor and product IDs — `UInt32` values formatted
///   as hex, so they *cannot* contain a shell metacharacter.
/// * The source is a file this app wrote to its own temporary directory under a generated UUID.
/// * Every path is re-validated against a strict character allowlist before the command is built,
///   and the destination is proved to resolve inside the override root. Anything else refuses.
///   (`PrivilegedInstallScript` holds that logic, in the kit, where it is tested.)
/// * The staged file sits in a user-writable directory, so the *privileged script* verifies it: it
///   copies into the root-owned override tree, checks the copy's SHA-256 against the hash the user
///   approved, and only then moves it into place. A same-user process swapping the staged file
///   between our checks and the root copy achieves nothing — the swap is caught as root, before
///   anything lands at the destination path.
/// * The result is verified afterwards by reading the file back (unprivileged) and comparing SHA-256
///   against the plan. A privileged write that is not verified is a privileged write you do not know
///   the outcome of.
/// * The privileged step runs **off the main thread**, in `/usr/bin/osascript`. It used to be an
///   in-process `NSAppleScript`, which is main-thread only and so held the main run loop for as
///   long as the password prompt was open: the window froze, and every event tap serviced on that
///   run loop stalled with it.
enum PrivilegedInstaller {

    /// Which privileged script failed, so its exit status can be put into words.
    enum Operation: Sendable { case install, remove }

    enum InstallError: LocalizedError {
        case unsafePath(String)
        case authorizationFailed(String)
        /// The privileged script ran and stopped at one of its own checks. `status` is the exit
        /// status `PrivilegedInstallScript` assigns to that step.
        case scriptFailed(Operation, status: Int, detail: String)
        case verificationFailed(expected: String, got: String)
        /// The bytes handed to `install` are not the ones the plan described. Caught before the
        /// privileged step, so nothing has run as root when this is thrown.
        case payloadMismatch(expected: String, got: String)
        case cancelled

        var errorDescription: String? {
            switch self {
            case .unsafePath(let path):
                return tr("Refusing to build a privileged command with this path: \(path)",
                          "Từ chối tạo lệnh đặc quyền với đường dẫn này: \(path)")
            case .authorizationFailed(let message):
                return message
            case .scriptFailed(let operation, let status, let detail):
                return Self.describe(operation, status: status, detail: detail)
            case .verificationFailed(let expected, let got):
                return tr(
                    "The file now installed does not match what was previewed "
                    + "(expected \(expected.prefix(12))…, got \(got.prefix(12))…) — something modified "
                    + "it immediately after installation. Do not log out yet: run restore.command from "
                    + "the recovery package in Downloads to put the previous file back.",
                    "Tệp vừa cài không khớp với bản đã xem trước "
                    + "(mong đợi \(expected.prefix(12))…, nhận được \(got.prefix(12))…) — có thứ gì đó đã "
                    + "sửa nó ngay sau khi cài. Đừng đăng xuất vội: chạy restore.command trong gói khôi "
                    + "phục ở Downloads để đưa tệp cũ trở lại.")
            case .payloadMismatch(let expected, let got):
                return tr(
                    "Refusing to install: the file to write does not match the one you were shown "
                    + "(expected \(expected.prefix(12))…, got \(got.prefix(12))…). Nothing was changed.",
                    "Từ chối cài đặt: tệp sắp ghi không khớp với tệp bạn đã xem "
                    + "(mong đợi \(expected.prefix(12))…, nhận được \(got.prefix(12))…). Chưa thay đổi gì.")
            case .cancelled:
                return tr("Authorization was cancelled.", "Đã hủy xác thực.")
            }
        }

        /// The exit statuses of `PrivilegedInstallScript.install` and `.remove`, in words.
        private static func describe(_ operation: Operation, status: Int, detail: String) -> String {
            switch (operation, status) {
            case (_, 2):
                return tr("Nothing was changed: the display override folder is not owned by the "
                            + "system administrator, so it is not safe to write into.",
                          "Chưa thay đổi gì: thư mục override màn hình không thuộc quyền quản trị hệ "
                            + "thống nên ghi vào đó không an toàn.")
            case (.install, 1):
                return tr("Nothing was installed: the file changed between your approval and the "
                            + "write, so it no longer matched what you were shown.",
                          "Chưa cài gì: tệp đã thay đổi giữa lúc bạn duyệt và lúc ghi nên không còn "
                            + "khớp với bản bạn đã xem.")
            case (.install, 3):
                return tr("Nothing was installed: the override folder could not be created.",
                          "Chưa cài gì: không tạo được thư mục override.")
            case (.install, 4):
                return tr("Nothing was installed: the file could not be copied into the override "
                            + "folder.",
                          "Chưa cài gì: không chép được tệp vào thư mục override.")
            case (.install, 5):
                return tr("Nothing was installed: the verified file could not be moved into place.",
                          "Chưa cài gì: không chuyển được tệp đã kiểm chứng vào đúng vị trí.")
            case (.remove, 1):
                return tr("Nothing was removed: the override file is no longer the one OneMac "
                            + "installed, so it was left alone.",
                          "Chưa gỡ gì: tệp override không còn là tệp OneMac đã cài nên được giữ nguyên.")
            case (.remove, 3):
                return tr("Nothing was removed: there is no override file at that path any more.",
                          "Chưa gỡ gì: không còn tệp override ở đường dẫn đó.")
            case (.remove, 4):
                return tr("The override file could not be deleted.", "Không xóa được tệp override.")
            default:
                return detail
            }
        }
    }

    /// Writes `payload` to the override root, prompting for authorization once.
    ///
    /// - Returns: the SHA-256 actually on disk afterwards, read back without privileges.
    @discardableResult
    static func install(plan: InstallationPlan, payload: Data) async throws -> String {
        guard let action = plan.actions.last(where: { $0.kind != .createDirectory }) else {
            throw InstallError.unsafePath("plan has no file to write")
        }
        return try await write(
            payload, relativePath: action.relativePath, under: plan.root,
            approvedHash: action.sha256After ?? "",
            prompt: tr("OneMac wants to install a display override in /Library/Displays.",
                       "OneMac muốn cài một override màn hình vào /Library/Displays."))
    }

    /// Writes one file under the override root as root, and reads it back to verify.
    ///
    /// The one privileged write this app has. Installing a new override and putting a previous one
    /// back both come through here, so both get the same path proof, the same root-side hash check
    /// and the same read-back.
    /// - Parameter approvedHash: the SHA-256 the user was shown. `payload` must hash to it.
    @discardableResult
    static func write(
        _ payload: Data, relativePath: String, under root: URL, approvedHash: String, prompt: String
    ) async throws -> String {
        // The plan told the user what would land, down to a hash. Writing anything else makes that
        // preview a lie — and it silently did, for as long as callers passed their own copy of the
        // generated file instead of the merged bytes the plan had computed.
        let hash = SHA256Hash.hex(of: payload)
        guard hash == approvedHash else {
            throw InstallError.payloadMismatch(expected: approvedHash, got: hash)
        }

        // Prove the destination is inside the override root before anything else happens.
        let destination = try OverridePaths.resolve(relativePath: relativePath, under: root)
        let vendorDirectory = destination.deletingLastPathComponent()

        // Stage in our own temporary directory. Mode 600 keeps other *users* out; a process running
        // as this user can still swap the file, which is why the privileged script re-verifies the
        // hash itself rather than trusting these bytes.
        let staging = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("hidisplay-install-\(UUID().uuidString)")
        try payload.write(to: staging, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: staging.path)
        defer { try? FileManager.default.removeItem(at: staging) }

        let script: String
        do {
            script = try PrivilegedInstallScript.install(
                staging: staging.path,
                vendorDirectory: vendorDirectory.path,
                destination: destination.path,
                sha256: hash)
        } catch PrivilegedInstallScript.ScriptError.unsafePath(let path) {
            throw InstallError.unsafePath(path)
        }

        Log.hidpiInstaller.notice("requesting authorization to install override")
        try await runWithAdministratorPrivileges(script, operation: .install, prompt: prompt)

        // Verify by reading it back ourselves rather than trusting the exit status.
        guard let written = SHA256Hash.hex(ofFileAt: destination) else {
            throw InstallError.verificationFailed(expected: approvedHash, got: "unreadable")
        }
        guard written == approvedHash else {
            throw InstallError.verificationFailed(expected: approvedHash, got: written)
        }

        Log.hidpiInstaller.notice("override installed and verified")
        return written
    }

    /// Removes an override file this app installed, prompting for authorization once.
    ///
    /// - Parameter installedHash: the SHA-256 of the file as this app wrote it. Root re-checks the
    ///   file against it and refuses to delete anything else.
    static func remove(relativePath: String, under root: URL, installedHash: String) async throws {
        let destination = try OverridePaths.resolve(relativePath: relativePath, under: root)
        let script: String
        do {
            script = try PrivilegedInstallScript.remove(
                vendorDirectory: destination.deletingLastPathComponent().path,
                destination: destination.path,
                sha256: installedHash)
        } catch PrivilegedInstallScript.ScriptError.unsafePath(let path) {
            throw InstallError.unsafePath(path)
        }

        Log.hidpiInstaller.notice("requesting authorization to remove override")
        try await runWithAdministratorPrivileges(
            script, operation: .remove,
            prompt: tr("OneMac wants to remove a display override it installed in /Library/Displays.",
                       "OneMac muốn gỡ một override màn hình nó đã cài trong /Library/Displays."))

        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw InstallError.verificationFailed(expected: "no file", got: "still present")
        }
        Log.hidpiInstaller.notice("override removed")
    }

    /// Runs one shell string as root through the system authorization prompt.
    ///
    /// `osascript` rather than an in-process `NSAppleScript`: the latter may only be used on the
    /// main thread, and this call lasts as long as the user takes to type a password. The script is
    /// passed as an argument — no shell is involved in launching it — and `with prompt` names this
    /// app in the dialog, which would otherwise say only that "osascript" wants to make changes.
    private static func runWithAdministratorPrivileges(
        _ shellScript: String, operation: Operation, prompt: String
    ) async throws {
        let source = "do shell script \"\(appleScriptEscaped(shellScript))\" "
            + "with prompt \"\(appleScriptEscaped(prompt))\" with administrator privileges"
        let result: (status: Int32, stderr: String)
        do {
            result = try await runOSAScript(source)
        } catch {
            throw InstallError.authorizationFailed(
                tr("could not start the authorization request: \(error.localizedDescription)",
                   "không khởi chạy được yêu cầu xác thực: \(error.localizedDescription)"))
        }
        guard result.status != 0 else { return }

        let failure = parseFailure(result.stderr)
        // -128 is the documented "user cancelled" code; it is a choice, not a failure.
        if failure.code == -128 { throw InstallError.cancelled }
        Log.hidpiInstaller.error("privileged step failed: \(failure.message, privacy: .public)")
        if let code = failure.code, (1...9).contains(code),
           failure.message.contains("failed:") || failure.message.contains("refused:") {
            throw InstallError.scriptFailed(operation, status: code, detail: failure.message)
        }
        throw InstallError.authorizationFailed(failure.message)
    }

    /// Backslashes first, then quotes: the path allowlist already excludes both, but the allowlist
    /// and this wrapper live in different files, so the wrapper escapes for itself.
    static func appleScriptEscaped(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Splits `osascript`'s `0:77: execution error: <message> (<code>)` into its two useful parts.
    static func parseFailure(_ stderr: String) -> (message: String, code: Int?) {
        var message = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if let marker = message.range(of: "execution error: ") {
            message = String(message[marker.upperBound...])
        }
        var code: Int?
        if message.hasSuffix(")"), let open = message.lastIndex(of: "("),
           let parsed = Int(message[message.index(after: open)..<message.index(before: message.endIndex)]) {
            code = parsed
            message = message[..<open].trimmingCharacters(in: .whitespaces)
        }
        return (message, code)
    }

    private static func runOSAScript(_ source: String) async throws -> (status: Int32, stderr: String) {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", source]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            // Only ever a line or two, so reading it after exit cannot fill the pipe and deadlock.
            let errors = Pipe()
            process.standardError = errors
            process.terminationHandler = { finished in
                let data = errors.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(
                    returning: (finished.terminationStatus, String(decoding: data, as: UTF8.self)))
            }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }
    }

    /// Ends the login session so WindowServer re-reads the overrides.
    ///
    /// Logging out is the cheaper of the two and all that is actually required — WindowServer reads
    /// `/Library/Displays` when a session starts, not when the machine boots. Restart is offered as
    /// well only because it is the more familiar instruction, and because it is what someone reading
    /// an older guide will expect.
    ///
    /// Both go through System Events rather than `shutdown`, so apps are asked to save first. That
    /// needs `NSAppleEventsUsageDescription` in the bundle: without it macOS denies the event with no
    /// prompt, and the button looks broken.
    enum SessionEnd: String {
        case logOut = "log out"
        case restart = "restart"

        var failureDescription: String {
            tr("could not build the \(rawValue) request",
               "không tạo được yêu cầu \(self == .logOut ? "đăng xuất" : "khởi động lại")")
        }
    }

    @MainActor
    static func endSession(_ kind: SessionEnd) throws {
        guard let script = NSAppleScript(
            source: "tell application \"System Events\" to \(kind.rawValue)")
        else {
            throw InstallError.authorizationFailed(kind.failureDescription)
        }
        var error: NSDictionary?
        script.executeAndReturnError(&error)
        if let error, (error[NSAppleScript.errorNumber] as? Int) != -128 {
            let message = error[NSAppleScript.errorMessage] as? String ?? "\(error)"
            Log.app.error("\(kind.rawValue, privacy: .public) failed: \(message, privacy: .public)")
            throw InstallError.authorizationFailed(message)
        }
    }
}
