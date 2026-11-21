// ObjectiveC — platform shim for the Android port.
//
// On Apple platforms `ObjectiveC` is the Clang module of the Objective-C runtime
// (`objc/*.h`). Retargeted SwiftUI interfaces reference exactly two of its types:
//
//   ObjectiveC.NSObject  — `@interface NSObject <NSObject>` (NSObject.h). It appears as a
//                          class constraint (`DelegateType : ObjectiveC.NSObject`), as a
//                          return type (`_makeUIHostingView`) and in class compositions
//                          (`any ObjectiveC.NSObject & SwiftUI._UIHostingViewable`).
//   ObjectiveC.Selector  — `typedef struct objc_selector *SEL` (NSObject.h), imported by
//                          Swift as a struct wrapping a method name.
//
// There is no Objective-C runtime on Android, so NSObject becomes an ordinary Swift
// class and Selector an ordinary struct. The member signatures kept below are the ones
// Apple's Swift view of NSObject exposes (`isEqual`, `hash`, `description`); the
// ObjC-runtime-only members (`class`, `superclass`, `isKind(of:)`, `conforms(to:)`,
// `responds(to:)`, `self`, `isProxy`) are deliberately not declared because they take
// `AnyClass`/`Protocol`, which only exist with an ObjC runtime. That omission is listed
// in docs/PORT-SDK.md under semantic gaps.
//
// Every body is `fatalError()` on purpose: declarations only. The Android runtime treats
// NSObject identity as plain Swift object identity.
public import Swift
public import Foundation

// MARK: - NSObject  (NSObject.h)
//
// The Swift SDK for Android's `Foundation` already ships a real `NSObject` root class
// (corelibs Foundation provides it), so redeclaring one here would make `NSObject`
// ambiguous in every file that imports both modules. `ObjectiveC.NSObject` is therefore a
// type alias for `Foundation.NSObject`, exactly as `CoreGraphics.CGFloat` aliases
// `Foundation.CGFloat` in the CoreGraphics shim.
public typealias NSObject = Foundation.NSObject
public typealias NSObjectProtocol = Foundation.NSObjectProtocol

// MARK: - Selector  (NSObject.h)

public struct Selector: Hashable, Sendable {
    public init(_ str: String) { fatalError() }
}

extension Selector: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { fatalError() }
}
