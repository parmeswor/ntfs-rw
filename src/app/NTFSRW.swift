// NTFS RW — a small front end for /usr/local/bin/ntfsctl.
//
// Read-only queries run `ntfsctl status --plain` as the current user.
// Changes run `ntfsctl ...` through an administrator prompt (osascript).

import AppKit
import SwiftUI

let ntfsctlPath = "/usr/local/bin/ntfsctl"

// MARK: - Model

struct Volume: Identifiable, Equatable {
    enum State: String { case rw, ro, none }
    var id: String { device }
    let device: String
    let name: String
    let size: Int64
    let state: State
    let mountPoint: String
    let volumeID: String
    let autoMount: Bool

    var sizeText: String { ByteCountFormatter.string(fromByteCount: size, countStyle: .file) }
}

struct Dependency {
    var installed = false
    var detail = ""
}

@MainActor
final class Store: ObservableObject {
    @Published var volumes: [Volume] = []
    @Published var config: [String: String] = [:]
    @Published var macfuse = Dependency()
    @Published var ntfs3g = Dependency()
    @Published var daemon = Dependency()
    @Published var kext = Dependency(installed: true)
    @Published var appleSilicon = true
    @Published var showKextHelp = false
    @Published var version = ""
    @Published var busy = false
    @Published var loaded = false
    @Published var toolMissing = false
    @Published var lastError: String?
    /// Set when a mount failed because Windows left the volume in use (Fast Startup).
    @Published var repairCandidate: Volume?
    @Published var fullDiskAccess = true

    var depsOK: Bool { macfuse.installed && ntfs3g.installed }
    var autoMount: Bool { config["AUTO_MOUNT"] == "yes" }

    private var observers: [NSObjectProtocol] = []

