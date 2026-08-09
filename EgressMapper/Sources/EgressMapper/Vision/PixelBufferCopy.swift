import Foundation
import CoreVideo

/// Deep-copies a `CVPixelBuffer`.
///
/// This exists for one reason. `ARFrame.capturedImage` is backed by a buffer
/// from ARKit's own fixed-size pool, and holding it keeps its `ARFrame` alive.
/// ARKit stops delivering new frames once too few buffers are available, which
/// on device shows up as a camera preview frozen on one frame while the rest of
/// the UI keeps responding. So anything that outlives the delegate callback —
/// Vision requests in particular — must work from a copy, never the original.
enum PixelBufferCopy {

    enum CopyError: Error, Equatable {
        case allocationFailed(CVReturn)
        case baseAddressUnavailable
    }

    /// Returns an independent buffer with the same format and contents.
    /// The caller may hold this for as long as it likes.
    static func copy(_ source: CVPixelBuffer) throws -> CVPixelBuffer {
        let width = CVPixelBufferGetWidth(source)
        let height = CVPixelBufferGetHeight(source)
        let format = CVPixelBufferGetPixelFormatType(source)

        var destination: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, width, height, format, attributes as CFDictionary, &destination
        )
        guard status == kCVReturnSuccess, let destination else {
            throw CopyError.allocationFailed(status)
        }

        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(destination, [])
        defer {
            CVPixelBufferUnlockBaseAddress(destination, [])
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
        }

        // ARKit's capture format is biplanar YCbCr, so copy plane by plane.
        // A single-plane copy would silently lose the chroma plane.
        let planeCount = CVPixelBufferGetPlaneCount(source)
        if planeCount == 0 {
            guard
                let from = CVPixelBufferGetBaseAddress(source),
                let to = CVPixelBufferGetBaseAddress(destination)
            else { throw CopyError.baseAddressUnavailable }
            let sourceStride = CVPixelBufferGetBytesPerRow(source)
            let destinationStride = CVPixelBufferGetBytesPerRow(destination)
            copyRows(
                from: from, sourceStride: sourceStride,
                to: to, destinationStride: destinationStride,
                rows: height
            )
            return destination
        }

        for plane in 0..<planeCount {
            guard
                let from = CVPixelBufferGetBaseAddressOfPlane(source, plane),
                let to = CVPixelBufferGetBaseAddressOfPlane(destination, plane)
            else { throw CopyError.baseAddressUnavailable }
            copyRows(
                from: from,
                sourceStride: CVPixelBufferGetBytesPerRowOfPlane(source, plane),
                to: to,
                destinationStride: CVPixelBufferGetBytesPerRowOfPlane(destination, plane),
                rows: CVPixelBufferGetHeightOfPlane(source, plane)
            )
        }
        return destination
    }

    /// Row-wise because the two buffers may have different row padding.
    private static func copyRows(
        from source: UnsafeMutableRawPointer,
        sourceStride: Int,
        to destination: UnsafeMutableRawPointer,
        destinationStride: Int,
        rows: Int
    ) {
        if sourceStride == destinationStride {
            destination.copyMemory(from: source, byteCount: sourceStride * rows)
            return
        }
        let width = min(sourceStride, destinationStride)
        for row in 0..<rows {
            destination.advanced(by: row * destinationStride)
                .copyMemory(from: source.advanced(by: row * sourceStride), byteCount: width)
        }
    }
}
