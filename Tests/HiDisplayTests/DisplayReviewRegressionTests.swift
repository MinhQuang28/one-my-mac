import XCTest
@testable import HiDisplayKit

// Regression tests for the problems found in the display feature review. Grouped here rather than
// spread over the existing files so the set reads as one list of "this must not come back".

// MARK: - Identity

final class DuplicateSerialIdentityTests: XCTestCase {

    /// Two units of one model shipping the same placeholder serial used to resolve to a single
    /// `-s<hash>` key: one profile, one brightness state, duplicate view identities.
    func testTwoDisplaysWithTheSameNonZeroSerialGetDifferentKeys() {
        let displays = [
            RawDisplayInfo(cgDisplayID: 1, vendorID: 0x5A63, productID: 0x3F, serialNumber: 0x0101_0101, unitNumber: 1),
            RawDisplayInfo(cgDisplayID: 2, vendorID: 0x5A63, productID: 0x3F, serialNumber: 0x0101_0101, unitNumber: 2),
        ]
        let metadata = [
            DisplayMetadata(vendorID: 0x5A63, productID: 0x3F, serialNumber: 0x0101_0101, registryEntryID: 0x4001),
            DisplayMetadata(vendorID: 0x5A63, productID: 0x3F, serialNumber: 0x0101_0101, registryEntryID: 0x4002),
        ]
        let resolved = DisplayIdentityResolver.resolve(displays: displays, metadata: metadata)

        XCTAssertEqual(resolved.count, 2)
        XCTAssertNotEqual(resolved[0].identity.stableKey, resolved[1].identity.stableKey)
        XCTAssertEqual(resolved.map(\.identity.keyTier), [.location, .location])
        XCTAssertEqual(resolved.map(\.pairing), [.ambiguous, .ambiguous],
                       "which unit is which was decided by order, and the UI must say so")
    }

    func testDistinctSerialsStayStrong() {
        let displays = [
            RawDisplayInfo(cgDisplayID: 1, vendorID: 0x10AC, productID: 0xD0A1, serialNumber: 0xAAAA),
            RawDisplayInfo(cgDisplayID: 2, vendorID: 0x10AC, productID: 0xD0A1, serialNumber: 0xBBBB),
        ]
        let resolved = DisplayIdentityResolver.resolve(displays: displays, metadata: [])
        XCTAssertEqual(resolved.map(\.identity.keyTier), [.strong, .strong])
    }

    /// A pin is recorded against the key the heuristic produced — which, for colliding displays,
    /// is now the port-based one — and must still be honoured.
    func testPinAppliesToTheSeparatedKey() {
        let displays = [
            RawDisplayInfo(cgDisplayID: 1, vendorID: 0x5A63, productID: 0x3F, serialNumber: 7, unitNumber: 1),
            RawDisplayInfo(cgDisplayID: 2, vendorID: 0x5A63, productID: 0x3F, serialNumber: 7, unitNumber: 2),
        ]
        let heuristic = DisplayIdentityResolver.resolve(displays: displays, metadata: [])
        let pin = UUID()
        let pinned = DisplayIdentityResolver.resolve(
            displays: displays, metadata: [],
            userAssignments: [heuristic[0].identity.stableKey: pin])

        XCTAssertEqual(pinned[0].identity.userAssignedID, pin)
        XCTAssertNil(pinned[1].identity.userAssignedID)
    }
}

// MARK: - Profiles

