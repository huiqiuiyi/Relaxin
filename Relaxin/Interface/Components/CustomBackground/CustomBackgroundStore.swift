import Foundation

/// Custom background configuration persisted in UserDefaults.
/// Supported types: none / image / video. File payloads are copied into
/// the application's Library/CustomBackground directory so the app owns them.
enum CustomBackgroundKind: String {
    case none
    case image
    case video

    var displayName: String {
        switch self {
        case .none: "None"
        case .image: "Image"
        case .video: "Video"
        }
    }
}

enum CustomBackgroundStore {
    private static let kindKey = "customBackground.kind"
    private static let fileNameKey = "customBackground.fileName"

    private static var storageDirectory: URL? {
        guard let library = FileManager.default.urls(
            for: .libraryDirectory,
            in: .userDomainMask
        ).first else {
            return nil
        }
        let directory = library.appendingPathComponent(
            "CustomBackground",
            isDirectory: true
        )
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    static var kind: CustomBackgroundKind {
        get {
            CustomBackgroundKind(
                rawValue: UserDefaults.standard.string(forKey: kindKey) ?? ""
            ) ?? .none
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: kindKey)
            if newValue == .none {
                UserDefaults.standard.removeObject(forKey: fileNameKey)
            }
        }
    }

    static var fileName: String? {
        get { UserDefaults.standard.string(forKey: fileNameKey) }
        set { UserDefaults.standard.set(newValue, forKey: fileNameKey) }
    }

    /// Absolute URL of the stored background payload, if any.
    static var storedURL: URL? {
        guard let fileName else { return nil }
        return storageDirectory?.appendingPathComponent(fileName)
    }

    /// Copy a picked payload into the storage directory and update settings.
    /// `kind` decides image vs. video; the picked file keeps its extension.
    @discardableResult
    static func install(
        kind: CustomBackgroundKind,
        sourceURL: URL
    ) -> Bool {
        guard let directory = storageDirectory else { return false }
        let fileName = sourceURL.lastPathComponent
        let destination = directory.appendingPathComponent(fileName)

        do {
            // Remove any previous payload to avoid stale files.
            if let previous = storedURL {
                try? FileManager.default.removeItem(at: previous)
            }
            try FileManager.default.copyItem(at: sourceURL, to: destination)
        } catch {
            return false
        }

        self.kind = kind
        self.fileName = fileName
        return true
    }

    static func clear() {
        if let storedURL {
            try? FileManager.default.removeItem(at: storedURL)
        }
        fileName = nil
        kind = .none
    }

    static var summary: String {
        switch kind {
        case .none:
            "None"
        case .image, .video:
            "\(kind.displayName): \(fileName ?? "?")"
        }
    }
}
