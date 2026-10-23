import Foundation

/// One of the plan's usage limits, as the Claude app shows them: the session's (five hours) and the week's.
struct PlanLimit: Equatable {
    enum Kind: String, CaseIterable {
        case session = "five_hour", weekly = "seven_day", weeklyOpus = "seven_day_opus", weeklySonnet = "seven_day_sonnet"
    }

    let kind: Kind
    /// Percent of the limit used, 0…100.
    let used: Double
    let resets: Date?

    var exhausted: Bool { used >= 100 }

    var name: String {
        switch kind {
        case .session: return tr("Лимит сессии", "Session limit")
        case .weekly: return tr("Недельный лимит", "Weekly limit")
        case .weeklyOpus: return tr("Недельный лимит Opus", "Weekly Opus limit")
        case .weeklySonnet: return tr("Недельный лимит Sonnet", "Weekly Sonnet limit")
        }
    }

    /// "Сброс через 4 ч 51 мин", or past a day "Сброс в пт, 12:00".
    func resetText(from now: Date = Date()) -> String {
        guard let resets else { return "" }
        let left = resets.timeIntervalSince(now)
        if left < 24 * 3600 {
            let minutes = max(1, Int((left / 60).rounded(.up)))
            let h = minutes / 60, m = minutes % 60
            let span = h == 0 ? tr("\(m) мин", "\(m) min") : m == 0 ? tr("\(h) ч", "\(h) h") : tr("\(h) ч \(m) мин", "\(h) h \(m) min")
            return tr("Сброс через \(span)", "Resets in \(span)")
        }
        let format = DateFormatter()
        format.locale = Locale(identifier: tr("ru_RU", "en_US"))
        format.setLocalizedDateFormatFromTemplate("EEE HH:mm")
        return tr("Сброс в \(format.string(from: resets))", "Resets \(format.string(from: resets))")
    }

    /// The limits in what api.anthropic.com/api/oauth/usage answers:
    /// `{"five_hour":{"utilization":4.0,"resets_at":"2026-10-23T20:00:00.123+00:00"},"seven_day":{…},"seven_day_opus":null,…}`
    static func parse(_ data: Data) -> [PlanLimit]? {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let precise = ISO8601DateFormatter()
        precise.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        let limits = Kind.allCases.compactMap { kind -> PlanLimit? in
            guard let limit = json[kind.rawValue] as? [String: Any], let used = (limit["utilization"] as? NSNumber)?.doubleValue else { return nil }
            let resets = (limit["resets_at"] as? String).flatMap { precise.date(from: $0) ?? plain.date(from: $0) }
            return PlanLimit(kind: kind, used: used, resets: resets)
        }
        return limits.isEmpty ? nil : limits
    }
}

/// Keeps an eye on the plan's limits and tells when one runs out and when it's back. Asks
/// api.anthropic.com with Claude Code's own login (`ClaudeLogin`), the way its /usage does: every few minutes while
/// Claude works and for a while after, then once more when a limit that ran out is due to reset.
/// Otherwise the limits can't run out, and it asks nothing. Used on the main thread.
final class PlanLimits: ObservableObject {
    enum Change { case exhausted(PlanLimit), restored(PlanLimit) }

    static let key = "planLimits"
    /// The limits that had run out at the last look, so a change is told once, across restarts too.
    private static let exhaustedKey = "exhaustedLimits"
    static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    /// How often to look while Claude works, and how long after it stopped.
    static let interval: TimeInterval = 4 * 60
    static let keepLooking: TimeInterval = 10 * 60

    @Published private(set) var limits: [PlanLimit] = []
    @Published private(set) var checked: Date?
    var onChange: (Change) -> Void = { _ in }
    /// Whether Claude was at work in the last `keepLooking`.
    var claudeWasBusy: () -> Bool = { false }

    private var timer: Timer?
    private var resetTimer: Timer?
    private var fetching = false
    private var lastFetch = Date.distantPast

    var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.key) }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.key)
            start()
        }
    }

    func start() {
        timer?.invalidate()
        resetTimer?.invalidate()
        timer = nil
        resetTimer = nil
        guard enabled else {
            limits = []
            return
        }
        refresh()
        let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            guard let self, self.claudeWasBusy() else { return }
            self.refresh()
        }
        timer.tolerance = 30
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// A turn ended, or the settings opened: look again, unless just looked. `urgent` (a turn ended at
    /// a rate limit): look anyway.
    func lookAgain(urgent: Bool = false) {
        guard enabled, urgent || Date().timeIntervalSince(lastFetch) > 60 else { return }
        refresh()
    }

    func refresh() {
        guard enabled, !fetching else { return }
        fetching = true
        lastFetch = Date()
        DispatchQueue.global(qos: .utility).async {
            let limits = Self.fetch()
            DispatchQueue.main.async {
                self.fetching = false
                if let limits { self.update(limits) }
            }
        }
    }

    /// The limits, with Claude Code's login, renewed first if it's stale; and once more if it turns
    /// out stale anyway. Off the main thread.
    private static func fetch() -> [PlanLimit]? {
        guard var login = ClaudeLogin.read() else {
            EventLog.append("Limits: no Claude Code login")
            return nil
        }
        var renewed = false
        if login.expired {
            guard login.renew() else { return nil }
            renewed = true
        }
        while true {
            var request = URLRequest(url: endpoint, timeoutInterval: 20)
            request.setValue("Bearer \(login.token)", forHTTPHeaderField: "Authorization")
            request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
            request.setValue("ClaudeNotch/\(Updates.current)", forHTTPHeaderField: "User-Agent")
            let (status, json) = ClaudeLogin.load(request) ?? (0, [:])
            if status == 401, !renewed {
                renewed = true
                if login.renew() { continue }
            }
            let limits = status == 200 ? (try? JSONSerialization.data(withJSONObject: json)).flatMap(PlanLimit.parse) : nil
            EventLog.append(limits.map { "Limits: " + $0.map { "\($0.kind.rawValue) \(Int($0.used))%" }.joined(separator: ", ") }
                            ?? "Limits: HTTP \(status)")
            return limits
        }
    }

    private func update(_ fresh: [PlanLimit]) {
        limits = fresh
        checked = Date()
        let before = Set(UserDefaults.standard.stringArray(forKey: Self.exhaustedKey) ?? [])
        let now = Set(fresh.filter(\.exhausted).map(\.kind.rawValue))
        UserDefaults.standard.set(Array(now).sorted(), forKey: Self.exhaustedKey)
        for limit in fresh {
            if now.contains(limit.kind.rawValue), !before.contains(limit.kind.rawValue) { onChange(.exhausted(limit)) }
            if before.contains(limit.kind.rawValue), !now.contains(limit.kind.rawValue) { onChange(.restored(limit)) }
        }
        scheduleReset()
    }

    /// A look just after the first limit that ran out resets, to tell it's back.
    private func scheduleReset() {
        resetTimer?.invalidate()
        resetTimer = nil
        guard let next = limits.filter(\.exhausted).compactMap(\.resets).min() else { return }
        let timer = Timer(fire: max(next, Date()).addingTimeInterval(20), interval: 0, repeats: false) { [weak self] _ in
            self?.resetTimer = nil
            self?.refresh()
        }
        timer.tolerance = 10
        RunLoop.main.add(timer, forMode: .common)
        resetTimer = timer
    }
}
