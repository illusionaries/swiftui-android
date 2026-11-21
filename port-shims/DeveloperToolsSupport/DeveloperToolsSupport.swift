// DeveloperToolsSupport — platform shim for the Android port.
//
// Apple's module provides SwiftUI previews for Xcode. Recompiled for Android it contributes no
// behaviour, but SwiftUI's generated bodies reference `PreviewLayout` cases, so the types are
// declared here (cases and names copied from Apple's DeveloperToolsSupport.swiftinterface).
import Foundation

public enum PreviewLayout: Sendable {
    case device
    case sizeThatFits
    case fixed(width: CGFloat, height: CGFloat)
}

public struct PreviewTrait<T>: Sendable {}

public struct ImageResource: Hashable, Sendable {
    public init(name: String, bundle: Bundle) {
        self.name = name
        self.bundle = bundle
    }

    public let name: String
    public let bundle: Bundle
}

/// `Preview` is an empty `@MainActor` struct in Apple's interface (DeveloperToolsSupport line 64);
/// SwiftUI extends it with its own nested `ViewTraits`, so the shim must not make it generic.
@MainActor public struct Preview {
    public init() {}

    /// DeveloperToolsSupport.swiftinterface line 158: `public enum ViewTraits` nested in `Preview`.
    public enum ViewTraits {}
}

/// DeveloperToolsSupport.swiftinterface line 210.
public struct ColorResource: Hashable, Sendable {
    public init(name: String, bundle: Bundle) {
        self.name = name
        self.bundle = bundle
    }

    public let name: String
    public let bundle: Bundle
}
