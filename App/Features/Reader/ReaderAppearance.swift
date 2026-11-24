import CoreText
import ImageIO
import SwiftUI
import UIKit

private struct ReaderPositionPreferenceKey: PreferenceKey {
    static let defaultValue: [Int: CGFloat] = [:]
    static func reduce(value: inout [Int: CGFloat], nextValue: () -> [Int: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

struct ReaderStylePreset: Identifiable {
    let id: String
    let name: String
    let background: UIColor
    let foreground: UIColor

    static let legadoDefaults: [ReaderStylePreset] = [
        .init(id: "wechat", name: "微信读书", background: UIColor(hex: 0xC0EDC6), foreground: UIColor(hex: 0x0B0B0B)),
        .init(id: "preset1", name: "预设1", background: UIColor(hex: 0xFFFFFF), foreground: UIColor(hex: 0x000000)),
        .init(id: "preset2", name: "预设2", background: UIColor(hex: 0xDDC090), foreground: UIColor(hex: 0x3E3422)),
        .init(id: "preset3", name: "预设3", background: UIColor(hex: 0xC2D8AA), foreground: UIColor(hex: 0x596C44)),
        .init(id: "preset4", name: "预设4", background: UIColor(hex: 0xDBB8E2), foreground: UIColor(hex: 0x68516C)),
        .init(id: "preset5", name: "预设5", background: UIColor(hex: 0xABCEE0), foreground: UIColor(hex: 0x3D4C54)),
        .init(id: "night", name: "夜间", background: UIColor(hex: 0x000000), foreground: UIColor(hex: 0xADADAD))
    ]
    static let eInk = ReaderStylePreset(
        id: "eink",
        name: "E-Ink",
        background: UIColor(hex: 0xFFFFFF),
        foreground: UIColor(hex: 0x000000)
    )

    static func resolve(_ id: String) -> ReaderStylePreset {
        let migratedID = switch id {
        case "dark": "night"
        case "light": "preset1"
        case "paper": "preset2"
        default: id
        }
        return legadoDefaults.first(where: { $0.id == migratedID }) ?? legadoDefaults[0]
    }
}

struct ReaderTextColors: RawRepresentable, Equatable {
    static let storageKey = "readerTextColors"
    private var colors: [String: UInt32] = [:]

    init() {}

    init?(rawValue: String) {
        guard let saved = try? JSONDecoder().decode([String: UInt32].self, from: Data(rawValue.utf8)),
              saved.values.allSatisfy({ $0 <= 0xFFFFFF }) else { return nil }
        colors = saved
    }

    var rawValue: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try! encoder.encode(colors), as: UTF8.self)
    }

    func customForeground(for theme: String) -> UIColor? {
        colors[ReaderStylePreset.resolve(theme).id].map { UIColor(hex: $0) }
    }

    mutating func setForeground(_ color: UIColor, for theme: String) {
        guard let rgb = Self.rgb(color) else { return }
        colors[ReaderStylePreset.resolve(theme).id] = rgb
    }

    mutating func resetForeground(for theme: String) {
        colors.removeValue(forKey: ReaderStylePreset.resolve(theme).id)
    }

    func style(for theme: String, isEInk: Bool = false) -> ReaderStylePreset {
        if isEInk { return .eInk }
        let preset = ReaderStylePreset.resolve(theme)
        guard let rgb = colors[preset.id] else { return preset }
        return ReaderStylePreset(id: preset.id, name: preset.name, background: preset.background, foreground: UIColor(hex: rgb))
    }

    static func hexString(for color: UIColor) -> String? {
        rgb(color).map { String(format: "#%06X", $0) }
    }

    private static func rgb(_ color: UIColor) -> UInt32? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let components = color.cgColor.converted(to: space, intent: .relativeColorimetric, options: nil)?.components,
              components.count >= 3 else { return nil }
        func byte(_ value: CGFloat) -> UInt32 { UInt32((min(1, max(0, value)) * 255).rounded()) }
        return (byte(components[0]) << 16) | (byte(components[1]) << 8) | byte(components[2])
    }
}

