import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor).ignoresSafeArea()
            switch model.phase {
            case .scanning:
                ScanView()
                    .transition(.opacity)
            case .choose:
                ChooseView()
                    .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))
            case .preparing:
                PrepareView()
                    .transition(.opacity)
            case .running:
                DashboardView()
                    .transition(.opacity)
            case .failed(let message):
                ContentUnavailableView("Something went wrong", systemImage: "exclamationmark.triangle",
                                       description: Text(message))
            }
        }
        .animation(.smooth(duration: 0.4), value: model.phase)
        .onAppear { NSApp.activate() }
    }
}

struct ScanView: View {
    @State private var step = 0
    private let steps = [
        "Reading chip, cores and GPU",
        "Measuring unified memory and disk",
        "Checking Apple Intelligence",
        "Looking for models already on this Mac",
        "Picking the right model for you",
    ]

    var body: some View {
        VStack(spacing: 28) {
            Image(systemName: "flame")
                .font(.system(size: 64, weight: .light))
                .foregroundStyle(Theme.flame)
                .symbolEffect(.pulse, options: .repeating)

            VStack(spacing: 8) {
                Text("Getting to know your Mac")
                    .font(.largeTitle.weight(.semibold))
                Text("Hearth checks what your Mac can run locally, for free.")
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 10) {
                ForEach(steps.indices, id: \.self) { index in
                    HStack(spacing: 10) {
                        Image(systemName: index < step ? "checkmark.circle.fill" : "circle.dotted")
                            .foregroundStyle(index < step ? Theme.ready : Color.secondary)
                        Text(steps[index])
                            .foregroundStyle(index <= step ? .primary : .tertiary)
                    }
                }
            }
            .font(.callout)
            .frame(width: 380, alignment: .leading)
        }
        .padding(40)
        .task {
            for i in 1...steps.count {
                try? await Task.sleep(for: .milliseconds(280))
                withAnimation(.snappy) { step = i }
            }
        }
    }
}
