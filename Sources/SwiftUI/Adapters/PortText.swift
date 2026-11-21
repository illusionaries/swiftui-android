// PortText.swift — styled text.
//
// Apple's `Text` is a value type whose storage is either a verbatim string or a class-backed
// `AnyTextStorage` (the escape hatch its own modifiers use to accumulate styling). The port uses
// that same slot: `Text.font(...)`, `.bold()`, `.foregroundColor(...)` etc. wrap the string in a
// `PortTextStorage` carrying the resolved style, and the renderer reads it back.
#if canImport(CoreGraphics)
import CoreGraphics
import Foundation
#else
import Foundation
#endif
import FoundationShims

final class PortTextStorage: AnyTextStorage {
    var string: String
    var font: PortFontSpec?
    var color: RGBAColor?
    var weight: TextStyleDescriptor.Weight?

    init(string: String, font: PortFontSpec? = nil, color: RGBAColor? = nil,
         weight: TextStyleDescriptor.Weight? = nil) {
        self.string = string
        self.font = font
        self.color = color
        self.weight = weight
    }
}

extension Text {
    /// Text's only stored property is its storage (Apple's own `init(verbatim:)` assigns it), so
    /// the port can build the class-backed variant the same way.
    init(_portStorage storage: Text.Storage) {
        self.storage = storage
    }

    var _portStorage: PortTextStorage? {
        switch storage {
        case let .anyTextStorage(any): return any as? PortTextStorage
        default: return nil
        }
    }

    /// The literal string a `Text` carries, whichever storage shape it has.
    var _portString: String? {
        switch storage {
        case let .verbatim(value): return value
        case let .anyTextStorage(any): return (any as? PortTextStorage)?.string
        default: return nil
        }
    }

    /// Applies a styling change on top of whatever the value already carries.
    func _portRestyle(_ change: (PortTextStorage) -> Void) -> Text {
        let updated: PortTextStorage
        if let existing = _portStorage {
            updated = PortTextStorage(string: existing.string, font: existing.font,
                                      color: existing.color, weight: existing.weight)
        } else if let string = _portString {
            updated = PortTextStorage(string: string)
        } else {
            return self
        }
        change(updated)
        return Text(_portStorage: .anyTextStorage(updated))
    }

    public func font(_ font: Font?) -> Text {
        _portRestyle { $0.font = font.flatMap { PortStyleRegistry.spec(of: $0) } }
    }

    public func fontWeight(_ weight: Font.Weight?) -> Text {
        _portRestyle { storage in
            guard let weight else { return }
            storage.weight = PortAdapters.textWeight(weight)
            if var font = storage.font {
                font.weight = weight
                storage.font = font
            }
        }
    }

    public func foregroundColor(_ color: Color?) -> Text {
        _portRestyle { storage in
            guard let color, let rgba = PortStyleRegistry.rgba(of: color) else { return }
            storage.color = rgba
        }
    }

    public func foregroundStyle<S>(_ style: S) -> Text where S: ShapeStyle {
        _portRestyle { storage in
            if let color = style as? Color, let rgba = PortStyleRegistry.rgba(of: color) {
                storage.color = rgba
            }
        }
    }

    public func bold() -> Text {
        fontWeight(.bold)
    }

    public func italic() -> Text { self }

    public func kerning(_ kerning: CGFloat) -> Text { self }

    public func tracking(_ tracking: CGFloat) -> Text { self }
}
