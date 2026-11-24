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
        func sessionCookie(_ name: String) throws -> HTTPCookie {
            try XCTUnwrap(HTTPCookie.cookies(withResponseHeaderFields: [
                "Set-Cookie": "\(name)=active; Path=/books; Secure; HttpOnly; SameSite=Strict"
            ], for: url).first)
        }
        let httpCookie = try sessionCookie("backup_http")
        XCTAssertTrue(httpCookie.isHTTPOnly)
        storage.setCookie(httpCookie)
        await web.setCookie(try sessionCookie("backup_web"))
        let policy = SourceNetworkPolicy.shared
        await policy.setCookieHeader("private_token=one", sourceID: "one", url: url)
        await policy.setCookieHeader("private_token=two", sourceID: "two", url: url)
        let saved = try await BackupSessionState.capture()
        let state = try BackupSessionState.decode(saved)
        let empty = try BackupSessionState.decode(nil)
        await empty.applyCookies()
        storage.setCookie(try sessionCookie("stale_local"))
        await policy.setCookieHeader("stale=yes", sourceID: "stale", url: url)
        await state.applyCookies()

        let cookies = storage.cookies(for: url) ?? []
        let restored = try XCTUnwrap(cookies.first { $0.name == "backup_http" })
        XCTAssertEqual(restored.value, "active")
        XCTAssertEqual(restored.path, "/books")
        XCTAssertTrue(restored.isSecure)
        XCTAssertTrue(restored.isHTTPOnly)
        XCTAssertEqual(restored.sameSitePolicy, httpCookie.sameSitePolicy)
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
