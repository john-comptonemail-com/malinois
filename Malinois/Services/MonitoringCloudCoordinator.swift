import Foundation

/// The watch facts and orchestration cloud work needs. No generic engine escape hatch.
@MainActor
protocol MonitoringCloudHost: AnyObject {
    var cloudHostState: MonitoringState { get }
    var cloudHostAllowsUpload: Bool { get }
    var cloudHostArmedPro: Bool { get }
    var cloudHostArmedSince: Date? { get }
    var cloudHostHadConnectivityAtArm: Bool { get }
    var cloudHostIsCharging: Bool { get }
    var cloudHostLiveFloodAnchorID: UUID? { get }
    func cloudEventCountDidChange(to count: Int)
    func cloudUploadInterferenceDetected()
    func cloudRefreshNotificationHealth() async
    func cloudRecordBackupChange(_ kind: String)
    func cloudWriteOwedReinstallRecord()
}

/// Owns cloud coordination state; the engine remains its observable facade and watch host.
@MainActor
final class MonitoringCloudCoordinator {
    weak var host: (any MonitoringCloudHost)?
    let settings: AppSettings
    let eventStore: EventStore
    let cloud: CloudExfiltrator
    let entitlements: ProEntitlements
    let timing: EngineTiming
    let connectivity: ConnectivityMonitor
    let thermalState: @MainActor () -> ProcessInfo.ThermalState

    // Keep original initial values and publish every assignment, including an equal value.
    // These callbacks are installed before watchBackupSetting, without an initial replay.
    var onCloudResetNoticeChange: @MainActor (String?) -> Void = { _ in }
    var onCloudPushRefusedChange: @MainActor (Bool) -> Void = { _ in }
    var onCloudRestoreInProgressChange: @MainActor (Bool) -> Void = { _ in }
    var onCurrentLaunchPullChange: @MainActor (LaunchPullKind) -> Void = { _ in }
    var onPendingSweepActiveChange: @MainActor (Bool) -> Void = { _ in }
    var onPendingSweepWaitingChange: @MainActor (Bool) -> Void = { _ in }

    var cloudResetNotice: String? { willSet { onCloudResetNoticeChange(newValue) } }
    var cloudPushRefused = false { willSet { onCloudPushRefusedChange(newValue) } }
    var cloudRestoreInProgress = false { willSet { onCloudRestoreInProgressChange(newValue) } }
    var currentLaunchPull: LaunchPullKind = .checking { willSet { onCurrentLaunchPullChange(newValue) } }
    var pendingSweepActive = false { willSet { onPendingSweepActiveChange(newValue) } }
    var pendingSweepWaiting = false { willSet { onPendingSweepWaitingChange(newValue) } }

    // Authoritative state, not mirrors. Internal because moved extensions use it across files.
    var cloudReuploadCount: Int?
    var encryptedResetHandled = false
    var bindingsInUse: [UUID: Int] = [:]
    var retryingSync = false
    var sweepRerunOwed = false
    var heartbeatSession: UUID?
    var heartbeatSequence = 0
    var heartbeatTimer: Timer?

    // These main-file constants are not function/type bodies, so the move-kit parser does
    // not copy them. Keep both original limits explicitly with stageDownloadedAsset.
    nonisolated static let maxDownloadedStillBytes = 25 * 1024 * 1024
    nonisolated static let maxDownloadedMovieBytes = 600 * 1024 * 1024

    init(settings: AppSettings, eventStore: EventStore, cloud: CloudExfiltrator,
         entitlements: ProEntitlements, timing: EngineTiming, connectivity: ConnectivityMonitor,
         thermalState: @escaping @MainActor () -> ProcessInfo.ThermalState) {
        self.settings = settings
        self.eventStore = eventStore
        self.cloud = cloud
        self.entitlements = entitlements
        self.timing = timing
        self.connectivity = connectivity
        self.thermalState = thermalState
    }

    // These names preserve existing moved expressions. Each access asks the current host;
    // never cache this group across an await. An unattached component has no active watch.
    var state: MonitoringState { host?.cloudHostState ?? .disarmed }
    var cloudAllowed: Bool { host?.cloudHostAllowsUpload ?? false }
    var armedPro: Bool { host?.cloudHostArmedPro ?? false }
    var armedSince: Date? { host?.cloudHostArmedSince }
    var hadConnectivityAtArm: Bool { host?.cloudHostHadConnectivityAtArm ?? false }
    var isCharging: Bool { host?.cloudHostIsCharging ?? true }
    var liveFloodAnchorID: UUID? { host?.cloudHostLiveFloodAnchorID }

    // A bridge, not another count. Only pullFromCloud writes it, immediately after merge.
    var eventCount: Int {
        get { eventStore.events.count }
        set { host?.cloudEventCountDidChange(to: newValue) }
    }

    // Keep the original backup/Verify ordering without importing their engine concerns.
    func logStateChange(_ kind: String) { host?.cloudRecordBackupChange(kind) }
    func writeOwedReinstallRecord() { host?.cloudWriteOwedReinstallRecord() }
    func refreshNotificationHealth() async { await host?.cloudRefreshNotificationHealth() }

    /// Bind a newly created first-hand record before journaling or any asynchronous capture/upload work.
    func registerLocalEvent(_ event: Event) { cloud.enrollment.registerLocalEvent(event) }

    /// Clear the same three per-watch notices, in the original order. The process reset guard stays set.
    func resetWatchNotices() {
        cloudPushRefused = false
        cloudResetNotice = nil
        cloudReuploadCount = nil
    }

    /// A finite operation's explicit strong ownership of the host. It is never stored on
    /// the coordinator, timer or uploader, so it cannot create a permanent ownership cycle.
    @MainActor
    struct FiniteWorkLifetime {
        private let owner: (any MonitoringCloudHost)?
        init(owner: (any MonitoringCloudHost)?) { self.owner = owner }
        func keepAlive() { withExtendedLifetime(owner) {} }
    }

    /// Take this synchronously before creating a task, not inside its first scheduled turn.
    func retainHostForFiniteWork() -> FiniteWorkLifetime { FiniteWorkLifetime(owner: host) }

    #if DEBUG
    var evidencePushForTesting: ((Event) async -> CloudExfiltrator.ExfilOutcome)?
    var sweepUploadForTesting: ((Event) async -> (state: CloudSyncState,
                                                transient: CloudExfiltrator.TransientFailure?))?
    var sweepTransientForTesting: CloudExfiltrator.TransientFailure?
    var sweepDisarmSignalsForTesting: [UUID: Bool] = [:]
    var sweepStandInAlertsForTesting: [UUID] = []
    var cloudPresenceForTesting: (([String]) async -> Set<String>?)?
    var cloudAccountForTesting: String?
    var cloudFetchForTesting: ((Int) async -> (events: [Event], complete: Bool))?
    var beatSendForTesting: ((HeartbeatBeat) async -> Bool)?
    var latestBeatFetchForTesting: ((UUID) async -> LastHeard)?
    var beatTrailsTrimForTesting: (@MainActor ([BeatSession]) async -> [UUID: BeatTrimOutcome])?
    var requiresCloudLeaseForTesting = false
    var fullMediaFetchForTesting: (@MainActor (UUID, [String]?) async -> CloudExfiltrator.FullMediaFetch?)?
    #endif
}
