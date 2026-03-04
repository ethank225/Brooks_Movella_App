//
//  DotGATTExplorer.swift
//  Brooks-Movella-App
//
//  Created by Ethan Kawahara on 3/2/26.
//

import CoreBluetooth
import Foundation
import MovellaDotSdk
import QuartzCore

final class DotGATTExplorer: NSObject, CBPeripheralDelegate {

    private let peripheral: CBPeripheral

    // Strong reference. peripheral.delegate is weak.
    private var originalDelegate: CBPeripheralDelegate?
    private var pendingServiceCount = 0

    /// When true, the explorer stays installed as peripheral.delegate after discovery
    /// so write ACKs and ready-to-send events are visible during export.
    /// Set before calling start(). Call stop() explicitly when done.
    var keepDelegateInstalled = false

    /// Optional: log the first N export headers for quick inspection.
    var logFirstNHeaders: Int = 0
    private var loggedHeaders = 0

    init(dot: Dot) {
        self.peripheral = dot.device.peripheral
        super.init()
    }

    func start() {
        resetSequenceState()
        originalDelegate = peripheral.delegate
        peripheral.delegate = self
        peripheral.discoverServices(nil)
        print("🔍 GATT explorer started for \(peripheral.identifier)")
    }

    func stop() {
        if seen > 0 {
            // Report based on observed anomalies; missingPkts is the one that matters for loss.
            let lossPct = missingPkts == 0 ? 0.0 : (Double(missingPkts) / Double(seen) * 100.0)
            print(
                "🔍 GATT explorer done — \(seen) notifications, missing=\(missingPkts), dup=\(duplicates), rewind=\(rewinds), groupSwitch=\(groupSwitches) (\(String(format: "%.2f", lossPct))% missing)"
            )
        }
        peripheral.delegate = originalDelegate
        originalDelegate = nil
        pendingWrites.removeAll()
        resetSequenceState()
        print("🔍 GATT explorer stopped, SDK delegate restored")
    }

    // MARK: - Discovery

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let services = peripheral.services, !services.isEmpty else {
            stop()
            return
        }
        print("\n📋 Found \(services.count) services")
        pendingServiceCount = services.count
        for service in services {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        defer {
            pendingServiceCount -= 1
            if pendingServiceCount <= 0 {
                if keepDelegateInstalled {
                    print("🔍 GATT explorer discovery complete, keeping delegate installed for logging")
                } else {
                    stop()
                }
            }
        }

        guard let chars = service.characteristics else { return }

        print("\n🔷 Service: \(service.uuid)")
        for char in chars {
            var props: [String] = []
            if char.properties.contains(.read) { props.append("read") }
            if char.properties.contains(.write) { props.append("write") }
            if char.properties.contains(.writeWithoutResponse) { props.append("writeNoResp") }
            if char.properties.contains(.notify) { props.append("notify") }
            if char.properties.contains(.indicate) { props.append("indicate") }
            print("  🔹 \(char.uuid) [\(props.joined(separator: ", "))]")
        }
    }

    // MARK: - Write Tracking

    /// FIFO queues of byte counts for in-flight .withResponse writes, keyed by characteristic UUID.
    private var pendingWrites: [CBUUID: [Int]] = [:]

    private func ts() -> String { String(format: "%.3f", Date().timeIntervalSince1970) }

    /// Wrapper for outgoing write logging. SDK writes that bypass this wrapper will still
    /// appear in didWriteValueFor but without a known byte count.
    func writeValue(_ data: Data, for characteristic: CBCharacteristic, type: CBCharacteristicWriteType) {
        let typeLabel = type == .withResponse ? "withResponse" : "withoutResponse"
        print("⏱️ \(ts()) ✏️ [\(characteristic.uuid)] → \(data.count) B [\(typeLabel)]")
        if type == .withResponse {
            pendingWrites[characteristic.uuid, default: []].append(data.count)
        }
        peripheral.writeValue(data, for: characteristic, type: type)
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        var queue = pendingWrites[characteristic.uuid] ?? []
        let bytes = queue.isEmpty ? nil : queue.removeFirst()
        pendingWrites[characteristic.uuid] = queue

        let byteStr = bytes.map { "\($0) B" } ?? "? B"
        if let error {
            print("⏱️ \(ts()) ❌ WRITE ACK [\(characteristic.uuid)] \(byteStr) withResponse → \(error.localizedDescription)")
        } else {
            print("⏱️ \(ts()) ✅ WRITE ACK [\(characteristic.uuid)] \(byteStr) withResponse")
        }

        originalDelegate?.peripheral?(peripheral, didWriteValueFor: characteristic, error: error)
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        print("⏱️ \(ts()) 📤 peripheral ready for withoutResponse writes")
        originalDelegate?.peripheralIsReady?(toSendWriteWithoutResponse: peripheral)
    }

    // MARK: - Sequence Tracking (Fixed)

    // Notify characteristic that carries export notifications (from your discovery)
    private let exportUUID = CBUUID(string: "15177003-4947-11E9-8646-D663BD873D93")

    /// Header layout observed in your logs:
    /// b[0] = kind/type (often 0x01)
    /// b[1] = group hi
    /// b[2] = group lo
    /// b[3] = idx (0x00...0xFF) wraps every 256 packets
    private struct ExportHeader: Equatable {
        let kind: UInt8
        let group: UInt16
        let idx: UInt8
    }