final class ProfileMoveTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("hidisplay-profile-move-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeDisplay() -> DisplayDevice {
        DisplayDevice(
            identity: DisplayIdentity(
                cgDisplayID: 1, vendorID: 0x10AC, productID: 0xD0A1, serialNumber: 0xABCD, keyTier: .strong),
            name: "TEST", isBuiltIn: false, isOnline: true, isMain: true)
    }

    /// Pinning renames a display's key; its settings have to follow it.
    func testMoveCarriesTheProfileToTheNewKey() async {
        let store = ProfileStore(
            fileURL: directory.appendingPathComponent("profiles.json"), saveDebounce: .milliseconds(1))
        let display = makeDisplay()
        await store.setBrightness(0.3, for: display)
        await store.setController(.gamma, for: display)

        await store.moveProfile(from: display.id, to: "user-abc")

        let moved = await store.profile(for: "user-abc")
        XCTAssertEqual(moved?.brightness, 0.3)
        XCTAssertEqual(moved?.brightnessController, .gamma)
        XCTAssertEqual(moved?.displayKey, "user-abc")
        let old = await store.profile(for: display.id)
        XCTAssertNil(old)
    }

    func testForgettingAPinnedDisplayDropsItsPin() async {
        let store = ProfileStore(
            fileURL: directory.appendingPathComponent("profiles.json"), saveDebounce: .milliseconds(1))
        let pin = UUID()
        let key = "user-\(pin.uuidString.lowercased())"
        await store.assignIdentity(pin, toHeuristicKey: "v10ac-pd0a1-tdispext0")
        await store.assignIdentity(UUID(), toHeuristicKey: "v10ac-pd0a1-tdispext1")

        await store.resetProfile(key: key)

        let assignments = await store.userAssignments()
        XCTAssertNil(assignments["v10ac-pd0a1-tdispext0"], "the forgotten display's pin must go")
        XCTAssertNotNil(assignments["v10ac-pd0a1-tdispext1"], "another display's pin must stay")
    }
}

// MARK: - Brightness keys

final class BrightnessKeyHandlingTests: XCTestCase {

    private func display(vendor: UInt32, builtIn: Bool = false) -> DisplayDevice {
        DisplayDevice(
            identity: DisplayIdentity(cgDisplayID: 1, vendorID: vendor, productID: 1, serialNumber: 1, keyTier: .strong),
            name: "D", isBuiltIn: builtIn, isOnline: true, isMain: false)
    }

    func testBuiltInIsAlwaysLeftToTheSystem() {
        XCTAssertEqual(
            BrightnessKeyResolver.handling(
                for: display(vendor: 0x0610, builtIn: true), controller: nil, phase: .unavailable),
            .leaveToSystem)
    }

    /// macOS drives Apple's external displays itself; gamma dimming must not take the key away.
    func testAppleExternalDisplayWithoutDDCIsLeftToTheSystem() {
        let apple = display(vendor: BrightnessKeyResolver.appleVendorID)
        XCTAssertEqual(BrightnessKeyResolver.handling(for: apple, controller: .gamma, phase: .ready(.gamma)),
                       .leaveToSystem)
        XCTAssertEqual(BrightnessKeyResolver.handling(for: apple, controller: .ddc, phase: .ready(.ddc)),
                       .adjust, "if DDC really answered, the app's hardware control is as good as the system's")
    }

    /// A press before the first probe finished used to be computed from a default of 100% and
    /// saved over the user's value.
    func testDisplayStillProbingWaitsInsteadOfAdjusting() {
        let other = display(vendor: 0x10AC)
        XCTAssertEqual(BrightnessKeyResolver.handling(for: other, controller: nil, phase: .probing), .wait)
        XCTAssertEqual(BrightnessKeyResolver.handling(for: other, controller: nil, phase: .unavailable), .ignore)
        XCTAssertEqual(BrightnessKeyResolver.handling(for: other, controller: .ddc, phase: .ready(.ddc)), .adjust)
        XCTAssertEqual(BrightnessKeyResolver.handling(for: other, controller: .gamma, phase: .heldForDDC), .adjust)
    }
}

// MARK: - DDC write failures

final class DDCWriteFailureTests: XCTestCase {

    private func waitForWriteAttempts(_ transport: FakeDDCTransport, _ count: Int) async {
        let deadline = ContinuousClock.now + .seconds(3)
        while transport.writeAttempts < count, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        // The count is bumped before the write throws; give the queue a moment to record it.
        try? await Task.sleep(for: .milliseconds(20))
    }

    func testQueueCountsConsecutiveWriteFailuresAndClearsOnSuccess() async {
        let transport = FakeDDCTransport()
        let queue = DDCCommandQueue(transport: transport, label: "t", writeInterval: .milliseconds(1))
        transport.errorToThrow = .timeout
        await queue.setBrightness(raw: 10)
        await queue.waitUntilIdle()
        await queue.setBrightness(raw: 20)
        await queue.waitUntilIdle()
        let failed = await queue.consecutiveWriteFailures
        XCTAssertEqual(failed, 2)
        let everWrote = await queue.hasWrittenSuccessfully
        XCTAssertFalse(everWrote)

        transport.errorToThrow = nil
        await queue.setBrightness(raw: 30)
        await queue.waitUntilIdle()
        let cleared = await queue.consecutiveWriteFailures
        XCTAssertEqual(cleared, 0)
    }

