import Foundation

/// On-disk store for downloaded map packages.
///
/// Layout: `Application Support/Packages/<building_id>/v<version>/`, containing
/// `manifest.json` plus every artifact under its own file name. A new version
/// is assembled in a staging directory and moved into place only once it has
/// verified, so an interrupted download can never replace a good package.
struct MapPackageCache {
    let root: URL

    init(root: URL? = nil) {
        if let root {
            self.root = root
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.root = base.appendingPathComponent("Packages", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
    }

    func buildingDirectory(_ buildingID: UUID) -> URL {
        root.appendingPathComponent(buildingID.uuidString, isDirectory: true)
    }

    func versionDirectory(_ buildingID: UUID, version: Int) -> URL {
        buildingDirectory(buildingID).appendingPathComponent("v\(version)", isDirectory: true)
    }

    // MARK: - Reading

    /// Every complete version present for a building, newest first.
    func cachedVersions(buildingID: UUID) -> [Int] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: buildingDirectory(buildingID), includingPropertiesForKeys: nil
        ) else { return [] }
        return entries
            .compactMap { url -> Int? in
                let name = url.lastPathComponent
                guard name.hasPrefix("v"), let value = Int(name.dropFirst()) else { return nil }
                // A directory without a manifest is a leftover staging attempt.
                guard fm.fileExists(
                    atPath: url.appendingPathComponent(MapPackageBuilder.manifestFileName).path
                ) else { return nil }
                return value
            }
            .sorted(by: >)
    }

    func cachedVersion(buildingID: UUID) -> Int? {
        cachedVersions(buildingID: buildingID).first
    }

    /// The newest complete manifest, or nil when nothing valid is cached.
    func manifest(buildingID: UUID) -> MapPackageManifest? {
        guard let version = cachedVersion(buildingID: buildingID) else { return nil }
        return manifest(buildingID: buildingID, version: version)
    }

    func manifest(buildingID: UUID, version: Int) -> MapPackageManifest? {
        let url = versionDirectory(buildingID, version: version)
            .appendingPathComponent(MapPackageBuilder.manifestFileName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? MapPackageCoder.decode(data)
    }

    func fileURL(buildingID: UUID, version: Int, fileName: String) -> URL {
        versionDirectory(buildingID, version: version).appendingPathComponent(fileName)
    }

    /// Bytes of one cached artifact, verified against the manifest checksum.
    /// Returns nil when the file is absent or has been corrupted on disk.
    func data(for artifact: PackageArtifact, buildingID: UUID, version: Int) -> Data? {
        let url = fileURL(buildingID: buildingID, version: version, fileName: artifact.localFileName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard PackageChecksum.matches(data, expected: artifact.checksum) else { return nil }
        return data
    }

    func isOfflineAvailable(buildingID: UUID) -> Bool {
        manifest(buildingID: buildingID) != nil
    }

    /// The ARWorldMap bytes for a downloaded building, verified against the
    /// manifest checksum.
    ///
    /// A downloaded building keeps its world map here, not under
    /// `Zones/<id>/`. Callers that only looked in the local zone store reported
    /// "this zone has no saved world map" for a map that was present the whole
    /// time. Returns nil when the package genuinely carries routing data only.
    func worldMapData(buildingID: UUID) -> Data? {
        guard let manifest = manifest(buildingID: buildingID) else {
            DiagnosticsLog.shared.log("World map lookup: no cached package for \(buildingID.uuidString.prefix(8))")
            return nil
        }
        guard let artifact = manifest.artifacts.first(where: { $0.kind == .worldmap }) else {
            DiagnosticsLog.shared.log(
                "World map lookup: package v\(manifest.version) carries routing data only"
            )
            return nil
        }
        guard let data = data(for: artifact, buildingID: buildingID, version: manifest.version) else {
            // Present in the manifest but unreadable or failing its checksum.
            DiagnosticsLog.shared.log(
                "World map lookup: artifact \(artifact.localFileName) missing or failed its checksum"
            )
            return nil
        }
        DiagnosticsLog.shared.log(
            "World map lookup: \(data.count) bytes for v\(manifest.version)"
        )
        return data
    }

    /// True when this building can support camera relocalization on this
    /// device — the bytes are present and intact, not merely promised.
    func hasUsableWorldMap(buildingID: UUID) -> Bool {
        worldMapData(buildingID: buildingID) != nil
    }

    // MARK: - Writing

    /// Writes a verified package atomically. Staging directory first, then a
    /// single move — the previous version is only removed afterwards.
    func store(manifest: MapPackageManifest, files: [String: Data]) throws {
        let fm = FileManager.default
        let buildingID = manifest.buildingID
        let staging = buildingDirectory(buildingID)
            .appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)

        do {
            for artifact in manifest.artifacts where artifact.kind != .package {
                guard let data = files[artifact.storagePath] else {
                    throw MapPackageError.missingArtifact(artifact.storagePath)
                }
                try data.write(
                    to: staging.appendingPathComponent(artifact.localFileName), options: .atomic
                )
            }
            // The manifest lands last: its presence is what marks the directory
            // complete, so a crash mid-write leaves an ignorable partial.
            try MapPackageCoder.encode(manifest).write(
                to: staging.appendingPathComponent(MapPackageBuilder.manifestFileName),
                options: .atomic
            )

            let destination = versionDirectory(buildingID, version: manifest.version)
            if fm.fileExists(atPath: destination.path) {
                try fm.removeItem(at: destination)
            }
            try fm.moveItem(at: staging, to: destination)
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }

        // Older versions are no longer needed once the new one is in place.
        for old in cachedVersions(buildingID: buildingID) where old != manifest.version {
            try? fm.removeItem(at: versionDirectory(buildingID, version: old))
        }
    }

    /// Removes a building's downloaded package. Local mapping zones, which live
    /// under a different root, are untouched.
    func remove(buildingID: UUID) {
        try? FileManager.default.removeItem(at: buildingDirectory(buildingID))
    }

    /// Version numbers for every cached building, for the Saved Maps merge.
    func allCachedVersions() -> [UUID: Int] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else {
            return [:]
        }
        var result: [UUID: Int] = [:]
        for entry in entries {
            guard let id = UUID(uuidString: entry.lastPathComponent),
                  let version = cachedVersion(buildingID: id) else { continue }
            result[id] = version
        }
        return result
    }
}
