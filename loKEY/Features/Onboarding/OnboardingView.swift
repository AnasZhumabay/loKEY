import SwiftUI

/// Вступление при первом запуске. По завершении вызывает `store.finishOnboarding()` (как раньше).
struct OnboardingView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var flow = OnboardingFlow()

    private var pageBinding: Binding<Int> {
        Binding(get: { flow.index }, set: { flow.go(to: $0) })
    }
    private var anim: Animation? { reduceMotion ? nil : .easeInOut(duration: 0.3) }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            TabView(selection: pageBinding) {
                WelcomePage().tag(OnboardingPage.welcome.rawValue)
                CipherPage().tag(OnboardingPage.cipher.rawValue)
                KeysPage().tag(OnboardingPage.keys.rawValue)
                WordsPage().tag(OnboardingPage.words.rawValue)
                ChatPage().tag(OnboardingPage.chat.rawValue)
                ProtectionPage().tag(OnboardingPage.protection.rawValue)
                FinalPage().tag(OnboardingPage.final.rawValue)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .animation(anim, value: flow.index)
            bottomBar
        }
        .lkScreen()
        .onChange(of: flow.index) { _, _ in Haptics.soft() }
    }

    private var topBar: some View {
        HStack {
            Text("\(flow.index + 1) / \(OnboardingPage.count)")
                .font(.lk(13, .bold)).tracking(1).foregroundStyle(Color.lkMuted)
                .accessibilityHidden(true)
            Spacer()
            if flow.canSkip {
                Button("Пропустить") { withAnimation(anim) { flow.skip() } }
                    .font(.lk(15, .semibold)).foregroundStyle(Color.lkText2)
                    .frame(minWidth: 44, minHeight: 44)
                    .accessibilityIdentifier("onboardingSkip")
            }
        }
        .frame(height: 44)
        .padding(.horizontal, 24)
    }

    private var bottomBar: some View {
        VStack(spacing: 16) {
            HStack(spacing: 6) {
                ForEach(0..<OnboardingPage.count, id: \.self) { i in
                    Capsule().fill(i == flow.index ? Color.lkAccent : (i < flow.index ? Color.lkAccentDim : Color.lkTrack))
                        .frame(width: i == flow.index ? 24 : 6, height: 6)
                }
                Spacer()
            }
            .animation(anim, value: flow.index)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(trf("Шаг %lld из %lld", flow.index + 1, OnboardingPage.count))
            HStack(spacing: 10) {
                if !flow.isFirst {
                    Button { withAnimation(anim) { flow.back() } } label: {
                        Image(systemName: "chevron.left").font(.system(size: 17, weight: .heavy))
                            .foregroundStyle(Color.lkText)
                            .frame(width: 56, height: 56)
                            .overlay(Circle().stroke(Color.white.opacity(0.14), lineWidth: 1))
                    }
                    .buttonStyle(LKPressStyle(scale: 0.92))
                    .accessibilityLabel("Назад")
                    .accessibilityIdentifier("onboardingBack")
                    .transition(.opacity)
                }
                if flow.isLast {
                    Button { Haptics.success(); store.finishOnboarding() } label: {
                        Text("Начать")
                    }
                    .buttonStyle(.lkPrimary)
                    .accessibilityIdentifier("onboardingStart")
                } else {
                    Button { withAnimation(anim) { flow.next() } } label: {
                        HStack(spacing: 8) {
                            Text("Дальше")
                            Image(systemName: "arrow.right").font(.system(size: 16, weight: .heavy))
                        }
                    }
                    .buttonStyle(.lkPrimary)
                    .accessibilityIdentifier("onboardingNext")
                }
            }
            .animation(anim, value: flow.isFirst)
        }
        .padding(.horizontal, 24).padding(.bottom, 24).padding(.top, 8)
    }
}
