// Text.swift — line breaking and measurement, independent of the platform.
//
// Apple measures text through CoreText; on Android the port measures through
// `Paint.measureText` over JNI. Both are hidden behind `TextMeasurer`, so the line-breaking
// algorithm here — paragraph splitting, greedy word wrap, character fallback for CJK and
// unbreakable tokens — is platform-free and unit-testable.

#if canImport(CoreGraphics)
import CoreGraphics
#else
import Foundation
#endif

public protocol TextMeasurer: AnyObject {
    /// Advance width of `text` in points (dp) for a single line.
    func advance(_ text: String, style: TextStyleDescriptor) -> CGFloat
    /// ascent (negative, above the baseline), descent, leading in points.
    func metrics(style: TextStyleDescriptor) -> (ascent: CGFloat, descent: CGFloat, leading: CGFloat)
}

/// The measurer for the current frame. The Android backend installs the canvas-backed
/// implementation at the start of `render`; host tests get the approximation below.
public enum TextMeasurement {
    nonisolated(unsafe) public static var current: TextMeasurer = ApproximateTextMeasurer()
}

/// A metrics approximation for host tests and for the first frame before a backend attaches.
/// Not pixel-accurate by design: it exists so layout logic can be exercised without a device.
public final class ApproximateTextMeasurer: TextMeasurer {
    public init() {}

    public func advance(_ text: String, style: TextStyleDescriptor) -> CGFloat {
        // Average glyph advance for the sans-serif family, per weight, in em units.
        let em: CGFloat
        switch style.weight {
        case .ultraLight, .thin, .light: em = 0.50
        case .regular: em = 0.54
        case .medium, .semibold: em = 0.56
        case .bold, .heavy, .black: em = 0.60
        }
        var width: CGFloat = 0
        for scalar in text.unicodeScalars {
            if scalar.isASCII {
                width += em
            } else {
                // CJK and emoji are full-width; combining marks are treated as narrow.
                width += scalar.isIdeographic ? 1.0 : em
            }
        }
        return width * style.size + CGFloat(max(0, text.count - 1)) * style.letterSpacing
    }

    public func metrics(style: TextStyleDescriptor) -> (ascent: CGFloat, descent: CGFloat, leading: CGFloat) {
        (ascent: -0.96 * style.size, descent: 0.24 * style.size, leading: 0)
    }
}

/// One laid-out line: its text, its origin within the text block, and its advance.
public struct TextLine: Equatable {
    public var text: String
    public var width: CGFloat
    public var baselineY: CGFloat

    public init(text: String, width: CGFloat, baselineY: CGFloat) {
        self.text = text
        self.width = width
        self.baselineY = baselineY
    }
}

public struct TextLayout: Equatable {
    public var lines: [TextLine]
    public var size: CGSize
    public var ascent: CGFloat
    public var descent: CGFloat
    public var lineHeight: CGFloat

    public static let empty = TextLayout(.init(), size: .zero, ascent: 0, descent: 0, lineHeight: 0)

    public init(_ lines: [TextLine], size: CGSize, ascent: CGFloat, descent: CGFloat, lineHeight: CGFloat) {
        self.lines = lines
        self.size = size
        self.ascent = ascent
        self.descent = descent
        self.lineHeight = lineHeight
    }
}

public enum TextLayouter {
    /// Lays out `text` inside `maxWidth` (nil = unbounded), honoring explicit newlines.
    public static func layout(_ text: String,
                              style: TextStyleDescriptor,
                              maxWidth: CGFloat?,
                              measurer: TextMeasurer = TextMeasurement.current,
                              lineLimit: Int? = nil) -> TextLayout {
        guard !text.isEmpty else { return .empty }

        let metrics = measurer.metrics(style: style)
        let lineHeight = metrics.descent - metrics.ascent + metrics.leading
        let spaceWidth = measurer.advance(" ", style: style)

        var lines: [TextLine] = []
        var y: CGFloat = 0

        for paragraph in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let wrapped = wrap(String(paragraph),
                               style: style,
                               maxWidth: maxWidth,
                               spaceWidth: spaceWidth,
                               measurer: measurer)
            for lineText in wrapped {
                if let lineLimit, lines.count >= lineLimit { break }
                let width = measurer.advance(lineText, style: style)
                lines.append(TextLine(text: lineText, width: width, baselineY: y - metrics.ascent))
                y += lineHeight
            }
            if let lineLimit, lines.count >= lineLimit { break }
        }

        if let lineLimit, lineLimit == 1, lines.count == 1, maxWidth != nil {
            // Single-line limit: report the clamped width so callers don't overflow.
            lines[0].width = min(lines[0].width, maxWidth ?? lines[0].width)
        }

        let width = lines.map(\.width).max() ?? 0
        return TextLayout(lines,
                          size: CGSize(width: width, height: CGFloat(lines.count) * lineHeight),
                          ascent: metrics.ascent,
                          descent: metrics.descent,
                          lineHeight: lineHeight)
    }

    /// Greedy word wrap with graceful handling of tokens wider than the line.
    static func wrap(_ paragraph: String,
                     style: TextStyleDescriptor,
                     maxWidth: CGFloat?,
                     spaceWidth: CGFloat,
                     measurer: TextMeasurer) -> [String] {
        guard let maxWidth, maxWidth > 0 else { return [paragraph] }
        if measurer.advance(paragraph, style: style) <= maxWidth { return [paragraph] }

        // Break into words but keep the separators, so "a b" and "a  b" round-trip sensibly.
        var tokens: [String] = []
        var current = ""
        for character in paragraph {
            if character == " " {
                if !current.isEmpty { tokens.append(current); current = "" }
                tokens.append(" ")
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { tokens.append(current) }

        var lines: [String] = []
        var line = ""
        var lineWidth: CGFloat = 0

        func flush() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { lines.append(trimmed) }
            line = ""
            lineWidth = 0
        }

        for token in tokens {
            if token == " " {
                if line.isEmpty { continue }
                line.append(" ")
                lineWidth += spaceWidth
                continue
            }

            let tokenWidth = measurer.advance(token, style: style)
            if lineWidth + tokenWidth <= maxWidth || line.isEmpty {
                if tokenWidth > maxWidth && line.isEmpty {
                    // Token wider than the whole line: break it by characters.
                    for character in token {
                        let candidate = line + String(character)
                        if measurer.advance(candidate, style: style) > maxWidth, !line.isEmpty {
                            flush()
                        }
                        line.append(character)
                        lineWidth = measurer.advance(line, style: style)
                    }
                } else {
                    line.append(token)
                    lineWidth += tokenWidth
                }
            } else {
                flush()
                line = token
                lineWidth = tokenWidth
            }
        }
        flush()
        return lines.isEmpty ? [""] : lines
    }
}

extension Unicode.Scalar {
    /// Full-width ideographs need character-level wrapping (no spaces to break on).
    var isIdeographic: Bool {
        switch value {
        case 0x3040...0x30FF,   // Hiragana, Katakana
             0x3400...0x4DBF,   // CJK Extension A
             0x4E00...0x9FFF,   // CJK Unified Ideographs
             0xF900...0xFAFF,   // CJK Compatibility Ideographs
             0xAC00...0xD7AF,   // Hangul
             0x1F300...0x1FAFF, // Emoji
             0x20000...0x2FA1F: // CJK Extensions B–F
            return true
        default:
            return false
        }
    }
}