    init() {
        let nc = NSWorkspace.shared.notificationCenter
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            })
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                // ntfs-3g mounts arrive a moment after the native unmount.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { self?.refresh() }
            })
        }
    }

    func refresh() {
        fullDiskAccess = hasFullDiskAccess()
        guard FileManager.default.isExecutableFile(atPath: ntfsctlPath) else {
            toolMissing = true
            loaded = true
            return
        }
        Task.detached {
            let result = Shell.run(ntfsctlPath, ["status", "--plain"])
            await MainActor.run { self.parse(result.output) }
        }
    }

    private func parse(_ text: String) {
        var vols: [Volume] = []
        var cfg: [String: String] = [:]
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard let kind = f.first else { continue }
            switch kind {
            case "meta" where f.count >= 3 && f[1] == "version":
                version = f[2]
            case "dep" where f.count >= 3:
                let dep = Dependency(installed: f[2] == "yes", detail: f.count > 3 ? f[3] : "")
                switch f[1] {
                case "macfuse": macfuse = dep
                case "ntfs3g": ntfs3g = dep
                case "daemon": daemon = dep
                case "kext": kext = dep
                case "arch": appleSilicon = f[2] == "arm64"
                default: break
                }
            case "cfg" where f.count >= 3:
                cfg[f[1]] = f[2]
            case "vol" where f.count >= 8:
                vols.append(Volume(device: f[1], name: f[2], size: Int64(f[3]) ?? 0,
                                   state: Volume.State(rawValue: f[4]) ?? .none,
                                   mountPoint: f[5], volumeID: f[6], autoMount: f[7] == "yes"))
            default: break
            }
        }
        volumes = vols
        config = cfg
        loaded = true
    }

    /// Runs `ntfsctl <args>` as root via the standard macOS administrator prompt.
    func privileged(_ args: [String], then: ((Shell.Result) -> Void)? = nil) {
        busy = true
        lastError = nil
        Task.detached {
            let script = """
            on run argv
                set cmd to quoted form of "\(ntfsctlPath)"
                repeat with a in argv
                    set cmd to cmd & space & quoted form of (contents of a)
                end repeat
                do shell script cmd with prompt "NTFS RW needs administrator access to change NTFS drives." with administrator privileges
            end run
            """
            let result = Shell.run("/usr/bin/osascript", ["-e", script] + args)
            await MainActor.run {
                self.busy = false
                if result.status != 0 && !result.output.contains("(-128)") {   // -128 = user cancelled
                    self.lastError = Self.cleanError(result.output)
                }
                then?(result)
                self.refresh()
            }
        }
    }

    /// Strips osascript's "176:297: execution error: … (1)" wrapper.
    static func cleanError(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = t.range(of: #"^\d+:\d+: execution error: "#, options: .regularExpression) { t.removeSubrange(r) }
        if let r = t.range(of: #"\s*\(-?\d+\)$"#, options: .regularExpression) { t.removeSubrange(r) }
        return t.replacingOccurrences(of: "\r", with: "\n")
    }

    func mount(_ v: Volume) {
        privileged(["mount", v.device]) { result in
            let out = result.output
            guard result.status != 0 else { return }
            if out.contains("Full Disk Access") {
                self.fullDiskAccess = false
            } else if out.contains("ntfsctl repair") {
                self.repairCandidate = v
            }
        }
    }
    func repair(_ v: Volume) { privileged(["repair", v.device]) }
    func unmount(_ v: Volume) { privileged(["unmount", v.device]) }
    func setAutoMount(_ on: Bool) { privileged(["auto", on ? "on" : "off"]) }
    func setExcluded(_ v: Volume, _ excluded: Bool) {
        privileged(["exclude", excluded ? "add" : "remove", v.volumeID])
    }
    func saveConfig(_ values: [String: String]) {
        let changed = values.filter { config[$0.key] != $0.value }
        guard !changed.isEmpty else { return }
        privileged(["config", "set"] + changed.map { "\($0.key)=\($0.value)" }.sorted())
    }
    func startDaemon() { privileged(["daemon", "start"]) }

    /// macFUSE's kernel extension isn't running although an NTFS drive is waiting to be
    /// made writable — almost always because macOS hasn't been allowed to load it yet.
    var needsKextApproval: Bool {
        depsOK && !kext.installed && volumes.contains { $0.state != .rw }
    }

    func installDependencies() {
        // Homebrew must run as the user, interactively, so hand it to Terminal.
        let script = """
        tell application "Terminal"
            activate
            do script "\(ntfsctlPath) install-deps"
        end tell
        """
        Task.detached { _ = Shell.run("/usr/bin/osascript", ["-e", script]) }
    }

    func openLog() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/var/log/ntfsrw.log"))
    }

    func uninstall() {
        privileged(["uninstall", "--yes"]) { _ in NSApp.terminate(nil) }
    }
}

enum Shell {
    struct Result { let status: Int32; let output: String }

