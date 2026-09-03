import Combine
import Foundation

// MARK: - Pure, testable core
//
// Everything above the `UpdateChecker` class is network-free and side-effect-free
// so it can be unit-tested from a sample JSON payload (see UpdateCheckerTests).

/// A minimal semantic version — enough to compare a GitHub release tag against the
/// running app's `CFBundleShortVersionString`. Parses `major.minor.patch` with an
/// optional pre-release suffix (`1.2.0-beta.1`); build metadata (`+…`) is ignored
/// for comparison, per the semver spec.
struct SemanticVersion: Comparable, Equatable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int
    /// Dot-separated pre-release identifiers, or empty for a normal release.
    let prerelease: [String]

    /// Parse a version string. A single leading `v`/`V` is stripped. Missing minor
    /// or patch components default to 0 (`"1"` → `1.0.0`). Returns nil if the core
    /// numeric part is malformed.
    init?(_ raw: String) {
        var s = raw.trimmingCharacters(in: .whitespaces)
        if let first = s.first, first == "v" || first == "V" {
            s.removeFirst()
        }
        // Split off build metadata (ignored) then the pre-release suffix.
        s = s.split(separator: "+", maxSplits: 1).first.map(String.init) ?? s
        let preSplit = s.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let core = String(preSplit[0])
        self.prerelease = preSplit.count > 1
            ? preSplit[1].split(separator: ".").map(String.init)
            : []

        let parts = core.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty, let maj = Int(parts[0]) else { return nil }
        func component(_ i: Int) -> Int? {
            guard i < parts.count else { return 0 }
            return Int(parts[i])
        }
        guard let min = component(1), let pat = component(2) else { return nil }
        self.major = maj
        self.minor = min
        self.patch = pat
    }

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }

        // A version WITH a pre-release ranks below the same version WITHOUT one.
        switch (lhs.prerelease.isEmpty, rhs.prerelease.isEmpty) {
        case (true, true): return false
        case (true, false): return false   // lhs is the final release → not less
        case (false, true): return true    // lhs is a pre-release → less
        case (false, false): break
        }
        // Compare pre-release identifiers per semver: numeric compared numerically,
        // alphanumeric lexically, numeric < alphanumeric, more fields wins a tie.
        for (l, r) in zip(lhs.prerelease, rhs.prerelease) {
            if l == r { continue }
            switch (Int(l), Int(r)) {
            case let (.some(li), .some(ri)): return li < ri
            case (.some, .none): return true
            case (.none, .some): return false
            case (.none, .none): return l < r
            }
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }

    var description: String {
        let core = "\(major).\(minor).\(patch)"
        return prerelease.isEmpty ? core : "\(core)-\(prerelease.joined(separator: "."))"
    }
}

/// The subset of GitHub's `releases/latest` payload we care about.
struct GitHubRelease: Decodable {
    let tagName: String
    let name: String?
    let body: String?
    let htmlURL: URL?
    let assets: [Asset]

    struct Asset: Decodable {
        let name: String
        let browserDownloadURL: URL

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case body
        case htmlURL = "html_url"
        case assets
    }
}

/// What the UI needs to present an available update.
struct UpdateInfo: Equatable {
    let version: SemanticVersion
    /// Human-facing tag as published, e.g. "v1.2.0".
    let versionString: String
    /// Release notes (`body`), possibly empty.
    let notes: String
    /// Where the "herunterladen" action points — the first `.zip` asset if present,
    /// otherwise the release page.
    let downloadURL: URL
    /// The release page on github.com.
    let releaseURL: URL
}

enum UpdateResolver {
    /// First asset whose filename ends in `.zip` (case-insensitive).
    static func firstZipAsset(_ release: GitHubRelease) -> URL? {
        release.assets.first { $0.name.lowercased().hasSuffix(".zip") }?.browserDownloadURL
    }

    /// Decide whether a release is a usable update relative to `current`.
    /// Returns nil when the tag is unparseable or not strictly newer.
    static func updateInfo(from release: GitHubRelease, current: SemanticVersion) -> UpdateInfo? {
        guard let version = SemanticVersion(release.tagName), version > current else { return nil }
        let zip = firstZipAsset(release)
        // Prefer the release page as a stable fallback target when no zip is attached.
        let fallback = release.htmlURL
        guard let download = zip ?? fallback else { return nil }
        return UpdateInfo(
            version: version,
            versionString: release.tagName,
            notes: release.body ?? "",
            downloadURL: download,
            releaseURL: fallback ?? download
        )
    }

    /// Parse a raw `releases/latest` response body into an `UpdateInfo` if newer.
    static func updateInfo(fromJSON data: Data, current: SemanticVersion) throws -> UpdateInfo? {
        let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
        return updateInfo(from: release, current: current)
    }
}

// MARK: - Live checker (network + throttling + publishing)

/// Queries GitHub Releases for a newer build and publishes it. Distribution is
/// manual (the user re-runs the install step or drags the app), so this only ever
/// *notifies* — it never downloads or installs anything.
@MainActor
final class UpdateChecker: ObservableObject {
    /// GitHub `owner/repo`. Derived from `git remote -v`
    /// (origin → https://github.com/jonas-gehring/notable.git).
    static let repo = "jonas-gehring/notable"