struct ReaderTextColorControls: View {
    let theme: String
    let isEInk: Bool
    var defaultForeground: UIColor? = nil

    var body: some View {
        ReaderTextColorPicker(theme: theme, isEInk: isEInk, defaultForeground: defaultForeground)
        ReaderTextColorReset(theme: theme, isEInk: isEInk)
    }
}

struct ReaderTextColorPicker: View {
    let theme: String
    let isEInk: Bool
    let defaultForeground: UIColor?
    @AppStorage(ReaderTextColors.storageKey) private var colors = ReaderTextColors()
    @State private var isChoosing = false

    init(theme: String, isEInk: Bool, defaultForeground: UIColor? = nil) {
        self.theme = theme
        self.isEInk = isEInk
        self.defaultForeground = defaultForeground
    }

    var body: some View {
        let custom = colors.customForeground(for: theme)
        let foreground = isEInk ? ReaderStylePreset.eInk.foreground
            : custom ?? defaultForeground ?? ReaderStylePreset.resolve(theme).foreground
        Button { isChoosing = true } label: {
            HStack(spacing: 8) {
                Text("字体颜色")
                Circle()
                    .fill(Color(uiColor: foreground))
                    .overlay { Circle().strokeBorder(Color.secondary, lineWidth: 1) }
                    .frame(width: 26, height: 26)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isEInk)
        .accessibilityIdentifier("reader.textColor")
        .accessibilityValue(ReaderTextColors.hexString(for: foreground) ?? "")
        .sheet(isPresented: $isChoosing) {
            ReaderTextColorSheet(foreground: foreground) { color in
                colors.setForeground(color, for: theme)
            }
        }
    }
}

private struct ReaderTextColorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var hex: String
    let select: (UIColor) -> Void

    private static let swatches: [(name: String, rgb: UInt32)] = [
        ("黑色", 0x000000), ("深灰", 0x343434), ("浅灰", 0xADADAD), ("白色", 0xFFFFFF),
        ("棕色", 0x705038), ("红色", 0xB74040), ("紫色", 0x705393), ("蓝色", 0x285AA2),
        ("青色", 0x216D76), ("绿色", 0x315C50), ("橄榄绿", 0x596C44), ("米色", 0xDECCA9)
    ]

    init(foreground: UIColor, select: @escaping (UIColor) -> Void) {
        _hex = State(initialValue: ReaderTextColors.hexString(for: foreground) ?? "#000000")
        self.select = select
    }

    private static func parseRGB(_ value: String) -> UInt32? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = trimmed.hasPrefix("#") ? trimmed.dropFirst() : trimmed[...]
        guard digits.count == 6, digits.allSatisfy(\.isHexDigit) else { return nil }
        return UInt32(digits, radix: 16)
    }

    var body: some View {
        let rgb = Self.parseRGB(hex)
        ReadingNavigationStack {
            Form {
                Section("常用颜色") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 8) {
                        ForEach(Self.swatches, id: \.rgb) { swatch in
                            let code = String(format: "%06X", swatch.rgb)
                            let selected = rgb == swatch.rgb
                            Button {
                                if hex == "#" + code {
                                    select(UIColor(hex: swatch.rgb))
                                } else {
                                    hex = "#" + code
                                }
                            } label: {
                                Circle()
                                    .fill(Color(uiColor: UIColor(hex: swatch.rgb)))
                                    .overlay { Circle().strokeBorder(Color.secondary, lineWidth: 1) }
                                    .overlay {
                                        if selected {
                                            Image(systemName: "checkmark.circle.fill")
                                                .symbolRenderingMode(.palette)
                                                .foregroundStyle(.white, .black)
                                        }
                                    }
                                    .frame(width: 36, height: 36)
                                    .frame(maxWidth: .infinity, minHeight: 44)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(swatch.name)
                            .accessibilityAddTraits(selected ? .isSelected : [])
                            .accessibilityIdentifier("reader.textColor.swatch." + code)
                        }
                    }
                }
                Section("自定义颜色") {
                    TextField("十六进制 RGB", text: $hex)
                        .font(.body.monospaced())
                        .keyboardType(.asciiCapable)
                        .textInputAutocapitalization(.characters)
                        .disableAutocorrection(true)
                        .accessibilityIdentifier("reader.textColor.hex")
                    if rgb == nil {
                        Text("请输入 6 位十六进制颜色，例如 #315C50。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("字体颜色")
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: hex) { value in
                if let rgb = Self.parseRGB(value) { select(UIColor(hex: rgb)) }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                        .disabled(rgb == nil)
                        .accessibilityIdentifier("reader.textColor.done")
                }
            }
        }
    }
}