    static func run(_ path: String, _ args: [String]) -> Result {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return Result(status: -1, output: error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return Result(status: p.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }
}

// MARK: - Views

@main
enum Entry {
    static func main() {
        // launchd runs "NTFSRW --helper <ntfsctl args>". ntfsctl is spawned as a child (not
        // exec'd) so this app stays the responsible process and its Full Disk Access applies.
        let args = CommandLine.arguments
        if args.count > 1 && args[1] == "--helper" {
            var env = ProcessInfo.processInfo.environment
            env["NTFSRW_HELPER"] = "1"
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            p.arguments = [ntfsctlPath] + args.dropFirst(2)
            p.environment = env
            do { try p.run() } catch { fputs("ntfsrw helper: \(error)\n", stderr); exit(1) }
            p.waitUntilExit()
            exit(p.terminationStatus)
        }
        NTFSRWApp.main()
    }
}

/// True if this app (and therefore the launchd helper, which runs the same binary) has
/// Full Disk Access. Reading the user's TCC database is only allowed with FDA.
func hasFullDiskAccess() -> Bool {
    let path = NSHomeDirectory() + "/Library/Application Support/com.apple.TCC/TCC.db"
    let fd = open(path, O_RDONLY)
    if fd >= 0 { close(fd); return true }
    return errno != EPERM && errno != EACCES   // e.g. ENOENT: can't tell, assume OK
}

func openFullDiskAccessSettings() {
    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
    NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
}

struct NTFSRWApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var store = Store()

    var body: some Scene {
        WindowGroup("NTFS RW") {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 620, minHeight: 440)
                .onAppear { store.refresh() }
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .appInfo) {
                Button("About NTFS RW") {
                    NSApp.orderFrontStandardAboutPanel(options: [
                        .credits: NSAttributedString(
                            string: "Developed by Pamdai\nRead & write NTFS drives on macOS using macFUSE and ntfs-3g.",
                            attributes: [.font: NSFont.systemFont(ofSize: 11),
                                         .foregroundColor: NSColor.secondaryLabelColor]),
                    ])
                }
            }
            CommandGroup(after: .toolbar) {
                Button("Refresh") { store.refresh() }.keyboardShortcut("r")
            }
        }
        Settings {
            SettingsView().environmentObject(store)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct ContentView: View {
    @EnvironmentObject var store: Store

    var body: some View {
        VStack(spacing: 0) {
            if store.toolMissing {
                Banner(icon: "xmark.octagon.fill", color: .red,
                       title: "ntfsctl is missing",
                       message: "Reinstall the NTFS RW package.")
            } else if store.loaded && !store.depsOK {
                DependencyBanner()
            } else if store.loaded && !store.fullDiskAccess {
                Banner(icon: "lock.shield.fill", color: .orange,
                       title: "Allow Full Disk Access",
                       message: "macOS blocks access to external disks until NTFS RW is allowed. In the window that opens, turn on NTFS RW (or click + and choose NTFS RW from Applications), then come back here.",
                       action: ("Open Settings", openFullDiskAccessSettings))
            } else if store.loaded && store.needsKextApproval {
                Banner(icon: "puzzlepiece.extension.fill", color: .orange,
                       title: "One more step: allow the macFUSE system extension",
                       message: store.appleSilicon
                           ? "Apple Silicon Macs need a one-time setting in Recovery mode before NTFS drives can be written. It takes about 5 minutes."
                           : "Open Privacy & Security and click Allow next to the macFUSE developer, then restart.",
                       action: ("Show Me How", { store.showKextHelp = true }))
            } else if store.loaded && !store.daemon.installed {
                Banner(icon: "exclamationmark.triangle.fill", color: .orange,
                       title: "Auto-mount service is not running",
                       message: "Drives will only be writable when mounted manually.",
                       action: ("Start Service", store.startDaemon))
            }

            HStack {
                Toggle(isOn: Binding(get: { store.autoMount }, set: { store.setAutoMount($0) })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Automatically make NTFS drives writable").font(.headline)
                        Text("When a drive is connected it is remounted read/write.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
                .disabled(store.busy || !store.depsOK)
            }
            .padding()

            Divider()

            if !store.loaded {
                Spacer(); ProgressView(); Spacer()
            } else if store.volumes.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "externaldrive.badge.questionmark")
                        .font(.system(size: 42)).foregroundStyle(.secondary)
                    Text("No NTFS drives connected").font(.title3)
                    Text("Connect a Windows-formatted drive and it will appear here.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
            } else {
                List(store.volumes) { VolumeRow(volume: $0) }
                    .listStyle(.inset)
            }

            if let err = store.lastError {
                Divider()
                HStack(alignment: .top) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(err).font(.caption).textSelection(.enabled)
                    Spacer()
                    Button("Dismiss") { store.lastError = nil }.controlSize(.small)
                }
                .padding(10)
            }

            Divider()
            HStack {
                if store.busy { ProgressView().controlSize(.small) }
                Text(store.version.isEmpty ? "Developed by Pamdai" : "NTFS RW \(store.version) · Developed by Pamdai")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Show Log", action: store.openLog)
                if #available(macOS 14.0, *) {
                    SettingsLink { Text("Settings…") }
                } else {
                    Button("Settings…") {
                        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                    }
                }
                Button { store.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh")
            }
            .padding(10)
        }
        .sheet(isPresented: $store.showKextHelp) {
            KextHelpView(appleSilicon: store.appleSilicon) { store.showKextHelp = false }
        }
        .alert(item: $store.repairCandidate) { v in
            Alert(
                title: Text("“\(v.name)” was left in use by Windows"),
                message: Text("""
                    Windows Fast Startup (or unplugging without ejecting) left this drive in an unsafe \
                    state, so it can only be opened read-only.

                    NTFS RW can repair it by clearing the Windows journal (ntfsfix) and then mount it \
                    read/write. Any changes Windows had not finished saving will be lost — your existing \
                    files are not affected.

                    If you still use this drive with Windows, shutting Windows down fully is the safer fix.
                    """),
                primaryButton: .destructive(Text("Repair & Make Writable")) { store.repair(v) },
                secondaryButton: .cancel())
        }
    }
}

struct VolumeRow: View {
    @EnvironmentObject var store: Store
    let volume: Volume

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "externaldrive.fill")
                .font(.system(size: 28))
                .foregroundStyle(volume.state == .rw ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(volume.name).font(.headline)
                HStack(spacing: 6) {
                    StatusPill(state: volume.state)
                    Text("\(volume.device) · \(volume.sizeText)")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Toggle("Auto", isOn: Binding(get: { volume.autoMount },
                                         set: { store.setExcluded(volume, !$0) }))
                .toggleStyle(.checkbox)
                .help("Automatically mount this drive read/write")
                .disabled(store.busy)
            if volume.state == .rw {
                Button("Open") { NSWorkspace.shared.open(URL(fileURLWithPath: volume.mountPoint)) }
                Button("Eject") { store.unmount(volume) }.disabled(store.busy)
            } else {
                Button(volume.state == .ro ? "Make Writable" : "Mount") { store.mount(volume) }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.busy || !store.depsOK)
                if volume.state == .ro {
                    Button("Eject") { store.unmount(volume) }.disabled(store.busy)
                }
            }
        }
        .padding(.vertical, 6)
        .contextMenu {
            Button("Repair Windows State…") { store.repairCandidate = volume }
                .disabled(store.busy || !store.depsOK)
        }
    }
}

