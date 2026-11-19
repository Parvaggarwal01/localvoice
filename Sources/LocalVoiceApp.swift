import AppKit
import SwiftUI

@main
struct LocalVoiceApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup("LocalVoice", id: "main") {
            AppPanel()
                .environmentObject(state)
                .environmentObject(state.meetings)
        }
        .defaultSize(width: 440, height: 660)
        .windowResizability(.contentSize)

        MenuBarExtra {
            AppPanel()
                .environmentObject(state)
                .environmentObject(state.meetings)
        } label: {
            MenuBarLabel()
                .environmentObject(state)
                .environmentObject(state.meetings)
        }
        .menuBarExtraStyle(.window)
    }
}

private struct MenuBarLabel: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var meetings: MeetingController

    var body: some View {
        let live = state.isRecording || meetings.isRecording
        Image(systemName: meetings.isRecording ? "person.2.wave.2.fill" : state.isRecording ? "waveform" : "waveform.circle.fill")
            .symbolRenderingMode(.palette)
            .foregroundStyle(live ? .red : .primary, .secondary)
    }
}
