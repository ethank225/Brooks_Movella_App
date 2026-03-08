# Plan: Time-Based Progress Estimation Using Known 33 pps Rate

## Context
The current progress estimator divides `packetsReceived` by `estimatedTotalPackets` (computed as `fileSize / 88`). This is inaccurate when the 88-bytes/packet ratio doesn't match the actual BLE packet size, causing the bar to overshoot or stall. The user knows the rate is a constant 33 packets/second, so a time-based estimator is more reliable: elapsed time divided by estimated total duration, where duration = totalPackets / 33.

## Math
- Estimated total packets: `fileSize / 88` (unchanged empirical ratio)
- Estimated duration: `(fileSize / 88) / 33` = `fileSize / 2904` seconds
- Progress: `elapsedTime / estimatedDuration`

`exportStartTime` is already captured at line 96 and `now` (= `CACurrentMediaTime()`) is already computed at line 194 inside the same closure — both are in scope at the progress update site.

## File to Modify
`Brooks-Movella-App/Managers/ExportManager+BLETransfer.swift`

## Changes

**Line 57** — replace packet-count estimate with duration estimate:
```swift
// Before
let estimatedTotalPackets = max(task.cartItem.recording.fileSize / 88, 1)

// After
let estimatedDurationSeconds = max(Double(task.cartItem.recording.fileSize) / (88.0 * 33.0), 1.0)
```

**Line 197** — replace packet-ratio progress with elapsed-time progress:
```swift
// Before
let progress = min(Double(packetsReceived) / Double(estimatedTotalPackets), 0.99)

// After
let progress = min((now - exportStartTime) / estimatedDurationSeconds, 0.99)
```

`packetsReceived` is still incremented and used for the end-of-transfer stats print — no other changes needed.

## Verification
Run an export and watch the progress bar. It should advance smoothly at roughly 1/33rd of its total estimated range per second and reach ~99% just as the transfer completes.
