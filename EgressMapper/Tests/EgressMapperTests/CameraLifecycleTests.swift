import XCTest
import CoreVideo
@testable import EgressMapper

/// Bug 1: the camera preview froze or went black while mapping.
///
/// Two distinct mechanisms, tested separately:
///
/// 1. Frozen frame — the OCR pass captured `ARFrame.capturedImage` in an async
///    closure. That buffer belongs to ARKit's fixed-size pool and holding it
///    keeps its `ARFrame` alive, so ARKit stops delivering frames while the UI
///    keeps responding.
/// 2. Black preview — the session was paused and never resumed: `onDisappear`
///    fired when the add-waypoint sheet came up, and interruptions only set an
///    error string.
final class PixelBufferCopyTests: XCTestCase {

    private func makeBuffer(
        width: Int = 32, height: Int = 24, format: OSType = kCVPixelFormatType_32BGRA, fill: UInt8 = 0x7A
    ) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, width, height, format,
            [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary,
            &buffer
        )
        let created = try XCTUnwrap(buffer, "CVPixelBufferCreate failed: \(status)")
        CVPixelBufferLockBaseAddress(created, [])
        if let base = CVPixelBufferGetBaseAddress(created) {
            memset(base, Int32(fill), CVPixelBufferGetBytesPerRow(created) * height)
        }
        CVPixelBufferUnlockBaseAddress(created, [])
        return created
    }

    private func firstByte(_ buffer: CVPixelBuffer) -> UInt8? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        return CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self).pointee
    }

    func testCopyProducesAnIndependentBuffer() throws {
        let source = try makeBuffer(fill: 0x7A)
        let copy = try PixelBufferCopy.copy(source)

        XCTAssertFalse(
            copy === source,
            "the copy must be a distinct buffer — sharing it defeats the entire purpose"
        )
        XCTAssertEqual(CVPixelBufferGetWidth(copy), CVPixelBufferGetWidth(source))
        XCTAssertEqual(CVPixelBufferGetHeight(copy), CVPixelBufferGetHeight(source))
        XCTAssertEqual(CVPixelBufferGetPixelFormatType(copy), CVPixelBufferGetPixelFormatType(source))
        XCTAssertEqual(firstByte(copy), 0x7A, "contents must survive the copy")
    }

    func testMutatingTheSourceDoesNotAffectTheCopy() throws {
        let source = try makeBuffer(fill: 0x11)
        let copy = try PixelBufferCopy.copy(source)

        CVPixelBufferLockBaseAddress(source, [])
        if let base = CVPixelBufferGetBaseAddress(source) {
            memset(base, 0x99, CVPixelBufferGetBytesPerRow(source) * CVPixelBufferGetHeight(source))
        }
        CVPixelBufferUnlockBaseAddress(source, [])

        XCTAssertEqual(firstByte(source), 0x99)
        XCTAssertEqual(firstByte(copy), 0x11, "the copy must not alias ARKit's buffer")
    }

    func testBiplanarYCbCrCopiesEveryPlane() throws {
        // ARKit delivers this format; a single-plane copy would drop chroma.
        let source = try makeBuffer(format: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
        XCTAssertEqual(CVPixelBufferGetPlaneCount(source), 2)

        let copy = try PixelBufferCopy.copy(source)
        XCTAssertEqual(CVPixelBufferGetPlaneCount(copy), 2)
        for plane in 0..<2 {
            XCTAssertEqual(
                CVPixelBufferGetWidthOfPlane(copy, plane), CVPixelBufferGetWidthOfPlane(source, plane)
            )
            XCTAssertEqual(
                CVPixelBufferGetHeightOfPlane(copy, plane), CVPixelBufferGetHeightOfPlane(source, plane)
            )
        }
    }

    /// The regression itself.
    ///
    /// The check is deliberately synchronous. Waiting would pass either way,
    /// because the Vision request eventually finishes and releases whatever it
    /// captured — but "eventually" is exactly the problem: ARKit needs the
    /// buffer back within a frame or two, not whenever OCR happens to end.
    /// So the requirement is that ARKit's buffer is released *by the time
    /// `process` returns*, which only holds if the work was handed a copy.
    func testRecognizerReleasesTheARKitBufferBeforeReturning() throws {
        let recognizer = RoomSignRecognizer()
        recognizer.interval = 0

        // Large enough that the Vision pass cannot plausibly complete during
        // the synchronous assertion below.
        var source: CVPixelBuffer? = try makeBuffer(width: 1280, height: 960)
        weak var observed: AnyObject? = source

        recognizer.process(pixelBuffer: source!) { _ in }
        source = nil

        XCTAssertNil(
            observed,
            "the OCR pass is still holding ARKit's frame buffer; ARKit will starve and the preview will freeze"
        )
    }

    /// And the copy handed to the background work must stay valid, or OCR
    /// would read freed memory.
    func testTheCopyOutlivesTheOriginal() throws {
        var source: CVPixelBuffer? = try makeBuffer(fill: 0x42)
        let copy = try PixelBufferCopy.copy(source!)
        source = nil
        XCTAssertEqual(firstByte(copy), 0x42, "the copy must remain readable after ARKit reclaims its buffer")
    }

    func testThrottlingStillApplies() throws {
        let recognizer = RoomSignRecognizer()
        recognizer.interval = 60
        let buffer = try makeBuffer()

        recognizer.process(pixelBuffer: buffer) { _ in }
        // A second immediate call is inside the throttle window and must be a
        // no-op — copying on every frame would be its own performance problem.
        recognizer.process(pixelBuffer: buffer) { _ in }
    }
}

