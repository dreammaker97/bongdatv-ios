import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings

    @State private var connectionMessage = ""
    @State private var cronMessage = ""
    @State private var proxyStatusText = "Đang kiểm tra..."
    @State private var isTesting = false
    @State private var isUpdatingCron = false

    private let apiClient = BongDaAPIClient()

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Chế độ phát luồng trên iPhone")) {
                    Picker("Nguồn phát", selection: $settings.playbackMode) {
                        ForEach(PlaybackMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }

                    Text(settings.playbackMode.subtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Toggle("Tự chuyển Proxy Server nếu CDN chặn", isOn: $settings.autoFallbackToProxy)
                }

                Section(header: Text("Local On-Device HLS Relay (Không tốn Server)")) {
                    HStack {
                        Text("Trạng thái")
                        Spacer()
                        Text(proxyStatusText)
                            .font(.caption.monospaced())
                            .foregroundColor(Color(red: 0.35, green: 0.92, blue: 0.55))
                    }
                    Text("Relay chạy nội bộ tại 127.0.0.1 ngay trong app để gắn header Referer khi gọi thẳng CDN.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section(header: Text("Địa chỉ máy chủ API (LAN & Dự phòng)"), footer: Text("Mặc định dùng địa chỉ LAN nội bộ. Nếu muốn xem qua 4G/5G bên ngoài, hãy nhập địa chỉ từ xa vào ô Server dự phòng.")) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Server chính (LAN)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        TextField("http://192.168.1.210:8080/bongda", text: $settings.serverURL)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .disableAutocorrection(true)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Server dự phòng (tùy chọn khi ra ngoài)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        TextField("Để trống nếu chỉ xem qua Wi-Fi nhà", text: $settings.secondaryServerURL)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .disableAutocorrection(true)
                    }

                    Button {
                        Task { await checkConnection() }
                    } label: {
                        HStack {
                            Text("Kiểm tra kết nối máy chủ")
                            Spacer()
                            if isTesting { ProgressView() }
                        }
                    }
                    .disabled(isTesting)

                    if !connectionMessage.isEmpty {
                        Text(connectionMessage)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Section(header: Text("Bảo trì dữ liệu máy chủ")) {
                    Button {
                        Task { await runCronUpdate() }
                    } label: {
                        HStack {
                            Text("Cập nhật lại lịch thi đấu (cron_update)")
                            Spacer()
                            if isUpdatingCron { ProgressView() }
                        }
                    }
                    .disabled(isUpdatingCron)

                    if !cronMessage.isEmpty {
                        Text(cronMessage)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Button("Khôi phục cài đặt mặc định", role: .destructive) {
                        settings.resetDefaults()
                        connectionMessage = ""
                        cronMessage = ""
                    }
                }
            }
            .navigationTitle("Cài đặt")
        }
        .navigationViewStyle(.stack)
        .task {
            await refreshProxyStatus()
        }
    }

    private func refreshProxyStatus() async {
        do {
            let url = try await LocalHLSProxy.shared.ensureRunning()
            proxyStatusText = "Đang chạy (\(url.absoluteString))"
        } catch {
            proxyStatusText = "Lỗi: \(error.localizedDescription)"
        }
    }

    private func checkConnection() async {
        isTesting = true
        var messages: [String] = []
        for url in settings.candidateBaseURLs {
            do {
                let msg = try await apiClient.testConnection(baseURL: url)
                messages.append("✅ \(url): \(msg)")
            } catch {
                messages.append("❌ \(url): \(error.localizedDescription)")
            }
        }
        connectionMessage = messages.joined(separator: "\n")
        isTesting = false
    }

    private func runCronUpdate() async {
        isUpdatingCron = true
        do {
            let res = try await apiClient.triggerCronUpdate(baseURLs: settings.candidateBaseURLs)
            cronMessage = "✅ \(res.summary)"
        } catch {
            cronMessage = "❌ \(error.localizedDescription)"
        }
        isUpdatingCron = false
    }
}
