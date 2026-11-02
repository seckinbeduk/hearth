import Foundation

/// An MLX model Hearth knows how to download and run.
/// Comes from models.json; later this will be fetched remotely so new models ship without an app update.
struct CatalogModel: Codable, Sendable, Hashable, Identifiable {
    enum Role: String, Codable, Sendable { case router, general, code }

    /// Hugging Face repo id (mlx-community/...)
    let id: String
    let displayName: String
    let roles: [Role]
    let paramsB: Double
    /// Weight size on disk / in memory (GB)
    let diskGB: Double
    /// Weights read per token (GB). Dense = diskGB, MoE = active experts.
    let activeGB: Double
    /// fp16 KV cache, KB per token
    let kvKBPerToken: Double
    /// Our internal quality score (0-100)
    let quality: Int
    let maxContext: Int

    var isMoE: Bool { activeGB < diskGB * 0.5 }
    var isCoder: Bool { roles.contains(.code) }

    /// Short, stable name clients can put in the `model` field, e.g. "qwen3-8b".
    var slug: String {
        displayName.lowercased()
            .replacingOccurrences(of: "(moe)", with: "")
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: " ", with: "-")
    }

    /// Weights + KV cache for the given context + runtime overhead (GB)
    func memoryGB(context: Int) -> Double {
        diskGB * 1.05 + kvKBPerToken * Double(context) / 1_048_576 + 0.4
    }
}

struct ModelCatalog: Codable, Sendable {
    let version: Int
    let updated: String
    let models: [CatalogModel]

    static func bundled() throws -> ModelCatalog {
        guard let url = Bundle.main.url(forResource: "models", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try JSONDecoder().decode(ModelCatalog.self, from: Data(contentsOf: url))
    }
}
