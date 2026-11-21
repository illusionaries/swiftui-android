// OSLog — platform shim for the Android port.
//
// Apple's OSLog is Darwin-only (closed source, and in some cases tied to ObjC/Metal).
// SwiftUI's public interface references a *small* subset of it; this module declares
// exactly that subset so Apple's real SwiftUICore/SwiftUI interfaces can be recompiled
// for Android. Declarations are copied from Apple's shipped .swiftinterface/.h files;
// behaviour is supplied by the Android runtime.
