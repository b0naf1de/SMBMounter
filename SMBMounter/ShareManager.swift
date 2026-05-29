import Foundation
import Combine
import AppKit
import Network
import UserNotifications

class ShareManager: ObservableObject {
    static let shared = ShareManager()

    @Published var shares: [SMBShare] = []

    private let stateQueue = DispatchQueue(label: "com.smbmounter.state")
    private var manuallyDisconnected: Set<UUID> = []
    private var pendingMounts: Set<UUID> = []
    private var extraRetryCount: [UUID: Int] = [:]
    private var failCount: [UUID: Int] = [:]
    private let maxExtraRetriesAfterDisconnect = 3

    private let mountQueue = DispatchQueue(label: "com.smbmounter.mount.serial", qos: .utility)
    private let unmountQueue = DispatchQueue(label: "com.smbmounter.unmount", qos: .utility)
    private let monitorQueue = DispatchQueue(label: "com.smbmounter.monitor", qos: .background)

    private var recoveryTimer: Timer?
    private var networkMonitor: NWPathMonitor?
    private var isNetworkAvailable = false

    private let unmountStatusRefreshDelay: TimeInterval = 1.0
    private let unmountReconnectDelay: TimeInterval = 1.0
    private let initialReconnectAttemptDelay: TimeInterval = 1.0
    private let reconnectTickInterval: TimeInterval = 1.5
    private let shortRetryInterval: TimeInterval = 0.35

    private let requiredStableSuccesses = 2
    private let bonjourCheckCycles = 4
    private let smbReachabilityTimeout: TimeInterval = 2.0
    private let bonjourQueryTimeout: TimeInterval = 2.0

    private let finderAppleScriptTimeoutSeconds = 2.0
    private let finderExecutionTimeout: TimeInterval = 10.0
    private let postMountVerifyTimeout: TimeInterval = 5.0

    private let postBootAutoConnectDelay: TimeInterval = 15.0
    private let normalLaunchAutoConnectDelay: TimeInterval = 1.0
    private var startupReadyAt: Date?
    private var startupReconnectScheduled = false

    private var hostProbeWindow: TimeInterval {
        let reachabilityBudget = Double(requiredStableSuccesses) * ((smbReachabilityTimeout * 2.0) + shortRetryInterval)
        let bonjourBudget = Double(bonjourCheckCycles) * (bonjourQueryTimeout + shortRetryInterval)
        return max(8.0, reachabilityBudget + bonjourBudget)
    }

    private var mountCycleTimeout: TimeInterval {
        hostProbeWindow + 10.0
    }

    private init() {
        loadShares()
    }

    // MARK: - State

    private func markManuallyDisconnected(_ id: UUID) {
        stateQueue.sync {
            _ = manuallyDisconnected.insert(id)
        }
    }

    private func clearManuallyDisconnected(_ id: UUID) {
        stateQueue.sync {
            _ = manuallyDisconnected.remove(id)
        }
    }

    private func isManuallyDisconnected(_ id: UUID) -> Bool {
        stateQueue.sync { manuallyDisconnected.contains(id) }
    }

    private func beginPendingMount(_ id: UUID) -> Bool {
        stateQueue.sync {
            if pendingMounts.contains(id) {
                return false
            }
            _ = pendingMounts.insert(id)
            return true
        }
    }

    private func endPendingMount(_ id: UUID) {
        stateQueue.sync {
            _ = pendingMounts.remove(id)
        }
    }

    private func isPendingMount(_ id: UUID) -> Bool {
        stateQueue.sync { pendingMounts.contains(id) }
    }

    private func consumeExtraRetry(_ id: UUID) -> Bool {
        stateQueue.sync {
            let current = extraRetryCount[id] ?? 0
            if current >= maxExtraRetriesAfterDisconnect {
                return false
            }
            extraRetryCount[id] = current + 1
            return true
        }
    }

    private func clearExtraRetry(_ id: UUID) {
        stateQueue.sync {
            extraRetryCount[id] = nil
        }
    }