    /// A monitor that stays connected but stops answering used to leave the slider moving with
    /// nothing happening and nothing reported. The controller must now say so, after one retry on
    /// a fresh transport.
    func testControllerReportsWritesThatKeepFailing() async throws {
        let transport = FakeDDCTransport()
        transport.errorToThrow = .timeout
        let binds = BindCounter()
        let controller = DDCBrightnessController(makeTransport: { _ in
            binds.increment()
            return transport
        })
        let display = makeExternalDisplay(serial: 41)

        try await controller.setBrightness(0.1, display: display)
        await waitForWriteAttempts(transport, 1)
        try await controller.setBrightness(0.2, display: display)
        await waitForWriteAttempts(transport, 2)
        XCTAssertEqual(binds.count, 1)

        // Two failures in a row: this call rebinds and tries once more.
        try await controller.setBrightness(0.3, display: display)
        await waitForWriteAttempts(transport, 3)
        XCTAssertEqual(binds.count, 2, "a run of failed writes must get a fresh transport")

        // Still failing on the fresh transport: now it is reported.
        do {
            try await controller.setBrightness(0.4, display: display)
            XCTFail("writes failing on a fresh transport must throw")
        } catch {}
    }

    func testAnIsolatedWriteFailureIsNotReported() async throws {
        let transport = FakeDDCTransport()
        let controller = DDCBrightnessController(makeTransport: { _ in transport })
        let display = makeExternalDisplay(serial: 42)

        transport.errorToThrow = .timeout
        try await controller.setBrightness(0.1, display: display)
        await waitForWriteAttempts(transport, 1)
        transport.errorToThrow = nil
        try await controller.setBrightness(0.2, display: display)
        await waitForWriteAttempts(transport, 2)
        try await controller.setBrightness(0.3, display: display)
        await waitForWriteAttempts(transport, 3)
        XCTAssertEqual(transport.recordedWrites.count, 2)
    }
}

private final class BindCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func increment() { lock.withLock { value += 1 } }
}

// MARK: - Coordinator

@MainActor
final class CoordinatorRecoveryTests: XCTestCase {

    /// "Use software dimming" on a held display: stop waiting, dim now.
    func testUseSoftwareDimmingNowLeavesTheHold() async {
        let (coordinator, ddc, gamma, _) = makeTestCoordinator()
        let display = makeExternalDisplay(serial: 51)
        await coordinator.seedDDCFacts(DDCSessionFacts(), for: display.id)
        await ddc.setProbeScript([nullDDCResult()], for: display.id)
        coordinator.savedBrightnessLookup = { _ in 0.4 }
        await coordinator.probeAndChoose(display: display)
        await waitForDDCProbeCount(ddc, key: display.id, atLeast: 5)
        XCTAssertTrue(coordinator.isHeld(display.id))

        await ddc.setProbeScript([unsupportedDDCResult()], for: display.id)
        await coordinator.useSoftwareDimmingNow(for: display)

        XCTAssertFalse(coordinator.isHeld(display.id))
        XCTAssertEqual(coordinator.controller(for: display.id), .gamma)
        XCTAssertEqual(gamma.setBrightnessCalls.last?.value, 0.4, "the saved value must be applied in software")
    }

    /// DDC reports whole steps, so a saved 0.4375 reads back as 0.44. That is the same value, and
    /// must not cost a write on every settle and wake.
    func testSavedValueWithinDDCQuantisationIsNotRewritten() async {
        let (coordinator, ddc, _, _) = makeTestCoordinator()
        let display = makeExternalDisplay(serial: 52)
        await ddc.setProbeScript([supportedDDCResult(0.44)], for: display.id)
        coordinator.savedBrightnessLookup = { _ in 0.4375 }

        await coordinator.probeAndChoose(display: display)

        let writes = await ddc.setBrightnessCalls
        XCTAssertTrue(writes.isEmpty)
    }

