import SwiftUI
import UIKit
import WebKit
import XCTest
@testable import Legado

@MainActor
final class ReaderFontStoreTests: XCTestCase {
    func testSameFilenameUsesNewFontAndLegacyContainerPathStillLoads() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent(UUID().uuidString + ".ttf")
        let file = ReaderFontStore.directory.appendingPathComponent(source.lastPathComponent)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: file)
        }
        let bundle = try XCTUnwrap(Bundle.main.url(forResource: "Readium_ReadiumNavigator", withExtension: "bundle"))
        let assets = bundle.appendingPathComponent("Assets/Static")
        let oldPath = "/previous-container/Library/Application Support/Legado/fonts/" + source.lastPathComponent
        var names: [String] = []
        for sample in ["readium-css/fonts/iAWriterDuospace-Regular.ttf", "fonts/OpenDyslexic-Regular.otf"] {
            try Data(contentsOf: assets.appendingPathComponent(sample)).write(to: source)
            let key = try ReaderFontStore.install(from: source)
            let font = try XCTUnwrap(ReaderFontStore.font(at: key, size: 20, weight: 0))
            names.append(font.fontName)
            XCTAssertEqual(ReaderFontStore.font(at: oldPath, size: 20, weight: 0)?.fontName, font.fontName)
        }
        XCTAssertNotEqual(names.first, names.last)
    }

    func testInvalidFontDoesNotOverwriteExistingFileOrLeaveNewFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: ReaderFontStore.directory, withIntermediateDirectories: true)
        let source = root.appendingPathComponent(UUID().uuidString + ".ttf")
        let target = ReaderFontStore.directory.appendingPathComponent(source.lastPathComponent)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: target)
        }
        let previous = Data("previous font bytes".utf8)
        try Data("invalid font".utf8).write(to: source)
        try previous.write(to: target)

        XCTAssertThrowsError(try ReaderFontStore.install(from: source))
        XCTAssertEqual(try Data(contentsOf: target), previous)

        try FileManager.default.removeItem(at: target)
        XCTAssertThrowsError(try ReaderFontStore.install(from: source))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }
}

@MainActor
final class AppearanceContrastTests: XCTestCase {
    func testDefaultTextColorsMatchExistingReaderPresets() {
        let colors = ReaderTextColors()
        for preset in ReaderStylePreset.legadoDefaults {
            let style = colors.style(for: preset.id)
            XCTAssertNil(colors.customForeground(for: preset.id))
            XCTAssertEqual(style.foreground, preset.foreground, preset.name)
            XCTAssertEqual(style.background, preset.background, preset.name)
        }
        XCTAssertEqual(ReaderTextColors.hexString(for: colors.style(for: "dark").foreground), "#ADADAD")
        XCTAssertEqual(ReaderTextColors.hexString(for: colors.style(for: "paper").foreground), "#3E3422")
    }

    func testTextColorsPersistAcrossSettingsInstancesAndResetOnlyCurrentTheme() throws {
        let suite = "ReaderTextColorsTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let paperColor = UIColor(red: 36 / 255, green: 82 / 255, blue: 105 / 255, alpha: 1)
        let nightColor = UIColor(red: 228 / 255, green: 203 / 255, blue: 166 / 255, alpha: 1)
        let setting = AppStorage(wrappedValue: ReaderTextColors(), ReaderTextColors.storageKey, store: defaults)
        var colors = setting.wrappedValue
        colors.setForeground(paperColor, for: "paper")
        colors.setForeground(nightColor, for: "night")
        setting.wrappedValue = colors

        let reopened = try XCTUnwrap(UserDefaults(suiteName: suite))
        let otherSetting = AppStorage(wrappedValue: ReaderTextColors(), ReaderTextColors.storageKey, store: reopened)
        var loaded = otherSetting.wrappedValue
        XCTAssertEqual(ReaderTextColors.hexString(for: loaded.style(for: "preset2").foreground), "#245269")
        XCTAssertEqual(ReaderTextColors.hexString(for: loaded.style(for: "dark").foreground), "#E4CBA6")
        XCTAssertEqual(loaded.style(for: "preset2").background, ReaderStylePreset.resolve("paper").background)
        XCTAssertNil(loaded.customForeground(for: "wechat"))
        loaded.resetForeground(for: "preset2")
        otherSetting.wrappedValue = loaded

        let saved = try XCTUnwrap(defaults.string(forKey: ReaderTextColors.storageKey))
        let afterReset = try XCTUnwrap(ReaderTextColors(rawValue: saved))
        XCTAssertNil(afterReset.customForeground(for: "paper"))
        XCTAssertEqual(afterReset.style(for: "paper").foreground, ReaderStylePreset.resolve("paper").foreground)
        XCTAssertEqual(ReaderTextColors.hexString(for: afterReset.style(for: "night").foreground), "#E4CBA6")
    }

