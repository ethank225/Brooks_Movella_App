//
//  DotDevice+Helpers.swift
//  Brooks-Movella-App
//
//  Created by Ethan Kawahara on 2/1/26.
//

import Foundation
import MovellaDotSdk

extension DotDevice {

    /// Returns the best available identifier: MAC address or UUID.
    func displayAddress() -> String {
        return macAddress
    }

    /// Short display name for UI: last 5 chars of MAC or UUID.
    func shortName() -> String {
        let addr = displayAddress()
        if addr.count > 5 {
            return String(addr.suffix(5))
        }
        return addr
    }
}
