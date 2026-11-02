import Foundation

/// An LLM server already running on this Mac (Ollama, LM Studio, mlx_lm.server …).
struct RunningServer: Sendable, Hashable, Identifiable {
    let name: String
    let port: Int
    /// OpenAI-compatible base URL, if the server offers one.
    let baseURL: String
    let models: [String]

    var id: Int { port }
}

/// A model already sitting on disk, downloaded by Hearth or another tool.
struct DiskModel: Sendable, Hashable, Identifiable {
    enum Source: String, Sendable {
        case huggingFace = "Hugging Face cache"
        case ollama = "Ollama"
        case lmStudio = "LM Studio"
    }

    let name: String
    let source: Source
    let sizeBytes: UInt64
    /// For Hugging Face repos: the repo id (org/name). Lets us match the catalog.
    let repoID: String?
    let isMLX: Bool

    var id: String { "\(source.rawValue)/\(name)" }
    /// Decimal GB, like Finder and Hugging Face.
    var sizeGB: Double { Double(sizeBytes) / 1_000_000_000 }
}

struct DiscoveryReport: Sendable {
    var servers: [RunningServer] = []
    var diskModels: [DiskModel] = []

    var isEmpty: Bool { servers.isEmpty && diskModels.isEmpty }
    var totalDiskGB: Double { diskModels.reduce(0) { $0 + $1.sizeGB } }
}

/// Finds what's already on this Mac: running servers and models on disk.
/// Needs a non-sandboxed app (it reads ~/.ollama, ~/.cache/huggingface, ~/.lmstudio).
enum LocalDiscovery {

    static func scan(excludingPort ownPort: Int?) async -> DiscoveryReport {
        async let servers = probeServers(excluding: ownPort)
        let disk = await Task.detached(priority: .utility) { scanDisk() }.value
        return DiscoveryReport(servers: await servers, diskModels: disk)
    }

    // MARK: - Running servers

    private struct Probe: Sendable {
        let name: String
        let port: Int
        let path: String
        let kind: Kind
        enum Kind: Sendable { case ollama, openAI }
    }

    private static let probes: [Probe] = [
        Probe(name: "Ollama", port: 11434, path: "/api/tags", kind: .ollama),
        Probe(name: "LM Studio", port: 1234, path: "/v1/models", kind: .openAI),
        Probe(name: "Jan", port: 1337, path: "/v1/models", kind: .openAI),
        Probe(name: "GPT4All", port: 4891, path: "/v1/models", kind: .openAI),
        Probe(name: "Local server", port: 8080, path: "/v1/models", kind: .openAI),   // mlx_lm.server, llama.cpp
        Probe(name: "Local server", port: 8000, path: "/v1/models", kind: .openAI),   // vLLM, LocalAI, others
    ]

    private static func probeServers(excluding ownPort: Int?) async -> [RunningServer] {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 0.8
        configuration.timeoutIntervalForResource = 1.5
        let session = URLSession(configuration: configuration)

        return await withTaskGroup(of: RunningServer?.self) { group in
            for probe in probes where probe.port != ownPort {
                group.addTask { await check(probe, session: session) }
            }
            var found: [RunningServer] = []
            for await server in group { if let server { found.append(server) } }
            return found.sorted { $0.port < $1.port }
        }
    }

