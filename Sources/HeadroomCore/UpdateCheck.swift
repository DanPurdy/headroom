import Foundation

/// Finds newer releases on GitHub.
public enum UpdateCheck {
    public static let latestURL = URL(string: "https://api.github.com/repos/DanPurdy/headroom/releases/latest")!
    public static let interval: TimeInterval = 24 * 3600

    public struct Release: Equatable, Sendable {
        public var version: String
        public var page: URL
        public var download: URL
    }

    /// GitHub's latest-release response. nil without a `Headroom-*.zip` asset on github.com.
    public static func parse(_ data: Data) -> Release? {
        struct Response: Decodable {
            struct Asset: Decodable {
                var name: String
                var browserDownloadUrl: URL
            }
            var tagName: String
            var htmlUrl: URL
            var assets: [Asset]
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let response = try? decoder.decode(Response.self, from: data),
              let asset = response.assets.first(where: { $0.name.hasPrefix("Headroom-") && $0.name.hasSuffix(".zip") }),
              asset.browserDownloadUrl.scheme == "https", asset.browserDownloadUrl.host == "github.com"
        else { return nil }
        let version = response.tagName.hasPrefix("v") ? String(response.tagName.dropFirst()) : response.tagName
        return Release(version: version, page: response.htmlUrl, download: asset.browserDownloadUrl)
    }

    /// Semantic versions: "0.5.0" is newer than "0.4.1" and than "0.5.0-dev".
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ version: String) -> (numbers: [Int], prerelease: String?) {
            let split = version.split(separator: "-", maxSplits: 1)
            let numbers = split.first.map { $0.split(separator: ".").map { Int($0) ?? 0 } } ?? []
            return (numbers, split.count > 1 ? String(split[1]) : nil)
        }
        let (a, aPre) = parts(candidate)
        let (b, bPre) = parts(current)
        for i in 0..<max(a.count, b.count) {
            let (x, y) = (i < a.count ? a[i] : 0, i < b.count ? b[i] : 0)
            if x != y { return x > y }
        }
        switch (aPre, bPre) {
        case (nil, .some): return true
        case (.some(let x), .some(let y)): return x.compare(y, options: .numeric) == .orderedDescending
        default: return false
        }
    }
}
