import SwiftUI

extension SharedRole {
    var title: String {
        switch self { case .owner: return "Владелец"; case .editor: return "Редактор"; case .viewer: return "Просмотр" }
    }
    var icon: String {
        switch self { case .owner: return "crown"; case .editor: return "pencil"; case .viewer: return "eye" }
    }
}
extension SharedMemberStatus {
    var title: String {
        switch self { case .invited: return "Приглашён"; case .active: return "В кейсе"; case .revoked: return "Доступ отозван" }
    }
}

/// Круглый аватар с инициалом.
struct SharedAvatar: View {
    let name: String
    var tint: Color = .lkAccent
    var size: CGFloat = 44
    var body: some View {
        Text(String(name.trimmingCharacters(in: .whitespaces).first.map { String($0).uppercased() } ?? "?"))
            .font(.lk(size * 0.4, .heavy)).foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.15), in: Circle())
            .overlay(Circle().stroke(tint.opacity(0.4), lineWidth: 1))
            .accessibilityHidden(true)
    }
}

struct SharedRoleTag: View {
    let role: SharedRole
    var body: some View {
        Label(tr(role.title), systemImage: role.icon)
            .font(.lk(11, .bold)).foregroundStyle(role == .owner ? Color.lkWarn : Color.lkAccent)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background((role == .owner ? Color.lkWarn : Color.lkAccent).opacity(0.12), in: Capsule())
    }
}
