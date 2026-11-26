import Combine
import SwiftUI

private struct PlayTarget: Identifiable {
    let id = UUID()
    let match: MatchGroup
    let commentator: CommentatorItem
}

enum MatchFilterOption: String, CaseIterable, Identifiable {
    case all = "Tất cả"
    case live = "Đang đá"
    case football = "Bóng đá"
    case tennis = "Quần vợt"
    case volleyball = "Bóng chuyền"
    case badminton = "Cầu lông"

    var id: String { rawValue }
}

struct MatchesView: View {
    @EnvironmentObject private var settings: AppSettings

    @State private var groups: [MatchGroup] = []
    @State private var timeUpdate = ""
    @State private var activeBaseURL = ""
    @State private var isLoading = false
    @State private var errorText: String?
    @State private var searchText = ""
    @State private var selectedFilter: MatchFilterOption = .all
    @State private var now = Date().timeIntervalSince1970

    @State private var matchForCommentatorSheet: MatchGroup?
    @State private var playTarget: PlayTarget?

    private let apiClient = BongDaAPIClient()
    private let ticker = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    private var filteredGroups: [MatchGroup] {
        groups.filter { group in
            let filterPass: Bool
            switch selectedFilter {
            case .all:
                filterPass = true
            case .live:
                filterPass = group.status(at: now) == .live
            case .football:
                filterPass = group.sportType.uppercased() == "FOOTBALL"
            case .tennis:
                filterPass = group.sportType.uppercased() == "TENNIS"
            case .volleyball:
                filterPass = group.sportType.uppercased() == "VOLLEYBALL"
            case .badminton:
                filterPass = group.sportType.uppercased() == "BADMINTON"
            }

            guard filterPass else { return false }
            let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            if query.isEmpty { return true }
            return group.title.localizedCaseInsensitiveContains(query)
                || group.giai.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                filterBar

                if isLoading && groups.isEmpty {
                    Spacer()
                    ProgressView("Đang tải danh sách trận đấu...")
                    Spacer()
                } else if let errorText = errorText, groups.isEmpty {
                    Spacer()
                    VStack(spacing: 14) {
                        Image(systemName: "wifi.exclamationmark")
                            .font(.system(size: 40))
                            .foregroundColor(.orange)
                        Text(errorText)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                        Button("Thử tải lại") {
                            Task { await loadMatches(forceUpdate: false) }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    Spacer()
                } else if filteredGroups.isEmpty {
                    Spacer()
                    VStack(spacing: 10) {
                        Text("⚽")
                            .font(.system(size: 42))
                        Text("Không có trận đấu phù hợp")
                            .font(.headline)
                        Text("Kéo xuống để làm mới hoặc đổi bộ lọc.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                } else {
                    List {
                        Section {
                            ForEach(filteredGroups) { group in
                                Button {
                                    handleMatchTap(group)
                                } label: {
                                    MatchRowView(group: group, now: now)
                                }
                                .buttonStyle(.plain)
                                .listRowBackground(Color(red: 0.10, green: 0.14, blue: 0.22))
                            }
                        } header: {
                            HStack {
                                Text("\(filteredGroups.count) trận")
                                Spacer()
                                if !timeUpdate.isEmpty {
                                    Text("Cập nhật: \(timeUpdate)")
                                }
                            }
                            .font(.caption)
                            .foregroundColor(.secondary)
                        }
                    }
                    .listStyle(.insetGrouped)
                    .refreshable {
                        await loadMatches(forceUpdate: false)
                    }
                }
            }
            .background(Color(red: 0.05, green: 0.07, blue: 0.12).ignoresSafeArea())
            .navigationTitle("Tivi Bóng Đá")
            .searchable(text: $searchText, prompt: "Tìm đội bóng hoặc giải đấu")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Text(settings.playbackMode == .serverProxy ? "Proxy Server" : "Không Proxy")
                        .font(.caption2.weight(.bold))
                        .foregroundColor(settings.playbackMode == .serverProxy ? .orange : Color(red: 0.35, green: 0.92, blue: 0.55))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.white.opacity(0.08))
                        .clipShape(Capsule())
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        Task { await loadMatches(forceUpdate: true) }
                    } label: {
                        if isLoading {
                            ProgressView()
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                }
            }
        }
        .navigationViewStyle(.stack)
        .task {
            if groups.isEmpty {
                await loadMatches(forceUpdate: false)
            }
        }
        .onReceive(ticker) { _ in
            now = Date().timeIntervalSince1970
        }
        .confirmationDialog(
            matchForCommentatorSheet?.title ?? "Chọn bình luận viên",
            isPresented: Binding(
                get: { matchForCommentatorSheet != nil },
                set: { if !$0 { matchForCommentatorSheet = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let group = matchForCommentatorSheet {
                ForEach(group.commentators) { comm in
                    Button("🎙️ BLV \(comm.blv)") {
                        playTarget = PlayTarget(match: group, commentator: comm)
                    }
                }
                Button("Hủy", role: .cancel) {}
            }
        } message: {
            Text("Chọn kênh bình luận viên để phát trực tiếp:")
        }
        .fullScreenCover(item: $playTarget) { target in
            VideoPlayerScreen(
                match: target.match,
                commentator: target.commentator,
                settings: settings
            )
        }
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(MatchFilterOption.allCases) { option in
                    Button {
                        selectedFilter = option
                    } label: {
                        Text(option.rawValue)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(selectedFilter == option ? Color(red: 0.22, green: 0.78, blue: 0.45) : Color.white.opacity(0.08))
                            .foregroundColor(selectedFilter == option ? .black : .white)
                            .clipShape(Capsule())
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(Color(red: 0.07, green: 0.10, blue: 0.16))
    }

    private func handleMatchTap(_ group: MatchGroup) {
        if group.commentators.count > 1 {
            matchForCommentatorSheet = group
        } else if let first = group.commentators.first {
            playTarget = PlayTarget(match: group, commentator: first)
        }
    }

    private func loadMatches(forceUpdate: Bool) async {
        isLoading = true
        errorText = nil
        now = Date().timeIntervalSince1970
        do {
            let result = try await apiClient.fetchMatches(baseURLs: settings.candidateBaseURLs, forceUpdate: forceUpdate)
            groups = result.groups
            timeUpdate = result.timeUpdate
            activeBaseURL = result.usedBaseURL
        } catch {
            errorText = error.localizedDescription
        }
        isLoading = false
    }
}

private struct MatchRowView: View {
    let group: MatchGroup
    let now: TimeInterval

    var body: some View {
        let status = group.status(at: now)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("\(group.sportIcon) \(group.displayCompetition)")
                    .font(.caption.weight(.medium))
                    .foregroundColor(.white.opacity(0.75))
                    .lineLimit(1)

                Spacer()

                statusBadge(status)
            }

            Text(group.title)
                .font(.headline)
                .foregroundColor(.white)
                .lineLimit(2)

            HStack(spacing: 10) {
                Label(group.displayTimeAndDate, systemImage: "clock")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Spacer()

                if group.commentators.count > 1 {
                    Text("\(group.commentators.count) BLV")
                        .font(.caption2.weight(.semibold))
                        .foregroundColor(Color(red: 0.98, green: 0.75, blue: 0.14))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color(red: 0.98, green: 0.75, blue: 0.14).opacity(0.16))
                        .clipShape(Capsule())
                } else if let blv = group.commentators.first?.blv {
                    Text("🎙️ \(blv)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func statusBadge(_ status: MatchStatus) -> some View {
        switch status {
        case .live:
            HStack(spacing: 4) {
                Circle()
                    .fill(Color.red)
                    .frame(width: 7, height: 7)
                Text("Đang đá")
            }
            .font(.caption2.weight(.bold))
            .foregroundColor(Color(red: 1.0, green: 0.45, blue: 0.45))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.red.opacity(0.2))
            .clipShape(Capsule())
        case .upcoming:
            Text("Sắp đá")
                .font(.caption2.weight(.semibold))
                .foregroundColor(Color(red: 0.45, green: 0.80, blue: 1.0))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.blue.opacity(0.2))
                .clipShape(Capsule())
        case .ended:
            Text("Hết giờ")
                .font(.caption2.weight(.medium))
                .foregroundColor(.gray)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.gray.opacity(0.2))
                .clipShape(Capsule())
        }
    }
}
