import SwiftUI

/// Темы чата: цвет ваших сообщений и мягкий фон. Выбор синхронизируется с собеседником внутри шифртекста.
struct ChatTheme: Identifiable, Equatable {
    let id: String
    let name: String
    let mine: [Color]
    let wallpaper: [Color]
    let accent: Color
    let onMine: Color

    static let all: [ChatTheme] = [
        .init(id: "teal", name: "Бирюза", mine: [Color.lkAccent, Color.lkAccentDim], wallpaper: [Color(hex: 0x0E1115), Color(hex: 0x0E2A2A)], accent: .lkAccent, onMine: Color.lkBg),
        .init(id: "violet", name: "Фиалка", mine: [Color(hex: 0x9B8CFF), Color(hex: 0x5B4BD6)], wallpaper: [Color(hex: 0x0E1115), Color(hex: 0x1D1740)], accent: Color(hex: 0x9B8CFF), onMine: .white),
        .init(id: "sunset", name: "Закат", mine: [Color(hex: 0xFF9A5A), Color(hex: 0xF0577A)], wallpaper: [Color(hex: 0x0E1115), Color(hex: 0x2E1522)], accent: Color(hex: 0xFF8A5A), onMine: .white),
        .init(id: "ocean", name: "Океан", mine: [Color(hex: 0x4DA3FF), Color(hex: 0x2F5BFF)], wallpaper: [Color(hex: 0x0E1115), Color(hex: 0x0F1F3A)], accent: Color(hex: 0x4DA3FF), onMine: .white),
        .init(id: "mint", name: "Мята", mine: [Color(hex: 0x6FE8B0), Color(hex: 0x2BB38A)], wallpaper: [Color(hex: 0x0E1115), Color(hex: 0x0E2A22)], accent: Color(hex: 0x6FE8B0), onMine: Color.lkBg),
        .init(id: "rose", name: "Роза", mine: [Color(hex: 0xFF7EB6), Color(hex: 0xD946A8)], wallpaper: [Color(hex: 0x0E1115), Color(hex: 0x2C1426)], accent: Color(hex: 0xFF7EB6), onMine: .white),
        .init(id: "night", name: "Ночь", mine: [Color(hex: 0xA9B0B8), Color(hex: 0x636B76)], wallpaper: [Color(hex: 0x0E1115), Color(hex: 0x171B22)], accent: Color(hex: 0xA9B0B8), onMine: Color.lkBg),
    ]
    static func by(_ id: String?) -> ChatTheme { all.first { $0.id == id } ?? all[0] }

    var mineGradient: LinearGradient { LinearGradient(colors: mine, startPoint: .topLeading, endPoint: .bottomTrailing) }
    var wallpaperGradient: LinearGradient { LinearGradient(colors: wallpaper, startPoint: .top, endPoint: .bottom) }
}

/// Стикеры (крупные анимированные эмодзи на цветной подложке).
struct ChatSticker: Identifiable {
    let id: String
    let emoji: String
    let caption: String
    let colors: [Color]

    static let all: [ChatSticker] = [
        .init(id: "heart", emoji: "❤️", caption: "Люблю", colors: [Color(hex: 0xFF5E7E), Color(hex: 0xFF9A9A)]),
        .init(id: "lock", emoji: "🔐", caption: "Закрыто", colors: [Color(hex: 0x3EC6BE), Color(hex: 0x2A8F8A)]),
        .init(id: "key", emoji: "🗝️", caption: "Мой ключ", colors: [Color(hex: 0xFFC857), Color(hex: 0xF08A3C)]),
        .init(id: "shield", emoji: "🛡️", caption: "Под защитой", colors: [Color(hex: 0x6C8CFF), Color(hex: 0x3F5BD6)]),
        .init(id: "shh", emoji: "🤫", caption: "Тсс", colors: [Color(hex: 0xA78BFA), Color(hex: 0x7C5CE0)]),
        .init(id: "eyes", emoji: "👀", caption: "Смотрю", colors: [Color(hex: 0x56D6A0), Color(hex: 0x2BA67A)]),
        .init(id: "fire", emoji: "🔥", caption: "Огонь", colors: [Color(hex: 0xFF8A3C), Color(hex: 0xE5484D)]),
        .init(id: "rocket", emoji: "🚀", caption: "Поехали", colors: [Color(hex: 0x5AA9FF), Color(hex: 0x7C5CE0)]),
        .init(id: "party", emoji: "🎉", caption: "Ура", colors: [Color(hex: 0xFF7EB6), Color(hex: 0xFFC857)]),
        .init(id: "laugh", emoji: "😂", caption: "Ха-ха", colors: [Color(hex: 0xFFC857), Color(hex: 0xFF9A5A)]),
        .init(id: "cool", emoji: "😎", caption: "Круто", colors: [Color(hex: 0x4DA3FF), Color(hex: 0x3EC6BE)]),
        .init(id: "ok", emoji: "👌", caption: "Окей", colors: [Color(hex: 0x6FE8B0), Color(hex: 0x3EC6BE)]),
    ]
    static func by(_ id: String) -> ChatSticker? { all.first { $0.id == id } }
}

