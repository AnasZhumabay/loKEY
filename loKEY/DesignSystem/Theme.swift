import SwiftUI
import UIKit

// MARK: - Цвета (токены из макетов, тёмная тема)

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }
    static let lkBg = Color(hex: 0x0E1115)
    static let lkCard = Color(hex: 0x161A20)
    static let lkCard2 = Color(hex: 0x1C2128)
    static let lkRaised = Color(hex: 0x20252D)
    static let lkTrack = Color(hex: 0x2A3038)
    static let lkAccent = Color(hex: 0x3EC6BE)
    static let lkAccentDim = Color(hex: 0x2C8F89)
    static let lkText = Color(hex: 0xF2F2EE)
    static let lkText2 = Color(hex: 0xC9CED4)
    static let lkMuted = Color(hex: 0x8B939E)      // контраст ≥ 4.5:1 на lkBg/lkCard
    static let lkBorder = Color.white.opacity(0.08)
    static let lkBorderSoft = Color.white.opacity(0.06)
    static let lkDanger = Color(hex: 0xFF8A7E)
    static let lkDangerSolid = Color(hex: 0xC9403A)
    static let lkWarn = Color(hex: 0xF2A65A)
    static let lkPurple = Color(hex: 0xC7B4FF)
}

// MARK: - Типографика (SF Pro; Manrope из макета можно подключить файлом шрифта)

extension Font {
    static func lk(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        if LKFont.available { return .custom("Manrope", size: size).weight(weight) }
        return .system(size: size, weight: weight, design: .default)
    }
    static func lkMono(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

// MARK: - Семантика доменных типов

extension SecurityLevel {
    var title: String {
        switch self { case .standard: return "STANDARD"; case .sensitive: return "SENSITIVE"; case .critical: return "CRITICAL" }
    }
    var tint: Color {
        switch self { case .standard: return .lkMuted; case .sensitive: return .lkPurple; case .critical: return .lkWarn }
    }
}

extension CaseIcon {
    var systemName: String {
        switch self {
        case .document: return "person.text.rectangle"
        case .wallet: return "creditcard"
        case .health: return "heart.text.square"
        case .home: return "house"
        case .travel: return "airplane"
        case .work: return "briefcase"
        case .photo: return "photo"
        case .key: return "key"
        }
    }
    var title: String {
        switch self {
        case .document: return "Документы"; case .wallet: return "Финансы"; case .health: return "Здоровье"
        case .home: return "Дом"; case .travel: return "Поездки"; case .work: return "Работа"
        case .photo: return "Фото"; case .key: return "Ключи"
        }
    }
}

extension FileKind {
    var label: String {
        switch self {
        case .pdf: return "PDF"; case .jpg: return "JPG"; case .heic: return "HEIC"; case .png: return "PNG"
        case .video: return "MOV"; case .note: return "NOTE"; case .password: return "PASS"; case .card: return "CARD"
        case .other: return "FILE"
        }
    }
    var systemName: String {
        switch self {
        case .pdf, .other: return "doc.text"
        case .jpg, .heic, .png: return "photo"
        case .video: return "video"
        case .note: return "note.text"
        case .password: return "key"
        case .card: return "creditcard"
        }
    }
    var tint: Color { self == .pdf ? .lkWarn : .lkAccent }
}

enum LKFormat {
    static func bytes(_ n: Int64) -> String {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useKB, .useMB, .useGB]
        f.countStyle = .file
        return f.string(fromByteCount: n)
    }
    static func clock(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

// MARK: - Haptics (схема из заметки на холсте)

@MainActor
enum Haptics {
    static func soft() { UIImpactFeedbackGenerator(style: .soft).impactOccurred() }
    static func rigid() { UIImpactFeedbackGenerator(style: .rigid).impactOccurred() }
    static func heavy() { UIImpactFeedbackGenerator(style: .heavy).impactOccurred() }
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    static func warning() { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
    static func error() { UINotificationFeedbackGenerator().notificationOccurred(.error) }
    /// Блокировка кейса — двойной щелчок
    static func lock() {
        rigid()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { rigid() }
    }
}

// MARK: - Шрифт Manrope (variable, OFL) — регистрируется при запуске

enum LKFont {
    nonisolated(unsafe) private(set) static var available = false
    static func register() {
        guard let url = Bundle.main.url(forResource: "Manrope", withExtension: "ttf") else { return }
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        available = UIFont(name: "Manrope", size: 12) != nil
    }
}
