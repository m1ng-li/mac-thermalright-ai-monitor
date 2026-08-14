// MenuBarView.swift — Menu bar dropdown content
//
// Shows device status, display set picker, brightness control, and actions.

import SwiftUI

struct MenuBarView: View {
    @Bindable var state: AppState
    @State private var started = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {

            // Status
            HStack {
                Circle()
                    .fill(state.isConnected ? .green : .red)
                    .frame(width: 8, height: 8)
                Text(state.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.top, 4)

            if state.isConnected {
                Text("\(state.frameCount) frames • \(state.lastFrameSize / 1024)KB")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 8)
            }

            Divider()

            // Display Set
            Text("Display Set")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)

            ForEach(DisplaySet.allCases) { set in
                Button {
                    state.currentSet = set
                    state.applySettings()
                } label: {
                    HStack {
                        Image(systemName: state.currentSet == set ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(state.currentSet == set ? .blue : .secondary)
                        Text(set.rawValue)
                    }
                }
            }

            Divider()

            // Agent columns
            Text("AI Agents")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)

            Menu("左侧 · \(state.leftAgent.displayName)") {
                ForEach(AgentKind.allCases) { kind in
                    Button {
                        state.leftAgent = kind
                        state.applyAgentSelection()
                    } label: {
                        HStack {
                            if state.leftAgent == kind {
                                Image(systemName: "checkmark")
                            }
                            Text(kind.displayName)
                        }
                    }
                }
            }

            Menu("右侧 · \(state.rightAgent.displayName)") {
                ForEach(AgentKind.allCases) { kind in
                    Button {
                        state.rightAgent = kind
                        state.applyAgentSelection()
                    } label: {
                        HStack {
                            if state.rightAgent == kind {
                                Image(systemName: "checkmark")
                            }
                            Text(kind.displayName)
                        }
                    }
                }
            }

            Divider()

            // Brightness
            HStack {
                Text("Brightness")
                    .font(.caption)
                Spacer()
                Text("\(state.brightness)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)

            HStack(spacing: 4) {
                Button("−") {
                    if state.brightness > 1 {
                        state.brightness -= 1
                        state.applySettings()
                    }
                }
                .buttonStyle(.bordered)

                Slider(value: brightnessBinding, in: 1...10, step: 1)
                    .onChange(of: state.brightness) {
                        state.applySettings()
                    }

                Button("+") {
                    if state.brightness < 10 {
                        state.brightness += 1
                        state.applySettings()
                    }
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal, 8)

            Divider()

            // Actions
            if !state.isConnected {
                Button("Reconnect") {
                    state.connect()
                }
            }

            SettingsLink {
                Text("Settings...")
            }

            Divider()

            Button("Quit") {
                state.stop()
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding(.vertical, 4)
        .frame(width: 220)
        .task {
            guard !started else { return }
            started = true
            state.start()
        }
    }

    private var brightnessBinding: Binding<Double> {
        Binding(
            get: { Double(state.brightness) },
            set: { state.brightness = Int($0) }
        )
    }
}
