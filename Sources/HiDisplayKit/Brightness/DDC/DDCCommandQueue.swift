import Foundation

/// Serialises every DDC operation for one physical display, and coalesces slider spam into the
/// smallest number of writes that still ends on the value the user let go at.
///
/// Three properties this guarantees, all of which are requirements rather than optimisations:
///
/// * **No concurrent I2C to one display.** Actor isolation alone does not give this: every `await`
///   on the transport is a suspension point, so a drain loop and a read transaction can interleave
///   frames mid-transaction — an actor only prevents overlapping *synchronous* sections. So the
///   wire is guarded by an explicit bus token (`acquireBus`/`releaseBus`): a write holds it from
///   the frame going out until its spacing interval has passed, and a read holds it across the
///   whole request → reply-delay → reply transaction. Overlapping frames are how monitors get
///   wedged until they are power cycled.
/// * **Bounded write rate.** `writeInterval` spacing keeps a fast drag from flooding the bus.
/// * **The final value always lands.** The drain loop re-checks for a newer pending value *after*
///   each write completes, so the last position of the slider is always the last frame sent — the
///   coalescing never drops the one write that matters.
public actor DDCCommandQueue {

    /// Result of asking a display what its brightness range is.
    public struct Range: Equatable, Sendable {
        public var minimum: UInt16
        public var maximum: UInt16
        public init(minimum: UInt16 = 0, maximum: UInt16 = 100) {
            self.minimum = minimum
            self.maximum = maximum
        }
    }

    private let transport: DDCTransport
    private let label: String
    private let writeInterval: Duration
    private let readTimeout: Duration
    private let maxRetries: Int

    /// Latest requested raw value per feature, overwritten rather than queued — this is the
    /// coalescing. In arrival order, so a volume change does not jump ahead of a brightness one.
    private var pendingWrites: [(code: VCPCode, value: UInt16)] = []
    private var isDraining = false
    private var invalidated = false

    /// Whether some transaction currently owns the wire. See the bus token note in the type comment.
    private var busBusy = false
    /// Transactions waiting for the wire, resumed in arrival order.
    private var busWaiters: [CheckedContinuation<Void, Never>] = []

    /// Which wire shape this display answers, learned from its replies. See `DDC.FrameShape`.
    ///
    /// Not a preference and not knowable up front: the same monitor needs different shapes depending
    /// on the DisplayPort mode its link negotiated. Wrong-shape requests come back as null messages
    /// rather than errors, so the only way to know is to send one and look.
    /// Re-learned on every null message rather than latched once. The link mode can change under a
    /// live connection — a monitor's DisplayPort-version setting is in its OSD, and toggling it does
    /// not force a reconnect — so a shape confirmed at probe time can stop working without the queue
    /// ever being torn down.
    private var frameShape: DDC.FrameShape = .withHostAddress

    /// The shape currently in use, for diagnostics.
    public var currentFrameShape: DDC.FrameShape { frameShape }

    /// Writes that failed in a row since the last one that reached the monitor.
    ///
    /// Writes are fire-and-forget, so nothing upstream sees one fail. This count is how the
    /// controller notices a monitor that stayed connected but stopped answering — a KVM or input
    /// switch, DDC/CI turned off in the OSD — instead of moving a slider that does nothing.
    public private(set) var consecutiveWriteFailures = 0
    /// Whether any write on this queue has reached the monitor.
    public private(set) var hasWrittenSuccessfully = false

    /// - Parameter initialFrameShape: the shape to try first, normally the one persisted from a
    ///   previous connection to the same display. Wrong is cheap — the null-message fallback in
    ///   `performRead` still re-learns — but starting right skips that round-trip entirely.
    public init(
        transport: DDCTransport,
        label: String,
        writeInterval: Duration = DDC.writeInterval,
        readTimeout: Duration = .milliseconds(500),
        maxRetries: Int = 2,
        initialFrameShape: DDC.FrameShape = .withHostAddress
    ) {
        self.transport = transport
        self.label = label
        self.writeInterval = writeInterval
        self.readTimeout = readTimeout
        self.maxRetries = maxRetries
        self.frameShape = initialFrameShape
    }

    /// Stops accepting work and drops anything pending.
    ///
    /// Called when a display disconnects. Without this, in-flight retries keep firing at a monitor
    /// that no longer exists, and a reconnect arrives to find a queue still working through commands
    /// addressed to the previous connection.
    public func invalidate() {
        invalidated = true
        pendingWrites.removeAll()
    }

    public var isInvalidated: Bool { invalidated }

    /// Requests a raw brightness value. Returns as soon as the value is recorded — it does not wait
    /// for the wire, so a caller on the main actor never blocks on I2C latency.
    public func setBrightness(raw value: UInt16) {
        set(.brightness, raw: value)
    }

    /// Requests a raw value for any feature, with the same coalescing as brightness.
    public func set(_ code: VCPCode, raw value: UInt16) {
        guard !invalidated else { return }
        if let index = pendingWrites.firstIndex(where: { $0.code == code }) {
            pendingWrites[index].value = value
        } else {
            pendingWrites.append((code, value))
        }
        guard !isDraining else { return }
        isDraining = true
        Task { await drain() }
    }

    /// Suspends until the drain loop has sent everything pending. For tests: polling the transport
    /// for "no new frame in a while" mistakes a slow runner's scheduling gap for completion.
    public func waitUntilIdle() async {
        while isDraining {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    // MARK: - The bus token

    /// Waits until no other transaction is on the wire, then takes it.
    ///
    /// Plain FIFO: a released bus is handed directly to the oldest waiter, which wakes already
    /// holding it — `busBusy` never flickers false while someone is queued, so arrival order is
    /// service order.
    private func acquireBus() async {
        if !busBusy {
            busBusy = true
            return
        }
        await withCheckedContinuation { busWaiters.append($0) }
    }

    private func releaseBus() {
        if busWaiters.isEmpty {
            busBusy = false
        } else {
            busWaiters.removeFirst().resume()
        }
    }

    /// Hands `body` the transport with the wire to itself, for a diagnostic that needs raw frames.
    ///
    /// A support trace talking to the monitor through a transport of its own would interleave with
    /// a drag in progress, and the readings would describe the collision rather than the monitor.
    /// The spacing interval is paid before the bus is released, same as after any other frame.
    public func withExclusiveBus<T: Sendable>(
        _ body: @Sendable (DDCTransport) async -> T
    ) async -> T {
        await acquireBus()
        let result = await body(transport)
        try? await Task.sleep(for: writeInterval)
        releaseBus()
        return result
    }

    /// Sends every pending value in order, spaced by `writeInterval`, until nothing new arrives.
    private func drain() async {
        defer { isDraining = false }
        while !invalidated, !pendingWrites.isEmpty {
            let (code, value) = pendingWrites.removeFirst()
            await acquireBus()
            do {
                try await transport.write(
                    VCPCodec.setRequest(code: code, value: value, shape: frameShape))
                consecutiveWriteFailures = 0
                hasWrittenSuccessfully = true
            } catch {
                consecutiveWriteFailures += 1
                Log.ddcBrightness.debug("\(self.label, privacy: .public): write failed: \(String(describing: error), privacy: .public)")
                // Do not retry writes. A brightness write is idempotent and superseded a moment later
                // by the next slider position, so retrying only adds bus traffic during a drag.
            }
            // Spacing goes after the write, so a single isolated change is not delayed. It happens
            // *while still holding the bus*: the interval separates this frame from whatever goes
            // out next, and that next frame may be a read transaction waiting on the token, not
            // just this loop's own next write.
            //
            // `||` rather than `&&` is deliberate and load-bearing: the sleep must also run when
            // this looks like the last write, because a new drain can start the moment this one
            // exits and its first frame still needs the full spacing from ours.
            if !pendingWrites.isEmpty || !invalidated {
                try? await Task.sleep(for: writeInterval)
            }
            releaseBus()
        }
    }

    /// Reads current and maximum brightness, with a bounded number of retries.
    ///
    /// Retries only on transient errors — a monitor that answered "unsupported" will keep saying so,
    /// and hammering it delays every other display sharing the queue's time.
    public func readBrightness(tolerateChecksumMismatch: Bool = false) async throws -> VCPCodec.Reply {
        try await read(.brightness, tolerateChecksumMismatch: tolerateChecksumMismatch)
    }

    /// Reads any feature's current and maximum value, with the same retries as brightness.
    public func read(
        _ code: VCPCode, tolerateChecksumMismatch: Bool = false
    ) async throws -> VCPCodec.Reply {
        guard !invalidated else { throw DDCError.disconnected }

        var lastError: DDCError = .timeout
        for attempt in 0...maxRetries {
            if invalidated { throw DDCError.disconnected }
            do {
                return try await performRead(code, tolerateChecksumMismatch: tolerateChecksumMismatch)
            } catch let error as DDCError {
                lastError = error
                guard error.isRetryable else { throw error }
                if attempt < maxRetries {
                    // Linear backoff: monitors that need a second chance usually need a little more
                    // time, not exponentially more.
                    try? await Task.sleep(for: .milliseconds(100 * (attempt + 1)))
                }
            } catch let error as VCPCodec.DecodeError {
                throw DDCError.decode(error)
            }
        }
        throw lastError
    }

    /// Reads with the remembered shape, and on a null message tries the other one before giving up.
    ///
    /// A null message is the *only* signal a wrong shape gives; it is never an I/O error. Without this
    /// second attempt the app reports "no DDC" on any link whose driver disagrees with the shape it
    /// happens to be holding — which is how toggling one OSD setting on a VX2780-2K turned working DDC
    /// into none.
    private func performRead(
        _ code: VCPCode, tolerateChecksumMismatch: Bool
    ) async throws -> VCPCodec.Reply {
        do {
            return try await read(
                code, shape: frameShape, tolerateChecksumMismatch: tolerateChecksumMismatch)
        } catch DDCError.decode(.nullMessage) {
            let alternative: DDC.FrameShape =
                frameShape == .withHostAddress ? .withoutHostAddress : .withHostAddress
            // Space the retry: a display that just answered null is mid-recovery, and an immediate
            // second request is the one most likely to be ignored too.
            try? await Task.sleep(for: DDC.writeInterval)

            let reply = try await read(
                code, shape: alternative, tolerateChecksumMismatch: tolerateChecksumMismatch)
            frameShape = alternative
            Log.ddcBrightness.notice(
                "\(self.label, privacy: .public): switched to frame shape \(String(describing: alternative), privacy: .public)")
            return reply
        }
    }

    private func read(
        _ code: VCPCode, shape: DDC.FrameShape, tolerateChecksumMismatch: Bool
    ) async throws -> VCPCodec.Reply {
        // The whole request → delay → reply sequence owns the wire. Without this, a drain loop
        // started mid-transaction slips a Set frame into the reply-delay window, and the monitor
        // answers whichever frame it noticed last — or wedges.
        await acquireBus()
        defer { releaseBus() }
        guard !invalidated else { throw DDCError.disconnected }

        try await transport.write(VCPCodec.getRequest(code: code, shape: shape))
        try await Task.sleep(for: DDC.replyDelay)

        // Bound the read itself: a monitor that never answers must not hold the queue forever.
        let bytes = try await withTimeout(readTimeout) { [transport] in
            try await transport.read(length: VCPCodec.replyLength)
        }
        do {
            return try VCPCodec.decodeReply(
                bytes, expecting: code, tolerateChecksumMismatch: tolerateChecksumMismatch)
        } catch let error as VCPCodec.DecodeError {
            throw DDCError.decode(error)
        }
    }
}

/// Races an operation against a deadline.
///
/// The task group does not return until both children have finished, so an operation that cannot
/// observe cancellation — a synchronous IOKit call — is still awaited to completion before the
/// timeout error propagates. That is deliberate: the caller holds the bus token across this call,
/// and releasing it while a frame is in flight is exactly the interleave the token exists to
/// prevent. The deadline therefore bounds a transport that *can* be cancelled (the fake, or a reply
/// delay); a real I2C read is bounded by the driver's own timeout instead. Asserted by
/// `testTimeoutDoesNotReleaseTheBusWhileAnUncancellableReadIsRunning`.
func withTimeout<T: Sendable>(
    _ duration: Duration,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: duration)
            throw DDCError.timeout
        }
        guard let result = try await group.next() else { throw DDCError.timeout }
        group.cancelAll()
        return result
    }
}