struct StatusPill: View {
    let state: Volume.State
    var body: some View {
        let (text, color): (String, Color) = {
            switch state {
            case .rw: return ("Read & Write", .green)
            case .ro: return ("Read Only", .orange)
            case .none: return ("Not Mounted", .gray)
            }
        }()
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }
}

struct Banner: View {
    let icon: String
    let color: Color
    let title: String
    let message: String
    var action: (String, () -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(color).font(.title2)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(message).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if let action { Button(action.0, action: action.1) }
        }
        .padding()
        .background(color.opacity(0.1))
    }
}

struct KextHelpView: View {
    let appleSilicon: Bool
    let done: () -> Void

    private var steps: [String] {
        appleSilicon ? [
            "Choose Apple menu → Shut Down.",
            "Press and hold the power button until “Loading startup options” appears. Click Options, then Continue.",
            "From the Utilities menu choose Startup Security Utility, select your disk and click Security Policy.",
            "Select “Reduced Security” and tick “Allow user management of kernel extensions from identified developers”. Click OK and restart.",
            "Open System Settings → Privacy & Security, scroll down and click Allow next to “Benjamin Fleischer” (macFUSE). Restart when asked.",
            "Connect your NTFS drive — it becomes writable automatically.",
        ] : [
            "Open System Settings → Privacy & Security.",
            "Scroll down and click Allow next to “Benjamin Fleischer” (macFUSE).",
            "Restart your Mac when asked, then connect your NTFS drive.",
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Allow the macFUSE system extension", systemImage: "puzzlepiece.extension.fill")
                .font(.title2.weight(.semibold))
            Text("NTFS RW writes to NTFS drives through macFUSE, which uses a kernel extension. macOS requires your permission once before it can load.\(appleSilicon ? " On Apple Silicon this setting can only be changed in Recovery mode." : "")")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(steps.enumerated()), id: \.offset) { i, step in
                    HStack(alignment: .top, spacing: 10) {
                        Text("\(i + 1)").font(.callout.weight(.bold)).foregroundStyle(.white)
                            .frame(width: 22, height: 22).background(Circle().fill(Color.accentColor))
                        Text(step).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if appleSilicon {
                Text("Tip: take a photo of these steps with your phone — this window is not available in Recovery mode.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Open Privacy & Security") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security")!)
                }
                Spacer()
                Button("Done", action: done).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520)
    }
}

struct DependencyBanner: View {
    @EnvironmentObject var store: Store

