import XCTest

@MainActor
final class WebDAVConnectionUITests: XCTestCase {
    func testNutstoreTemplateAndLoopbackBackupProperties() throws {
        continueAfterFailure = false
        let port = try XCTUnwrap(ProcessInfo.processInfo.environment["LEGADO_TEST_DAV_PORT"].flatMap(UInt16.init),
                                 "Start the loopback WebDAV fixture before running this test.")
        let directory = "http://127.0.0.1:\(port)/dav/ui-history/"
        let app = XCUIApplication()
        app.launchArguments = ["-uiDemoTab", "settings"]
        app.launch()
        defer { app.terminate() }

        let settings = app.buttons["profile.arrow.triangle.2.circlepath"]
        reveal(settings, in: app)
        settings.tap()
        XCTAssertTrue(app.navigationBars["备份与恢复"].waitForExistence(timeout: 15))
        let templates = app.buttons["backup.address.templates"]
        reveal(templates, in: app)
        templates.tap()
        let nutstore = app.buttons["坚果云"]
        XCTAssertTrue(nutstore.waitForExistence(timeout: 5))
        nutstore.tap()
        let address = app.textFields["WebDAV 目录地址"]
        XCTAssertEqual(address.value as? String, "https://dav.jianguoyun.com/dav/legado/")

        // A triple tap selects the full URL, including its punctuation.
        address.tap()
        address.tap(withNumberOfTaps: 3, numberOfTouches: 1)
        address.typeText(directory + "\n")
        XCTAssertEqual(address.value as? String, directory)
        let tools = app.buttons["backup.connection.tools"]
        reveal(tools, in: app)
        tools.tap()
        let check = app.buttons["测试连接"]
        XCTAssertTrue(check.waitForExistence(timeout: 5))
        check.tap()
        let connected = app.staticTexts.matching(NSPredicate(format: "identifier == %@ AND label == %@",
                                                            "backup.status", "已连接到 WebDAV 目录。")).firstMatch
        XCTAssertTrue(connected.waitForExistence(timeout: 20), app.debugDescription)

        let browse = app.buttons["从 WebDAV 选择备份恢复"]
        reveal(browse, in: app)
        browse.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5)).tap()
        XCTAssertTrue(app.navigationBars["云端备份"].waitForExistence(timeout: 15))
        let filename = "connection-sample.zip"
        let item = app.buttons["backup.remote." + filename]
        XCTAssertTrue(item.waitForExistence(timeout: 10))
        XCTAssertEqual(item.label, filename)
        app.buttons["backup.remote.actions." + filename].tap()
        let properties = app.buttons["属性"]
        XCTAssertTrue(properties.waitForExistence(timeout: 5))
        properties.tap()
        let detail = app.alerts["文件属性"]
        XCTAssertTrue(detail.waitForExistence(timeout: 15), app.debugDescription)
        let metadata = detail.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", filename)).firstMatch
        XCTAssertTrue(metadata.exists, detail.debugDescription)
        XCTAssertNotNil(metadata.label.range(of: #"大小：\s*\d"#, options: .regularExpression), metadata.label)
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<8 {
            let navigation = app.navigationBars.firstMatch
            let tabs = app.tabBars.firstMatch
            let top = (navigation.exists ? navigation.frame.maxY : app.frame.minY) + 8
            let bottom = (tabs.exists ? tabs.frame.minY : app.frame.maxY) - 12
            if element.exists, !element.frame.isEmpty {
                let y = element.frame.midY
                if element.isHittable && y > top && y < bottom { return }
                if y <= top {
                    app.swipeDown(velocity: .slow)
                    continue
                }
            }
            app.swipeUp(velocity: .slow)
        }
        XCTFail("Could not reveal \(element). " + app.debugDescription)
    }
}