    func testSavedValueOutsideDDCQuantisationIsRewritten() async {
        let (coordinator, ddc, _, _) = makeTestCoordinator()
        let display = makeExternalDisplay(serial: 53)
        await ddc.setProbeScript([supportedDDCResult(0.80)], for: display.id)
        coordinator.savedBrightnessLookup = { _ in 0.4375 }

        await coordinator.probeAndChoose(display: display)

        let writes = await ddc.setBrightnessCalls
        XCTAssertEqual(writes.last?.value, 0.4375)
    }
}

// MARK: - Installer

final class InstallerReviewTests: XCTestCase {

    private var base: URL!
    private var root: URL!

    override func setUpWithError() throws {
        // /tmp: these paths go into the privileged script, which only accepts allowlisted characters.
        base = URL(fileURLWithPath: "/tmp/hidisplay-review-\(UUID().uuidString)")
        root = base.appendingPathComponent("root")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
    }

    private func makeDisplay() -> DisplayDevice {
        DisplayDevice(
            identity: DisplayIdentity(
                cgDisplayID: 1, vendorID: 0x10AC, productID: 0xD0A1, serialNumber: 0xABCD, keyTier: .strong),
            name: "TEST U2723QE", isBuiltIn: false, isOnline: true, isMain: true)
    }

    private func makeGenerated(width: Int = 1920, height: Int = 1080) -> GeneratedOverride {
        OverrideGenerator.generate(
            DisplayOverrideDocument(
                vendorID: 0x10AC, productID: 0xD0A1, displayName: "TEST U2723QE",
                scaleResolutions: [ScaledResolution(logicalWidth: width, logicalHeight: height)]),
            nativePixelSize: (3840, 2160))
    }

