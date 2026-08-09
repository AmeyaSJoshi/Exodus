import SwiftUI
import PhotosUI

/// Optional workflow: import a floor plan and align the recorded route to it
/// by pairing waypoints with taps on the image.
struct FloorPlanAlignmentView: View {
    let zone: MappingZone
    let waypoints: [Waypoint]
    let path: RoutePath

    @Environment(ZoneRepository.self) private var repository
    @Environment(\.dismiss) private var dismiss

    @State private var planImage: UIImage?
    @State private var photoItem: PhotosPickerItem?
    @State private var pairs: [FloorPlanAlignmentService.Correspondence] = []
    @State private var pendingWaypoint: Waypoint?
    @State private var alignment: FloorPlanAlignment?
    @State private var errorMessage: String?

    private var unpaired: [Waypoint] {
        waypoints.filter { w in
            !pairs.contains { $0.mapPoint == w.mapPoint }
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if let planImage {
                    editor(planImage)
                } else {
                    picker
                }
            }
            .navigationTitle("Floor Plan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(alignment == nil)
                }
            }
            .alert("Floor Plan", isPresented: .presenting($errorMessage)) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
            .task { load() }
        }
    }

    private var picker: some View {
        VStack(spacing: 16) {
            ContentUnavailableView(
                "No Floor Plan",
                systemImage: "photo.on.rectangle.angled",
                description: Text("Import a floor-plan image, then tap matching points to align it with your recorded walk.")
            )
            PhotosPicker(selection: $photoItem, matching: .images) {
                Label("Import Image", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.borderedProminent)
        }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let image = UIImage(data: data) {
                    planImage = image
                } else {
                    errorMessage = "That image could not be imported. Try a JPEG or PNG."
                }
            }
        }
    }

    private func editor(_ image: UIImage) -> some View {
        VStack(spacing: 0) {
            instructionBar

            GeometryReader { geo in
                let display = Self.fittedRect(imageSize: image.size, in: geo.size)
                ZStack(alignment: .topLeading) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()

                    // Existing correspondences
                    ForEach(Array(pairs.enumerated()), id: \.offset) { index, pair in
                        marker(at: toView(pair.planPoint, image: image, display: display),
                               label: "\(index + 1)", color: .orange)
                    }

                    // Live overlay of the aligned route
                    if let alignment {
                        Path { p in
                            let pts = path.simplified().map {
                                toView(alignment.apply($0.mapPoint), image: image, display: display)
                            }
                            guard let first = pts.first else { return }
                            p.move(to: first)
                            for pt in pts.dropFirst() { p.addLine(to: pt) }
                        }
                        .stroke(Color.green, lineWidth: 3)

                        ForEach(waypoints) { w in
                            marker(at: toView(alignment.apply(w.mapPoint), image: image, display: display),
                                   label: "", color: w.type.tint)
                        }
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { location in
                    handleTap(location, image: image, display: display)
                }
            }

            controls
        }
    }

    private var instructionBar: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let pendingWaypoint {
                Label("Now tap where “\(pendingWaypoint.name)” is on the plan.", systemImage: "hand.tap")
                    .foregroundStyle(.green)
            } else if pairs.count < 2 {
                Text("Select a waypoint below, then tap its location on the plan. Two pairs minimum; three gives a better fit.")
            } else if let alignment {
                Text(String(format: "Fit error: %.1f px · scale %.1f px/m", alignment.rmsError, alignment.scale))
                    .foregroundStyle(alignment.rmsError < 40 ? .green : .orange)
            }
        }
        .font(.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.ultraThinMaterial)
    }

    private var controls: some View {
        VStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(unpaired) { w in
                        Button {
                            pendingWaypoint = w
                        } label: {
                            Label(w.name, systemImage: w.type.symbolName)
                                .font(.caption)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(
                                    pendingWaypoint == w ? w.type.tint.opacity(0.4) : Color.white.opacity(0.1),
                                    in: Capsule()
                                )
                        }
                    }
                }
                .padding(.horizontal, 10)
            }

            HStack {
                Button("Undo Pair") {
                    if !pairs.isEmpty { pairs.removeLast(); recompute() }
                }
                .disabled(pairs.isEmpty)
                Spacer()
                Text("\(pairs.count) pair\(pairs.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
        .background(.ultraThinMaterial)
    }

    private func marker(at point: CGPoint, label: String, color: Color) -> some View {
        ZStack {
            Circle().fill(color).frame(width: 12, height: 12)
            if !label.isEmpty {
                Text(label).font(.system(size: 9, weight: .bold)).foregroundStyle(.black)
            }
        }
        .position(point)
    }

    // MARK: - Coordinate conversion

    /// The rect the aspect-fitted image actually occupies inside the view.
    static func fittedRect(imageSize: CGSize, in container: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
        let scale = min(container.width / imageSize.width, container.height / imageSize.height)
        let w = imageSize.width * scale
        let h = imageSize.height * scale
        return CGRect(x: (container.width - w) / 2, y: (container.height - h) / 2, width: w, height: h)
    }

    private func toImage(_ viewPoint: CGPoint, image: UIImage, display: CGRect) -> CGPoint? {
        guard display.contains(viewPoint), display.width > 0 else { return nil }
        let rx = (viewPoint.x - display.minX) / display.width
        let ry = (viewPoint.y - display.minY) / display.height
        return CGPoint(x: rx * image.size.width, y: ry * image.size.height)
    }

    private func toView(_ imagePoint: CGPoint, image: UIImage, display: CGRect) -> CGPoint {
        guard image.size.width > 0, image.size.height > 0 else { return .zero }
        return CGPoint(
            x: display.minX + (imagePoint.x / image.size.width) * display.width,
            y: display.minY + (imagePoint.y / image.size.height) * display.height
        )
    }

    // MARK: - Actions

    private func handleTap(_ location: CGPoint, image: UIImage, display: CGRect) {
        guard let waypoint = pendingWaypoint else { return }
        guard let imagePoint = toImage(location, image: image, display: display) else { return }
        pairs.append(.init(mapPoint: waypoint.mapPoint, planPoint: imagePoint))
        pendingWaypoint = nil
        recompute()
    }

    private func recompute() {
        guard pairs.count >= 2 else { alignment = nil; return }
        do {
            alignment = try FloorPlanAlignmentService.solve(pairs)
        } catch {
            alignment = nil
            errorMessage = error.localizedDescription
        }
    }

    private func load() {
        planImage = repository.store.loadFloorPlanImage(zone.id)
        alignment = repository.store.loadAlignment(zone.id)
    }

    private func save() {
        guard let alignment, let planImage else { return }
        do {
            try repository.store.saveFloorPlanImage(planImage, zoneID: zone.id)
            try repository.store.saveAlignment(alignment, zoneID: zone.id)
            var updated = zone
            updated.hasFloorPlan = true
            updated.updatedAt = Date()
            Task { await repository.upsert(updated) }
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
