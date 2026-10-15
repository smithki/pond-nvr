// Events: filled in by object detection (phase 5). Until then, says what will appear here.
import SwiftUI

struct EventsView: View {
    var body: some View {
        ContentUnavailableView {
            Label("No events yet", systemImage: "figure.walk.motion")
        } description: {
            Text("When detection is built, people, vehicles, animals and packages seen by your cameras appear here, each with a clip, a thumbnail and a description you can search.")
        }
    }
}
