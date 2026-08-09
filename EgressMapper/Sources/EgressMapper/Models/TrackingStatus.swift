import Foundation
import ARKit

/// Human-readable translation of ARKit's tracking + world-mapping state.
/// Kept as a pure value type so it can be unit tested without a live session.
struct TrackingStatus: Equatable {
    enum Quality: Equatable {
        case initializing
        case normal
        case limitedFeatures
        case limitedMotion
        case relocalizing
        case limitedOther
        case notAvailable
    }

    var quality: Quality = .initializing
    var trackingText: String = "Initializing"
    var mappingText: String = "Mapping not available"
    var advice: String?
    /// True only when the world map is good enough that saving is meaningful.
    var canSave: Bool = false
    /// True when precise AR guidance may be shown.
    var isReliable: Bool = false

    var isRelocalizing: Bool { quality == .relocalizing }

    static func interpret(
        tracking: ARCamera.TrackingState,
        mapping: ARFrame.WorldMappingStatus
    ) -> TrackingStatus {
        var s = TrackingStatus()

        switch tracking {
        case .notAvailable:
            s.quality = .notAvailable
            s.trackingText = "Tracking not available"
            s.advice = "Point the camera at a well-lit, textured area."
        case .normal:
            s.quality = .normal
            s.trackingText = "Tracking normal"
            s.isReliable = true
        case .limited(let reason):
            switch reason {
            case .insufficientFeatures:
                s.quality = .limitedFeatures
                s.trackingText = "Limited — not enough visual detail"
                s.advice = "Point toward signs, doors or textured walls. Blank walls are hard to track."
            case .excessiveMotion:
                s.quality = .limitedMotion
                s.trackingText = "Limited — moving too fast"
                s.advice = "Slow down and hold the phone steadier."
            case .relocalizing:
                s.quality = .relocalizing
                s.trackingText = "Relocalizing"
                s.advice = "Stand where you started mapping and pan slowly across the same view."
            case .initializing:
                s.quality = .initializing
                s.trackingText = "Initializing"
                s.advice = "Move the phone slowly to start tracking."
            @unknown default:
                s.quality = .limitedOther
                s.trackingText = "Limited tracking"
                s.advice = "Move the phone slowly."
            }
        }

        switch mapping {
        case .notAvailable:
            s.mappingText = "Mapping not available"
        case .limited:
            s.mappingText = "Mapping limited"
        case .extending:
            s.mappingText = "Mapping extending"
        case .mapped:
            s.mappingText = "Mapped — ready to save"
        @unknown default:
            s.mappingText = "Mapping unknown"
        }

        // Saving requires both a usable map and stable tracking, otherwise the
        // saved map will not relocalize later.
        s.canSave = (mapping == .mapped || mapping == .extending) && s.quality == .normal
        return s
    }

    /// Explains, in the user's terms, why the save button is disabled.
    var saveBlockedReason: String? {
        if canSave { return nil }
        if quality != .normal {
            return "Saving needs steady, normal tracking. \(trackingText)."
        }
        return "Keep walking and looking around until mapping reaches “extending” or “mapped”."
    }
}