    private func parseHeader(_ data: Data) -> ExportHeader? {
        guard data.count >= 4 else { return nil }
        let b = [UInt8](data.prefix(4))
        let group = (UInt16(b[1]) << 8) | UInt16(b[2])
        return ExportHeader(kind: b[0], group: group, idx: b[3])
    }

    private var lastHeader: ExportHeader?

    private var seen = 0

    // These are the meaningful counters
    private var missingPkts = 0        // inferred missing indices within a group
    private var duplicates = 0         // exact duplicate idx within same group
    private var rewinds = 0            // unexpected backwards jump within same group
    private var groupSwitches = 0      // group changed (page/block changed)

    // Rate window
    private var windowStart: CFTimeInterval = 0
    private var windowBytes = 0
    private var windowPkts = 0

    private func bumpWindow(len: Int) {
        let now = CACurrentMediaTime()
        if windowStart == 0 { windowStart = now }
        windowPkts += 1
        windowBytes += len

        if now - windowStart >= 1.0 {
            let dt = now - windowStart
            print(String(format: "📈 notify: %.1f pkt/s, %.1f KB/s",
                         Double(windowPkts) / dt,
                         Double(windowBytes) / dt / 1024.0))
            windowStart = now
            windowPkts = 0
            windowBytes = 0
        }
    }

    private func resetSequenceState() {
        lastHeader = nil
        seen = 0
        missingPkts = 0
        duplicates = 0
        rewinds = 0
        groupSwitches = 0

        windowStart = 0
        windowBytes = 0
        windowPkts = 0

        loggedHeaders = 0
    }

    // MARK: - Raw Data

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value else {
            originalDelegate?.peripheral?(peripheral, didUpdateValueFor: characteristic, error: error)
            return
        }

        // Only do header-based tracking on the export notify characteristic.
        if characteristic.uuid == exportUUID, let hdr = parseHeader(data) {

            if logFirstNHeaders > 0, loggedHeaders < logFirstNHeaders {
                loggedHeaders += 1
                print(String(format: "hdr: %02X %02X %02X %02X",
                             hdr.kind,
                             UInt8(hdr.group >> 8),
                             UInt8(hdr.group & 0x00FF),
                             hdr.idx))
            }

            if let last = lastHeader {
                if hdr.group != last.group || hdr.kind != last.kind {
                    // New group or message kind: do not treat this as loss. Just note the transition.
                    groupSwitches += 1
                } else {
                    // Same group/kind: idx should progress mod 256.
                    let expected = last.idx &+ 1

                    if hdr.idx == expected {
                        // OK
                    } else if last.idx == 0xFF && hdr.idx == 0x00 {
                        // OK rollover
                    } else if hdr.idx == last.idx {
                        duplicates += 1
                        print("⚠️ DUP: group=\(String(format: "%04X", last.group)) idx=\(String(format: "%02X", hdr.idx)) (dup=\(duplicates))")
                    } else {
                        // Infer missing if it jumped forward within the same cycle without wrap.
                        // Example: last=0x10, got=0x13 => missing 0x11,0x12 (2 missing)
                        if hdr.idx > last.idx {
                            let miss = Int(hdr.idx - last.idx - 1)
                            if miss > 0 {
                                missingPkts += miss
                                print("⚠️ MISSING: group=\(String(format: "%04X", last.group)) expected=\(String(format: "%02X", expected)) got=\(String(format: "%02X", hdr.idx)) (+\(miss), missing=\(missingPkts))")
                            } else {
                                // Should not happen, but keep safe.
                                rewinds += 1
                                print("⚠️ ANOMALY: group=\(String(format: "%04X", last.group)) last=\(String(format: "%02X", last.idx)) got=\(String(format: "%02X", hdr.idx)) (rewind=\(rewinds))")
                            }
                        } else {
                            // Backwards without a wrap: likely replay, reset, or out-of-order delivery.
                            rewinds += 1
                            print("⚠️ REWIND: group=\(String(format: "%04X", last.group)) expected=\(String(format: "%02X", expected)) got=\(String(format: "%02X", hdr.idx)) (rewind=\(rewinds))")
                        }
                    }
                }
            }

            lastHeader = hdr
            seen += 1

            let isZeroTail = data.dropFirst(4).allSatisfy { $0 == 0 }
            if isZeroTail {
                print("🏁 end/status marker? kind=\(String(format: "%02X", hdr.kind)) group=\(String(format: "%04X", hdr.group)) idx=\(String(format: "%02X", hdr.idx)) len=\(data.count) seen=\(seen)")
            }

            bumpWindow(len: data.count)

        } else {
            // For other characteristics, log hex (keeps your original behavior).
            let hex = data.map { String(format: "%02X", $0) }.joined(separator: " ")
            print("📦 [\(characteristic.uuid)] \(data.count) bytes: \(hex)")
        }

        originalDelegate?.peripheral?(peripheral, didUpdateValueFor: characteristic, error: error)
    }

    // MARK: - Forward everything else to SDK

    override func responds(to aSelector: Selector!) -> Bool {
        super.responds(to: aSelector) || (originalDelegate?.responds(to: aSelector) ?? false)
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        if let orig = originalDelegate, orig.responds(to: aSelector) { return orig }
        return super.forwardingTarget(for: aSelector)
    }
}
