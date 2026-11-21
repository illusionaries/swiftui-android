// Symbols — platform shim for the Android port.
//
// Apple's Symbols module provides SF Symbol effects. On Android there is no symbol renderer, so
// these declarations exist to give SwiftUI's declarations the type identity and metadata they
// reference (effect types are stored in view modifiers); every entry point traps.
//
// Names, conformances and members are transcribed from Apple's Symbols.swiftinterface.
import Foundation

public struct SymbolEffectConfiguration: Hashable, Sendable {
    public init() {}
    /// Storing an instance forces emission of the type metadata that clients reference.
    public static let _portInstance = SymbolEffectConfiguration()
}

public struct SymbolEffectOptions: Hashable, Sendable {
    public init() {}
    public static let _portInstance = SymbolEffectOptions()

    public static var `default`: SymbolEffectOptions { SymbolEffectOptions() }
    public static func speed(_ speed: Double) -> SymbolEffectOptions { SymbolEffectOptions() }
    public func speed(_ speed: Double) -> SymbolEffectOptions { self }
    public static func `repeat`(_ count: Int?) -> SymbolEffectOptions { SymbolEffectOptions() }
    public func `repeat`(_ count: Int?) -> SymbolEffectOptions { self }
    public static var repeating: SymbolEffectOptions { SymbolEffectOptions() }
    public func repeating(_ behavior: SymbolEffectOptions.RepeatBehavior) -> SymbolEffectOptions { self }
    public static var nonRepeating: SymbolEffectOptions { SymbolEffectOptions() }

    public struct RepeatBehavior: Hashable, Sendable {
        public static var continuous: RepeatBehavior { RepeatBehavior() }
        public static func periodic(_ count: Int, delay: Double = 0) -> RepeatBehavior { RepeatBehavior() }
    }
}

public protocol SymbolEffect: Hashable, Sendable {
    var configuration: SymbolEffectConfiguration { get }
}

@_marker public protocol IndefiniteSymbolEffect {}
@_marker public protocol DiscreteSymbolEffect {}
@_marker public protocol TransitionSymbolEffect {}
@_marker public protocol ContentTransitionSymbolEffect {}

/// The effect types Apple declares, each conforming to `SymbolEffect` plus the appropriate marker.
public struct PulseSymbolEffect: SymbolEffect, IndefiniteSymbolEffect, DiscreteSymbolEffect {
    public init() {}
    public var configuration: SymbolEffectConfiguration { SymbolEffectConfiguration() }
}

public struct BounceSymbolEffect: SymbolEffect, DiscreteSymbolEffect {
    public init() {}
    public var configuration: SymbolEffectConfiguration { SymbolEffectConfiguration() }
}

public struct VariableColorSymbolEffect: SymbolEffect, IndefiniteSymbolEffect {
    public init() {}
    public var configuration: SymbolEffectConfiguration { SymbolEffectConfiguration() }
}

public struct ScaleSymbolEffect: SymbolEffect, IndefiniteSymbolEffect, DiscreteSymbolEffect {
    public init() {}
    public var configuration: SymbolEffectConfiguration { SymbolEffectConfiguration() }
}

public struct AppearSymbolEffect: SymbolEffect, DiscreteSymbolEffect {
    public init() {}
    public var configuration: SymbolEffectConfiguration { SymbolEffectConfiguration() }
}

public struct DisappearSymbolEffect: SymbolEffect, DiscreteSymbolEffect {
    public init() {}
    public var configuration: SymbolEffectConfiguration { SymbolEffectConfiguration() }
}

public struct ReplaceSymbolEffect: SymbolEffect, DiscreteSymbolEffect {
    public init() {}
    public var configuration: SymbolEffectConfiguration { SymbolEffectConfiguration() }
}

public struct AutomaticSymbolEffect: SymbolEffect, DiscreteSymbolEffect, TransitionSymbolEffect, ContentTransitionSymbolEffect {
    public init() {}
    public var configuration: SymbolEffectConfiguration { SymbolEffectConfiguration() }
}

public struct WiggleSymbolEffect: SymbolEffect, DiscreteSymbolEffect {
    public init() {}
    public var configuration: SymbolEffectConfiguration { SymbolEffectConfiguration() }
}

public struct RotateSymbolEffect: SymbolEffect, DiscreteSymbolEffect {
    public init() {}
    public var configuration: SymbolEffectConfiguration { SymbolEffectConfiguration() }
}

public struct BreatheSymbolEffect: SymbolEffect, DiscreteSymbolEffect {
    public init() {}
    public var configuration: SymbolEffectConfiguration { SymbolEffectConfiguration() }
}

public struct DrawOnSymbolEffect: SymbolEffect, IndefiniteSymbolEffect {
    public init() {}
    public var configuration: SymbolEffectConfiguration { SymbolEffectConfiguration() }
}

public struct DrawOffSymbolEffect: SymbolEffect, IndefiniteSymbolEffect {
    public init() {}
    public var configuration: SymbolEffectConfiguration { SymbolEffectConfiguration() }
}

// MARK: - Ergonomic statics Apple declares in `extension SymbolEffect where Self == …`

