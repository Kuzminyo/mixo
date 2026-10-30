import SwiftUI

struct MixerView: View {
    @ObservedObject var model: MixerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            masterRow
            Divider().opacity(0.6)
            appsSection
            if model.needsPermission { permissionBanner }
            Divider().opacity(0.6)
            footer
        }
        .padding(16)
        .frame(width: 340)
    }

    // MARK: - Sections

    private var header: some View {
        HStack {
            Text("Звук")
                .font(.system(size: 15, weight: .semibold))
            Spacer()
            Menu {
                ForEach(model.devices) { device in
                    Button {
                        model.selectOutput(device)
                    } label: {
                        if device.id == model.outputID {
                            Label(device.name, systemImage: "checkmark")
                        } else {
                            Label(device.name, systemImage: device.symbol)
                        }
                    }
                }
            } label: {
                Label(model.outputDevice?.name ?? "Нет устройства", systemImage: model.outputDevice?.symbol ?? "speaker.slash")
                    .font(.system(size: 12, weight: .medium))
            }
            .menuStyle(.button)
            .buttonStyle(.glass)
            .controlSize(.small)
            .fixedSize()
            .help("Устройство вывода")
        }
    }

    private var masterRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                MuteButton(isMuted: model.masterMuted, volume: model.masterVolume, size: 15) {
                    model.toggleMasterMute()
                }
                Slider(
                    value: Binding(get: { Double(model.masterVolume) }, set: { model.setMasterVolume(Float($0)) }),
                    in: 0...1
                )
                .disabled(!model.canChangeMaster)
                Percent(value: model.masterMuted ? 0 : model.masterVolume)
            }
            if !model.canChangeMaster {
                Text("Громкость этого устройства меняется на нём самом")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var appsSection: some View {
        HStack {
            Text("Приложения")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
            if model.apps.contains(where: { $0.needsTap }) {
                Button("Сбросить") { model.resetAll() }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11))
            }
        }

        if model.apps.isEmpty {
            HStack(spacing: 10) {
                Image(systemName: "speaker.zzz")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(.secondary)
                Text("Сейчас ничего не играет.\nВключите музыку или видео — приложение появится здесь.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 8)
        } else if model.apps.count <= 5 {
            appList
        } else {
            ScrollView { appList }
                .scrollIndicators(.never)
                .frame(height: 300)
        }
    }

    private var appList: some View {
        VStack(spacing: 12) {
            ForEach(model.apps) { app in
                AppRow(app: app, model: model)
            }
        }
    }

    private var permissionBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 6) {
                Text("Чтобы менять громкость приложений, разрешите Mixo «Запись системного звука».")
                    .font(.callout)
                Button("Открыть настройки") { model.openPermissionSettings() }
                    .buttonStyle(.glass)
                    .controlSize(.small)
            }
        }
        .padding(10)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var footer: some View {
        HStack {
            Toggle("Запускать при входе", isOn: Binding(
                get: { model.launchAtLogin },
                set: { model.launchAtLogin = $0 }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .font(.system(size: 12))
            Spacer()
            Button("Выйти") { NSApp.terminate(nil) }
                .buttonStyle(.borderless)
                .font(.system(size: 12))
        }
    }
}

private struct AppRow: View {
    let app: MixerApp
    let model: MixerModel

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let icon = app.icon {
                    Image(nsImage: icon).resizable()
                } else {
                    Image(systemName: "app.dashed").resizable().foregroundStyle(.secondary)
                }
            }
            .frame(width: 30, height: 30)
            .opacity(app.isMuted ? 0.5 : 1)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(app.name)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    if app.isPlaying && !app.isMuted {
                        Image(systemName: "waveform")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.tint)
                            .symbolEffect(.variableColor.iterative, isActive: true)
                    }
                    Spacer()
                    Percent(value: app.gain)
                }
                HStack(spacing: 8) {
                    MuteButton(isMuted: app.isMuted, volume: app.volume, size: 12) {
                        model.toggleMute(app)
                    }
                    Slider(
                        value: Binding(get: { Double(app.volume) }, set: { model.setVolume(Float($0), for: app) }),
                        in: 0...1
                    )
                    .controlSize(.small)
                }
            }
        }
    }
}

private struct MuteButton: View {
    let isMuted: Bool
    let volume: Float
    let size: CGFloat
    let action: () -> Void

    private var symbol: String {
        if isMuted || volume == 0 { return "speaker.slash.fill" }
        if volume < 0.34 { return "speaker.wave.1.fill" }
        if volume < 0.67 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(isMuted ? Color.red : Color.secondary)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: size * 1.9, alignment: .leading)
        }
        .buttonStyle(.plain)
        .help(isMuted ? "Включить звук" : "Выключить звук")
    }
}

private struct Percent: View {
    let value: Float

    var body: some View {
        Text("\(Int((value * 100).rounded()))%")
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .frame(width: 34, alignment: .trailing)
    }
}
