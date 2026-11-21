// os — platform shim for the Android port.
//
// Apple ships `os` as a Clang module (`os/log.h`, `os/lock.h`, ...) plus a 2,602-line
// Swift overlay (`$APPLE_SDK/usr/lib/swift/os.swiftmodule/arm64-apple-ios-simulator
// .swiftinterface`). The overlay is not retargetable: it imports `ObjectiveC` and
// `Builtin`, calls `_os_log_impl`, and relies on compiler builtins for the OSLog
// message format string. The retargeted SwiftUI/SwiftUICore/DeveloperToolsSupport
// interfaces reference exactly two declarations from it, which are declared here:
//
//   os::OSLog        — class, from os/log.h (`LOG_SWIFT_NAME(OSLog)`, an os_log_t
//                      handle). Members copied from the overlay's `extension os::OSLog`.
//   os::OSLogMessage — struct, from the overlay (line 910 of the interface above),
//                      used by DeveloperToolsSupport's `__designTimeString(_:fallback:)`
//                      and by SwiftUICore's preview-time string constants.
//
// NOTHING HERE LOGS ANYTHING. Every body traps: the Android runtime decides how
// diagnostics are emitted (it can forward to `android.util.Log` through the bridge).
// The `fatalError()` bodies below are deliberate placeholders — this file exists so
// that Apple's retargeted interfaces typecheck, not to implement logging.
public import Swift

// MARK: - OSLog  (os/log.h + overlay `extension os::OSLog`)

public class OSLog: @unchecked Sendable {
    public static let `default`: OSLog = OSLog(subsystem: "", category: "")

    public init(subsystem: String, category: String) { fatalError() }

    public init(subsystem: String, category: String, signpost: Void) { fatalError() }
}

// MARK: - OSLogMessage  (os overlay, line 910)

public struct OSLogMessage: ExpressibleByStringInterpolation, ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { fatalError() }

    public init(stringInterpolation: OSLogInterpolation) { fatalError() }

    public var interpolation: OSLogInterpolation { fatalError() }
}

// MARK: - OSLogInterpolation  (os overlay)

public struct OSLogInterpolation: StringInterpolationProtocol, Sendable {
    public init(literalCapacity: Int, interpolationCount: Int) { fatalError() }

    public mutating func appendLiteral(_ literal: String) { fatalError() }

    public mutating func appendInterpolation(_ argument: String) { fatalError() }

    public mutating func appendInterpolation(_ value: Int) { fatalError() }

    public mutating func appendInterpolation(_ value: Double) { fatalError() }

    public mutating func appendInterpolation(_ value: Bool) { fatalError() }
}

/// `OSLogType` — Android has no unified-logging equivalent; the port's diagnostics go to
/// stderr through the JNI layer, so these are declaration-only.
public struct OSLogType: RawRepresentable, Equatable, Hashable, Sendable {
    public var rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let `default` = OSLogType(rawValue: 0)
    public static let info = OSLogType(rawValue: 1)
    public static let debug = OSLogType(rawValue: 2)
    public static let error = OSLogType(rawValue: 16)
    public static let fault = OSLogType(rawValue: 17)
}

/// Apple's `os_log` takes an `OSLogMessage`; the port accepts the same shape and drops it.
public func os_log(_ message: OSLogMessage,
                   dso: UnsafeRawPointer = #dsohandle,
                   log: OSLog = .default,
                   type: OSLogType = .default,
                   _ args: any CVarArg...) {
    // Diagnostics are emitted by the Android runtime; the shim stays silent.
}
