import Testing
import Foundation
@testable import Hearth

/// Synthetic Macs, so the advisor can be tested without the real hardware.
private func mac(_ chip: String, ramGB: Double, gpuCores: Int? = nil,
                 ai: HardwareProfile.AppleIntelligenceStatus = .available,
                 diskGB: Double = 300, arch: HardwareProfile.Architecture = .appleSilicon) -> HardwareProfile {
    let family = ChipFamily.parse(chip)
    let gib = 1_073_741_824.0
    return HardwareProfile(
        architecture: arch, chipName: chip, chipFamily: family,
        performanceCores: 8, efficiencyCores: 4, gpuCores: gpuCores,
        physicalMemory: UInt64(ramGB * gib),
        gpuWorkingSetLimit: UInt64(ramGB * (ramGB <= 36 ? 0.67 : 0.75) * gib),
        memoryBandwidthGBs: family.estimatedBandwidth(gpuCores: gpuCores),
        freeDiskBytes: UInt64(diskGB * gib), osVersion: "macOS 26.0",
        appleIntelligence: ai, hasInternalBattery: true, isLowPowerMode: false, scannedAt: .now)
}

private func hf(_ repo: String, gb: Double) -> DiskModel {
    DiskModel(name: String(repo.split(separator: "/").last!), source: .huggingFace,
              sizeBytes: UInt64(gb * 1_073_741_824), repoID: repo, isMLX: repo.hasPrefix("mlx-community/"))
}

struct ModelAdvisorTests {
    let advisor: ModelAdvisor

    init() throws {
        advisor = ModelAdvisor(catalog: try ModelCatalog.bundled().models)
    }

    @Test func chipParsing() {
        #expect(ChipFamily.parse("Apple M3 Pro") == ChipFamily(generation: 3, tier: .pro))
        #expect(ChipFamily.parse("Apple M4 Max").estimatedBandwidth(gpuCores: 32) == 410)
    }

    @Test func sixteenGigGetsEightB() {
        let advice = advisor.advise(for: mac("Apple M3", ramGB: 16, gpuCores: 10))
        #expect(advice.recommended?.model.id == "mlx-community/Qwen3-8B-4bit")
        #expect(advice.fits.first?.isRecommended == true)
    }

    @Test func eightGigStaysSmall() {
        let advice = advisor.advise(for: mac("Apple M1", ramGB: 8))
        #expect((advice.recommended?.model.diskGB ?? 99) < 2)
    }

    @Test func bigMacPrefersFastMoE() {
        let advice = advisor.advise(for: mac("Apple M4 Max", ramGB: 128, gpuCores: 40))
        #expect(advice.recommended?.model.isMoE == true)
    }

    @Test func intelHasNoPick() {
        let advice = advisor.advise(for: mac("Intel Core i9", ramGB: 32, arch: .intel))
        #expect(advice.recommended == nil)
        #expect(!advice.warnings.isEmpty)
    }

    @Test func neverRecommendsMoreThanComfortable() {
        for ram in [8.0, 16, 18, 24, 32, 36, 48, 64, 96, 128, 192] {
            let hw = mac("Apple M3 Max", ramGB: ram, gpuCores: 40)
            if let pick = advisor.advise(for: hw).recommended {
                #expect(pick.memoryGB <= hw.gpuWorkingSetGB * 0.65 + 0.01, "\(ram) GB")
            }
        }
    }

    @Test func lowDiskBlocksDownloads() {
        let advice = advisor.advise(for: mac("Apple M4 Pro", ramGB: 48, diskGB: 10.5))
        #expect(advice.recommended == nil)
    }

    /// Already downloaded, close in quality and not much slower → no download.
    @Test func prefersModelAlreadyOnDisk() {
        let hw = mac("Apple M2 Pro", ramGB: 32)
        #expect(advisor.advise(for: hw).recommended?.model.id == "mlx-community/Qwen3-14B-4bit")
        let onDisk = advisor.advise(for: hw, onDisk: [hf("mlx-community/Qwen3-8B-4bit", gb: 4.6)])
        #expect(onDisk.recommended?.model.id == "mlx-community/Qwen3-8B-4bit")
        #expect(onDisk.recommended?.isDownloaded == true)
    }

    /// A much faster pick is still worth the download.
    @Test func fasterPickBeatsSlowDownloadedModel() {
        let advice = advisor.advise(for: mac("Apple M4 Pro", ramGB: 48),
                                    onDisk: [hf("mlx-community/Qwen3-14B-4bit", gb: 8.3)])
        #expect(advice.recommended?.model.isMoE == true)
    }

    /// A downloaded model doesn't need free disk.
    @Test func downloadedModelIgnoresDiskSpace() {
        let advice = advisor.advise(for: mac("Apple M3", ramGB: 16, diskGB: 5),
                                    onDisk: [hf("mlx-community/Qwen3-8B-4bit", gb: 4.6)])
        #expect(advice.recommended?.model.id == "mlx-community/Qwen3-8B-4bit")
    }

