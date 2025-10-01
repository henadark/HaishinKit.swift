import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
            PublishView()
                .tabItem {
                    Image(systemName: "record.circle")
                    Text("Publish")
                }

            PlaybackView()
                .tabItem {
                    Image(systemName: "play.circle")
                    Text("Playback")
                }

            PreferenceView()
                .tabItem {
                    Image(systemName: "person.circle")
                    Text("Preference")
                }
        }
    }
}
