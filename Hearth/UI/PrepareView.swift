import SwiftUI

/// Download → load → ready.
struct PrepareView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: icon)
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(Theme.flame)
                .symbolEffect(.pulse, options: .repeating, isActive: model.models.state.isBusy)

            VStack(spacing: 6) {
                Text(title)
                    .font(.title.weight(.semibold))
                Text(model.models.activeModel?.displayName ?? "")
                    .foregroundStyle(.secondary)
            }

            switch model.models.state {
            case .downloading(let progress):
                VStack(spacing: 8) {
                    ProgressView(value: progress)
                        .frame(width: 360)
                    if let size = model.models.activeModel?.diskGB {
                        Text("\(Format.gb(size * progress)) of \(Format.gb(size))")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            case .loading:
                ProgressView()
                    .controlSize(.small)
            case .failed(let message):
                VStack(spacing: 12) {
                    Text(message)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                    HStack {
                        Button("Pick another model") { Task { await model.changeModel() } }
                        Button("Try again") { Task { await model.retryPreparing() } }
                            .buttonStyle(.borderedProminent)
                            .tint(Theme.flame)
                    }
                }
            default:
                EmptyView()
            }

            Text("You can close this window. Hearth keeps going in the menu bar.")
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
        .padding(40)
    }

    private var title: String {
        switch model.models.state {
        case .downloading: "Downloading"
        case .loading: "Loading into memory"
        case .failed: "That didn't work"
        default: "Getting ready"
        }
    }

    private var icon: String {
        switch model.models.state {
        case .downloading: "arrow.down.circle"
        case .failed: "exclamationmark.triangle"
        default: "flame"
        }
    }
}
