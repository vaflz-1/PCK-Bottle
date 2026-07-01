import Foundation

// MARK: - Semantic version

/// A dotted numeric version such as `1.0.2`, tolerant of a leading `v` and of
/// trailing pre-release / build metadata (`-beta`, `+ci`) which we drop before
/// comparing. Missing trailing components compare as zero (`1.0` == `1.0.0`).
struct AppVersion: Comparable, CustomStringConvertible {
    let components: [Int]
    let raw: String

    init?(_ string: String) {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        var core = trimmed
        if core.first == "v" || core.first == "V" {
            core.removeFirst()
        }
        // Ignore SemVer pre-release / build metadata for ordering purposes.
        if let cut = core.firstIndex(where: { $0 == "-" || $0 == "+" }) {
            core = String(core[..<cut])
        }
        let parts = core.split(separator: ".", omittingEmptySubsequences: false)
        let numbers = parts.compactMap { Int($0) }
        guard !numbers.isEmpty, numbers.count == parts.count else {
            return nil
        }
        self.components = numbers
        self.raw = trimmed
    }

    var description: String { raw }

    private static func compare(_ lhs: AppVersion, _ rhs: AppVersion) -> Int {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right {
                return left < right ? -1 : 1
            }
        }
        return 0
    }

    static func < (lhs: AppVersion, rhs: AppVersion) -> Bool { compare(lhs, rhs) < 0 }
    static func == (lhs: AppVersion, rhs: AppVersion) -> Bool { compare(lhs, rhs) == 0 }
}

/// Static facts about this build and where its updates live.
enum AppInfo {
    /// Kept in sync with the repo-root `VERSION` file. Used only when running
    /// outside a packaged `.app` (e.g. `swift run`), where Info.plist is absent.
    static let fallbackVersion = "1.0.2"
    static let repoOwner = "vaflz-1"
    static let repoName = "PCK-Bottle"
    static let bundleIdentifier = "com.godotpckstudio.pckbottle"

    static var currentVersion: AppVersion {
        let raw = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? fallbackVersion
        return AppVersion(raw) ?? AppVersion(fallbackVersion)!
    }
}

// MARK: - GitHub release model

struct GitHubReleaseAsset: Decodable {
    let name: String
    let browserDownloadURL: String

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
    }
}

struct GitHubRelease: Decodable {
    let tagName: String
    let name: String?
    let body: String?
    let htmlURL: String
    let prerelease: Bool
    let draft: Bool
    let assets: [GitHubReleaseAsset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case body
        case htmlURL = "html_url"
        case prerelease
        case draft
        case assets
    }

    var version: AppVersion? { AppVersion(tagName) }

    /// The distributable `.dmg` asset, if any. The download URL is pinned to
    /// `https://github.com/<owner>/<repo>/releases/download/…` — an exact host
    /// and repo path, over TLS — so a tampered API response cannot redirect the
    /// auto-installer to another origin or a different project's artifact.
    /// (URLSession still follows GitHub's transparent redirect to its CDN; only
    /// the API-supplied URL is validated here.)
    var dmgAsset: GitHubReleaseAsset? {
        let expectedPrefix = "/\(AppInfo.repoOwner)/\(AppInfo.repoName)/releases/download/"
        return assets.first { asset in
            guard asset.name.lowercased().hasSuffix(".dmg"),
                  let url = URL(string: asset.browserDownloadURL),
                  url.scheme?.lowercased() == "https",
                  url.host?.lowercased() == "github.com",
                  url.path.hasPrefix(expectedPrefix) else {
                return false
            }
            return true
        }
    }
}

// MARK: - Errors

enum UpdateError: LocalizedError {
    case network(String)
    case http(Int)
    case decoding(String)
    case noAsset
    case notBundled
    case notWritable
    case install(String)

    var errorDescription: String? {
        switch self {
        case .network(let detail): return detail
        case .http(let code): return "GitHub returned HTTP \(code)."
        case .decoding(let detail): return detail
        case .noAsset: return localized("updateNoAsset")
        case .notBundled: return localized("updateNotBundled")
        case .notWritable: return localized("updateNotWritable")
        case .install(let detail): return detail
        }
    }
}

// MARK: - Network

enum UpdateService {
    private static var latestReleaseURL: URL {
        URL(string: "https://api.github.com/repos/\(AppInfo.repoOwner)/\(AppInfo.repoName)/releases/latest")!
    }

    /// Fetches the newest published (non-draft) release. Completion is invoked on
    /// an arbitrary queue; callers must hop to main before touching AppKit.
    static func fetchLatestRelease(completion: @escaping (Result<GitHubRelease, UpdateError>) -> Void) {
        var request = URLRequest(url: latestReleaseURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("PCKBottle/\(AppInfo.currentVersion)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                completion(.failure(.network(error.localizedDescription)))
                return
            }
            guard let http = response as? HTTPURLResponse else {
                completion(.failure(.network("No HTTP response.")))
                return
            }
            guard (200..<300).contains(http.statusCode) else {
                completion(.failure(.http(http.statusCode)))
                return
            }
            guard let data = data else {
                completion(.failure(.network("Empty response body.")))
                return
            }
            do {
                completion(.success(try JSONDecoder().decode(GitHubRelease.self, from: data)))
            } catch {
                completion(.failure(.decoding(error.localizedDescription)))
            }
        }.resume()
    }
}
