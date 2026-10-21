import Foundation

/// Looks on GitHub for a newer release of Claude Notch: at launch and once a day, and only when that's
/// switched on in the settings. It's off unless you turn it on, and then it's the one thing the app
/// ever asks the network for. Used on the main thread.
final class Updates: ObservableObject {
    enum Status: Equatable {
        case idle, checking
        case upToDate(Date)
        case available(version: String, page: URL)
        case failed
    }

    static let key = "checkForUpdates"
    /// The newest version already told about, so it's announced once.
    private static let announcedKey = "announcedVersion"
    static let latestRelease = URL(string: "https://api.github.com/repos/CraftStick/ClaudeNotch/releases/latest")!
    static let releasesPage = URL(string: "https://github.com/CraftStick/ClaudeNotch/releases/latest")!

    @Published private(set) var status = Status.idle
    /// A newer version found for the first time: (version, its page).
    var announce: ((String, URL) -> Void)?
    private var timer: Timer?

    static var current: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }
    static var currentBuild: Int { Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0 }

    var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.key) }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.key)
            schedule()
        }
    }

    /// Checks now and then every day while it's on; stops when it's turned off.
    func schedule() {
        timer?.invalidate()
        timer = nil
        guard enabled else {
            status = .idle
            return
        }
        check()
        let daily = Timer(timeInterval: 24 * 3600, repeats: true) { [weak self] _ in
            self?.check()
        }
        daily.tolerance = 3600
        RunLoop.main.add(daily, forMode: .common)
        timer = daily
    }

    func check() {
        guard status != .checking else { return }
        status = .checking
        var request = URLRequest(url: Self.latestRelease, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: request) { data, response, _ in
            let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let ok = (response as? HTTPURLResponse)?.statusCode == 200
            let tag = json?["tag_name"] as? String
            let page = (json?["html_url"] as? String).flatMap(URL.init(string:)) ?? Self.releasesPage
            let assets = (json?["assets"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
            let build = assets.lazy.compactMap(Self.build(fromDiskImage:)).first ?? 0
            DispatchQueue.main.async { self.finish(ok ? tag : nil, build: build, page: page) }
        }.resume()
    }

    private func finish(_ tag: String?, build: Int, page: URL) {
        guard let tag else {
            status = .failed
            return
        }
        var version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        guard Self.isNewer(version, build: build, than: Self.current, build: Self.currentBuild) else {
            status = .upToDate(Date())
            return
        }
        // The same version built again says which build: "0.1.2 (18)".
        if !Self.isNewer(version, than: Self.current) { version += " (\(build))" }
        status = .available(version: version, page: page)
        if UserDefaults.standard.string(forKey: Self.announcedKey) != version {
            UserDefaults.standard.set(version, forKey: Self.announcedKey)
            announce?(version, page)
        }
    }

    /// The build number in a release's disk image name, "ClaudeNotch-0.1.2-18.dmg"; nil for one without.
    static func build(fromDiskImage name: String) -> Int? {
        guard name.hasPrefix("ClaudeNotch-"), name.hasSuffix(".dmg") else { return nil }
        let parts = name.dropFirst("ClaudeNotch-".count).dropLast(".dmg".count).split(separator: "-")
        return parts.count == 2 ? Int(parts[1]) : nil
    }

    /// A newer version, or the same version built again: a release republished with fixes.
    static func isNewer(_ version: String, build: Int, than current: String, build currentBuild: Int) -> Bool {
        isNewer(version, than: current) || (!isNewer(current, than: version) && build > currentBuild)
    }

    /// "0.1.10" is newer than "0.1.9"; a missing part counts as 0.
    static func isNewer(_ version: String, than current: String) -> Bool {
        let a = version.split(separator: ".").map { Int($0) ?? 0 }, b = current.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
