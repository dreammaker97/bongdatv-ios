import AVFoundation
import SwiftUI

@main
struct BongDaTVApp: App {
    @StateObject private var settings = AppSettings()

    init() {
        configureAudioSession()
        Task {
            _ = try? await LocalHLSProxy.shared.ensureRunning()
        }
    }

    var body: some Scene {
        WindowGroup {
            MainTabView()
                .environmentObject(settings)
                .preferredColorScheme(.dark)
        }
    }

    private func configureAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .moviePlayback, options: [.allowAirPlay])
            try session.setActive(true)
        } catch {
            // Audio session will be re-attempted before playback starts
        }
    }
}
