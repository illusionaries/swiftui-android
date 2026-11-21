// PortState.swift — `@State` and `@Binding`.
//
// Apple's declarations keep the plumbing: `State` stores `_value` plus an optional
// `AnyLocation<Value>`, and `Binding` stores a location. The engine, however, re-evaluates
// `body` every frame, so a view's stored wrappers are recreated each frame — state has to live
// outside them.
//
// `PortStateStore` is that outside: a slot table indexed by *creation order within a frame*.
// Wrapper initialisers run in a fixed order for a stable view tree, so slot N on frame k is the
// same logical state as slot N on frame k+1. (A conditional that changes how many `@State`
// wrappers are created shifts the slots after it; that limitation is documented in
// docs/RENDERER.md.)
import Foundation

/// A location that can hold a value — how `State` and `Binding` reach their storage.
protocol PortLocationBox<Value>: AnyObject {
    associatedtype Value
    var value: Value { get set }
}

final class PortStateLocation<Value>: AnyLocation<Value>, PortLocationBox {
    var value: Value

    init(_ value: Value) {
        self.value = value
    }
}

/// Backing location for `Binding(get:set:)`.
final class PortClosureLocation<Value>: AnyLocation<Value>, PortLocationBox {
    private let getter: () -> Value
    private let setter: (Value) -> Void

    init(get: @escaping () -> Value, set: @escaping (Value) -> Void) {
        self.getter = get
        self.setter = set
    }

    var value: Value {
        get { getter() }
        set { setter(newValue) }
    }
}

public enum PortStateStore {
    /// Slot index of the wrapper currently being created.
    nonisolated(unsafe) private static var cursor = 0
    nonisolated(unsafe) private static var slots: [Int: AnyObject] = [:]
    /// Set when state changes so the host can schedule another frame.
    nonisolated(unsafe) public static var isDirty = false

    /// Resets the slot cursor. Called once per frame, before `body` is evaluated.
    public static func beginFrame() {
        cursor = 0
        isDirty = false
    }

    static func nextLocation<Value>(initial: Value) -> PortStateLocation<Value> {
        let index = cursor
        cursor += 1
        if let existing = slots[index] as? PortStateLocation<Value> {
            return existing
        }
        let created = PortStateLocation(initial)
        slots[index] = created
        return created
    }

    static func markDirty() {
        isDirty = true
    }
}

// MARK: - State

extension State {
    public init(wrappedValue value: Value) {
        self._value = value
        self._location = PortStateStore.nextLocation(initial: value)
    }

    public var wrappedValue: Value {
        get { (_location as? any PortLocationBox<Value>)?.value ?? _value }
        nonmutating set {
            (_location as? any PortLocationBox<Value>)?.value = newValue
            PortStateStore.markDirty()
        }
    }

    public var projectedValue: Binding<Value> {
        Binding(get: { self.wrappedValue }, set: { self.wrappedValue = $0 })
    }
}

// MARK: - Binding

extension Binding {
    public init(get: @escaping () -> Value, set: @escaping (Value) -> Void) {
        self.location = PortClosureLocation(get: get, set: set)
        self._value = get()
        self.transaction = Transaction()
    }

    public static func constant(_ value: Value) -> Binding<Value> {
        Binding(get: { value }, set: { _ in })
    }

    public var wrappedValue: Value {
        get { (location as? any PortLocationBox<Value>)?.value ?? _value }
        nonmutating set {
            (location as? any PortLocationBox<Value>)?.value = newValue
            PortStateStore.markDirty()
        }
    }

    public var projectedValue: Binding<Value> { self }
}

// MARK: - LazyState
//
// `@State` expands (via Apple's macro) to `LazyState`, which holds either a thunk or a value plus
// an optional location. It gets the same treatment as `State`: the value lives in the slot store,
// so it survives the per-frame recreation of the view struct.

extension LazyState {
    public init(initialValue thunk: @escaping () -> Value) {
        self._storage = .thunk(thunk)
        self._location = PortStateStore.nextLocation(initial: thunk())
    }

    public var wrappedValue: Value {
        get {
            if let box = _location as? any PortLocationBox<Value> { return box.value }
            switch _storage {
            case let .value(value): return value
            case let .thunk(thunk): return thunk()
            }
        }
        nonmutating set {
            (_location as? any PortLocationBox<Value>)?.value = newValue
            PortStateStore.markDirty()
        }
    }

    public var projectedValue: Binding<Value> {
        Binding(get: { self.wrappedValue }, set: { self.wrappedValue = $0 })
    }
}