    /// A dense 32B in Ollama on a 64 GB Mac: the 30B-A3B MoE in Hearth is several times faster.
    @Test func suggestsFasterAlternativeForOllamaModel() {
        let ollama = DiskModel(name: "qwen3:32b", source: .ollama, sizeBytes: UInt64(20 * 1_073_741_824.0),
                               repoID: nil, isMLX: false)
        let advice = advisor.advise(for: mac("Apple M4 Max", ramGB: 64, gpuCores: 40), onDisk: [ollama])
        let review = advice.existing.first
        #expect(review?.runnableInHearth == false)
        #expect(review?.fasterAlternative?.model.isMoE == true)
    }

    @Test func unknownMLXModelOnDiskIsRunnable() {
        let advice = advisor.advise(for: mac("Apple M3", ramGB: 16),
                                    onDisk: [hf("mlx-community/gemma-3-4b-it-4bit", gb: 3.0)])
        let review = advice.existing.first
        #expect(review?.runnableInHearth == true)
        #expect(review?.model?.id == "mlx-community/gemma-3-4b-it-4bit")
    }

    @Test func parameterCounts() {
        #expect(ModelAdvisor.parameterCounts("Qwen3-30B-A3B-4bit") == (30, 3))
        #expect(ModelAdvisor.parameterCounts("llama3.1:8b").total == 8)
        #expect(ModelAdvisor.parameterCounts("qwen3:32b").total == 32)
        #expect(ModelAdvisor.parameterCounts("gemma-3-270m").total == 0.27)
        #expect(ModelAdvisor.parameterCounts("Qwen3-8B-4bit").total == 8)
        #expect(ModelAdvisor.parameterCounts("mistral:latest").total == nil)
    }
}

struct ServerTests {
    @Test func parsesCompleteRequest() {
        let raw = "POST /v1/chat/completions?x=1 HTTP/1.1\r\nHost: localhost\r\nContent-Length: 2\r\nUser-Agent: curl/8.7\r\n\r\n{}"
        guard case .complete(let request) = HTTPServer.parse(Data(raw.utf8)) else {
            Issue.record("expected a complete request"); return
        }
        #expect(request.method == "POST")
        #expect(request.path == "/v1/chat/completions")
        #expect(request.header("User-Agent") == "curl/8.7")
        #expect(request.body == Data("{}".utf8))
    }

    @Test func waitsForBody() {
        let raw = "POST /v1/chat/completions HTTP/1.1\r\nContent-Length: 10\r\n\r\n{\"a\""
        guard case .needMore = HTTPServer.parse(Data(raw.utf8)) else {
            Issue.record("expected needMore"); return
        }
    }

    @Test func decodesContentParts() throws {
        let json = #"{"model":"x","messages":[{"role":"system","content":null},{"role":"user","content":[{"type":"text","text":"hi"},{"type":"image_url"}]}],"max_completion_tokens":50}"#
        let request = try JSONDecoder().decode(OpenAI.ChatRequest.self, from: Data(json.utf8))
        #expect(request.messages[0].content == "")
        #expect(request.messages[1].content == "hi")
        #expect(request.tokenLimit == 50)
    }

    @Test func chunkHasExplicitNullFinishReason() throws {
        let chunk = OpenAI.ChatChunk(id: "c", created: 0, model: "m",
                                     choices: [.init(delta: .init(content: "x"), finishReason: nil)])
        let text = String(decoding: try JSONEncoder().encode(chunk), as: UTF8.self)
        #expect(text.contains(#""finish_reason":null"#))
        #expect(!text.contains("usage"))
    }

    @Test func identifiesClients() {
        #expect(ClientIdentifier.name(userAgent: "OpenAI/Python 1.54.0", title: nil) == "Python")
        #expect(ClientIdentifier.name(userAgent: "curl/8.7.1", title: nil) == "curl")
        #expect(ClientIdentifier.name(userAgent: "OpenAI/JS 4.70.0", title: nil) == "Node.js")
        #expect(ClientIdentifier.name(userAgent: "MyTool/1.0", title: nil) == "MyTool")
        #expect(ClientIdentifier.name(userAgent: "anything", title: "My App") == "My App")
        #expect(ClientIdentifier.name(userAgent: nil, title: nil) == "Unknown app")
    }

    @Test func appleIntelligencePromptKeepsLatestTurn() {
        let messages: [OpenAI.ChatRequest.Message] = [
            .init(role: "system", content: "Be brief."),
            .init(role: "user", content: "Hi"),
            .init(role: "assistant", content: "Hello!"),
            .init(role: "user", content: "What's 2+2?"),
        ]
        let (instructions, prompt) = AppleIntelligenceBackend.split(messages)
        #expect(instructions == "Be brief.")
        #expect(prompt.contains("User: Hi"))
        #expect(prompt.hasSuffix("What's 2+2?"))
    }
}
