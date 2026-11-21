// UniformTypeIdentifiers — platform shim for the Android port.
public struct UTType: Hashable, Sendable {
    public var identifier: String
    public init?(_ identifier: String) { self.identifier = identifier }
    public init?(filenameExtension: String) { self.identifier = filenameExtension }
    public init?(mimeType: String) { self.identifier = mimeType }
    public static let plainText = UTType("public.plain-text")!
    public static let utf8PlainText = UTType("public.utf8-plain-text")!
    public static let text = UTType("public.text")!
    public static let data = UTType("public.data")!
    public static let image = UTType("public.image")!
    public static let png = UTType("public.png")!
    public static let jpeg = UTType("public.jpeg")!
    public static let url = UTType("public.url")!
    public static let fileURL = UTType("public.file-url")!
}
