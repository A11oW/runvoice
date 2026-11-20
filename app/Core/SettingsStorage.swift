import Foundation

enum SettingsStorage {
    struct Usage {
        let cache: Int64?
        let models: Int64?
        let history: Int64?
        var total: Int64? {
            guard let cache, let models, let history else { return nil }
            return cache + models + history
        }
        var hasFiles: Bool { [cache, models, history].contains { ($0 ?? 0) > 0 } }
    }

    struct ClearResult {
        var removedModels = false
        var error: Error?
    }

    private static let fileKeys: Set<URLResourceKey> = [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey, .fileSizeKey]

    static func measure() -> Usage {
        let cache = try? cacheFiles().reduce(Int64(URLCache.shared.currentDiskUsage)) { try $0 + size(of: $1) }
        let models = try? modelFiles().reduce(Int64(0)) { try $0 + size(of: $1) }
        let history = try? historySize()
        return Usage(cache: cache, models: models, history: history)
    }

    static func clear(includingData: Bool) -> ClearResult {
        var result = ClearResult()
        URLCache.shared.removeAllCachedResponses()
        func remove(_ files: () throws -> [URL], models: Bool = false) {
            do {
                for item in try files() {
                    do {
                        try FileManager.default.removeItem(at: item)
                        if models { result.removedModels = true }
                    } catch let error as CocoaError where isMissing(error) {
                        continue
                    } catch {
                        if result.error == nil { result.error = error }
                    }
                }
            } catch {
                if result.error == nil { result.error = error }
            }
        }
        remove(cacheFiles)
        if includingData {
            remove(modelFiles, models: true)
            do {
                let supportIsOwned = try hasOwnedSupport()
                try HistoryStore.shared.clearFromDisk(removingFile: supportIsOwned)
            }
            catch { if result.error == nil { result.error = error } }
        }
        return result
    }

    private static func hasOwnedSupport() throws -> Bool {
        try properties(of: Paths.support)?.isDirectory == true
    }

    private static func historySize() throws -> Int64 {
        guard try hasOwnedSupport(), let values = try properties(of: Paths.history) else { return 0 }
        guard values.isRegularFile == true else { throw CocoaError(.fileReadUnknown) }
        return Int64(values.fileSize ?? 0)
    }

    private static func modelFiles() throws -> [URL] {
        guard try hasOwnedSupport() else { return [] }
        let modelRoot = Paths.support.appendingPathComponent("models", isDirectory: true)
        return try entries(in: modelRoot).compactMap { file, properties in
            if properties.isDirectory == true, let fluid = FluidModel(rawValue: file.lastPathComponent),
               FluidModelStore.installed(fluid) {
                return file
            }
            if properties.isRegularFile == true, WhisperModelStore.isDiscoverableModelName(file),
               WhisperModelStore.isWhisperModel(at: file) {
                return file
            }
            return nil
        }
    }

    private static func cacheFiles() throws -> [URL] {
        guard try hasOwnedSupport() else { return [] }
        let modelRoot = Paths.support.appendingPathComponent("models", isDirectory: true)
        let partials = try entries(in: modelRoot, matching: { file in
            file.pathExtension == "download" && WhisperModelStore.isDiscoverableModelName(file.deletingPathExtension())
        })
        var files = partials.compactMap { file, properties in properties.isRegularFile == true ? file : nil }
        let state = Paths.support.appendingPathComponent("state", isDirectory: true)
        for (file, properties) in try entries(in: state) where properties.isRegularFile == true {
            let name = file.deletingPathExtension().lastPathComponent
            let extensionName = file.pathExtension
            let capture = name.hasPrefix("capture-") && UUID(uuidString: String(name.dropFirst("capture-".count))) != nil
            let micTest = name.hasPrefix("mic-test-") && UUID(uuidString: String(name.dropFirst("mic-test-".count))) != nil
            if (capture && ["wav", "txt"].contains(extensionName)) || (micTest && extensionName == "wav") {
                files.append(file)
            }
        }
        let api = state.appendingPathComponent("api", isDirectory: true)
        if try properties(of: state)?.isDirectory == true, try properties(of: api)?.isDirectory == true {
            let requests = api.appendingPathComponent("requests", isDirectory: true)
            for (file, properties) in try entries(in: requests) where properties.isRegularFile == true {
                if file.pathExtension == "wav", UUID(uuidString: file.deletingPathExtension().lastPathComponent) != nil {
                    files.append(file)
                }
            }
        }
        return files
    }

    private static func entries(in directory: URL, matching: (URL) -> Bool = { _ in true }) throws -> [(URL, URLResourceValues)] {
        guard try properties(of: directory)?.isDirectory == true else { return [] }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(fileKeys))
        return try files.filter(matching).compactMap { file in
            try properties(of: file).map { (file, $0) }
        }
    }

    private static func properties(of url: URL) throws -> URLResourceValues? {
        do {
            let values = try url.resourceValues(forKeys: fileKeys)
            return values.isSymbolicLink == true ? nil : values
        } catch let error as CocoaError where isMissing(error) {
            return nil
        }
    }

    private static func isMissing(_ error: CocoaError) -> Bool {
        error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile
    }

    private static func size(of url: URL) throws -> Int64 {
        guard let values = try properties(of: url) else { return 0 }
        if values.isRegularFile == true { return Int64(values.fileSize ?? 0) }
        guard values.isDirectory == true else { return 0 }
        var scanError: Error?
        guard let files = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(fileKeys), errorHandler: { _, error in
            if let error = error as? CocoaError, isMissing(error) { return true }
            scanError = error
            return false
        }) else { throw CocoaError(.fileReadUnknown) }
        var total: Int64 = 0
        for case let file as URL in files {
            guard let child = try properties(of: file) else {
                files.skipDescendants()
                continue
            }
            if child.isRegularFile == true { total += Int64(child.fileSize ?? 0) }
        }
        if let scanError { throw scanError }
        return total
    }
}