    private func write(_ data: Data, toRelative relativePath: String) throws {
        let target = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: target)
    }

    @discardableResult
    private func runBash(_ script: String) throws -> (status: Int32, stderr: String) {
        let bash = Process()
        bash.executableURL = URL(fileURLWithPath: "/bin/bash")
        bash.arguments = ["-c", script]
        let pipe = Pipe()
        bash.standardError = pipe
        try bash.run()
        bash.waitUntilExit()
        return (bash.terminationStatus,
                String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }

    // MARK: Staging

    /// A plan that found no file has nothing to back up and merged with nothing. If a file has
    /// appeared since, installing would overwrite it with no backup at all.
    func testStagingRefusesAFileThatAppearedAfterPlanning() throws {
        let installer = OverrideInstaller(root: root, appVersion: "test")
        let generated = makeGenerated()
        let plan = try installer.plan(generated: generated, display: makeDisplay())
        XCTAssertEqual(plan.manifest.entries.first?.existedBefore, false)

        try write(Data("another tool's override".utf8), toRelative: generated.relativePath)

        XCTAssertThrowsError(
            try installer.stageBackups(for: plan.manifest, into: base.appendingPathComponent("backup"))
        ) { error in
            guard case InstallerError.manifestMismatch = error else {
                return XCTFail("expected manifestMismatch, got \(error)")
            }
        }
    }

    // MARK: Privileged scripts

    /// Each step reports its own failure; a `mkdir` that fails must not be described as tampering.
    func testInstallScriptReportsAFolderItCannotCreateAsThat() throws {
        let staging = base.appendingPathComponent("staging")
        try Data("payload".utf8).write(to: staging)
        // A plain file where the vendor directory should be makes `mkdir -p` fail.
        let vendor = root.appendingPathComponent("DisplayVendorID-10ac")
        try Data().write(to: vendor)
        let script = try PrivilegedInstallScript.install(
            staging: staging.path, vendorDirectory: vendor.path,
            destination: vendor.appendingPathComponent("DisplayProductID-d0a1").path,
            sha256: SHA256Hash.hex(of: Data("payload".utf8)))

        let result = try runBash(script)
        XCTAssertEqual(result.status, 3)
        XCTAssertTrue(result.stderr.contains("could not create the override folder"), result.stderr)
        XCTAssertFalse(result.stderr.contains("did not match"), result.stderr)
    }

    func testInstallScriptStillReportsASwappedFileAsAMismatch() throws {
        let staging = base.appendingPathComponent("staging")
        try Data("swapped".utf8).write(to: staging)
        let vendor = root.appendingPathComponent("DisplayVendorID-10ac")
        let script = try PrivilegedInstallScript.install(
            staging: staging.path, vendorDirectory: vendor.path,
            destination: vendor.appendingPathComponent("DisplayProductID-d0a1").path,
            sha256: SHA256Hash.hex(of: Data("approved".utf8)))

        let result = try runBash(script)
        XCTAssertEqual(result.status, 1)
        XCTAssertTrue(result.stderr.contains("did not match the approved contents"), result.stderr)
    }

    func testRemoveScriptDeletesOnlyTheFileThisAppInstalled() throws {
        let vendor = root.appendingPathComponent("DisplayVendorID-10ac")
        let destination = vendor.appendingPathComponent("DisplayProductID-d0a1")
        let installed = Data("what the app wrote".utf8)
        try write(installed, toRelative: "DisplayVendorID-10ac/DisplayProductID-d0a1")

        let script = try PrivilegedInstallScript.remove(
            vendorDirectory: vendor.path, destination: destination.path,
            sha256: SHA256Hash.hex(of: installed))
        XCTAssertFalse(script.contains("\n"))
        XCTAssertFalse(script.contains("\""))
        XCTAssertFalse(script.contains("rm -r"), "nothing here may remove a tree")

        XCTAssertEqual(try runBash(script).status, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: vendor.path),
                       "an emptied vendor folder is removed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path), "the root itself is never touched")
    }

    func testRemoveScriptRefusesAFileSomeoneElseRewrote() throws {
        let vendor = root.appendingPathComponent("DisplayVendorID-10ac")
        let destination = vendor.appendingPathComponent("DisplayProductID-d0a1")
        try write(Data("rewritten by another tool".utf8), toRelative: "DisplayVendorID-10ac/DisplayProductID-d0a1")

        let script = try PrivilegedInstallScript.remove(
            vendorDirectory: vendor.path, destination: destination.path,
            sha256: SHA256Hash.hex(of: Data("what the app wrote".utf8)))

        let result = try runBash(script)
        XCTAssertEqual(result.status, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
    }

    func testRemoveScriptLeavesANonEmptyVendorFolder() throws {
        let vendor = root.appendingPathComponent("DisplayVendorID-10ac")
        let installed = Data("ours".utf8)
        try write(installed, toRelative: "DisplayVendorID-10ac/DisplayProductID-d0a1")
        try write(Data("theirs".utf8), toRelative: "DisplayVendorID-10ac/DisplayProductID-ffff")

        let script = try PrivilegedInstallScript.remove(
            vendorDirectory: vendor.path,
            destination: vendor.appendingPathComponent("DisplayProductID-d0a1").path,
            sha256: SHA256Hash.hex(of: installed))

        XCTAssertEqual(try runBash(script).status, 0)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: vendor.appendingPathComponent("DisplayProductID-ffff").path))
    }

    func testRemoveScriptRefusesUnsafeInput() {
        let hash = String(repeating: "ab", count: 32)
        XCTAssertThrowsError(try PrivilegedInstallScript.remove(
            vendorDirectory: "/tmp/v", destination: "/tmp/v/a'b", sha256: hash))
        XCTAssertThrowsError(try PrivilegedInstallScript.remove(
            vendorDirectory: "/tmp/../etc", destination: "/tmp/v/d", sha256: hash))
        XCTAssertThrowsError(try PrivilegedInstallScript.remove(
            vendorDirectory: "/tmp/v", destination: "/tmp/v/d", sha256: "zz"))
    }

    // MARK: Undo records

    /// Simulates an install: plans against the root, stages the backup, writes the payload,
    /// and records the package the way the app does.
    private func install(
        _ generated: GeneratedOverride, store: InstalledOverrideStore, at date: Date
    ) throws -> InstallationPlan {
        let installer = OverrideInstaller(root: root, appVersion: "test")
        let plan = try installer.plan(generated: generated, display: makeDisplay(), now: date)
        let package = try RecoveryPackageBuilder.create(
            manifest: plan.manifest, in: base.appendingPathComponent("downloads"), timestamp: date)
        try installer.stageBackups(for: plan.manifest, into: package.backupDirectory)
        try write(plan.payload, toRelative: generated.relativePath)
        try store.record(package)
        return plan
    }

    func testUndoOfAFirstInstallIsARemoval() throws {
        let store = InstalledOverrideStore(directory: base.appendingPathComponent("records"))
        let plan = try install(makeGenerated(), store: store, at: Date(timeIntervalSince1970: 1_000))

        let undo = try XCTUnwrap(store.undo(vendorID: 0x10AC, productID: 0xD0A1, root: root))
        XCTAssertEqual(undo.kind, .remove)
        XCTAssertEqual(undo.installedHash, SHA256Hash.hex(of: plan.payload))
    }

    /// The records behave as a stack: the newest install restores what the one before it wrote.
    func testUndoOfASecondInstallRestoresTheFirst() throws {
        let store = InstalledOverrideStore(directory: base.appendingPathComponent("records"))
        let first = try install(makeGenerated(), store: store, at: Date(timeIntervalSince1970: 1_000))
        _ = try install(
            makeGenerated(width: 2560, height: 1440), store: store, at: Date(timeIntervalSince1970: 2_000))

        let undo = try XCTUnwrap(store.undo(vendorID: 0x10AC, productID: 0xD0A1, root: root))
        guard case .restorePrevious(let data, let sha256) = undo.kind else {
            return XCTFail("expected a restore, got \(undo.kind)")
        }
        XCTAssertEqual(data, first.payload)
        XCTAssertEqual(sha256, SHA256Hash.hex(of: first.payload))

        // Put the first file back, as the undo would: the first record is now the candidate.
        try write(data, toRelative: undo.relativePath)
        let next = try XCTUnwrap(store.undo(vendorID: 0x10AC, productID: 0xD0A1, root: root))
        XCTAssertEqual(next.kind, .remove)
    }

    func testNoUndoIsOfferedForAFileThisAppDidNotWrite() throws {
        let store = InstalledOverrideStore(directory: base.appendingPathComponent("records"))
        let generated = makeGenerated()
        _ = try install(generated, store: store, at: Date(timeIntervalSince1970: 1_000))
        try write(Data("rewritten by another tool".utf8), toRelative: generated.relativePath)

        XCTAssertNil(store.undo(vendorID: 0x10AC, productID: 0xD0A1, root: root))
    }

    func testNoUndoIsOfferedForAnotherDisplayOrRoot() throws {
        let store = InstalledOverrideStore(directory: base.appendingPathComponent("records"))
        _ = try install(makeGenerated(), store: store, at: Date(timeIntervalSince1970: 1_000))

        XCTAssertNil(store.undo(vendorID: 0x10AC, productID: 0xFFFF, root: root))
        XCTAssertNil(store.undo(
            vendorID: 0x10AC, productID: 0xD0A1, root: base.appendingPathComponent("elsewhere")))
    }

    /// A record whose backup is gone cannot restore anything, and must not be offered.
    func testARecordWithAMissingBackupIsSkipped() throws {
        let records = base.appendingPathComponent("records")
        let store = InstalledOverrideStore(directory: records)
        _ = try install(makeGenerated(), store: store, at: Date(timeIntervalSince1970: 1_000))
        _ = try install(
            makeGenerated(width: 2560, height: 1440), store: store, at: Date(timeIntervalSince1970: 2_000))

        for (manifest, folder) in store.records() where manifest.entries.first?.existedBefore == true {
            try FileManager.default.removeItem(at: folder.appendingPathComponent("backup"))
        }
        XCTAssertNil(store.undo(vendorID: 0x10AC, productID: 0xD0A1, root: root))
    }

    // MARK: Recovery README

    /// `/Library` and `/Users` are on the Data volume in Recovery. The commands used to point at
    /// the sealed system volume, where neither the override nor the backup exists.
    func testRecoveryCommandsPointAtTheDataVolume() throws {
        let installer = OverrideInstaller(
            root: URL(fileURLWithPath: OverridePaths.systemOverrideRoot), appVersion: "test")
        let plan = try installer.plan(generated: makeGenerated(), display: makeDisplay())
        let readme = RecoveryPackageBuilder.readmeText(manifest: plan.manifest)

        XCTAssertTrue(readme.contains("/Volumes/Data\(OverridePaths.systemOverrideRoot)/"), readme)
        XCTAssertFalse(readme.contains("/Volumes/Macintosh HD/"), readme)
        XCTAssertTrue(readme.contains("FileVault"), readme)
    }
}
