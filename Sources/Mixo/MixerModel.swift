import AppKit
import CoreAudio
import ServiceManagement

struct MixerApp: Identifiable {
    let id: String
    let name: String
    let icon: NSImage?
    var processes: Set<AudioObjectID>
    var isPlaying: Bool
    var volume: Float
    var isMuted: Bool

    var gain: Float { isMuted ? 0 : volume }
    var needsTap: Bool { isMuted || volume < 0.995 }
}

private struct AppSetting: Codable {
    var volume: Float = 1
    var isMuted = false
}

final class MixerModel: ObservableObject {
    @Published private(set) var devices: [OutputDevice] = []
    @Published private(set) var outputID = AudioObjectID(kAudioObjectUnknown)
    @Published private(set) var masterVolume: Float = 1
    @Published private(set) var masterMuted = false
    @Published private(set) var canChangeMaster = false
    @Published private(set) var apps: [MixerApp] = []
    @Published private(set) var needsPermission = false

    private static let settingsKey = "appSettings"
    private var settings: [String: AppSetting] = [:]
    private var taps: [String: AppTap] = [:]
    private var failedAt: [String: Date] = [:]
    /// Apps that made sound since Mixo started; they stay listed while running, like on Windows.
    private var heard: Set<String> = []
    private var timer: Timer?
    private let ownPID = ProcessInfo.processInfo.processIdentifier

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.settingsKey),
           let saved = try? JSONDecoder().decode([String: AppSetting].self, from: data) {
            settings = saved
        }
        refresh()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    var outputDevice: OutputDevice? { devices.first { $0.id == outputID } }

    // MARK: - Refresh

    func refresh() {
        devices = HAL.outputDevices()
        let output = HAL.defaultOutputDevice()
        if output != outputID { outputID = output }
        canChangeMaster = HAL.canSetVolume(output)
        let volume = HAL.volume(output)
        if abs(volume - masterVolume) > 0.004 { masterVolume = volume }
        let muted = HAL.isMuted(output)
        if muted != masterMuted { masterMuted = muted }

        refreshApps()
        syncTaps()
    }

    private func refreshApps() {
        var groups: [String: MixerApp] = [:]
        for process in HAL.processes() where process.pid > 0 && process.pid != ownPID {
            guard let owner = AppResolver.owner(of: process.pid, bundleID: process.bundleID) else { continue }
            var app = groups[owner.id] ?? MixerApp(
                id: owner.id, name: owner.name, icon: owner.icon,
                processes: [], isPlaying: false, volume: 1, isMuted: false
            )
            app.processes.insert(process.objectID)
            app.isPlaying = app.isPlaying || process.isPlaying
            groups[owner.id] = app
        }

        for app in groups.values where app.isPlaying { heard.insert(app.id) }
        heard.formIntersection(groups.keys)

        apps = groups.values
            .filter { heard.contains($0.id) || settings[$0.id] != nil }
            .map { app in
                var app = app
                let setting = settings[app.id] ?? AppSetting()
                app.volume = setting.volume
                app.isMuted = setting.isMuted
                return app
            }
            .sorted { ($0.isPlaying ? 0 : 1, $0.name.lowercased()) < ($1.isPlaying ? 0 : 1, $1.name.lowercased()) }
    }

    /// Only apps whose volume was changed get routed through Mixo; the rest play untouched.
    private func syncTaps() {
        guard let outputUID = HAL.uid(of: outputID) else { return }
        var permissionProblem = false

        for app in apps {
            guard app.needsTap else {
                taps[app.id] = nil
                continue
            }
            if let tap = taps[app.id], tap.processes == app.processes, tap.outputUID == outputUID {
                tap.setGain(app.gain)
                continue
            }
            if let failed = failedAt[app.id], Date().timeIntervalSince(failed) < 5 {
                permissionProblem = true
                continue
            }
            taps[app.id] = nil
            do {
                taps[app.id] = try AppTap(processes: app.processes, outputUID: outputUID, gain: app.gain)
                failedAt[app.id] = nil
            } catch {
                NSLog("Mixo: %@ for %@", error.localizedDescription, app.id)
                failedAt[app.id] = Date()
                permissionProblem = true
            }
        }
        for id in taps.keys where !apps.contains(where: { $0.id == id }) {
            taps[id] = nil
        }
        if permissionProblem != needsPermission { needsPermission = permissionProblem }
    }

    // MARK: - Actions

    func setMasterVolume(_ volume: Float) {
        masterVolume = volume
        HAL.setVolume(outputID, volume)
        if masterMuted && volume > 0 { toggleMasterMute() }
    }

    func toggleMasterMute() {
        masterMuted.toggle()
        HAL.setMuted(outputID, masterMuted)
    }

    func selectOutput(_ device: OutputDevice) {
        HAL.setDefaultOutputDevice(device.id)
        refresh()
    }

    func setVolume(_ volume: Float, for app: MixerApp) {
        update(app) { $0.volume = volume; if volume > 0 { $0.isMuted = false } }
    }

    func toggleMute(_ app: MixerApp) {
        update(app) { $0.isMuted.toggle() }
    }

    private func update(_ app: MixerApp, _ change: (inout AppSetting) -> Void) {
        var setting = settings[app.id] ?? AppSetting()
        change(&setting)
        settings[app.id] = (setting.volume >= 0.995 && !setting.isMuted) ? nil : setting

        if let index = apps.firstIndex(where: { $0.id == app.id }) {
            apps[index].volume = setting.volume
            apps[index].isMuted = setting.isMuted
            if let tap = taps[app.id], apps[index].needsTap {
                tap.setGain(apps[index].gain)
            } else {
                syncTaps()
            }
        }
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: Self.settingsKey)
        }
    }

    func resetAll() {
        settings = [:]
        UserDefaults.standard.removeObject(forKey: Self.settingsKey)
        refresh()
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            objectWillChange.send()
            try? newValue ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
        }
    }

    func openPermissionSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Maps audio processes (browser helpers, WebKit, etc.) to the app the user sees.
enum AppResolver {
    struct Owner {
        let id: String
        let name: String
        let icon: NSImage?
    }

    private typealias ResponsibleFunction = @convention(c) (pid_t) -> pid_t
    private static let responsiblePID: ResponsibleFunction? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else {
            return nil
        }
        return unsafeBitCast(symbol, to: ResponsibleFunction.self)
    }()

    static func owner(of pid: pid_t, bundleID: String?) -> Owner? {
        if let responsible = responsiblePID?(pid),
           let app = NSRunningApplication(processIdentifier: responsible),
           app.activationPolicy == .regular {
            return owner(app)
        }
        if let bundleID,
           let app = NSWorkspace.shared.runningApplications
               .filter({ $0.activationPolicy == .regular && bundleID.hasPrefix($0.bundleIdentifier ?? "\u{0}") })
               .max(by: { ($0.bundleIdentifier?.count ?? 0) < ($1.bundleIdentifier?.count ?? 0) }) {
            return owner(app)
        }
        if let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy != .prohibited {
            return owner(app)
        }
        return nil
    }

    private static func owner(_ app: NSRunningApplication) -> Owner {
        Owner(
            id: app.bundleIdentifier ?? "pid-\(app.processIdentifier)",
            name: app.localizedName ?? app.bundleIdentifier ?? "Приложение",
            icon: app.icon
        )
    }
}
