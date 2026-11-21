// Spatial — platform shim for the Android port.
//
// Spatial is a pure ObjC/C framework with a Swift overlay (`$APPLE_SDK/usr/lib/swift/
// Spatial.swiftmodule/arm64-apple-ios-simulator.swiftinterface`). Its value types
// (`Size3D`, `Vector3D`, `Rotation3D`, `Pose3D`) are C structs from
// `usr/include/Spatial/Structures.h`; the Swift interface only adds extensions. Since
// there is no Clang importer on Android, the structs are declared here.
//
// The retargeted SwiftUI/SwiftUICore interfaces use them in visionOS-only API:
//   * `extension Spatial.Size3D : VectorArithmetic` (SwiftUICore adds `scale(by:)` and
//     `magnitudeSquared`), which is why `Size3D` must already conform to
//     `AdditiveArithmetic` — on Darwin `Spatial` provides that.
//   * `extension Spatial.Size3D : Animatable` declares
//     `animatableData: Vector3D` *and* `typealias AnimatableData = Size3D`.
//     On Darwin those are two distinct C structs and the pair only typechecks because
//     the extension is visionOS-only. On the port `Vector3D` is declared as a typealias
//     of `Size3D` (which carries both the `width/height/depth` and the `x/y/z` spellings
//     from Structures.h) so the `Animatable` conformance is consistent.
//   * `Spatial.Rotation3D` / `Spatial.Pose3D` appear as property types only.
//
// Semantic gap (docs/PORT-SDK.md): visionOS spatial API exists for API fidelity, not
// behaviour; the Android runtime has no 3D coordinate space. All bodies are `fatalError()`
// placeholders except the arithmetic, which is plain value semantics and therefore
// implemented for real.
public import Foundation

// MARK: - Size3D / Vector3D  (Spatial/Structures.h: SPSize3D, SPVector3D)

public struct Size3D: Hashable, Sendable, AdditiveArithmetic {
    public var x: Double
    public var y: Double
    public var z: Double

    public var width: Double {
        get { x }
        set { x = newValue }
    }

    public var height: Double {
        get { y }
        set { y = newValue }
    }

    public var depth: Double {
        get { z }
        set { z = newValue }
    }

    public init() {
        self.x = 0
        self.y = 0
        self.z = 0
    }

    public init(x: Double, y: Double, z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }

    public init(width: Double, height: Double, depth: Double) {
        self.x = width
        self.y = height
        self.z = depth
    }

    public static let zero = Size3D()

    public static func + (lhs: Size3D, rhs: Size3D) -> Size3D {
        Size3D(x: lhs.x + rhs.x, y: lhs.y + rhs.y, z: lhs.z + rhs.z)
    }

    public static func - (lhs: Size3D, rhs: Size3D) -> Size3D {
        Size3D(x: lhs.x - rhs.x, y: lhs.y - rhs.y, z: lhs.z - rhs.z)
    }

    public static func += (lhs: inout Size3D, rhs: Size3D) { lhs = lhs + rhs }

    public static func -= (lhs: inout Size3D, rhs: Size3D) { lhs = lhs - rhs }
}

public typealias Vector3D = Size3D

// MARK: - Rotation3D  (Structures.h: SPRotation3D, a simd_quatd)

public struct Rotation3D: Hashable, Sendable {
    public var angle: Double
    public var axis: Vector3D

    public init() { fatalError() }

    public init(angle: Double, axis: Vector3D) { fatalError() }
}

// MARK: - Pose3D  (Structures.h: SPPose3D { SPPoint3D position; SPRotation3D rotation; })

public struct Pose3D: Hashable, Sendable {
    public var position: Point3D
    public var rotation: Rotation3D

    public init() { fatalError() }

    public init(position: Point3D, rotation: Rotation3D) { fatalError() }
}

// MARK: - Point3D  (Structures.h: SPPoint3D)

public struct Point3D: Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var z: Double

    public init() { fatalError() }

    public init(x: Double, y: Double, z: Double) { fatalError() }
}
