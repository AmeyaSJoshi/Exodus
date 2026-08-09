import SwiftUI

/// The app's shared visual vocabulary.
///
/// Deliberately small: semantic colours, four spacing steps, three corner
/// radii, and the handful of components the screens were each re-inventing.
/// Everything here is expressed in Dynamic Type styles and SF Symbols so the
/// UI scales and reads correctly without any custom sizing.
enum EG {
    enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }

    enum Radius {
        static let control: CGFloat = 10
        static let card: CGFloat = 14
        static let prominent: CGFloat = 20
    }

    /// Minimum comfortable target for a control someone taps while moving.
    static let minTarget: CGFloat = 44
}

extension Color {
    /// The red from the app icon. Reserved for evacuation, blocked routes and
    /// destructive actions — never used for ordinary emphasis.
    static let egEmergency = Color(red: 0.87, green: 0.11, blue: 0.09)
    /// Calm confirmation: a good route, a live connection, a completed step.
    static let egSafe = Color(red: 0.16, green: 0.72, blue: 0.45)
    /// Degraded but working: cached data, limited tracking, reduced accuracy.
    static let egCaution = Color(red: 0.95, green: 0.64, blue: 0.16)
    /// Raised surface on the charcoal background.
    static let egSurface = Color.white.opacity(0.06)
    static let egSurfaceStrong = Color.white.opacity(0.10)
    static let egHairline = Color.white.opacity(0.12)
}

// MARK: - Motion

extension View {
    /// Animates only when the user has not asked for reduced motion.
    func egAnimation<V: Equatable>(_ value: V) -> some View {
        modifier(EGMotion(value: value))
    }
}

private struct EGMotion<V: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let value: V

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : .snappy(duration: 0.28), value: value)
    }
}

/// A transition that degrades to a plain fade under Reduce Motion.
struct EGTransition: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.transition(
            reduceMotion
            ? .opacity
            : .asymmetric(
                insertion: .move(edge: .top).combined(with: .opacity),
                removal: .opacity
            )
        )
    }
}

// MARK: - Brand

