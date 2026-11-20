import Foundation

/// One way to undo the override currently installed for a display.
public struct OverrideUndo: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// A file was there before the install; putting it back is the undo.
        case restorePrevious(data: Data, sha256: String)
        /// Nothing was there before; deleting what the app wrote is the undo.
        case remove
    }

    public var kind: Kind
    public var manifest: BackupManifest
    /// Path of the override file, relative to the override root.
    public var relativePath: String
    /// SHA-256 of the file this app wrote — and, because that is how the candidate was matched,
    /// of the file on disk right now.
    public var installedHash: String
}

/// The app's own copy of every recovery package it has produced.
///
/// The package in Downloads is for the day the app cannot run. It is also the first thing a tidy
/// user deletes, and until this existed that deleted the only undo there was. Keeping a copy in
/// Application Support lets the app offer "undo" itself.
///
/// What can be undone is decided by content, not by recency: the candidate is the newest record
/// whose `sha256After` is the file on disk *now*. That makes the records a stack without storing
/// one — undo an install and the file reverts to what an earlier record wrote, which then becomes
/// the candidate — and it means a file some other tool has rewritten since is never offered up.
public struct InstalledOverrideStore: Sendable {

    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// `~/Library/Application Support/HiDisplay/Recovery`, beside `profiles.json`.
    public static func defaultDirectory(fileManager: FileManager = .default) -> URL {
        ProfileStore.defaultFileURL(fileManager: fileManager)
            .deletingLastPathComponent()
            .appendingPathComponent("Recovery", isDirectory: true)
    }

    /// Keeps a copy of a recovery package. Call once the install it describes has been verified.
    public func record(_ package: RecoveryPackage, fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let copy = directory.appendingPathComponent(package.directory.lastPathComponent, isDirectory: true)
        if fileManager.fileExists(atPath: copy.path) {
            try fileManager.removeItem(at: copy)
        }
        try fileManager.copyItem(at: package.directory, to: copy)
    }

    /// Every stored manifest with the folder it lives in, newest first. Unreadable entries are
    /// skipped: one damaged record must not hide the others.
    public func records(fileManager: FileManager = .default) -> [(manifest: BackupManifest, directory: URL)] {
        let folders = (try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        return folders
            .compactMap { folder -> (manifest: BackupManifest, directory: URL)? in
                guard let data = fileManager.contents(
                    atPath: folder.appendingPathComponent("manifest.json").path),
                      let manifest = try? BackupManifest.decode(from: data)
                else { return nil }
                return (manifest, folder)
            }
            .sorted { $0.manifest.createdAt > $1.manifest.createdAt }
    }

    /// The undo available right now for one display model, or `nil` when there is none this app
    /// can vouch for.
    ///
    /// - Parameter root: the override root the file is under. A record made against a different
    ///   root is ignored, so a restore can never be pointed somewhere the install was not.
    public func undo(
        vendorID: UInt32, productID: UInt32, root: URL, fileManager: FileManager = .default
    ) -> OverrideUndo? {
        for (manifest, folder) in records(fileManager: fileManager)
        where manifest.vendorID == vendorID && manifest.productID == productID
            && manifest.overrideRoot == root.path {
            guard let entry = manifest.entries.first,
                  let target = try? OverridePaths.resolve(relativePath: entry.relativePath, under: root),
                  let current = fileManager.contents(atPath: target.path),
                  SHA256Hash.hex(of: current) == entry.sha256After
            else { continue }

            guard entry.existedBefore else {
                return OverrideUndo(
                    kind: .remove, manifest: manifest,
                    relativePath: entry.relativePath, installedHash: entry.sha256After)
            }
            // A backup that is missing or is not the file that was replaced cannot be restored
            // from. Keep looking rather than offer an undo that would fail — or worse, succeed
            // with the wrong content.
            guard let backupRelative = entry.backupRelativePath, let expected = entry.sha256Before,
                  let backup = fileManager.contents(
                    atPath: folder.appendingPathComponent("backup")
                        .appendingPathComponent(backupRelative).path),
                  SHA256Hash.hex(of: backup) == expected
            else { continue }
            return OverrideUndo(
                kind: .restorePrevious(data: backup, sha256: expected), manifest: manifest,
                relativePath: entry.relativePath, installedHash: entry.sha256After)
        }
        return nil
    }
}