    private static func check(_ probe: Probe, session: URLSession) async -> RunningServer? {
        guard let url = URL(string: "http://127.0.0.1:\(probe.port)\(probe.path)"),
              let result = try? await session.data(from: url),
              (result.1 as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: result.0) as? [String: Any]
        else { return nil }

        let models: [String]
        switch probe.kind {
        case .ollama:
            models = (json["models"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        case .openAI:
            models = (json["data"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
        }
        let base = "http://localhost:\(probe.port)/v1"
        // LM Studio identifies itself in model ids only loosely; trust the port for naming.
        return RunningServer(name: probe.name, port: probe.port, baseURL: base, models: models)
    }

    // MARK: - Models on disk

    static var huggingFaceCache: URL {
        if let custom = ProcessInfo.processInfo.environment["HF_HUB_CACHE"] {
            return URL(fileURLWithPath: custom)
        }
        if let home = ProcessInfo.processInfo.environment["HF_HOME"] {
            return URL(fileURLWithPath: home).appending(path: "hub")
        }
        return URL.homeDirectory.appending(path: ".cache/huggingface/hub")
    }

    /// True if the repo has a snapshot with a config and at least one weight file.
    static func isInHuggingFaceCache(_ repoID: String) -> Bool {
        let folder = huggingFaceCache
            .appending(path: "models--" + repoID.replacingOccurrences(of: "/", with: "--"))
            .appending(path: "snapshots")
        let fm = FileManager.default
        guard let snapshots = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return false }
        return snapshots.contains { snapshot in
            let files = (try? fm.contentsOfDirectory(atPath: snapshot.path)) ?? []
            return files.contains("config.json") && files.contains { $0.hasSuffix(".safetensors") }
        }
    }

    private static func scanDisk() -> [DiskModel] {
        scanHuggingFace() + scanOllama() + scanLMStudio()
    }

    private static func scanHuggingFace() -> [DiskModel] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: huggingFaceCache.path) else { return [] }
        return entries.compactMap { entry in
            guard entry.hasPrefix("models--") else { return nil }
            let repoID = entry.dropFirst("models--".count).replacingOccurrences(of: "--", with: "/")
            let blobs = huggingFaceCache.appending(path: entry).appending(path: "blobs")
            let size = directorySize(blobs)
            // Skip tokenizer-only or half-finished downloads.
            guard size > 200_000_000 else { return nil }
            let lower = repoID.lowercased()
            let isMLX = lower.hasPrefix("mlx-community/") || lower.contains("-mlx") || lower.contains("mlx-")
            let name = repoID.split(separator: "/").last.map(String.init) ?? repoID
            return DiskModel(name: name, source: .huggingFace, sizeBytes: size, repoID: repoID, isMLX: isMLX)
        }
    }

    /// Ollama keeps one manifest per model:tag; layer sizes add up to the model size.
    private static func scanOllama() -> [DiskModel] {
        let root = URL.homeDirectory.appending(path: ".ollama/models/manifests")
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }

        var models: [DiskModel] = []
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
                  let data = try? Data(contentsOf: url),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let layers = json["layers"] as? [[String: Any]]
            else { continue }
            let size = layers.reduce(UInt64(0)) { $0 + UInt64(($1["size"] as? Int) ?? 0) }
            let tag = url.lastPathComponent
            let model = url.deletingLastPathComponent().lastPathComponent
            let namespace = url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
            let name = (namespace == "library" ? "" : namespace + "/") + model + ":" + tag
            models.append(DiskModel(name: name, source: .ollama, sizeBytes: size, repoID: nil, isMLX: false))
        }
        return models
    }

    /// LM Studio: ~/.lmstudio/models/<publisher>/<model>/ (older versions: ~/.cache/lm-studio/models).
    private static func scanLMStudio() -> [DiskModel] {
        let roots = [
            URL.homeDirectory.appending(path: ".lmstudio/models"),
            URL.homeDirectory.appending(path: ".cache/lm-studio/models"),
        ]
        let fm = FileManager.default
        var models: [DiskModel] = []
        for root in roots {
            guard let publishers = try? fm.contentsOfDirectory(atPath: root.path) else { continue }
            for publisher in publishers where !publisher.hasPrefix(".") {
                let publisherURL = root.appending(path: publisher)
                guard let names = try? fm.contentsOfDirectory(atPath: publisherURL.path) else { continue }
                for name in names where !name.hasPrefix(".") {
                    let folder = publisherURL.appending(path: name)
                    let size = directorySize(folder)
                    guard size > 200_000_000 else { continue }
                    let files = (try? fm.contentsOfDirectory(atPath: folder.path)) ?? []
                    let isMLX = files.contains { $0.hasSuffix(".safetensors") }
                    models.append(DiskModel(name: "\(publisher)/\(name)", source: .lmStudio, sizeBytes: size,
                                            repoID: "\(publisher)/\(name)", isMLX: isMLX))
                }
            }
        }
        return models
    }

    private static func directorySize(_ url: URL) -> UInt64 {
        let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey]
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) else { return 0 }
        var total: UInt64 = 0
        for case let file as URL in enumerator {
            guard let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            total += UInt64(values.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}
