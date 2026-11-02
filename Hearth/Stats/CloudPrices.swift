import Foundation

/// Cloud models we compare against for "saved by running locally".
/// Standard (non-cached, short-prompt) list prices per million tokens.
struct CloudPrice: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let inputPerMTok: Double
    let outputPerMTok: Double

    func cost(input: Int, output: Int) -> Double {
        (Double(input) * inputPerMTok + Double(output) * outputPerMTok) / 1_000_000
    }

    /// Update these when providers change their pricing.
    static let checkedOn = "Nov 1, 2026"

    static let all: [CloudPrice] = [
        CloudPrice(id: "claude-haiku-5-5", name: "Claude Haiku 5.5", inputPerMTok: 0.10, outputPerMTok: 0.50),
        CloudPrice(id: "claude-sonnet-5-5", name: "Claude Sonnet 5.5", inputPerMTok: 2, outputPerMTok: 10),
        CloudPrice(id: "claude-opus-5-5", name: "Claude Opus 5.5", inputPerMTok: 4, outputPerMTok: 20),
    ]

    /// A small, fast cloud model is the fair comparison for an 8B local model.
    static let defaultID = "claude-haiku-5-5"
    static let storageKey = "hearth.savingsReference"

    static func with(id: String) -> CloudPrice {
        all.first { $0.id == id } ?? all[0]
    }
}
