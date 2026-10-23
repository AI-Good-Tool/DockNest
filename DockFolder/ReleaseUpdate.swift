import Foundation

struct ReleaseUpdate: Decodable {
    let tagName: String
    let htmlURL: URL
    let draft: Bool
    let prerelease: Bool

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name", htmlURL = "html_url", draft, prerelease
    }

    static func components(_ version: String) -> [Int]? {
        let value = version.hasPrefix("v") ? String(version.dropFirst()) : version
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        let numbers = parts.compactMap { part -> Int? in
            guard !part.isEmpty, part.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
            return Int(part)
        }
        return numbers.count == 3 ? numbers : nil
    }

    func isNewer(than installed: String) throws -> Bool {
        guard !draft, !prerelease,
              htmlURL.scheme == "https", htmlURL.host == "github.com",
              htmlURL.path.hasPrefix("/AI-Good-Tool/DockNest/releases/"),
              let latest = Self.components(tagName), let current = Self.components(installed) else {
            throw URLError(.cannotParseResponse)
        }
        return current.lexicographicallyPrecedes(latest)
    }

    static func latest() async throws -> ReleaseUpdate {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/AI-Good-Tool/DockNest/releases/latest")!)
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("DockNest", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard http.statusCode == 200 else {
            let message = http.statusCode == 404 ? "仓库尚未发布正式版本。" : "检查失败（HTTP \(http.statusCode)），请稍后重试。"
            throw NSError(domain: "DockNest.Update", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: message])
        }
        return try JSONDecoder().decode(ReleaseUpdate.self, from: data)
    }
}