struct StickerView: View {
    let sticker: ChatSticker
    var size: CGFloat = 120
    var animated = true
    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var on = false
    var body: some View {
        VStack(spacing: 4) {
            Text(sticker.emoji).font(.system(size: size * 0.52))
                .rotationEffect(.degrees(on && animated && !reduce ? 6 : -6))
                .scaleEffect(on && animated && !reduce ? 1.08 : 1)
            Text(sticker.caption).font(.lk(size * 0.11, .heavy)).foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .background(LinearGradient(colors: sticker.colors, startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).stroke(Color.white.opacity(0.25), lineWidth: 1))
        .shadow(color: sticker.colors[0].opacity(0.4), radius: 10, y: 4)
        .onAppear { withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { on = true } }
        .accessibilityLabel("Стикер: " + sticker.caption)
    }
}

enum EmojiSet {
    static let quick = ["❤️", "😂", "😮", "😢", "👍", "🔥"]
    static let categories: [(String, String, [String])] = [
        ("Частые", "clock", ["😀","😂","🥹","😍","😘","😎","🤔","😅","😭","🥳","🙏","👍","👏","🔥","❤️","✨","💯","🎉","👀","🤝"]),
        ("Лица", "face.smiling", ["😀","😃","😄","😁","😆","😅","🤣","😂","🙂","🙃","😉","😊","😇","🥰","😍","🤩","😘","😋","😛","😜","🤪","🤗","🤭","🤫","🤔","🤐","😐","😶","🙄","😏","😴","🥱","😌","😪","🤤","😷","🤒","🤕","🤢","🥵","🥶","🥴","😵","🤯","🤠","🥳","😎","🤓","🧐","😕","😟","🙁","😮","😲","🥺","😢","😭","😱","😖","😞","😤","😡","🤬","😈","💀"]),
        ("Жесты", "hand.raised", ["👍","👎","👌","🤌","✌️","🤞","🤟","🤘","🤙","👈","👉","👆","👇","☝️","✋","🤚","🖐️","🖖","👋","🤝","🙏","👏","🙌","🫶","💪","🫡","🤲","✍️","🫰","🤏"]),
        ("Сердца", "heart", ["❤️","🧡","💛","💚","💙","💜","🖤","🤍","🤎","💔","❣️","💕","💞","💓","💗","💖","💘","💝","💟","♥️","😻","💑","💌","🫶","🥰","😍","😘"]),
        ("Предметы", "key", ["🔐","🔒","🔓","🗝️","🔑","🛡️","📱","💻","⌨️","🖥️","📷","🎧","📎","📁","📄","💳","🪪","🧾","🔔","💡","⏰","⌛","🔋","📡","🧲","🛠️","🧩","🎁","📦","🚀"]),
        ("Символы", "number", ["✅","❌","⚠️","❓","❗","💤","💬","💭","🔔","➕","➖","✔️","♻️","⭐","🌟","⚡","💥","🎯","🏆","🔝","🆗","🆒","🔴","🟢","🔵","🟣","🟠","⚪","⚫","🔶"]),
    ]

    /// Одно–три эмодзи без текста показываем крупно, без пузыря.
    static func isBigEmoji(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.count <= 3 else { return false }
        return t.allSatisfy { ch in
            guard let f = ch.unicodeScalars.first else { return false }
            return f.properties.isEmojiPresentation || (f.properties.isEmoji && ch.unicodeScalars.count > 1)
        }
    }
}
