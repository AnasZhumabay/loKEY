import SwiftUI
import UIKit

// MARK: - Скелетон списка (вместо спиннера)

struct LKSkeletonRows: View {
    var count = 5
    var height: CGFloat = 68
    var body: some View {
        VStack(spacing: 10) {
            ForEach(0..<count, id: \.self) { i in
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.06)).frame(width: 46, height: 46)
                    VStack(alignment: .leading, spacing: 8) {
                        RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.08)).frame(width: 150 + CGFloat((i * 37) % 70), height: 12)
                        RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.05)).frame(width: 90, height: 10)
                    }
                    Spacer()
                }
                .padding(.horizontal, 14).frame(height: height)
                .background(Color.lkCard, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .lkShimmer()
            }
        }
        .padding(.horizontal, 16).padding(.top, 8)
        .accessibilityLabel("Загрузка")
    }
}

// MARK: - Одноразовая подсказка

enum LKHints {
    private static let key = "dismissedHints"
    static func isDismissed(_ id: String) -> Bool { (UserDefaults.standard.stringArray(forKey: key) ?? []).contains(id) }
    static func dismiss(_ id: String) {
        var a = UserDefaults.standard.stringArray(forKey: key) ?? []
        if !a.contains(id) { a.append(id); UserDefaults.standard.set(a, forKey: key) }
    }
}

struct LKHintBanner: View {
    let id: String
    let icon: String
    let text: String
    @State private var visible = false
    var body: some View {
        Group {
            if visible {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: icon).font(.system(size: 16, weight: .semibold)).foregroundStyle(Color.lkAccent)
                        .frame(width: 34, height: 34).background(Color.lkAccent.opacity(0.14), in: Circle())
                    Text(text).font(.lk(13, .semibold)).foregroundStyle(Color.lkText2).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Button {
                        Haptics.soft(); LKHints.dismiss(id)
                        withAnimation(LKMotion.spring) { visible = false }
                    } label: {
                        Image(systemName: "xmark").font(.system(size: 12, weight: .bold)).foregroundStyle(Color.lkMuted).frame(width: 36, height: 36)
                    }
                    .accessibilityLabel("Закрыть подсказку")
                }
                .padding(.leading, 12).padding(.trailing, 2).padding(.vertical, 8)
                .background(Color.lkAccent.opacity(0.07), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color.lkAccent.opacity(0.25), lineWidth: 1))
                .transition(.scale(scale: 0.92).combined(with: .opacity))
            }
        }
        .onAppear {
            guard !LKHints.isDismissed(id) else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { withAnimation(LKMotion.spring) { visible = true } }
        }
    }
}

// MARK: - Встряхивание

extension Notification.Name { static let lkDeviceShake = Notification.Name("lkDeviceShake") }

extension UIWindow {
    open override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        if motion == .motionShake { NotificationCenter.default.post(name: .lkDeviceShake, object: nil) }
        super.motionEnded(motion, with: event)
    }
}
