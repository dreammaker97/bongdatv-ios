import SwiftUI

struct MainTabView: View {
    var body: some View {
        TabView {
            MatchesView()
                .tabItem {
                    Label("Trực tiếp", systemImage: "sportscourt.fill")
                }

            LeagueScheduleView()
                .tabItem {
                    Label("NHA & C1", systemImage: "calendar")
                }

            SettingsView()
                .tabItem {
                    Label("Cài đặt", systemImage: "gearshape.fill")
                }
        }
        .accentColor(Color(red: 0.22, green: 0.78, blue: 0.45))
    }
}
