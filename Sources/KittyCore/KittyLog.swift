import Foundation
#if canImport(os) && canImport(Darwin)
import os
#endif

/// Unified logging via os.Logger (no self-managed log file, system handles
/// persistence, rotation and privacy).
public enum KittyLog {
    #if canImport(os) && canImport(Darwin)
    private static let logger = Logger(subsystem: "com.t3codekitty.app", category: "runtime")
    #endif

    public static func write(_ message: String) {
        #if canImport(os) && canImport(Darwin)
        logger.info("\(message, privacy: .public)")
        #else
        print("[T3CodeKitty] \(message)")
        #endif
    }
}
