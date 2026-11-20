/// Which button-ups to swallow: exactly the ones whose DOWN was swallowed.
///
/// Deciding an up from the state at release time desyncs the pair — a mapping added, removed or
/// disabled mid-press would strand an app with a stuck button-down, or feed it an up it never saw
/// the down for. Pure, so the pairing is unit-testable; the engine owns one on the tap thread.
struct ButtonPairing {
    private(set) var swallowedDowns: Set<Int> = []

    /// Records a button-down the engine decided to swallow.
    mutating func swallowDown(_ button: Int) { swallowedDowns.insert(button) }

    /// Whether to swallow this button-up. `gestureConsumed`: the drag gesture claimed it.
    mutating func shouldSwallowUp(_ button: Int, gestureConsumed: Bool) -> Bool {
        let downWasSwallowed = swallowedDowns.remove(button) != nil
        return gestureConsumed || downWasSwallowed
    }

    /// Forget every pending press. For when ups may have been missed (the tap was disabled or
    /// rebuilt): a stale entry would swallow the up of a later, unrelated click and leave that
    /// app holding the button down. The cost is one stray up if the button is in fact still held.
    mutating func reset() { swallowedDowns.removeAll() }
}
