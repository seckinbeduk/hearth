import Foundation
import Observation
import MLXLMCommon
import MLXLLM
import MLXHuggingFace
import HuggingFace
import Tokenizers

/// Lifecycle of the local MLX model: download → load into memory → ready.
/// One model in memory at a time; switching releases the previous one first.
@MainActor
@Observable
final class LocalModelManager {
    enum State: Equatable {
        case idle
        /// 0...1
        case downloading(Double)
        /// Download finished, weights are being loaded into GPU memory
        case loading
        case ready
        case failed(String)

        var isBusy: Bool {
            switch self {
            case .downloading, .loading: true
            default: false
            }
        }
    }

    private(set) var state: State = .idle
    private(set) var activeModel: CatalogModel?
    private(set) var container: MLXLMCommon.ModelContainer?
    /// Seconds spent downloading + loading
    private(set) var lastPrepareDuration: TimeInterval?
    /// True when the weights were already on disk (Hugging Face cache) before we started.
    private(set) var wasAlreadyDownloaded = false

    private var prepareTask: Task<Void, Never>?

    /// Prepares the model. No-op if it's ready; waits if it's already preparing.
    func prepare(_ model: CatalogModel) async {
        if activeModel?.id == model.id {
            if state == .ready { return }
            if let prepareTask, state.isBusy { await prepareTask.value; return }
        }

        prepareTask?.cancel()
        // Release the old model first so two never sit in memory together.
        container = nil
        activeModel = model
        wasAlreadyDownloaded = LocalDiscovery.isInHuggingFaceCache(model.id)
        state = wasAlreadyDownloaded ? .loading : .downloading(0)

        let task = Task { await self.load(model) }
        prepareTask = task
        await task.value
    }

    func retry() async {
        guard let activeModel else { return }
        state = .idle
        await prepare(activeModel)
    }

    /// Frees GPU memory. The server keeps answering with Apple Intelligence if it's available.
    func unload() {
        prepareTask?.cancel()
        prepareTask = nil
        container = nil
        state = .idle
    }

    private func load(_ model: CatalogModel) async {
        let started = Date()
        do {
            let modelID = model.id
            let configuration = MLXLMCommon.ModelConfiguration(id: modelID)
            let loaded = try await MLXLMCommon.loadModelContainer(
                from: #hubDownloader(),
                using: #huggingFaceTokenizerLoader(),
                configuration: configuration
            ) { progress in
                let fraction = progress.fractionCompleted
                Task { @MainActor in self.updateDownload(fraction, for: modelID) }
            }
            guard !Task.isCancelled, activeModel?.id == model.id else { return }
            container = loaded
            lastPrepareDuration = Date().timeIntervalSince(started)
            state = .ready
        } catch {
            guard !Task.isCancelled, activeModel?.id == model.id else { return }
            state = .failed(Self.describe(error))
        }
    }

    private func updateDownload(_ fraction: Double, for modelID: String) {
        guard activeModel?.id == modelID, state.isBusy else { return }
        // Once the download completes, the weights still need loading; show that as its own step.
        state = fraction >= 0.999 ? .loading : .downloading(max(0, min(1, fraction)))
    }

    private static func describe(_ error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return "Couldn't reach Hugging Face. Check your connection and try again."
        }
        return error.localizedDescription
    }
}