struct ReaderTextColorReset: View {
    let theme: String
    let isEInk: Bool
    @AppStorage(ReaderTextColors.storageKey) private var colors = ReaderTextColors()

    var body: some View {
        Button("恢复主题默认字体颜色") { colors.resetForeground(for: theme) }
            .disabled(isEInk || colors.customForeground(for: theme) == nil)
            .accessibilityIdentifier("reader.resetTextColor")
        if isEInk {
            Text("E-Ink 模式使用黑色文字。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

private extension UIColor {
    convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xff) / 255,
            green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255,
            alpha: 1
        )
    }
}

enum ReaderBackgroundStore {
    static let maximumPixelSize = 2560

    static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Legado/reader-background.jpg")
    }

    static func load(from source: URL = url) -> UIImage? {
        guard let data = try? Data(contentsOf: source, options: .mappedIfSafe) else { return nil }
        return try? downsample(data)
    }

    static func save(_ data: Data, to target: URL = url) throws -> UIImage {
        let image = try downsample(data)
        guard let encoded = image.jpegData(compressionQuality: 0.9) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoded.write(to: target, options: .atomic)
        return image
    }

    private static func downsample(_ data: Data) throws -> UIImage {
        // Decode only the size used by the reader, including backgrounds saved
        // by older versions. Full-resolution camera photos can exhaust memory.
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize
              ] as CFDictionary) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return UIImage(cgImage: image)
    }

    static func remove() { try? FileManager.default.removeItem(at: url) }
}

enum ReaderFontStore {
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Legado/fonts", isDirectory: true)
    }

    static func install(from source: URL) throws -> String {
        let accessing = source.startAccessingSecurityScopedResource()
        defer { if accessing { source.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: source)
        guard let provider = CGDataProvider(data: data as CFData),
              font(provider: provider, size: 20, weight: 0) != nil else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent(source.lastPathComponent)
        if target != source {
            try data.write(to: target, options: .atomic)
        }
        return target.lastPathComponent
    }

    static func font(at path: String, size: CGFloat, weight: Int) -> UIFont? {
        guard !path.isEmpty else { return nil }
        // Older versions saved the absolute sandbox path. Resolve managed fonts
        // against the current container, including after an app update or restore.
        let url = directory.appendingPathComponent(URL(fileURLWithPath: path).lastPathComponent)
        guard let provider = CGDataProvider(url: url as CFURL) else { return nil }
        return font(provider: provider, size: size, weight: weight)
    }

    private static func font(provider: CGDataProvider, size: CGFloat, weight: Int) -> UIFont? {
        guard let graphicsFont = CGFont(provider) else { return nil }
        // Use the selected face even when its PostScript name matches an installed font.
        let base = CTFontCreateWithGraphicsFont(graphicsFont, size, nil, nil) as UIFont
        if weight == 1,
           let descriptor = base.fontDescriptor.withSymbolicTraits(.traitBold) {
            return UIFont(descriptor: descriptor, size: size)
        }
        if weight == 2 {
            let descriptor = base.fontDescriptor.addingAttributes([
                .traits: [UIFontDescriptor.TraitKey.weight: UIFont.Weight.light.rawValue]
            ])
            return UIFont(descriptor: descriptor, size: size)
        }
        return base
    }
}
