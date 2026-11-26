import AVKit
import SwiftUI

struct VideoPlayerScreen: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel: StreamPlayerViewModel

    init(match: MatchGroup, commentator: CommentatorItem, settings: AppSettings) {
        _viewModel = StateObject(
            wrappedValue: StreamPlayerViewModel(
                match: match,
                commentator: commentator,
                settings: settings
            )
        )
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let player = viewModel.player {
                AVPlayerControllerRepresentable(player: player)
                    .ignoresSafeArea()
            }

            VStack(spacing: 0) {
                topBar
                Spacer()
            }

            if viewModel.isLoading {
                VStack(spacing: 14) {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .amberHighlight))
                        .scaleEffect(1.35)
                    Text(viewModel.statusText)
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
                .padding(.vertical, 22)
                .padding(.horizontal, 24)
                .background(Color.black.opacity(0.75))
                .cornerRadius(16)
            }

            if let errorMessage = viewModel.errorMessage {
                VStack(spacing: 14) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 36))
                        .foregroundColor(.amberHighlight)
                    Text(errorMessage)
                        .font(.body)
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center)
                    HStack(spacing: 12) {
                        Button("Thử lại") {
                            viewModel.start()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.green)

                        if viewModel.activeMode != .serverProxy {
                            Button("Dùng Proxy Server") {
                                viewModel.start(modeOverride: .serverProxy)
                            }
                            .buttonStyle(.bordered)
                            .tint(.amberHighlight)
                        }

                        Button("Đóng") {
                            viewModel.stop()
                            dismiss()
                        }
                        .buttonStyle(.bordered)
                        .tint(.gray)
                    }
                }
                .padding(24)
                .background(Color(red: 0.08, green: 0.11, blue: 0.18).opacity(0.95))
                .cornerRadius(18)
                .padding(.horizontal, 20)
            }
        }
        .onAppear {
            viewModel.start()
        }
        .onDisappear {
            viewModel.stop()
        }
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            Button {
                viewModel.stop()
                dismiss()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.left")
                    Text("Quay lại")
                }
                .font(.subheadline.weight(.semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.black.opacity(0.65))
                .clipShape(Capsule())
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(viewModel.match.title)
                    .font(.subheadline.weight(.bold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(viewModel.activeRouteLabel)
                        .font(.caption2.weight(.semibold))
                        .foregroundColor(viewModel.isUsingServerProxy ? .amberHighlight : Color(red: 0.35, green: 0.92, blue: 0.55))
                    Text("• BLV \(viewModel.selectedCommentator.blv)")
                        .font(.caption2)
                        .foregroundColor(.white.opacity(0.8))
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.black.opacity(0.55))
            .cornerRadius(10)

            Spacer()

            if viewModel.match.commentators.count > 1 {
                Menu {
                    ForEach(viewModel.match.commentators) { comm in
                        Button {
                            viewModel.start(commentator: comm)
                        } label: {
                            if comm.id == viewModel.selectedCommentator.id {
                                Label(comm.blv, systemImage: "checkmark")
                            } else {
                                Text(comm.blv)
                            }
                        }
                    }
                } label: {
                    Image(systemName: "mic.fill")
                        .font(.subheadline)
                        .foregroundColor(.white)
                        .padding(9)
                        .background(Color.black.opacity(0.65))
                        .clipShape(Circle())
                }
            }

            Menu {
                ForEach(PlaybackMode.allCases) { mode in
                    Button {
                        viewModel.start(modeOverride: mode)
                    } label: {
                        if mode == viewModel.activeMode {
                            Label(mode.title, systemImage: "checkmark")
                        } else {
                            Text(mode.title)
                        }
                    }
                }
            } label: {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.subheadline)
                    .foregroundColor(.white)
                    .padding(9)
                    .background(Color.black.opacity(0.65))
                    .clipShape(Circle())
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }
}

private extension Color {
    static let amberHighlight = Color(red: 0.98, green: 0.75, blue: 0.14)
}

struct AVPlayerControllerRepresentable: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.showsPlaybackControls = true
        controller.allowsPictureInPicturePlayback = true
        if #available(iOS 14.2, *) {
            controller.canStartPictureInPictureAutomaticallyFromInline = true
        }
        controller.updatesNowPlayingInfoCenter = true
        return controller
    }

    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {
        if uiViewController.player !== player {
            uiViewController.player = player
        }
    }
}
