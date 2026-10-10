import AppKit
import SwiftUI

struct AppRowView: View {
    var app: AppRowModel
    var onVolume: (Float) -> Void
    var onMute: (Bool) -> Void

    var body: some View {
        HStack(spacing: 10) {
            AppIcon(icon: app.icon)
                .frame(width: 28, height: 28)
                .onTapGesture { onMute(!app.muted) }
                .opacity(app.muted ? 0.4 : 1.0)
                .help("Click icon to mute/unmute")

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(app.name)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .layoutPriority(1)
                    if app.isComm {
                        Text("CALL")
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.blue.opacity(0.2))
                            .cornerRadius(3)
                    }
                    Spacer()
                    Text(app.muted ? "Muted" : "\(Int(app.volume * 100))%")
                        .font(.system(size: 11, weight: .regular))
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                }
                HStack(spacing: 8) {
                    Slider(value: Binding(
                        get: { app.muted ? 0 : app.volume },
                        set: { onVolume($0) }
                    ), in: 0...1, step: 0.01)
                    Button(action: { onMute(!app.muted) }) {
                        Image(systemName: app.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .font(.system(size: 12))
                            .foregroundColor(app.muted ? .red : .secondary)
                            .frame(width: 22)
                    }
                    .buttonStyle(.plain)
                }
                LevelMeter(level: app.level, muted: app.muted)
                    .frame(height: 3)
            }
        }
        .padding(.vertical, 3)
    }
}

struct AppIcon: View {
    var icon: NSImage?
    var body: some View {
        Group {
            if let icon {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.gray.opacity(0.3))
                    .overlay(Text("♪").font(.system(size: 14)))
            }
        }
    }
}

struct LevelMeter: View {
    var level: Float
    var muted: Bool
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.gray.opacity(0.2))
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(muted ? Color.gray : (level > 0.9 ? Color.red : Color.green))
                    .frame(width: geo.size.width * CGFloat(min(max(level, 0), 1)))
                    .animation(.linear(duration: 0.08), value: level)
            }
        }
    }
}

struct MasterControlView: View {
    @ObservedObject var state: AudioState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Output")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
            Picker("Device", selection: Binding(
                get: { state.outputs.first(where: { $0.isDefault })?.id ?? 0 },
                set: { state.setOutput($0) }
            )) {
                ForEach(state.outputs, id: \.id) { o in
                    Text(o.name).tag(o.id)
                }
            }
            .labelsHidden()
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack {
                Text("Master")
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                Text(state.masterMuted ? "Muted" : "\(Int(state.masterVolume * 100))%")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            }
            HStack {
                Slider(value: Binding(
                    get: { state.masterMuted ? 0 : state.masterVolume },
                    set: { state.setMasterVolume($0) }
                ), in: 0...1, step: 0.01)
                .disabled(state.masterMuted)
                Button(action: { state.setMasterMuted(!state.masterMuted) }) {
                    Image(systemName: state.masterMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .foregroundColor(state.masterMuted ? .red : .secondary)
                }
                .buttonStyle(.plain)
            }

            HStack {
                Toggle("Auto-duck others on calls", isOn: Binding(
                    get: { state.duckEnabled },
                    set: { state.setDuck(enabled: $0, amount: state.duckAmount) }
                ))
                .font(.system(size: 11))
                Spacer()
                Slider(value: Binding(
                    get: { state.duckAmount },
                    set: { state.setDuck(enabled: state.duckEnabled, amount: $0) }
                ), in: 0...0.9, step: 0.05)
                .frame(width: 80)
                .disabled(!state.duckEnabled)
                Text("\(Int(state.duckAmount * 100))%")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .frame(width: 34, alignment: .trailing)
            }
        }
        .padding(10)
        .background(Color.gray.opacity(0.08))
        .cornerRadius(8)
    }
}

struct MixerPanelView: View {
    @ObservedObject var state: AudioState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("AppMixer")
                    .font(.system(size: 14, weight: .bold))
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
            }
            MasterControlView(state: state)
            Divider()
            if state.apps.isEmpty {
                VStack(spacing: 6) {
                    Text("No audible apps right now")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    Text("Play audio in Music, Safari, Spotify…\nRows appear automatically.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            } else {
                Text("Applications (\(state.apps.count))")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                VStack(spacing: 2) {
                    ForEach(state.apps) { app in
                        AppRowView(
                            app: app,
                            onVolume: { state.setVolume(key: app.key, value: $0) },
                            onMute: { state.setMuted(key: app.key, muted: $0) }
                        )
                        Divider().opacity(0.4)
                    }
                }
            }
            if state.needsPermission {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Permission needed")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.orange)
                    Text("Allow System Audio Recording in System Settings → Privacy & Security → Screen & System Audio Recording, then relaunch.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                .padding(8)
                .background(Color.orange.opacity(0.1))
                .cornerRadius(6)
            }
            if let err = state.errorMessage {
                Text(err)
                    .font(.system(size: 11))
                    .foregroundColor(.red)
                    .lineLimit(3)
            }
            Text("Tip: click an app icon to mute. Drag a muted app's slider to unmute it.")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        }
        .padding(12)
        .frame(width: 360)
    }
}
