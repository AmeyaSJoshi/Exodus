import Foundation

/// Everything the publisher needs from a backend, expressed so the ordering
/// rules (upload first, publish last) can be tested without a network.
protocol MapPackageUploading: Sendable {
    /// Puts bytes at `path` inside the artifacts bucket.
    func upload(path: String, data: Data, contentType: String) async throws
    /// Best-effort removal used to clean up after a failed publish.
    func remove(paths: [String]) async
    /// Records the artifact row that points at a stored object.
    func recordArtifacts(_ artifacts: [PackageArtifact], manifest: MapPackageManifest) async throws
    /// Records OCR-searchable aliases for the version's nodes.
    func recordAliases(_ aliases: [UUID: [String]], mapVersionID: UUID) async throws
    /// Flips the draft version to published. Called only after every upload.
    func publishVersion(mapVersionID: UUID) async throws
}

/// The read side. `manifest` is metadata-only and cheap; `download` pulls the
/// large binaries, and is deliberately a separate call so metadata discovery
/// never drags an ARWorldMap down with it.
protocol MapPackageFetching: Sendable {
    func manifest(buildingID: UUID, mapVersionID: UUID) async throws -> MapPackageManifest
    func download(path: String) async throws -> Data
}

// MARK: - Publishing

/// Publishes a complete package: artifacts to Storage, rows to Postgres, then —
/// and only then — the version itself.
///
/// If any upload fails the version is left as a draft and the objects already
/// written are removed, so a half-uploaded package can never appear published.
struct MapPackagePublisher {
    let uploader: MapPackageUploading

    struct Outcome: Equatable {
        var manifest: MapPackageManifest
        var uploadedPaths: [String]
        var artifactCount: Int
    }

    func publish(
        manifest: MapPackageManifest,
        artifacts pending: [PendingArtifact],
        aliases: [UUID: [String]] = [:]
    ) async throws -> Outcome {
        var uploaded: [String] = []

        func rollback() async {
            guard !uploaded.isEmpty else { return }
            await uploader.remove(paths: uploaded)
        }

        // 1. Binaries.
        for item in pending {
            guard let described = manifest.artifacts.first(where: { $0.id == item.id }) else {
                await rollback()
                throw MapPackageError.missingArtifact(item.fileName)
            }
            do {
                try await uploader.upload(
                    path: described.storagePath,
                    data: item.data,
                    contentType: contentType(for: described.kind)
                )
                uploaded.append(described.storagePath)
            } catch {
                await rollback()
                throw error
            }
        }

        // 2. The manifest itself, so the package is self-describing in Storage.
        let manifestArtifact = PackageArtifact(
            id: UUID(),
            kind: .package,
            zoneID: nil,
            floorID: manifest.defaultFloorID,
            storagePath: MapPackageBuilder.storagePath(
                buildingID: manifest.buildingID,
                mapVersionID: manifest.mapVersionID,
                fileName: MapPackageBuilder.manifestFileName
            ),
            byteSize: 0,
            checksum: "",
            viewpoint: nil,
            localFileName: MapPackageBuilder.manifestFileName
        )

        let manifestData: Data
        do {
            manifestData = try MapPackageCoder.encode(manifest)
        } catch {
            await rollback()
            throw error
        }

        var stored = manifestArtifact
        stored.byteSize = manifestData.count
        stored.checksum = PackageChecksum.sha256(manifestData)

        do {
            try await uploader.upload(
                path: stored.storagePath, data: manifestData, contentType: "application/json"
            )
            uploaded.append(stored.storagePath)
        } catch {
            await rollback()
            throw error
        }

        // A partial upload must never reach the publish step.
        let expected = pending.count + 1
        guard uploaded.count == expected else {
            await rollback()
            throw MapPackageError.incompleteUpload(uploaded: uploaded.count, expected: expected)
        }

        // 3. Rows referencing the stored objects.
        do {
            try await uploader.recordArtifacts(manifest.artifacts + [stored], manifest: manifest)
            if !aliases.isEmpty {
                try await uploader.recordAliases(aliases, mapVersionID: manifest.mapVersionID)
            }
            // 4. Publish last: a new immutable version, old ones untouched.
            try await uploader.publishVersion(mapVersionID: manifest.mapVersionID)
        } catch {
            await rollback()
            throw error
        }

        return Outcome(
            manifest: manifest, uploadedPaths: uploaded, artifactCount: manifest.artifacts.count + 1
        )
    }