final class CameraFeedStateTests: XCTestCase {

    func testOnlyActiveCountsAsLive() {
        XCTAssertTrue(CameraFeedState.active.isLive)
        for state: CameraFeedState in [
            .idle, .stalled(seconds: 3), .interrupted, .recovering, .failed("boom"),
        ] {
            XCTAssertFalse(state.isLive, "\(state) must not report a live feed")
        }
    }

    /// The whole point of the fix: an unhealthy camera shows an explicit
    /// screen, never a bare black rectangle.
    func testEveryUnhealthyStateAsksForRecoveryUI() {
        for state: CameraFeedState in [
            .stalled(seconds: 5), .interrupted, .recovering, .failed("session failed"),
        ] {
            XCTAssertTrue(state.needsRecoveryUI, "\(state) must surface a recovery screen")
            XCTAssertFalse(state.label.isEmpty)
        }
        XCTAssertFalse(CameraFeedState.active.needsRecoveryUI)
        XCTAssertFalse(CameraFeedState.idle.needsRecoveryUI)
    }

    func testFailureReasonIsCarriedToTheUser() {
        let state = CameraFeedState.failed("Camera hardware unavailable")
        XCTAssertTrue(state.label.contains("Camera hardware unavailable"))
    }

    func testStallLabelNamesTheGap() {
        XCTAssertTrue(CameraFeedState.stalled(seconds: 7).label.contains("7"))
    }

    func testStallThresholdAllowsNormalFrameJitter() {
        // Frames arrive ~60fps; the watchdog must not fire on a brief hitch.
        XCTAssertGreaterThanOrEqual(ARSessionManager.frameStallSeconds, 1.0)
    }
}

@MainActor
final class ARSessionManagerLifecycleTests: XCTestCase {

    /// Two managers must never be confused for one another in the log — a
    /// stale retained manager running a second session is a real failure mode.
    func testEachManagerHasItsOwnIdentity() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("egress-ar-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let a = ARSessionManager(store: ZoneFileStore(root: root))
        let b = ARSessionManager(store: ZoneFileStore(root: root))

        XCTAssertNotEqual(a.instanceID, b.instanceID)
        XCTAssertEqual(a.shortID.count, 8)
        XCTAssertNotEqual(a.shortID, b.shortID)
    }

    func testAFreshManagerStartsIdleWithNoFrames() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("egress-ar-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let manager = ARSessionManager(store: ZoneFileStore(root: root))
        XCTAssertEqual(manager.cameraFeed, .idle)
        XCTAssertEqual(manager.frameCount, 0)
        XCTAssertNil(manager.lastFrameTime)
        XCTAssertEqual(manager.mode, .idle)
    }

    /// Resuming must be a no-op when nothing is running, so a stray scene-phase
    /// change cannot start a session behind the user's back.
    func testResumingAnIdleManagerDoesNothing() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("egress-ar-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let manager = ARSessionManager(store: ZoneFileStore(root: root))
        manager.resumeAfterInterruption()
        manager.handleScenePhaseActive()
        manager.handleScenePhaseBackground()

        XCTAssertEqual(manager.cameraFeed, .idle)
        XCTAssertEqual(manager.mode, .idle)
    }
}
