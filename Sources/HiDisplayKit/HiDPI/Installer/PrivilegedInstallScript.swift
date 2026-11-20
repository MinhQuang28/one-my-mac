import Foundation

/// Builds the one shell string the app ever runs as root, and refuses inputs that would make that
/// dangerous.
///
/// Lives in the kit rather than next to the AppleScript call that runs it, so both of its safety
/// properties — the path allowlist and the shape of the generated script — are covered by tests.
public enum PrivilegedInstallScript {

    public enum ScriptError: Error, Equatable {
        case unsafePath(String)
    }

    /// Characters a path may contain before it is allowed anywhere near a shell command.
    ///
    /// Deliberately narrow. Every legitimate path here is made of hex digits, ASCII letters, and the
    /// separators below — a space or a quote means something has gone wrong upstream, and the right
    /// response is to refuse rather than to escape harder.
    public static let allowedPathCharacters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/-._")

    public static func requireSafe(_ path: String) throws {
        guard !path.isEmpty,
              path.unicodeScalars.allSatisfy({ allowedPathCharacters.contains($0) }),
              !path.contains("..")
        else { throw ScriptError.unsafePath(path) }
    }

    /// The install command run as root.
    ///
    /// The staged file lives in a user-writable temporary directory, so between the app's own hash
    /// check and the privileged copy, any process running as the same user could swap it — file
    /// permissions cannot prevent that. So root never trusts it: the script copies the staged file to
    /// a partial file *next to the destination* (inside the root-owned override tree), verifies that
    /// copy's SHA-256 against the hash the user approved, and only then moves it into place. A swap
    /// after the `cp` changes nothing, because the copy is what gets verified and moved; `mv` within
    /// one directory is atomic, so no half-written file is ever at the destination path.
    ///
    /// Fixed operations only — `mkdir -p`, `cp`, `chmod`, `shasum -c`, `mv` — plus one `rm -f` of the
    /// script's own partial file on the failure path, the single non-recursive delete it may perform.
    /// Every binary is named by absolute path, and the override root, when something already exists at
    /// its path, must be owned by the user the script runs as (root in production, the test user under
    /// `bash -c`). `/Library` itself is root-owned, so this is defence in depth rather than a live hole:
    /// it refuses to follow a planted directory or symlink into a tree root did not create. `stat -L`
    /// so a symlink is judged by its target.
    ///
    /// Each step reports its own failure and exit status. One catch-all message used to cover them
    /// all, so a `mkdir` that failed on a read-only volume was reported as "the file did not match
    /// the approved contents" — which sends the user looking for tampering that never happened.
    public static func install(
        staging: String, vendorDirectory: String, destination: String, sha256: String
    ) throws -> String {
        for path in [staging, vendorDirectory, destination] {
            try requireSafe(path)
        }
        try requireDigest(sha256)
        let partial = destination + ".hidisplay-partial"
        // No double quotes anywhere in the script: it is embedded in an AppleScript string literal.
        return rootOwnershipCheck(vendorDirectory: vendorDirectory, verb: "install")
            + "/bin/mkdir -p '\(vendorDirectory)' || "
            + "{ echo 'install failed: could not create the override folder' >&2; exit 3; }; "
            + "{ /bin/cp '\(staging)' '\(partial)' && /bin/chmod 644 '\(partial)'; } || "
            + "{ /bin/rm -f '\(partial)'; "
            + "echo 'install failed: could not copy the file into the override folder' >&2; exit 4; }; "
            + "echo '\(sha256)  \(partial)' | /usr/bin/shasum -a 256 -c --status - || "
            + "{ /bin/rm -f '\(partial)'; "
            + "echo 'install failed: the file to install did not match the approved contents' >&2; "
            + "exit 1; }; "
            + "/bin/mv '\(partial)' '\(destination)' || "
            + "{ /bin/rm -f '\(partial)'; "
            + "echo 'install failed: could not move the file into place' >&2; exit 5; }"
    }

    /// The command, run as root, that removes an override this app installed.
    ///
    /// Root does not take the app's word for which file that is: it verifies the file's SHA-256
    /// against the hash recorded when the app wrote it, and removes it only on a match. A file
    /// another tool has rewritten since — or anything planted at that path — is refused, the same
    /// ownership rule `OverrideInstaller.removeAppOwned` applies without privileges.
    ///
    /// One non-recursive `rm -f` of that single file, then `rmdir` of the vendor folder, which only
    /// succeeds when the folder is left empty. Nothing here can remove a tree.
    public static func remove(
        vendorDirectory: String, destination: String, sha256: String
    ) throws -> String {
        for path in [vendorDirectory, destination] {
            try requireSafe(path)
        }
        try requireDigest(sha256)
        return rootOwnershipCheck(vendorDirectory: vendorDirectory, verb: "remove")
            + "{ [ -f '\(destination)' ] && [ ! -L '\(destination)' ]; } || "
            + "{ echo 'remove refused: there is no override file at that path' >&2; exit 3; }; "
            + "echo '\(sha256)  \(destination)' | /usr/bin/shasum -a 256 -c --status - || "
            + "{ echo 'remove refused: the override file is not the one this app installed' >&2; "
            + "exit 1; }; "
            + "/bin/rm -f '\(destination)' || "
            + "{ echo 'remove failed: could not delete the override file' >&2; exit 4; }; "
            + "/bin/rmdir '\(vendorDirectory)' 2>/dev/null; exit 0"
    }

    private static func requireDigest(_ sha256: String) throws {
        guard sha256.count == 64, sha256.allSatisfy(\.isHexDigit) else {
            throw ScriptError.unsafePath(sha256)
        }
    }

    /// Refuses to work under an override root owned by anyone but the user the script runs as.
    /// Both substitutions expand to a bare integer, so unquoted use is safe.
    private static func rootOwnershipCheck(vendorDirectory: String, verb: String) -> String {
        let root = (vendorDirectory as NSString).deletingLastPathComponent
        return "{ [ ! -e '\(root)' ] || [ $(/usr/bin/stat -L -f %u '\(root)') = $(/usr/bin/id -u) ]; } || "
            + "{ echo '\(verb) refused: the override root is not owned by the installing user' >&2; exit 2; }; "
    }
}
