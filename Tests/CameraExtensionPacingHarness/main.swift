// swiftc Sources/CameraExtension/StreamEmissionPolicy.swift Tests/CameraExtensionPacingHarness/main.swift -o build/extension-pacing-check
import Foundation

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
}
let ms: UInt64 = 1_000_000
var policy = StreamEmissionPolicy()
require(policy.decision(now: 0, revision: 0) == .emit, "new consumer receives standby immediately")
policy.emitted(at: 0, revision: 0)
require(policy.decision(now: 2 * ms, revision: 1) == .waitUntil(30 * ms), "fresh image respects spacing after standby")
require(policy.decision(now: 20 * ms, revision: 2) == .waitUntil(30 * ms), "burst replaces pending image without moving deadline")
require(policy.decision(now: 30 * ms, revision: 2) == .emit, "newest burst image emits at earliest safe time")
policy.emitted(at: 30 * ms, revision: 2)
require(policy.lastRevision == 2, "coalesced output records latest revision")
require(policy.decision(now: 60 * ms, revision: 2) == .idle, "watchdog does not repeat after just 30 ms")
require(policy.decision(now: 74 * ms, revision: 2) == .idle, "watchdog waits until actual output gap reaches 45 ms")
require(policy.decision(now: 75 * ms, revision: 2) == .emit, "stalled source repeats complete frame after 45 ms")
policy.emitted(at: 75 * ms, revision: 2)
require(policy.decision(now: 76 * ms, revision: 3) == .waitUntil(105 * ms), "recovery cannot burst immediately after watchdog")
require(policy.decision(now: 74 * ms, revision: 4) == .idle, "clock regression cannot emit nonmonotonic timestamps")
require(policy.decision(now: 105 * ms, revision: 0) == .emit, "opaque standby transition observes normal pacing")

// Ten seconds of 30 fps source arrivals have no timer-phase wait or watchdog duplicates.
policy = StreamEmissionPolicy()
var previous: UInt64 = 0
for revision in 1...300 {
    let now = UInt64(revision) * 33_333_333
    require(policy.decision(now: now, revision: UInt64(revision)) == .emit, "steady 30 fps input publishes immediately")
    require(now > previous, "presentation timestamps strictly increase")
    policy.emitted(at: now, revision: UInt64(revision))
    require(policy.decision(now: now + 20 * ms, revision: UInt64(revision)) == .idle, "intermediate watchdog adds no output")
    previous = now
}
// Timer scheduling jitter shorter than 3 ms cannot add a frame of latency.
policy = StreamEmissionPolicy()
for revision in 1...300 {
    let jitter = revision % 2 == 0 ? 1_000_000 : 0
    let now = UInt64(revision) * 33_333_333 + UInt64(jitter)
    require(policy.decision(now: now, revision: UInt64(revision)) == .emit, "normal arrival jitter still emits immediately")
    policy.emitted(at: now, revision: UInt64(revision))
}
policy.emitted(at: UInt64.max - 10, revision: 1)
require(policy.decision(now: UInt64.max, revision: 2) == .idle, "unrepresentable future deadline does not overflow")
print("PASS: immediate 30 fps delivery, normal jitter, bounded burst coalescing, 45 ms watchdog, standby transitions, monotonic timestamps, clock overflow")