    /// Published when a strictly-newer release is found; nil otherwise.
    @Published private(set) var available: UpdateInfo?
    @Published private(set) var isChecking = false
    @Published private(set) var lastChecked: Date?
    /// Human-readable last-error, for the Settings row. Cleared on success.
    @Published private(set) var lastError: String?

    /// Called once per newly-found version by `checkOnLaunch`. A closure rather
    /// than a direct call into `NotificationCenterService`: the checker is a
    /// network+parsing unit that the test bundle compiles on its own, and reaching
    /// for the notification singleton from here would drag the whole UserNotifications
    /// stack in behind it. The app wires this up in `AppDelegate`.
    var onUpdateFound: ((String) -> Void)?

    private let currentVersion: SemanticVersion
    private let session: URLSession
    private let defaults: UserDefaults

    private static let lastCheckKey = "updateLastCheckAt"
    /// The version the user asked not to be reminded about again.
    static let skippedVersionKey = "updateSkippedVersion"
    /// Whether the launch check runs at all. Defaults to on (see `automaticChecks`).
    static let automaticChecksKey = "updateAutomaticChecks"
    /// The last version we already posted a notification for — so a found update
    /// is announced once, not on every launch until it is installed.
    private static let notifiedVersionKey = "updateNotifiedVersion"
    /// On-launch checks run at most once per this interval.
    private static let launchThrottle: TimeInterval = 24 * 60 * 60

    /// - Parameters:
    ///   - currentVersion: defaults to the running bundle's `CFBundleShortVersionString`.
    ///   - session/defaults: injectable for tests.
    init(
        currentVersion: SemanticVersion? = nil,
        session: URLSession = .shared,
        defaults: UserDefaults = .standard
    ) {
        let bundleVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        self.currentVersion = currentVersion ?? SemanticVersion(bundleVersion ?? "") ?? SemanticVersion("0.0.0")!
        self.session = session
        self.defaults = defaults
        if let ts = defaults.object(forKey: Self.lastCheckKey) as? Double {
            self.lastChecked = Date(timeIntervalSince1970: ts)
        }
    }

    /// Whether the launch check is allowed to run. Absent means on: an updater
    /// that has to be switched on is one nobody switches on.
    var automaticChecks: Bool {
        get { defaults.object(forKey: Self.automaticChecksKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Self.automaticChecksKey) }
    }

    /// Called at launch. Skips if switched off, or if we already checked within
    /// the throttle window. Announces a find once, because the menu only shows it
    /// to whoever happens to open the menu.
    func checkOnLaunch() async {
        guard automaticChecks else { return }
        if let last = lastChecked, Date().timeIntervalSince(last) < Self.launchThrottle {
            return
        }
        await check()
        guard let found = available else { return }
        guard defaults.string(forKey: Self.notifiedVersionKey) != found.versionString else { return }
        defaults.set(found.versionString, forKey: Self.notifiedVersionKey)
        onUpdateFound?(found.versionString)
    }

    /// Stop offering this version. Deliberately per-version rather than a blanket
    /// mute: skipping 1.2.0 must not hide 1.3.0.
    func skip(_ info: UpdateInfo) {
        defaults.set(info.versionString, forKey: Self.skippedVersionKey)
        available = nil
    }

    /// True once the user skipped exactly this version.
    private func isSkipped(_ info: UpdateInfo) -> Bool {
        defaults.string(forKey: Self.skippedVersionKey) == info.versionString
    }

    /// Manual check (Settings button / menu). Always hits the network.
    func check() async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }

        guard let url = URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest") else {
            lastError = String(localized: "Ungültige Repository-URL.")
            return
        }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        // GitHub rejects requests without a User-Agent.
        request.setValue("Notable-UpdateChecker", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        do {
            let (data, response) = try await session.data(for: request)
            recordCheckTime()

            guard let http = response as? HTTPURLResponse else {
                lastError = "Unerwartete Antwort vom Server."
                return
            }
            switch http.statusCode {
            case 200:
                let info = try UpdateResolver.updateInfo(fromJSON: data, current: currentVersion)
                available = info.flatMap { isSkipped($0) ? nil : $0 }
                lastError = nil
            case 404:
                // No releases published yet — not an error, just nothing to offer.
                //
                // Caveat worth knowing: a *private* repository answers 404 to an
                // unauthenticated request as well, so while `repo` is private this
                // branch cannot tell "nothing published" from "not allowed to look",
                // and the UI will say the app is up to date either way. The updater
                // therefore only works once the repository is public — which is the
                // intent — or once a token is added here.
                available = nil
                lastError = nil
            case 403:
                lastError = String(localized: "GitHub-Anfragelimit erreicht. Später erneut versuchen.")
            default:
                lastError = "Update-Prüfung fehlgeschlagen (HTTP \(http.statusCode))."
            }
        } catch {
            // Network offline, DNS, timeout, etc. — stay quiet, record nothing fatal.
            lastError = error.localizedDescription
        }
    }

    private func recordCheckTime() {
        let now = Date()
        lastChecked = now
        defaults.set(now.timeIntervalSince1970, forKey: Self.lastCheckKey)
    }
}