    private func contentType(for kind: PackageArtifact.Kind) -> String {
        switch kind {
        case .worldmap: return "application/octet-stream"
        case .referenceImage, .floorplan: return "image/jpeg"
        case .package: return "application/json"
        }
    }
}

// MARK: - Downloading

/// Fetches, verifies and caches a package. The previously cached version stays
/// in place until the new one has passed every check.
struct MapPackageDownloader {
    let source: MapPackageFetching
    let cache: MapPackageCache

    struct Outcome: Equatable {
        var version: Int
        var artifactCount: Int
        /// True when a failed update left an older good package in place.
        var keptPreviousVersion: Bool
    }

    /// - Parameter progress: called with 0…1 as artifacts arrive.
    @discardableResult
    func download(
        buildingID: UUID,
        mapVersionID: UUID,
        progress: ((Double) -> Void)? = nil
    ) async throws -> Outcome {
        let previous = cache.cachedVersion(buildingID: buildingID)

        do {
            let manifest = try await source.manifest(
                buildingID: buildingID, mapVersionID: mapVersionID
            )
            guard manifest.isSchemaSupported else {
                throw MapPackageError.unsupportedSchema(manifest.schemaVersion)
            }

            let needed = manifest.artifacts.filter { $0.kind != .package }
            var files: [String: Data] = [:]
            for (index, artifact) in needed.enumerated() {
                files[artifact.storagePath] = try await source.download(path: artifact.storagePath)
                progress?(Double(index + 1) / Double(max(needed.count, 1)))
            }

            // Verify before anything touches the live cache directory.
            try MapPackageValidator.verify(manifest: manifest, files: files)
            try cache.store(manifest: manifest, files: files)

            return Outcome(
                version: manifest.version,
                artifactCount: manifest.artifacts.count,
                keptPreviousVersion: false
            )
        } catch {
            // The old package is still whole — say so rather than pretending
            // the building became unavailable.
            if let previous, cache.manifest(buildingID: buildingID) != nil {
                _ = previous
                throw MapPackageDownloadFailure(underlying: error, keptCachedVersion: previous)
            }
            throw error
        }
    }
}

/// Raised when an update fails but a usable older package survives.
struct MapPackageDownloadFailure: LocalizedError {
    var underlying: Error
    var keptCachedVersion: Int

    var errorDescription: String? {
        "\(underlying.localizedDescription) Keeping the downloaded v\(keptCachedVersion)."
    }
}

// MARK: - Coding

enum MapPackageCoder {
    /// Fractional seconds are kept so a manifest round-trips byte-identically:
    /// the checksum of a re-encoded manifest must match the one that was
    /// uploaded, and plain ISO8601 would silently truncate the timestamp.
    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(isoFormatter.string(from: date))
        }
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        // Accepts timestamps with or without fractional seconds, so a manifest
        // written by any producer still decodes.
        d.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            guard let date = ISO8601DateFormatter.egressParsers
                .compactMap({ $0.date(from: raw) }).first else {
                throw DecodingError.dataCorrupted(
                    .init(codingPath: decoder.codingPath, debugDescription: "Bad date: \(raw)")
                )
            }
            return date
        }
        return d
    }()

    static func encode(_ manifest: MapPackageManifest) throws -> Data {
        try encoder.encode(manifest)
    }

    static func decode(_ data: Data) throws -> MapPackageManifest {
        try decoder.decode(MapPackageManifest.self, from: data)
    }
}