public extension SymbolEffect where Self == PulseSymbolEffect {
    static var pulse: PulseSymbolEffect { PulseSymbolEffect() }
}
public extension SymbolEffect where Self == BounceSymbolEffect {
    static var bounce: BounceSymbolEffect { BounceSymbolEffect() }
}
public extension SymbolEffect where Self == VariableColorSymbolEffect {
    static var variableColor: VariableColorSymbolEffect { VariableColorSymbolEffect() }
}
public extension SymbolEffect where Self == ScaleSymbolEffect {
    static var scale: ScaleSymbolEffect { ScaleSymbolEffect() }
}
public extension SymbolEffect where Self == AppearSymbolEffect {
    static var appear: AppearSymbolEffect { AppearSymbolEffect() }
}
public extension SymbolEffect where Self == DisappearSymbolEffect {
    static var disappear: DisappearSymbolEffect { DisappearSymbolEffect() }
}
public extension SymbolEffect where Self == ReplaceSymbolEffect {
    static var replace: ReplaceSymbolEffect { ReplaceSymbolEffect() }
    static var downUp: ReplaceSymbolEffect { ReplaceSymbolEffect() }
    static var upUp: ReplaceSymbolEffect { ReplaceSymbolEffect() }
    static var offUp: ReplaceSymbolEffect { ReplaceSymbolEffect() }
}
public extension SymbolEffect where Self == AutomaticSymbolEffect {
    static var automatic: AutomaticSymbolEffect { AutomaticSymbolEffect() }
}
public extension SymbolEffect where Self == WiggleSymbolEffect {
    static var wiggle: WiggleSymbolEffect { WiggleSymbolEffect() }
}
public extension SymbolEffect where Self == RotateSymbolEffect {
    static var rotate: RotateSymbolEffect { RotateSymbolEffect() }
}
public extension SymbolEffect where Self == BreatheSymbolEffect {
    static var breathe: BreatheSymbolEffect { BreatheSymbolEffect() }
}
public extension SymbolEffect where Self == DrawOnSymbolEffect {
    static var drawOn: DrawOnSymbolEffect { DrawOnSymbolEffect() }
}
public extension SymbolEffect where Self == DrawOffSymbolEffect {
    static var drawOff: DrawOffSymbolEffect { DrawOffSymbolEffect() }
}

// MARK: - Customizers Apple declares on the effect structs
//
// Symbol effects are chainable value types (`effect.byLayer.speed(0.5)`). The port keeps that
// shape so SwiftUI's declarations type-check; the values are inert.

public extension WiggleSymbolEffect {
    func custom(angle: Double) -> WiggleSymbolEffect { self }
    var byLayer: WiggleSymbolEffect { self }
    var wholeSymbol: WiggleSymbolEffect { self }
    var reversing: WiggleSymbolEffect { self }
    var nonReversing: WiggleSymbolEffect { self }
}
public extension PulseSymbolEffect {
    var byLayer: PulseSymbolEffect { self }
    var wholeSymbol: PulseSymbolEffect { self }
    var repeating: PulseSymbolEffect { self }
    var nonRepeating: PulseSymbolEffect { self }
}
public extension BounceSymbolEffect {
    var byLayer: BounceSymbolEffect { self }
    var wholeSymbol: BounceSymbolEffect { self }
    var reversing: BounceSymbolEffect { self }
    var nonReversing: BounceSymbolEffect { self }
}
public extension VariableColorSymbolEffect {
    var reversing: VariableColorSymbolEffect { self }
    var nonReversing: VariableColorSymbolEffect { self }
    var cumulative: VariableColorSymbolEffect { self }
    var iterating: VariableColorSymbolEffect { self }
    var hideInactiveLayers: VariableColorSymbolEffect { self }
    var dimInactiveLayers: VariableColorSymbolEffect { self }
}
public extension ScaleSymbolEffect {
    var byLayer: ScaleSymbolEffect { self }
    var wholeSymbol: ScaleSymbolEffect { self }
    var up: ScaleSymbolEffect { self }
    var down: ScaleSymbolEffect { self }
}
public extension AppearSymbolEffect {
    var byLayer: AppearSymbolEffect { self }
    var wholeSymbol: AppearSymbolEffect { self }
}
public extension DisappearSymbolEffect {
    var byLayer: DisappearSymbolEffect { self }
    var wholeSymbol: DisappearSymbolEffect { self }
}
public extension ReplaceSymbolEffect {
    var byLayer: ReplaceSymbolEffect { self }
    var wholeSymbol: ReplaceSymbolEffect { self }
    var offUp: ReplaceSymbolEffect { self }
    var upUp: ReplaceSymbolEffect { self }
    var downUp: ReplaceSymbolEffect { self }
    var magic: ReplaceSymbolEffect { self }
}
public extension RotateSymbolEffect {
    var byLayer: RotateSymbolEffect { self }
    var wholeSymbol: RotateSymbolEffect { self }
    var clockwise: RotateSymbolEffect { self }
    var counterClockwise: RotateSymbolEffect { self }
}
public extension BreatheSymbolEffect {
    var byLayer: BreatheSymbolEffect { self }
    var wholeSymbol: BreatheSymbolEffect { self }
    var pulse: BreatheSymbolEffect { self }
    var plain: BreatheSymbolEffect { self }
}
public extension DrawOnSymbolEffect {
    var byLayer: DrawOnSymbolEffect { self }
    var wholeSymbol: DrawOnSymbolEffect { self }
    var individually: DrawOnSymbolEffect { self }
}
public extension DrawOffSymbolEffect {
    var byLayer: DrawOffSymbolEffect { self }
    var wholeSymbol: DrawOffSymbolEffect { self }
    var individually: DrawOffSymbolEffect { self }
}