    private func scheduleOneExtraRetryIfNeeded(for shareID: UUID, delay: TimeInterval = 0.8) {
        guard consumeExtraRetry(shareID) else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard self.isNetworkAvailable else { return }
            guard !self.isManuallyDisconnected(shareID) else { return }
            guard let share = self.shares.first(where: { $0.id == shareID }) else { return }
            guard share.status == .disconnected else { return }
            guard !self.isMounted(share) else { return }

            self.mount(share)
        }
    }

    // MARK: - Persistence

    private var savePath: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = dir.appendingPathComponent("SMBMounter")
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        return appDir.appendingPathComponent("shares.json")
    }

    func saveShares() {
        if let data = try? JSONEncoder().encode(shares) {
            try? data.write(to: savePath)
        }
    }

    func loadShares() {
        guard let data = try? Data(contentsOf: savePath),
              let decoded = try? JSONDecoder().decode([SMBShare].self, from: data) else { return }
        shares = decoded
    }

    // MARK: - Monitoring

    func startMonitoring() {
        // Startup permission check: disable shares whose mount point the user can't use.
        applyPermissionStatuses()

        let uptime = ProcessInfo.processInfo.systemUptime
        let remainingBootDelay = max(0, postBootAutoConnectDelay - uptime)
        let startupDelay = max(normalLaunchAutoConnectDelay, remainingBootDelay)

        startupReadyAt = Date().addingTimeInterval(startupDelay)
        startupReconnectScheduled = false

        let nm = NWPathMonitor()
        nm.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }
            let available = path.status == .satisfied
            DispatchQueue.main.async {
                let wasAvailable = self.isNetworkAvailable
                self.isNetworkAvailable = available

                if available && !wasAvailable {
                    self.startReconnectTimer()
                } else if !available {
                    self.stopReconnectTimer()
                    self.setAllDisconnectedSilently()
                }
            }
        }
        nm.start(queue: monitorQueue)
        networkMonitor = nm

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(volumeDidUnmount(_:)),
            name: NSWorkspace.didUnmountNotification,
            object: nil
        )

        DispatchQueue.main.asyncAfter(deadline: .now() + startupDelay) {
            guard self.isNetworkAvailable else { return }
            self.startReconnectTimer()
        }
    }

    func stopMonitoring() {
        stopReconnectTimer()
        networkMonitor?.cancel()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    @objc private func volumeDidUnmount(_ notification: Notification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + unmountStatusRefreshDelay) {
            self.updateMountStatuses()
            let hasDisconnected = self.shares.contains {
                $0.autoMount && !self.isManuallyDisconnected($0.id) && !self.isMounted($0)
            }
            if hasDisconnected {
                DispatchQueue.main.asyncAfter(deadline: .now() + self.unmountReconnectDelay) {
                    self.startReconnectTimer()
                }
            }
        }
    }

    // MARK: - Reconnect Timer

    private func startReconnectTimer() {
        guard recoveryTimer == nil else { return }
        guard isNetworkAvailable else { return }

        if let readyAt = startupReadyAt, Date() < readyAt {
            guard !startupReconnectScheduled else { return }
            startupReconnectScheduled = true
            let delay = max(0, readyAt.timeIntervalSinceNow)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                self.startupReconnectScheduled = false
                self.startReconnectTimer()
            }
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + initialReconnectAttemptDelay) {
            guard self.isNetworkAvailable else { return }
            self.mountAllAutoShares()
        }

        recoveryTimer = Timer.scheduledTimer(withTimeInterval: reconnectTickInterval, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            guard self.isNetworkAvailable else { return }
            self.mountAllAutoShares()

            let allMounted = self.shares
                .filter { $0.autoMount && !self.isManuallyDisconnected($0.id) }
                .allSatisfy { self.isMounted($0) }

            if allMounted {
                self.stopReconnectTimer()
            }
        }
    }

    private func stopReconnectTimer() {
        recoveryTimer?.invalidate()
        recoveryTimer = nil
    }

    private func setAllDisconnectedSilently() {
        for i in shares.indices {
            if shares[i].status != .disconnected {
                shares[i].status = .disconnected
                shares[i].lastError = nil
            }
        }
        stateQueue.sync {
            manuallyDisconnected.removeAll()
            pendingMounts.removeAll()
            extraRetryCount.removeAll()
        }
        failCount = [:]
        updateAppIcon()
    }

    func mountAllAutoShares() {
        guard isNetworkAvailable else { return }

        // Shares whose mount point the user cannot prepare are skipped entirely so the
        // app never tries (and never needs admin) — they stay visibly disabled.
        func isBlocked(_ share: SMBShare) -> Bool {
            Self.runtimeBlockReason(mountPoint: share.resolvedMountPoint, shareName: share.shareName) != nil
        }

        let needsReconnect = shares.contains {
            $0.autoMount && !isManuallyDisconnected($0.id) && !isMounted($0) && !isPendingMount($0.id) && !isBlocked($0)
        }

        for share in shares where share.autoMount && !isManuallyDisconnected(share.id) && !isBlocked(share) {
            if !isMounted(share) {
                mount(share)
            }
        }

        updateMountStatuses()

        if !needsReconnect {
            stopReconnectTimer()
        }
    }

    // MARK: - Host Resolution

    private enum ConfiguredHostType {
        case local(base: String)
        case plain(host: String)
        case ip(host: String)
    }

    private func baseHostName(from host: String) -> String {
        if host.contains("._smb._tcp") {
            return host.components(separatedBy: "._smb._tcp").first ?? host
        }
        if host.hasSuffix(".local") {
            return String(host.dropLast(6))
        }
        return host
    }

    private func isIPAddress(_ host: String) -> Bool {
        var ipv4 = in_addr()
        var ipv6 = in6_addr()
        return host.withCString { inet_pton(AF_INET, $0, &ipv4) } == 1 ||
               host.withCString { inet_pton(AF_INET6, $0, &ipv6) } == 1
    }

    private func configuredHostType(for host: String) -> ConfiguredHostType {
        let normalized = host.trimmingCharacters(in: .whitespacesAndNewlines)

        if normalized.contains("._smb._tcp.local") || normalized.hasSuffix(".local") {
            return .local(base: baseHostName(from: normalized))
        }
        if isIPAddress(normalized) {
            return .ip(host: normalized)
        }
        return .plain(host: normalized)
    }

    private func hostCandidates(for host: String) -> [String] {
        switch configuredHostType(for: host) {
        case .local(let base):
            return ["\(base).local", base]
        case .plain(let plain):
            return [plain]
        case .ip(let ip):
            return [ip]
        }
    }

    private func shouldKeepRetrying(_ share: SMBShare) -> Bool {
        guard isNetworkAvailable else { return false }
        guard !isManuallyDisconnected(share.id) else { return false }
        return shares.contains { $0.id == share.id }
    }

    @discardableResult
    private func waitRetry(for share: SMBShare, interval: TimeInterval = 0.35, until: Date? = nil) -> Bool {
        let slice: TimeInterval = 0.05
        var elapsed: TimeInterval = 0

        while elapsed < interval {
            if let until, Date() >= until { return false }
            if !shouldKeepRetrying(share) { return false }
            let remaining = interval - elapsed
            let sleepTime = min(slice, remaining)
            Thread.sleep(forTimeInterval: sleepTime)
            elapsed += sleepTime
        }

        if let until, Date() >= until { return false }
        return shouldKeepRetrying(share)
    }

    private func isSMBReachable(host: String, timeout: TimeInterval? = nil) -> Bool {
        let effectiveTimeout = timeout ?? smbReachabilityTimeout
        guard let port = NWEndpoint.Port(rawValue: 445) else { return false }

        let semaphore = DispatchSemaphore(value: 0)
        var reachable = false

        let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                reachable = true
                semaphore.signal()
            case .failed, .cancelled:
                semaphore.signal()
            default:
                break
            }
        }

        connection.start(queue: monitorQueue)
        _ = semaphore.wait(timeout: .now() + effectiveTimeout)
        connection.cancel()
        return reachable
    }

    private func isBonjourAvailable(for serverName: String) -> Bool {
        let semaphore = DispatchSemaphore(value: 0)
        var found = false

        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_smb._tcp", domain: "local"), using: .tcp)
        browser.browseResultsChangedHandler = { results, _ in
            for result in results {
                if case .service(let name, _, _, _) = result.endpoint,
                   name.lowercased() == serverName.lowercased() {
                    found = true
                    semaphore.signal()
                    break
                }
            }
        }
        browser.stateUpdateHandler = { state in
            if case .failed = state {
                semaphore.signal()
            }
        }

        browser.start(queue: monitorQueue)
        _ = semaphore.wait(timeout: .now() + bonjourQueryTimeout)
        browser.cancel()
        return found
    }

    private func stableReachability(for hosts: [String], share: SMBShare, until: Date) -> [String: Int] {
        var scores: [String: Int] = [:]
        while shouldKeepRetrying(share) && Date() < until {
            for host in hosts {
                if isSMBReachable(host: host) {
                    scores[host.lowercased(), default: 0] += 1
                }
            }
            if scores.values.contains(where: { $0 >= requiredStableSuccesses }) {
                break
            }
            if !waitRetry(for: share, interval: shortRetryInterval, until: until) {
                break
            }
        }
        return scores
    }

    private func isBonjourStable(base: String, share: SMBShare, until: Date) -> Bool {
        var successes = 0
        for i in 0..<bonjourCheckCycles {
            guard shouldKeepRetrying(share), Date() < until else { return false }
            if isBonjourAvailable(for: base) {
                successes += 1
                if successes >= requiredStableSuccesses {
                    return true
                }
            } else {
                successes = 0
            }

            if i < (bonjourCheckCycles - 1), !waitRetry(for: share, interval: shortRetryInterval, until: until) {
                return false
            }
        }
        return false
    }

    private func chooseMountHost(for share: SMBShare, until: Date) -> String? {
        let hostType = configuredHostType(for: share.host)

        switch hostType {
        case .plain(let host):
            let scores = stableReachability(for: [host], share: share, until: until)
            return (scores[host.lowercased()] ?? 0) >= requiredStableSuccesses ? host : nil

        case .ip(let host):
            let scores = stableReachability(for: [host], share: share, until: until)
            return (scores[host.lowercased()] ?? 0) >= requiredStableSuccesses ? host : nil

        case .local(let base):
            let localHost = "\(base).local"
            let plainHost = base
            let reachabilityScores = stableReachability(for: [localHost, plainHost], share: share, until: until)

            let localReachable = (reachabilityScores[localHost.lowercased()] ?? 0) >= requiredStableSuccesses
            let plainReachable = (reachabilityScores[plainHost.lowercased()] ?? 0) >= requiredStableSuccesses

            guard localReachable || plainReachable else { return nil }

            if isBonjourStable(base: base, share: share, until: until) {
                return "\(base)._smb._tcp.local"
            }
            if localReachable { return localHost }
            if plainReachable { return plainHost }
            return nil
        }
    }

    private func finalPreflight(share: SMBShare, selectedHost: String, until: Date) -> Bool {
        if selectedHost.contains("._smb._tcp.local") {
            let base = baseHostName(from: share.host)
            let localHost = "\(base).local"
            let plainHost = base

            guard isBonjourAvailable(for: base) else { return false }
            return isSMBReachable(host: localHost) || isSMBReachable(host: plainHost)
        }

        var successCount = 0
        while shouldKeepRetrying(share) && Date() < until {
            if isSMBReachable(host: selectedHost) {
                successCount += 1
                if successCount >= requiredStableSuccesses {
                    return true
                }
            }
            if !waitRetry(for: share, interval: shortRetryInterval, until: until) {
                return false
            }
        }
        return false
    }

    private func waitForSMBAvailability(for share: SMBShare) -> String? {
        guard shouldKeepRetrying(share) else { return nil }

        while shouldKeepRetrying(share) {
            let cycleDeadline = Date().addingTimeInterval(mountCycleTimeout)
            let resolutionDeadline = min(cycleDeadline, Date().addingTimeInterval(hostProbeWindow))

            if let selectedHost = chooseMountHost(for: share, until: resolutionDeadline),
               finalPreflight(share: share, selectedHost: selectedHost, until: cycleDeadline) {
                return selectedHost
            }

            if Date() >= cycleDeadline {
                continue
            }
            if !waitRetry(for: share, interval: shortRetryInterval, until: cycleDeadline) {
                if shouldKeepRetrying(share) {
                    continue
                }
                return nil
            }
        }

        return nil
    }

    // MARK: - Mount Status

    func isMounted(_ share: SMBShare) -> Bool {
        let baseHost: String
        if share.host.hasSuffix(".local") && !share.host.contains("._smb._tcp") {
            baseHost = String(share.host.dropLast(6)).lowercased()
        } else if share.host.contains("._smb._tcp") {
            baseHost = (share.host.components(separatedBy: "._smb._tcp").first ?? share.host).lowercased()
        } else {
            baseHost = share.host.lowercased()
        }
        let shareName = share.shareName.lowercased()

        let vols = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: [.volumeURLForRemountingKey],
            options: []
        ) ?? []

        for vol in vols {
            if let r = try? vol.resourceValues(forKeys: [.volumeURLForRemountingKey]).volumeURLForRemounting {
                let s = r.absoluteString.lowercased()
                if s.contains("smb") && s.contains(baseHost) && s.contains(shareName) {
                    return true
                }
            }
        }

        if mountMethod(for: share) == .smbfs {
            let targetPath = (share.resolvedMountPoint as NSString).expandingTildeInPath
            return vols.contains { vol in
                let vp = vol.path
                return vp == targetPath
                    || vp == targetPath + "/"
                    || (vp.hasSuffix("/") && String(vp.dropLast()) == targetPath)
            }
        }
        return false
    }

    /// Returns the filesystem paths where this share is currently mounted, regardless
    /// of which method mounted it. The Finder method mounts at /Volumes/<shareName>
    /// (ignoring the configured mount point), while mount_smbfs mounts at the configured
    /// path — so the real location must be discovered, not assumed from resolvedMountPoint.
    func mountedPaths(for share: SMBShare) -> [String] {
        let baseHost: String
        if share.host.hasSuffix(".local") && !share.host.contains("._smb._tcp") {
            baseHost = String(share.host.dropLast(6)).lowercased()
        } else if share.host.contains("._smb._tcp") {
            baseHost = (share.host.components(separatedBy: "._smb._tcp").first ?? share.host).lowercased()
        } else {
            baseHost = share.host.lowercased()
        }
        let shareName = share.shareName.lowercased()
        let targetPath = (share.resolvedMountPoint as NSString).expandingTildeInPath

        let vols = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: [.volumeURLForRemountingKey],
            options: []
        ) ?? []

        var paths: [String] = []
        for vol in vols {
            var matched = false
            if let r = try? vol.resourceValues(forKeys: [.volumeURLForRemountingKey]).volumeURLForRemounting {
                let s = r.absoluteString.lowercased()
                if s.contains("smb") && s.contains(baseHost) && s.contains(shareName) {
                    matched = true
                }
            }
            if !matched {
                let vp = vol.path
                if vp == targetPath || vp == targetPath + "/"
                    || (vp.hasSuffix("/") && String(vp.dropLast()) == targetPath) {
                    matched = true
                }
            }
            if matched { paths.append(vol.path) }
        }
        return paths
    }

    // MARK: - Mount Method Determination (dynamic, never stored)

    /// Chooses the mount method. The single no-preparation case is /Volumes/<shareName>,
    /// which uses Finder (macOS creates that directory itself, no admin prompt). Every
    /// other location — including other paths under /Volumes — uses mount_smbfs, which
    /// mounts at the exact path provided. Such paths must exist and be user-owned before
    /// the mount; `prepareMountPoint(_:)` creates them (with consent) when needed.
    static func autoMountMethod(forMountPoint rawPath: String, shareName: String) -> MountMethod {
        let path = (rawPath as NSString).expandingTildeInPath
        return path == "/Volumes/\(shareName)" ? .finder : .smbfs
    }

    func mountMethod(for share: SMBShare) -> MountMethod {
        Self.autoMountMethod(forMountPoint: share.resolvedMountPoint, shareName: share.shareName)
    }

    /// Describes what (if anything) must happen before a mount point can be used.
    enum MountPointPreparation: Equatable {
        case finderManaged                       // /Volumes/<shareName> — macOS handles it
        case ready                               // exists and is user-writable
        case needsCreation(requiresAuth: Bool)   // missing; will be created (+chowned)
        case needsPermissionFix                  // exists but not writable; chown required (admin)
        case unusable(String)                    // exists but isn't a usable directory
    }

    /// Inspects the mount point and returns what preparation it needs. `requiresAuth`
    /// is true when creation must write into a directory the user can't (e.g. the
    /// root-owned /Volumes), which means administrator authorization.
    static func mountPointPreparation(mountPoint rawPath: String, shareName: String) -> MountPointPreparation {
        let path = (rawPath as NSString).expandingTildeInPath
        if path == "/Volumes/\(shareName)" { return .finderManaged }

        let fm = FileManager.default
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: path, isDirectory: &isDir) {
            if !isDir.boolValue { return .unusable("\(path) exists but is not a folder.") }
            return fm.isWritableFile(atPath: path) ? .ready : .needsPermissionFix
        }

        // Missing — find the deepest existing ancestor to decide if creation needs admin.
        var dir = (path as NSString).deletingLastPathComponent
        while !dir.isEmpty && dir != "/" {
            if fm.fileExists(atPath: dir, isDirectory: &isDir) {
                if !isDir.boolValue { return .unusable("\(dir) is not a folder.") }
                return .needsCreation(requiresAuth: !fm.isWritableFile(atPath: dir))
            }
            dir = (dir as NSString).deletingLastPathComponent
        }
        return .needsCreation(requiresAuth: !fm.isWritableFile(atPath: "/"))
    }

    /// The reason a share cannot be auto-mounted right now, or nil if it can. A mount
    /// point that only needs a non-privileged folder creation is *not* blocked — the
    /// mount path creates it silently. Anything that would need admin (which we never
    /// prompt for unattended) or is structurally unusable is blocked.
    static func runtimeBlockReason(mountPoint rawPath: String, shareName: String) -> String? {
        let path = (rawPath as NSString).expandingTildeInPath
        switch mountPointPreparation(mountPoint: path, shareName: shareName) {
        case .finderManaged, .ready:
            return nil
        case .needsCreation(let requiresAuth):
            return requiresAuth
                ? "Mount point \(path) doesn't exist and needs administrator authorization to create. Edit the share to create it."
                : nil
        case .needsPermissionFix:
            return "You don't have permission to use \(path). Edit the share to set it up."
        case .unusable(let reason):
            return reason
        }
    }

    /// Creates the mount-point hierarchy if missing and makes it owned by the current
    /// user, so a later user-level mount_smbfs can mount onto it. Uses administrator
    /// authorization (a system prompt) only when the location isn't user-writable.
    /// Returns nil on success or an error string. Call only after the user has agreed.
    static func prepareMountPoint(_ rawPath: String) -> String? {
        let path = (rawPath as NSString).expandingTildeInPath
        let fm = FileManager.default
        var isDir: ObjCBool = false

        if fm.fileExists(atPath: path, isDirectory: &isDir) {
            if !isDir.boolValue { return "\(path) exists but is not a folder." }
            if fm.isWritableFile(atPath: path) { return nil }   // already usable
            // exists but not writable -> fall through to privileged chown
        } else {
            // Try a non-privileged create when the parent is user-writable.
            var dir = (path as NSString).deletingLastPathComponent
            var ancestor = "/"
            while !dir.isEmpty && dir != "/" {
                if fm.fileExists(atPath: dir) { ancestor = dir; break }
                dir = (dir as NSString).deletingLastPathComponent
            }
            if fm.isWritableFile(atPath: ancestor) {
                do {
                    try fm.createDirectory(atPath: path, withIntermediateDirectories: true)
                    return nil
                } catch {
                    return "Failed to create \(path): \(error.localizedDescription)"
                }
            }
        }

        // Privileged path: create (if needed) and hand ownership to the user.
        let user = NSUserName()
        let script = "do shell script \"mkdir -p '\(path)' && chown '\(user)' '\(path)'\" with administrator privileges"
        let task = Process()
        task.launchPath = "/usr/bin/osascript"
        task.arguments = ["-e", script]
        task.standardOutput = Pipe()
        task.standardError = Pipe()
        do {
            try task.run()
        } catch {
            return "Failed to create \(path): \(error.localizedDescription)"
        }
        task.waitUntilExit()
        if task.terminationStatus != 0 {
            return "Could not create \(path) — administrator authorization was cancelled or failed."
        }
        return nil
    }

    /// Applies the startup check: any share that can't be auto-mounted (unusable path,
    /// or one needing admin-level creation/permission changes we won't prompt for
    /// unattended) is marked with an error so it is visibly disabled and skipped.
    func applyPermissionStatuses() {
        DispatchQueue.main.async {
            for i in self.shares.indices {
                let s = self.shares[i]
                if let reason = Self.runtimeBlockReason(mountPoint: s.resolvedMountPoint, shareName: s.shareName),
                   !self.isMounted(s) {
                    self.shares[i].status = .error
                    self.shares[i].lastError = reason
                }
            }
            self.updateAppIcon()
        }
    }

    func updateMountStatuses() {
        DispatchQueue.main.async {
            for i in self.shares.indices {
                let mounted = self.isMounted(self.shares[i])
                if mounted && self.shares[i].status != .mounted {
                    self.shares[i].status = .mounted
                    self.shares[i].lastConnected = Date()
                    self.shares[i].lastError = nil
                } else if !mounted && self.shares[i].status == .mounted {
                    self.shares[i].status = .disconnected
                    self.shares[i].lastError = nil
                }
            }
            self.updateAppIcon()
        }
    }

    private func updateAppIcon() {
        let hasError = shares.contains { $0.status == .error || ($0.status == .disconnected && $0.autoMount) }
        DispatchQueue.main.async {
            if let delegate = NSApp.delegate as? AppDelegate {
                delegate.updateStatusIcon(hasError: hasError)
            }
        }
    }

    // MARK: - SMBFS Mount

    private func splitDomainUser(_ username: String) -> (domain: String?, user: String) {
        if let backslash = username.firstIndex(of: "\\") {
            let domain = String(username[username.startIndex..<backslash])
            let user = String(username[username.index(after: backslash)...])
            return (domain.isEmpty ? nil : domain, user)
        }
        return (nil, username)
    }

    private func ensureMountPointExists(_ path: String) -> String? {
        let fm = FileManager.default

        var isDir: ObjCBool = false
        if fm.fileExists(atPath: path, isDirectory: &isDir) {
            return isDir.boolValue ? nil : "Mount point \(path) exists but is not a directory"
        }

        // smbfs is only ever used for user-writable, non-/Volumes paths (the method
        // is auto-selected from the location), so a plain mkdir always suffices — no
        // administrator authorization is needed or requested.
        do {
            try fm.createDirectory(atPath: path, withIntermediateDirectories: true)
            return nil
        } catch {
            return "Failed to create mount point: \(error.localizedDescription)"
        }
    }

    private func runSmbfsMount(share: SMBShare, host: String) -> String? {
        let expandedPath = (share.resolvedMountPoint as NSString).expandingTildeInPath

        if let err = ensureMountPointExists(expandedPath) {
            return err
        }

        let password = KeychainHelper.shared.getPassword(for: share.id) ?? ""
        let (domain, user) = splitDomainUser(share.username)

        var smbfsUserAllowed = CharacterSet.urlUserAllowed
        smbfsUserAllowed.remove(charactersIn: ";")
        var smbfsPassAllowed = CharacterSet.urlPasswordAllowed
        smbfsPassAllowed.remove(charactersIn: ":")

        let urlString: String
        if !user.isEmpty && !password.isEmpty {
            let encodedUser = user.addingPercentEncoding(withAllowedCharacters: smbfsUserAllowed) ?? user
            let encodedPass = password.addingPercentEncoding(withAllowedCharacters: smbfsPassAllowed) ?? password
            if let domain = domain {
                let encodedDomain = domain.addingPercentEncoding(withAllowedCharacters: smbfsUserAllowed) ?? domain
                urlString = "//\(encodedDomain);\(encodedUser):\(encodedPass)@\(host)/\(share.shareName)"
            } else {
                urlString = "//\(encodedUser):\(encodedPass)@\(host)/\(share.shareName)"
            }
        } else if !user.isEmpty {
            let encodedUser = user.addingPercentEncoding(withAllowedCharacters: smbfsUserAllowed) ?? user
            urlString = "//\(encodedUser)@\(host)/\(share.shareName)"
        } else {
            urlString = "//\(host)/\(share.shareName)"
        }

        let task = Process()
        task.launchPath = "/sbin/mount_smbfs"
        task.arguments = [urlString, expandedPath]
        let errPipe = Pipe()
        task.standardError = errPipe
        task.standardOutput = Pipe()

        do {
            try task.run()
        } catch {
            return "Failed to launch mount_smbfs: \(error.localizedDescription)"
        }

        let deadline = Date().addingTimeInterval(15)
        while task.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        if task.isRunning {
            task.terminate()
            return "mount_smbfs timed out"
        }
        task.waitUntilExit()

        let data = errPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrMsg = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if task.terminationStatus != 0 {
            return stderrMsg.isEmpty ? "mount_smbfs failed (exit \(task.terminationStatus))" : stderrMsg
        }
        return nil
    }

    // MARK: - Finder Mount

    private func runFinderMount(urlString: String) {
        let script = """
        try
            tell application "Finder"
                with timeout of \(finderAppleScriptTimeoutSeconds) seconds
                    mount volume "\(urlString)"
                end timeout
            end tell
        on error
        end try
        """

        let task = Process()
        task.launchPath = "/usr/bin/osascript"
        task.arguments = ["-e", script]
        task.standardError = Pipe()
        task.standardOutput = Pipe()

        do {
            try task.run()

            let deadline = Date().addingTimeInterval(finderExecutionTimeout)
            while task.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.1)
            }

            if task.isRunning {
                task.terminate()
            }

            task.waitUntilExit()
        } catch {
            return
        }
    }

    private func waitUntilMounted(_ share: SMBShare, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if isMounted(share) {
                return true
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return isMounted(share)
    }

    // MARK: - Mount / Unmount

    func mount(_ share: SMBShare) {
        clearManuallyDisconnected(share.id)

        guard let idx = shares.firstIndex(where: { $0.id == share.id }) else { return }
        guard shares[idx].status != .mounted else { return }

        // Refuse to mount shares whose mount point isn't ready. This keeps the app from
        // ever needing administrator authorization at mount time (preparation happens
        // in the editor, with consent) or mounting somewhere other than specified.
        if let reason = Self.runtimeBlockReason(mountPoint: shares[idx].resolvedMountPoint, shareName: shares[idx].shareName) {
            shares[idx].status = .error
            shares[idx].lastError = reason
            updateAppIcon()
            return
        }

        guard beginPendingMount(share.id) else { return }

        shares[idx].status = .connecting
        shares[idx].lastError = nil
        updateAppIcon()

        mountQueue.async {
            defer { self.endPendingMount(share.id) }
            self.performMount(for: share.id)
        }
    }

    private func performMount(for shareID: UUID) {
        guard let share = shares.first(where: { $0.id == shareID }) else { return }
        guard shouldKeepRetrying(share) else { return }

        guard let host = waitForSMBAvailability(for: share) else {
            DispatchQueue.main.async {
                guard let idx = self.shares.firstIndex(where: { $0.id == shareID }) else { return }
                if self.isManuallyDisconnected(shareID) {
                    self.shares[idx].status = .disconnected
                    self.shares[idx].lastError = nil
                    self.clearExtraRetry(shareID)
                } else {
                    self.failCount[shareID, default: 0] += 1
                    self.shares[idx].status = .disconnected
                    self.shares[idx].lastError = "Host aktuell nicht erreichbar (SMB Port 445)."
                    self.scheduleOneExtraRetryIfNeeded(for: shareID)
                }
                self.updateAppIcon()
            }
            return
        }

        guard shouldKeepRetrying(share) else { return }

        switch mountMethod(for: share) {
        case .finder:
            // The credentialed smb:// URL is only needed by the Finder method. Build
            // it (and read the keychain) here so an smbfs mount doesn't read the
            // password twice — runSmbfsMount fetches its own and builds its own URL.
            let password = KeychainHelper.shared.getPassword(for: shareID) ?? ""
            let urlString: String
            if !share.username.isEmpty && !password.isEmpty {
                let encodedPass = password.addingPercentEncoding(withAllowedCharacters: .urlPasswordAllowed) ?? password
                let encodedUser = share.username.addingPercentEncoding(withAllowedCharacters: .urlUserAllowed) ?? share.username
                urlString = "smb://\(encodedUser):\(encodedPass)@\(host)/\(share.shareName)"
            } else if !share.username.isEmpty {
                let encodedUser = share.username.addingPercentEncoding(withAllowedCharacters: .urlUserAllowed) ?? share.username
                urlString = "smb://\(encodedUser)@\(host)/\(share.shareName)"
            } else {
                urlString = "smb://\(host)/\(share.shareName)"
            }
            runFinderMount(urlString: urlString)
        case .smbfs:
            if let errorMsg = runSmbfsMount(share: share, host: host) {
                DispatchQueue.main.async {
                    guard let idx = self.shares.firstIndex(where: { $0.id == shareID }) else { return }
                    self.failCount[shareID, default: 0] += 1
                    self.shares[idx].status = .disconnected
                    self.shares[idx].lastError = errorMsg
                    self.scheduleOneExtraRetryIfNeeded(for: shareID)
                    self.updateAppIcon()
                }
                return
            }
        }

        let mounted = waitUntilMounted(share, timeout: postMountVerifyTimeout)

        DispatchQueue.main.async {
            guard let idx = self.shares.firstIndex(where: { $0.id == shareID }) else { return }

            if self.isManuallyDisconnected(shareID) {
                self.shares[idx].status = .disconnected
                self.shares[idx].lastError = nil
                self.clearExtraRetry(shareID)
                self.updateAppIcon()
                return
            }

            if mounted {
                self.failCount[shareID] = nil
                self.clearExtraRetry(shareID)
                self.shares[idx].status = .mounted
                self.shares[idx].lastConnected = Date()
                self.shares[idx].lastError = nil
                self.sendNotification(title: "Connected", body: "\(self.shares[idx].name) successfully connected.")
            } else {
                self.failCount[shareID, default: 0] += 1
                self.shares[idx].status = .disconnected
                self.shares[idx].lastError = nil
                self.scheduleOneExtraRetryIfNeeded(for: shareID)
            }

            self.updateAppIcon()
        }
    }

    func unmount(_ share: SMBShare) {
        markManuallyDisconnected(share.id)
        endPendingMount(share.id)
        clearExtraRetry(share.id)
        failCount[share.id] = nil

        unmountQueue.async {
            for attempt in 0..<6 {
                let paths = self.mountedPaths(for: share)
                if paths.isEmpty {
                    break
                }
                for path in paths {
                    let task = Process()
                    task.launchPath = "/sbin/umount"
                    // First attempt is graceful; escalate to a forced unmount on retries
                    // (network volumes with open handles often need -f).
                    task.arguments = attempt == 0 ? [path] : ["-f", path]
                    try? task.run()
                    task.waitUntilExit()
                }
                Thread.sleep(forTimeInterval: 0.3)
            }

            DispatchQueue.main.async {
                guard let idx = self.shares.firstIndex(where: { $0.id == share.id }) else { return }
                if self.isMounted(share) {
                    // Reflect reality instead of falsely showing "disconnected".
                    self.shares[idx].status = .error
                    self.shares[idx].lastError = "Unmount failed — volume is still mounted."
                } else {
                    self.shares[idx].status = .disconnected
                    self.shares[idx].lastError = nil
                }
                self.updateAppIcon()
            }
        }
    }

    // MARK: - CRUD

    /// Returns true if an existing share already uses the same mount point.
    /// Two shares cannot mount to the same location.
    func isDuplicate(_ share: SMBShare) -> Bool {
        shares.contains {
            $0.id != share.id &&
            $0.resolvedMountPoint == share.resolvedMountPoint
        }
    }

    func addShare(_ share: SMBShare, password: String) {
        var s = share
        s.status = .disconnected
        if let reason = Self.runtimeBlockReason(mountPoint: s.resolvedMountPoint, shareName: s.shareName) {
            s.status = .error
            s.lastError = reason
        }
        shares.append(s)
        if !password.isEmpty {
            KeychainHelper.shared.savePassword(password, for: s.id)
        }
        saveShares()
        if s.autoMount && s.status != .error {
            mount(s)
        }
    }

    func updateShare(_ share: SMBShare, password: String?) {
        guard let idx = shares.firstIndex(where: { $0.id == share.id }) else { return }
        let wasAutoMount = shares[idx].autoMount
        let wasMounted = isMounted(shares[idx])

        if wasMounted {
            unmount(shares[idx])
        }

        shares[idx] = share

        // Reflect the (re-evaluated) state immediately so editing a share to a valid
        // path clears a prior error, and vice versa.
        if let reason = Self.runtimeBlockReason(mountPoint: shares[idx].resolvedMountPoint, shareName: shares[idx].shareName) {
            shares[idx].status = .error
            shares[idx].lastError = reason
        } else {
            shares[idx].status = .disconnected
            shares[idx].lastError = nil
        }

        if let pwd = password, !pwd.isEmpty {
            KeychainHelper.shared.savePassword(pwd, for: share.id)
        }

        saveShares()

        if (share.autoMount || (wasAutoMount && wasMounted)) && shares[idx].status != .error {
            mount(share)
        }
    }

    func removeShare(_ share: SMBShare) {
        if isMounted(share) {
            unmount(share)
        }
        clearManuallyDisconnected(share.id)
        endPendingMount(share.id)
        clearExtraRetry(share.id)
        failCount[share.id] = nil
        KeychainHelper.shared.deletePassword(for: share.id)
        shares.removeAll { $0.id == share.id }
        saveShares()
    }

    // MARK: - Helpers

    private func setError(for share: SMBShare, message: String) {
        DispatchQueue.main.async {
            guard let idx = self.shares.firstIndex(where: { $0.id == share.id }) else { return }
            self.shares[idx].status = .error
            self.shares[idx].lastError = message
            self.updateAppIcon()
        }
    }

    private func sendNotification(title: String, body: String) {
        DispatchQueue.main.async {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
        }
    }

    func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
}
