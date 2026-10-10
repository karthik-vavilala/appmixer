import SwiftUI

@main
struct AppMixerApp: App {
    @StateObject private var state = AudioState()

    var body: some Scene {
        MenuBarExtra("AppMixer", systemImage: "speaker.wave.2.fill") {
            MixerPanelView(state: state)
                .onAppear { state.start() }
        }
        .menuBarExtraStyle(.window)
    }
}