/// Compact wordmark. Intentionally typographic — the icon is not repeated in
/// the interface.
struct EGBrandMark: View {
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: EG.Space.xs) {
            HStack(alignment: .firstTextBaseline, spacing: EG.Space.s) {
                Text("EGRESS")
                    .font(.largeTitle.weight(.heavy))
                    .kerning(3)
                    .foregroundStyle(.primary)
                Circle()
                    .fill(Color.egEmergency)
                    .frame(width: 10, height: 10)
                    .accessibilityHidden(true)
            }
            if let subtitle {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Status

/// Every state the product reports to a person, with an icon *and* a word so
/// nothing depends on colour alone.
enum EGStatus: Equatable {
    case connected
    case connecting
    case offline
    case usingCachedMap
    case relocalizing
    case trackingLimited
    case locationFound
    case routeReady
    case rerouting
    case noSafeRoute
    case exitReached
    case custom(String, String, EGTone)

    var title: String {
        switch self {
        case .connected: return "Live updates connected"
        case .connecting: return "Connecting to live updates…"
        case .offline: return "Offline"
        case .usingCachedMap: return "Using downloaded map"
        case .relocalizing: return "Relocalizing…"
        case .trackingLimited: return "Tracking limited"
        case .locationFound: return "Location found"
        case .routeReady: return "Route ready"
        case .rerouting: return "Rerouting…"
        case .noSafeRoute: return "No safe route"
        case .exitReached: return "Exit reached"
        case .custom(let title, _, _): return title
        }
    }

    var symbol: String {
        switch self {
        case .connected: return "antenna.radiowaves.left.and.right"
        case .connecting: return "antenna.radiowaves.left.and.right.slash"
        case .offline: return "wifi.slash"
        case .usingCachedMap: return "arrow.down.circle.fill"
        case .relocalizing: return "viewfinder"
        case .trackingLimited: return "eye.trianglebadge.exclamationmark"
        case .locationFound: return "location.fill"
        case .routeReady: return "checkmark.circle.fill"
        case .rerouting: return "arrow.triangle.branch"
        case .noSafeRoute: return "exclamationmark.triangle.fill"
        case .exitReached: return "flag.checkered"
        case .custom(_, let symbol, _): return symbol
        }
    }

    var tone: EGTone {
        switch self {
        case .connected, .locationFound, .routeReady, .exitReached: return .safe
        case .connecting, .relocalizing, .rerouting: return .neutral
        case .offline, .usingCachedMap, .trackingLimited: return .caution
        case .noSafeRoute: return .critical
        case .custom(_, _, let tone): return tone
        }
    }

    /// True while the app is actively working on it.
    var isInProgress: Bool {
        switch self {
        case .connecting, .relocalizing, .rerouting: return true
        default: return false
        }
    }

    init(connection: ConnectionStatus) {
        switch connection {
        case .live: self = .connected
        case .connecting: self = .connecting
        case .offline: self = .offline
        case .error: self = .custom("Live updates unavailable", "wifi.exclamationmark", .caution)
        }
    }
}

enum EGTone {
    case safe, neutral, caution, critical

    var color: Color {
        switch self {
        case .safe: return .egSafe
        case .neutral: return .secondary
        case .caution: return .egCaution
        case .critical: return .egEmergency
        }
    }
}

/// Icon + text pill. Small, quiet, and readable at any Dynamic Type size.
struct EGStatusBadge: View {
    let status: EGStatus
    var compact = false

    var body: some View {
        HStack(spacing: EG.Space.s) {
            if status.isInProgress {
                ProgressView()
                    .controlSize(.mini)
                    .tint(status.tone.color)
            } else {
                Image(systemName: status.symbol)
                    .foregroundStyle(status.tone.color)
            }
            Text(status.title)
                .foregroundStyle(compact ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
        }
        .font(compact ? .caption : .subheadline)
        .padding(.horizontal, compact ? EG.Space.s : EG.Space.m)
        .padding(.vertical, compact ? EG.Space.xs : EG.Space.s)
        .background(Color.egSurface, in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(status.title)
    }
}

/// Inline connection line for list rows, where a pill would look heavy.
struct EGConnectionRow: View {
    let connection: ConnectionStatus
    var usingCache = false

    var body: some View {
        VStack(alignment: .leading, spacing: EG.Space.xs) {
            EGStatusBadge(status: EGStatus(connection: connection))
            if usingCache {
                Label(
                    "Live closures unavailable — the downloaded map is being used.",
                    systemImage: "arrow.down.circle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Banner

/// A short, high-contrast message. Used for reroutes, closures and warnings.
struct EGBanner: View {
    let title: String
    var detail: String?
    var tone: EGTone = .caution
    var symbol: String?
    var onDismiss: (() -> Void)?

    private var icon: String {
        symbol ?? (tone == .critical ? "exclamationmark.triangle.fill" : "info.circle.fill")
    }

    var body: some View {
        HStack(alignment: .top, spacing: EG.Space.m) {
            Image(systemName: icon)
                .font(.headline)
                .foregroundStyle(tone.color)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                if let detail {
                    Text(detail).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: EG.minTarget, height: EG.minTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
            }
        }
        .padding(.leading, EG.Space.m)
        .padding(.vertical, EG.Space.m)
        .padding(.trailing, onDismiss == nil ? EG.Space.m : 0)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.egSurfaceStrong, in: RoundedRectangle(cornerRadius: EG.Radius.card))
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(tone.color)
                .frame(width: 4)
                .clipShape(
                    UnevenRoundedRectangle(
                        topLeadingRadius: EG.Radius.card,
                        bottomLeadingRadius: EG.Radius.card
                    )
                )
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Containers

/// Grouped block with an optional heading. The administrative screens use it
/// so unrelated controls stop sharing one undifferentiated surface.
struct EGCard<Content: View>: View {
    var title: String?
    var footnote: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: EG.Space.m) {
            if let title {
                Text(title.uppercased())
                    .font(.caption.weight(.semibold))
                    .kerning(0.6)
                    .foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
            }
            content
            if let footnote {
                Text(footnote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(EG.Space.l)
        .background(Color.egSurface, in: RoundedRectangle(cornerRadius: EG.Radius.card))
    }
}

// MARK: - Buttons

/// The one dominant action on a screen. Red only when it is the emergency
/// path or genuinely destructive.
struct EGPrimaryButtonStyle: ButtonStyle {
    var tone: EGTone = .critical
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: EG.minTarget)
            .padding(.vertical, EG.Space.m)
            .background(
                (tone == .neutral ? Color.accentColor : tone.color).opacity(isEnabled ? 1 : 0.35),
                in: RoundedRectangle(cornerRadius: EG.Radius.control)
            )
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}

/// Everything that is not the primary action on the screen.
struct EGSecondaryButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.medium))
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, minHeight: EG.minTarget, alignment: .leading)
            .padding(.horizontal, EG.Space.l)
            .padding(.vertical, EG.Space.m)
            .background(Color.egSurface, in: RoundedRectangle(cornerRadius: EG.Radius.control))
            .overlay(
                RoundedRectangle(cornerRadius: EG.Radius.control)
                    .stroke(Color.egHairline, lineWidth: 1)
            )
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}

// MARK: - Map labels

/// Places node captions on the top-down maps without letting them overlap.
///
/// Adjacent rooms sit a few points apart on screen, so drawing every caption at
/// a fixed offset above its dot produced overlapping runs like
/// "East StairwellEast Exit". Each label takes the first candidate offset that
/// is still free.
struct EGMapLabelLayout {
    private var placed: [CGRect] = []
    private static let offsets: [CGFloat] = [-14, -26, 18, 30, -38, 42]

    /// The point to draw `text` centred on, given the node's screen position.
    ///
    /// Pass `within` to keep captions inside the canvas: a node near the left
    /// edge would otherwise centre its name off-screen and render as "Vest
    /// Exit".
    mutating func position(
        for text: String, at point: CGPoint, fontSize: CGFloat, within canvas: CGSize? = nil
    ) -> CGPoint {
        // Canvas cannot measure text, so approximate: 0.58em average advance.
        let width = CGFloat(text.count) * fontSize * 0.58 + 6
        let height = fontSize + 4

        var x = point.x
        if let canvas {
            let half = width / 2
            // Only clamps when the caption would actually leave the canvas, so
            // labels stay centred on their node wherever there is room.
            x = min(max(x, half + 2), max(half + 2, canvas.width - half - 2))
        }

        for dy in Self.offsets {
            var y = point.y + dy
            if let canvas {
                y = min(max(y, height / 2 + 2), max(height / 2 + 2, canvas.height - height / 2 - 2))
            }
            let rect = CGRect(x: x - width / 2, y: y - height / 2, width: width, height: height)
            if !placed.contains(where: { $0.intersects(rect) }) {
                placed.append(rect)
                return CGPoint(x: x, y: y)
            }
        }
        return CGPoint(x: x, y: point.y + Self.offsets[0])
    }
}

// MARK: - States

/// Loading with a sentence that says what is being waited on. Never a bare
/// spinner, never a fabricated percentage.
struct EGLoadingState: View {
    let title: String
    var detail: String?

    var body: some View {
        VStack(spacing: EG.Space.m) {
            ProgressView()
                .controlSize(.large)
            Text(title)
                .font(.headline)
                .multilineTextAlignment(.center)
            if let detail {
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, EG.Space.xl)
        .accessibilityElement(children: .combine)
    }
}

/// Empty state that names the next action instead of only reporting absence.
struct EGEmptyState: View {
    let title: String
    let message: String
    var symbol: String = "tray"
    var tone: EGTone = .neutral
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: EG.Space.m) {
            Image(systemName: symbol)
                .font(.system(size: 38))
                .foregroundStyle(tone == .neutral ? AnyShapeStyle(.secondary) : AnyShapeStyle(tone.color))
                .accessibilityHidden(true)
            Text(title)
                .font(.headline)
                .multilineTextAlignment(.center)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .tint(.accentColor)
                    .padding(.top, EG.Space.xs)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, EG.Space.xl)
        .padding(.horizontal, EG.Space.l)
    }
}