    func testEInkKeepsBlackTextOnWhiteWithoutLosingThemeColor() {
        var colors = ReaderTextColors()
        colors.setForeground(.red, for: "night")
        let eink = colors.style(for: "night", isEInk: true)
        XCTAssertEqual(ReaderTextColors.hexString(for: eink.foreground), "#000000")
        XCTAssertEqual(ReaderTextColors.hexString(for: eink.background), "#FFFFFF")
        XCTAssertEqual(ReaderTextColors.hexString(for: colors.style(for: "dark").foreground), "#FF0000")
    }

    func testLoginWebViewUsesAdaptiveBackgroundBeforeContentArrives() async throws {
        var source = BookSource(bookSourceUrl: "https://appearance.invalid", bookSourceName: "外观测试")
        source.loginUrl = "about:blank"
        let controller = UIHostingController(rootView: SourceLoginView(source: source))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.overrideUserInterfaceStyle = .dark
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        func webView(in view: UIView) -> WKWebView? {
            if let view = view as? WKWebView { return view }
            return view.subviews.lazy.compactMap { webView(in: $0) }.first
        }
        window.layoutIfNeeded()
        for _ in 0..<20 {
            if webView(in: controller.view) != nil { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let web = try XCTUnwrap(webView(in: controller.view))
        XCTAssertFalse(web.isOpaque)
        for style in [UIUserInterfaceStyle.dark, .light] {
            window.overrideUserInterfaceStyle = style
            window.layoutIfNeeded()
            let traits = UITraitCollection(userInterfaceStyle: style)
            let background = try XCTUnwrap(web.backgroundColor).resolvedColor(with: traits)
            let scroll = try XCTUnwrap(web.scrollView.backgroundColor).resolvedColor(with: traits)
            if style == .dark {
                XCTAssertLessThan(luminance(background), 0.15)
                XCTAssertLessThan(luminance(scroll), 0.15)
            } else {
                XCTAssertGreaterThan(luminance(background), 0.6)
                XCTAssertGreaterThan(luminance(scroll), 0.6)
            }
        }
    }

    func testSyntaxTokensHaveReadableContrastInBaseAndElevatedAppearances() {
        let samples: [(SyntaxCodeEditor.Language, String)] = [
            (.json, #"{"title":"正文","count":12,"enabled":true,"empty":null}"#),
            (.rule, "@css:div && $.title {{key}} ##"),
            (.regex, #"\d+.*(word){2,4}"#),
            (.javascript, "// comment\nconst value = 'text'; return 123; /* comment */")
        ]
        for style in [UIUserInterfaceStyle.light, .dark] {
            for level in [UIUserInterfaceLevel.base, .elevated] {
                let traits = UITraitCollection(traitsFrom: [
                    UITraitCollection(userInterfaceStyle: style),
                    UITraitCollection(userInterfaceLevel: level)
                ])
                for (language, text) in samples {
                    let editor = SyntaxCodeEditor(text: .constant(text), language: language)
                    let view = UITextView()
                    view.overrideUserInterfaceStyle = style
                    view.text = text
                    editor.makeCoordinator().highlight(view)
                    let background = UIColor.secondarySystemGroupedBackground.resolvedColor(with: traits)
                    view.textStorage.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: view.textStorage.length)) { color, _, _ in
                        guard let color = color as? UIColor else { return XCTFail("Missing syntax color") }
                        let foreground = color.resolvedColor(with: traits)
                        let values = [luminance(foreground), luminance(background)].sorted()
                        XCTAssertGreaterThanOrEqual((values[1] + 0.05) / (values[0] + 0.05), 4.5,
                                                    "Low contrast for \(language), \(style), \(level)")
                    }
                }
            }
        }
    }

    private func luminance(_ color: UIColor) -> Double {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        XCTAssertTrue(color.getRed(&r, green: &g, blue: &b, alpha: &a))
        func linear(_ value: CGFloat) -> Double {
            let value = Double(value)
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
    }
}
