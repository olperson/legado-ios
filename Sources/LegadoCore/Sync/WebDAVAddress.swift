import Foundation

public enum WebDAVAddress {
    /// Returns a directory URL suitable for the client, including any credentials in the input.
    public static func complete(_ input: String) throws -> URL {
        var parts = try components(input)
        if parts.percentEncodedPath.isEmpty, parts.host?.lowercased() == "dav.jianguoyun.com" {
            parts.percentEncodedPath = "/dav/"
        } else if !parts.percentEncodedPath.hasSuffix("/") {
            parts.percentEncodedPath += "/"
        }
        guard let url = parts.url else { throw WebDAVSyncError.invalidDirectory }
        return url
    }

    public enum Preset: CaseIterable, Hashable, Sendable {
        case nutstore, nextcloud, alist

        public var title: String {
            switch self {
            case .nutstore: "坚果云"
            case .nextcloud: "Nextcloud"
            case .alist: "AList / OpenList"
            }
        }

        public func directory(for input: String, username: String) throws -> String {
            if self == .nutstore { return "https://dav.jianguoyun.com/dav/legado/" }

            var parts = try WebDAVAddress.components(input)
            parts.user = nil
            parts.password = nil
            var path = parts.percentEncodedPath.split(separator: "/").map(String.init)
            if self == .nextcloud {
                let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
                guard !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      username != ".", username != "..",
                      let account = username.addingPercentEncoding(withAllowedCharacters: unreserved) else {
                    throw PresetError.nextcloudUsername
                }
                let endpoint = ["remote.php", "dav", "files", account]
                if let index = path.firstIndex(of: "remote.php") {
                    // Preserve a backup subdirectory when the user reapplies the preset.
                    let route = path.dropFirst(index + 1)
                    var suffix: ArraySlice<String> = []
                    if route.starts(with: ["dav", "files"]) { suffix = route.dropFirst(3) }
                    if route.first == "webdav" { suffix = route.dropFirst() }
                    path = Array(path.prefix(index)) + endpoint + suffix
                } else {
                    path += endpoint
                }
            } else if !path.contains("dav") {
                path.append("dav")
            }
            parts.percentEncodedPath = "/" + path.joined(separator: "/") + "/"
            guard let url = parts.url else { throw WebDAVSyncError.invalidDirectory }
            return url.absoluteString
        }
    }

    private enum PresetError: LocalizedError {
        case nextcloudUsername

        var errorDescription: String? { "请先填写有效的 Nextcloud 用户名。" }
    }

    private static func components(_ input: String) throws -> URLComponents {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        var scheme = "https"
        var body = value[...]
        if let prefix = value.range(of: "^[A-Za-z][A-Za-z0-9+.-]*:", options: .regularExpression) {
            let rest = value[prefix.upperBound...]
            if rest.hasPrefix("//") {
                scheme = value[prefix].dropLast().lowercased()
                guard ["http", "https"].contains(scheme) else { throw WebDAVSyncError.invalidDirectory }
                body = rest.dropFirst(2)
            } else {
                // A bare server can have a port, including a single-label host such as localhost.
                let port = rest.prefix { !"/?#".contains($0) }
                guard UInt16(port) != nil else { throw WebDAVSyncError.invalidDirectory }
            }
        } else if body.hasPrefix("//") {
            body = body.dropFirst(2)
        }
        let authority = body.prefix { !"/?#".contains($0) }
        let allowed = CharacterSet.urlHostAllowed.union(CharacterSet(charactersIn: ":@[]"))
        let encoded = try encode(authority, allowing: allowed)
        guard var parts = URLComponents(string: "\(scheme)://\(encoded)"), let host = parts.host, !host.isEmpty,
              host.rangeOfCharacter(from: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "/?#@\\"))) == nil,
              parts.port.map({ UInt16(exactly: $0) != nil }) ?? true else { throw WebDAVSyncError.invalidDirectory }

        // Preserve existing escapes while encoding literals in their own URL component.
        let resource = body[authority.endIndex...].prefix { $0 != "#" }
        let path = resource.prefix { $0 != "?" }
        parts.percentEncodedPath = try encode(path, allowing: .urlPathAllowed)
        if path.endIndex < resource.endIndex {
            parts.percentEncodedQuery = try encode(resource[resource.index(after: path.endIndex)...], allowing: .urlQueryAllowed)
        }
        return parts
    }

    private static func encode(_ value: Substring, allowing characters: CharacterSet) throws -> String {
        let escaped = value.replacingOccurrences(of: "%(?![0-9A-Fa-f]{2})", with: "%25", options: .regularExpression)
        guard let encoded = escaped.addingPercentEncoding(withAllowedCharacters: characters.union(CharacterSet(charactersIn: "%"))) else {
            throw WebDAVSyncError.invalidDirectory
        }
        return encoded
    }
}