    var body: some View {
        let missing = [store.macfuse.installed ? nil : "macFUSE",
                       store.ntfs3g.installed ? nil : "ntfs-3g"].compactMap { $0 }
        VStack(alignment: .leading, spacing: 8) {
            Banner(icon: "shippingbox.fill", color: .blue,
                   title: "Install \(missing.joined(separator: " and "))",
                   message: "These drivers are normally included with NTFS RW. Reinstall NTFS RW to restore them, or click Install to set them up with Homebrew in Terminal.",
                   action: ("Install…", store.installDependencies))
        }
    }
}

/// Editable copy of the settings. A class (rather than @State) so the app builds with
/// the Command Line Tools alone — their SDK lacks the SwiftUI macro plugin @State needs.
final class SettingsForm: ObservableObject {
    @Published var fallback = true
    @Published var notify = true
    @Published var openFinder = false
    @Published var internalDisks = false
    @Published var mountRoot = "/Volumes"
    @Published var options = ""
    @Published var ntfs3gPath = ""
    @Published var confirmUninstall = false
}

struct SettingsView: View {
    @EnvironmentObject var store: Store
    @StateObject private var form = SettingsForm()

    var body: some View {
        Form {
            Section("Behavior") {
                Toggle("Remount read-only if read/write fails", isOn: $form.fallback)
                Toggle("Show notifications", isOn: $form.notify)
                Toggle("Open drive in Finder after mounting", isOn: $form.openFinder)
                Toggle("Also auto-mount internal disks (Boot Camp)", isOn: $form.internalDisks)
            }
            Section("Advanced") {
                TextField("Mount folder", text: $form.mountRoot)
                TextField("ntfs-3g options", text: $form.options)
                TextField("ntfs-3g path (empty = auto)", text: $form.ntfs3gPath)
                LabeledContent("macFUSE", value: store.macfuse.installed ? store.macfuse.detail : "not installed")
                LabeledContent("ntfs-3g", value: store.ntfs3g.installed ? store.ntfs3g.detail : "not installed")
            }
            HStack {
                Button("Uninstall NTFS RW…", role: .destructive) { form.confirmUninstall = true }
                Spacer()
                Text("Developed by Pamdai").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Revert") { load() }
                Button("Save") {
                    store.saveConfig([
                        "FALLBACK_READONLY": form.fallback ? "yes" : "no",
                        "NOTIFY": form.notify ? "yes" : "no",
                        "OPEN_IN_FINDER": form.openFinder ? "yes" : "no",
                        "AUTO_MOUNT_INTERNAL": form.internalDisks ? "yes" : "no",
                        "MOUNT_ROOT": form.mountRoot,
                        "MOUNT_OPTIONS": form.options,
                        "NTFS3G_BIN": form.ntfs3gPath,
                    ])
                }
                .keyboardShortcut(.defaultAction)
                .disabled(store.busy)
            }
        }
        .formStyle(.grouped)
        .frame(width: 500)
        .onAppear(perform: load)
        .onChange(of: store.config) { _ in load() }
        .confirmationDialog("Remove NTFS RW from this Mac?", isPresented: $form.confirmUninstall) {
            Button("Uninstall", role: .destructive, action: store.uninstall)
        } message: {
            Text("The app, auto-mount service and settings are removed. macFUSE is kept for other apps that may use it.")
        }
    }

    private func load() {
        let c = store.config
        form.fallback = c["FALLBACK_READONLY", default: "yes"] == "yes"
        form.notify = c["NOTIFY", default: "yes"] == "yes"
        form.openFinder = c["OPEN_IN_FINDER"] == "yes"
        form.internalDisks = c["AUTO_MOUNT_INTERNAL"] == "yes"
        form.mountRoot = c["MOUNT_ROOT", default: "/Volumes"]
        form.options = c["MOUNT_OPTIONS", default: ""]
        form.ntfs3gPath = c["NTFS3G_BIN", default: ""]
    }
}
