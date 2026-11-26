import SwiftUI

enum LeagueFilter: String, CaseIterable, Identifiable {
    case all = "Tất cả"
    case nha = "Ngoại hạng Anh"
    case c1 = "Cúp C1"

    var id: String { rawValue }
}

struct LeagueScheduleView: View {
    @EnvironmentObject private var settings: AppSettings

    @State private var matches: [LeagueMatchItem] = []
    @State private var timeUpdate = ""
    @State private var isLoading = false
    @State private var errorText: String?
    @State private var filter: LeagueFilter = .all

    private let apiClient = BongDaAPIClient()

    private var filteredMatches: [LeagueMatchItem] {
        matches.filter { item in
            switch filter {
            case .all:
                return true
            case .nha:
                return item.leagueKey.lowercased() == "nha" || item.league.localizedCaseInsensitiveContains("Ngoại hạng Anh")
            case .c1:
                return item.leagueKey.lowercased() == "c1" || item.league.localizedCaseInsensitiveContains("Cúp C1")
            }
        }
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                Picker("Giải đấu", selection: $filter) {
                    ForEach(LeagueFilter.allCases) { f in
                        Text(f.rawValue).tag(f)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color(red: 0.07, green: 0.10, blue: 0.16))

                if isLoading && matches.isEmpty {
                    Spacer()
                    ProgressView("Đang tải lịch thi đấu...")
                    Spacer()
                } else if let errorText = errorText, matches.isEmpty {
                    Spacer()
                    VStack(spacing: 12) {
                        Text(errorText)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                        Button("Thử lại") {
                            Task { await loadSchedule(forceUpdate: false) }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    Spacer()
                } else if filteredMatches.isEmpty {
                    Spacer()
                    Text("Chưa có dữ liệu lịch thi đấu")
                        .foregroundColor(.secondary)
                    Spacer()
                } else {
                    List {
                        Section {
                            ForEach(filteredMatches) { item in
                                LeagueMatchRow(item: item)
                                    .listRowBackground(Color(red: 0.10, green: 0.14, blue: 0.22))
                            }
                        } header: {
                            HStack {
                                Text("\(filteredMatches.count) trận")
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
                        await loadSchedule(forceUpdate: false)
                    }
                }
            }
            .background(Color(red: 0.05, green: 0.07, blue: 0.12).ignoresSafeArea())
            .navigationTitle("Lịch NHA & C1")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        Task { await loadSchedule(forceUpdate: true) }
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
            if matches.isEmpty {
                await loadSchedule(forceUpdate: false)
            }
        }
    }

    private func loadSchedule(forceUpdate: Bool) async {
        isLoading = true
        errorText = nil
        do {
            let res = try await apiClient.fetchLeagueSchedule(baseURLs: settings.candidateBaseURLs, forceUpdate: forceUpdate)
            matches = res.matches
            timeUpdate = res.timeUpdate
        } catch {
            errorText = error.localizedDescription
        }
        isLoading = false
    }
}

private struct LeagueMatchRow: View {
    let item: LeagueMatchItem

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(item.league) • \(item.round)")
                    .font(.caption.weight(.medium))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                Spacer()
                Text("\(item.time) \(item.day)")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(item.status == "live" ? .red : .white.opacity(0.85))
            }

            HStack(spacing: 10) {
                teamView(name: item.home, logoURL: item.homeLogo, alignment: .leading)

                VStack(spacing: 2) {
                    if item.hasScore, let sh = item.scoreHome, let sa = item.scoreAway {
                        Text("\(sh) - \(sa)")
                            .font(.headline.monospacedDigit())
                            .foregroundColor(Color(red: 0.98, green: 0.75, blue: 0.14))
                    } else {
                        Text("VS")
                            .font(.caption.weight(.bold))
                            .foregroundColor(.secondary)
                    }
                }
                .frame(minWidth: 46)

                teamView(name: item.away, logoURL: item.awayLogo, alignment: .trailing)
            }

            if !item.channel.isEmpty {
                Text("📺 \(item.channel)")
                    .font(.caption2)
                    .foregroundColor(Color(red: 0.45, green: 0.80, blue: 1.0))
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func teamView(name: String, logoURL: String, alignment: HorizontalAlignment) -> some View {
        HStack(spacing: 6) {
            if alignment == .trailing {
                Spacer(minLength: 0)
                Text(name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.trailing)
                    .lineLimit(2)
            }

            if let url = URL(string: logoURL), !logoURL.isEmpty {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let img):
                        img.resizable().scaledToFit()
                    default:
                        Image(systemName: "shield.fill")
                            .foregroundColor(.gray)
                    }
                }
                .frame(width: 24, height: 24)
            }

            if alignment == .leading {
                Text(name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity)
    }
}
