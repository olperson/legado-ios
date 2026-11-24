import XCTest
import WebKit
@testable import Legado

@MainActor
final class BackupSessionStateTests: XCTestCase {
    func testRestoresCookieScopesAndReplacesStaleSessions() async throws {
        let original = try await BackupSessionState.capture()
        addTeardownBlock {
            let state = try BackupSessionState.decode(original)
            await state.applyCookies()
        }
        let url = try XCTUnwrap(URL(string: "https://backup.example.test/books"))
        let storage = HTTPCookieStorage.shared
        let web = WKWebsiteDataStore.default().httpCookieStore
        func sessionCookie(_ name: String, strict: Bool = false) throws -> HTTPCookie {
            let attributes = strict ? "; SameSite=Strict" : ""
            return try XCTUnwrap(HTTPCookie.cookies(withResponseHeaderFields: [
                "Set-Cookie": "\(name)=active; Path=/books; Secure; HttpOnly\(attributes)"
            ], for: url).first)
        }
        let httpCookie = try sessionCookie("backup_http")
        let strict = try sessionCookie("backup_strict", strict: true)
        XCTAssertTrue(httpCookie.isHTTPOnly)
        await web.setCookie(try sessionCookie("backup_web", strict: true))
        storage.setCookies([httpCookie, strict], for: url, mainDocumentURL: url)
        let before = storage.cookies(for: url) ?? []
        XCTAssertNotNil(before.first { $0.name == httpCookie.name }, "测试夹具未将 HTTPS Cookie 写入同站请求。")
        XCTAssertNotNil(storage.cookies?.first { $0.name == strict.name }, "同站 Cookie 未进入 HTTP 存储。")
        let policy = SourceNetworkPolicy.shared
        await policy.setCookieHeader("private_token=one", sourceID: "one", url: url)
        await policy.setCookieHeader("private_token=two", sourceID: "two", url: url)
        let saved = try await BackupSessionState.capture()
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: saved) as? [String: Any])
        let http = try XCTUnwrap(document["http"] as? [[String: Any]])
        XCTAssertTrue(http.contains { $0["name"] as? String == httpCookie.name }, "备份未读取 HTTP Cookie。")
        let state = try BackupSessionState.decode(saved)
        let empty = try BackupSessionState.decode(nil)
        await empty.applyCookies()
        storage.setCookies([try sessionCookie("stale_local")], for: url, mainDocumentURL: url)
        await policy.setCookieHeader("stale=yes", sourceID: "stale", url: url)
        await state.applyCookies()

        let cookies = storage.cookies(for: url) ?? []
        let restored = try XCTUnwrap(cookies.first { $0.name == "backup_http" }, "恢复的 HTTP Cookie 无法用于原 HTTPS 请求。")
        XCTAssertEqual(restored.value, "active")
        XCTAssertEqual(restored.path, "/books")
        XCTAssertTrue(restored.isSecure)
        XCTAssertTrue(restored.isHTTPOnly)
        let restoredStrict = try XCTUnwrap(storage.cookies?.first { $0.name == strict.name }, "同站 Cookie 未恢复。")
        XCTAssertTrue(restoredStrict.isHTTPOnly)
        XCTAssertEqual(restoredStrict.sameSitePolicy, strict.sameSitePolicy)
        XCTAssertEqual(cookies.contains { $0.name == strict.name }, before.contains { $0.name == strict.name },
                       "SameSite=Strict 的 Cookie 恢复后应保持原请求可见性。")
        let otherPath = try XCTUnwrap(URL(string: "https://backup.example.test/other"))
        XCTAssertFalse((storage.cookies(for: otherPath) ?? []).contains { $0.name == "backup_http" })
        XCTAssertFalse(cookies.contains { $0.name == "stale_local" })
        let webCookies = await withCheckedContinuation { continuation in
            web.getAllCookies { continuation.resume(returning: $0) }
        }
        XCTAssertTrue(webCookies.contains { $0.name == "backup_web" && $0.value == "active" })
        let first = await policy.cookieHeader(sourceID: "one", url: url)
        let second = await policy.cookieHeader(sourceID: "two", url: url)
        let stale = await policy.cookieHeader(sourceID: "stale", url: url)
        XCTAssertEqual(first, "private_token=one")
        XCTAssertEqual(second, "private_token=two")
        XCTAssertEqual(stale, "")
    }

    func testRejectsInvalidSessionBeforeApplyingIt() {
        let unsupported = Data(#"{"version":9,"http":[],"web":[],"sources":{}}"#.utf8)
        XCTAssertThrowsError(try BackupSessionState.decode(unsupported))
        let invalidCookie = Data(#"{"version":1,"http":[],"web":[],"sources":{"one":[{"name":"session","value":"one","domain":"","path":"/","secure":true}]}}"#.utf8)
        XCTAssertThrowsError(try BackupSessionState.decode(invalidCookie))
    }
}
