import Foundation
import simd

/// `simd_float4x4` is not `Codable`. This wraps it as a flat 16-element
/// column-major array so waypoint poses survive a save/load round trip.
struct CodableTransform: Codable, Hashable {
    /// Column-major, matching `simd_float4x4`'s own memory layout.
    var m: [Float]

    init(_ t: simd_float4x4) {
        m = [
            t.columns.0.x, t.columns.0.y, t.columns.0.z, t.columns.0.w,
            t.columns.1.x, t.columns.1.y, t.columns.1.z, t.columns.1.w,
            t.columns.2.x, t.columns.2.y, t.columns.2.z, t.columns.2.w,
            t.columns.3.x, t.columns.3.y, t.columns.3.z, t.columns.3.w,
        ]
    }

    init(matrix: simd_float4x4) { self.init(matrix) }

    var matrix: simd_float4x4 {
        guard m.count == 16 else { return matrix_identity_float4x4 }
        return simd_float4x4(
            SIMD4<Float>(m[0], m[1], m[2], m[3]),
            SIMD4<Float>(m[4], m[5], m[6], m[7]),
            SIMD4<Float>(m[8], m[9], m[10], m[11]),
            SIMD4<Float>(m[12], m[13], m[14], m[15])
        )
    }

    /// Translation component — where the device was when this was captured.
    var position: SIMD3<Float> {
        guard m.count == 16 else { return .zero }
        return SIMD3<Float>(m[12], m[13], m[14])
    }

    /// Compass-style heading in radians derived from the pose's forward axis.
    /// ARKit cameras look down -Z, so forward is the negated third column.
    var heading: Float {
        let f = matrix.columns.2
        return atan2(-f.x, -f.z)
    }

    static let identity = CodableTransform(matrix_identity_float4x4)
}
