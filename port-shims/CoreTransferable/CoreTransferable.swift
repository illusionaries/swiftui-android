// CoreTransferable — platform shim for the Android port.
//
// NOT retargeted on purpose: Apple's interface declares `Data`/`URL`/`AttributedString`
// conformances to `Transferable` that depend on a library-evolution build of Foundation.
// The Android Swift SDK ships Foundation as a *dynamic, non-resilient* module, so those
// conformances cannot be satisfied and the interface refuses to load. SwiftUI only references
// the protocol and a handful of supporting types, declared here with Apple's signatures.
//
// Behaviour (drag and drop, share sheets) has no Android counterpart in the port yet; bodies
// trap and are reachable only through API the demo does not use.

import Foundation
import UniformTypeIdentifiers

public protocol Transferable {
    associatedtype Representation: TransferRepresentation
    static var transferRepresentation: Representation { get }
}

public protocol TransferRepresentation {
    associatedtype Item: Transferable
}

public struct CodableRepresentation<Item, Encoder, Decoder>: TransferRepresentation
where Item: Transferable & Codable, Encoder: TopLevelEncoder, Decoder: TopLevelDecoder {
    public typealias Item = Item
    public init(contentType: UTType, encoder: Encoder, decoder: Decoder) {
        fatalError("CoreTransferable shim: CodableRepresentation is not implemented on Android")
    }
}

public struct ProxyRepresentation<Item, Proxy>: TransferRepresentation
where Item: Transferable, Proxy: Transferable {
    public typealias Item = Item
    public typealias Proxy = Proxy
    public init(exporting: @escaping (Item) throws -> Proxy,
                importing: @escaping (Proxy) throws -> Item) {
        fatalError("CoreTransferable shim: ProxyRepresentation is not implemented on Android")
    }
}

public struct FileRepresentation<Item>: TransferRepresentation where Item: Transferable {
    public typealias Item = Item
    public init(contentType: UTType,
                exporting: @escaping (Item) async throws -> SentTransferredFile,
                importing: @escaping (ReceivedTransferredFile) async throws -> Item) {
        fatalError("CoreTransferable shim: FileRepresentation is not implemented on Android")
    }
}

public struct DataRepresentation<Item>: TransferRepresentation where Item: Transferable {
    public typealias Item = Item
    public init(contentType: UTType,
                exporting: @escaping (Item) throws -> Data,
                importing: @escaping (Data) throws -> Item) {
        fatalError("CoreTransferable shim: DataRepresentation is not implemented on Android")
    }
}

public struct SentTransferredFile {
    public var file: URL
    public var allowAccessingOriginalFile: Bool
    public init(_ file: URL, allowAccessingOriginalFile: Bool = false) {
        self.file = file
        self.allowAccessingOriginalFile = allowAccessingOriginalFile
    }
}

public struct ReceivedTransferredFile {
    public var file: URL
    public var isOriginalFile: Bool
    public init(file: URL, isOriginalFile: Bool) {
        self.file = file
        self.isOriginalFile = isOriginalFile
    }
}

public protocol TopLevelEncoder {
    associatedtype Output
    func encode<T: Encodable>(_ value: T) throws -> Output
}

public protocol TopLevelDecoder {
    associatedtype Input
    func decode<T: Decodable>(from input: Input) throws -> T
}

public struct TransferableProxy<Item: Transferable> {
    public init(_ item: Item) { self.item = item }
    public var item: Item
}

// MARK: - Conformances for stdlib / Foundation types  (Apple interface lines 16-27, 34-46)
//
// Apple declares `Never`, `Data`, `URL` and `AttributedString` conformances to
// `Transferable` in CoreTransferable's own interface. SwiftUI's sharing/drag API defaults
// its generic parameters to these types (`ShareLink(item:"text")`, `PreviewImage == Never`,
// ...), so the conformances have to exist for the retargeted interface to typecheck.
// AttributedString is left out: corelibs Foundation has the type but SwiftUI never derives
// a Transferable conformance from it. The representation is inert on Android (no share
// sheet, no drag session), which is documented as a semantic gap in docs/PORT-SDK.md.

/// The representation used by the conformances below. It carries no behaviour.
public struct _OpaqueTransferRepresentation<Item>: TransferRepresentation where Item: Transferable {
    public typealias Item = Item
}

extension Never: Transferable {
    public typealias Representation = _OpaqueTransferRepresentation<Never>

    public static var transferRepresentation: Representation { fatalError() }
}

extension String: Transferable {
    public typealias Representation = _OpaqueTransferRepresentation<String>

    public static var transferRepresentation: Representation { fatalError() }
}

extension URL: Transferable {
    public typealias Representation = _OpaqueTransferRepresentation<URL>

    public static var transferRepresentation: Representation { fatalError() }
}

extension Data: Transferable {
    public typealias Representation = _OpaqueTransferRepresentation<Data>

    public static var transferRepresentation: Representation { fatalError() }
}

// `Never` must also satisfy `TransferRepresentation`: Apple declares `some TransferRepresentation`
// for `Color`, `Image` and `AttributedTextFormatting.Transferable`, and those opaque results
// become `Never` when the interface is recompiled from text (port rule R3).
extension Never: TransferRepresentation {
    public typealias Item = Never
}
