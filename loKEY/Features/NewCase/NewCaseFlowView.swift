import SwiftUI
import UIKit
import UniformTypeIdentifiers

// `KeyFileDocument` (файл ключа для `.fileExporter`) общий: объявлен в Features/Case/CaseSheets.swift.

struct NewCaseFlowView: View {
    @Environment(AppStore.self) private var store
    @Environment(Router.self) private var router
    @Environment(\.dismiss) private var dismiss

    // Шаг 1
    @State private var name = ""
    @State private var icon: CaseIcon = .document
    @State private var level: SecurityLevel = .standard
    @State private var isCreating = false
    @State private var createError: String?
    @FocusState private var nameFocused: Bool

    // Шаг 2 — ключ и слова только в памяти, не логируются и не сохраняются
    @State private var result: NewCaseResult?
    @State private var copied = false
    @State private var confirmed = false
    @State private var exporting = false
    @State private var confirmClose = false
    @State private var isFinishing = false
    @State private var copyResetTask: Task<Void, Never>?

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canCreate: Bool { !trimmedName.isEmpty && trimmedName.count <= 40 && !isCreating }

    var body: some View {
        VStack(spacing: 12) {
            topBar
            if let result {
                keyStep(result).overlay(alignment: .top) { ConfettiBurst().padding(.top, 140) }
            } else {
                createStep
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .lkScreen()
        .interactiveDismissDisabled(result != nil)
        .confirmationDialog("Закрыть без подтверждения?", isPresented: $confirmClose, titleVisibility: .visible) {
            Button("Закрыть", role: .destructive) { Task { await close(openCase: false) } }
            Button("Остаться", role: .cancel) {}
        } message: {
            Text("Кейс уже создан. Ключ можно будет выгрузить позже из меню кейса, но фразу восстановления вы больше не увидите.")
        }
    }

    // MARK: Шапка

    private var topBar: some View {
        HStack {
            Button {
                if result != nil && !confirmed { confirmClose = true } else if result != nil { Task { await close(openCase: false) } } else { dismiss() }
            } label: {
                Image(systemName: "xmark").font(.system(size: 16, weight: .bold))
                    .frame(width: 44, height: 44)
                    .background(Color.lkCard, in: Circle())
                    .overlay(Circle().stroke(Color.lkBorder, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Закрыть")
            Spacer()
            HStack(spacing: 6) {
                Capsule().fill(Color.lkAccent).frame(width: 28, height: 6)
                Capsule().fill(result == nil ? Color.lkTrack : Color.lkAccent).frame(width: 28, height: 6)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(tr(result == nil ? "Шаг 1 из 2" : "Шаг 2 из 2"))
            Spacer()
            Color.clear.frame(width: 44, height: 44)
        }
        .frame(height: 44)
    }

    // MARK: Шаг 1

    private var createStep: some View {
        VStack(spacing: 12) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Новый кейс").font(.lk(28, .heavy)).tracking(-0.8)
                        Text("У каждого кейса свой ключ. Файлы шифруются на телефоне.")
                            .font(.lk(14, .medium)).foregroundStyle(Color(hex: 0xA9B0B8))
                    }
                    LKField(title: "Название", error: createError) {
                        TextField("Например, Поездки", text: $name)
                            .focused($nameFocused)
                            .submitLabel(.done)
                            .onSubmit { nameFocused = false }
                            .onChange(of: name) { _, _ in createError = nil }
                            .tint(Color.lkAccent)
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Значок").font(.lk(13, .bold)).foregroundStyle(Color.lkText2)
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 10) {
                            ForEach(CaseIcon.allCases, id: \.self) { ic in
                                Button { icon = ic; Haptics.soft() } label: {
                                    VStack(spacing: 4) {
                                        Image(systemName: ic.systemName).font(.system(size: 22, weight: .medium))
                                        Text(ic.title).font(.lk(10, .semibold)).lineLimit(1).minimumScaleFactor(0.7)
                                    }
                                    .foregroundStyle(icon == ic ? Color.lkAccent : Color.lkText2)
                                    .frame(maxWidth: .infinity, minHeight: 64)
                                    .background(icon == ic ? Color.lkAccent.opacity(0.12) : Color.lkCard,
                                                in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                                        .stroke(icon == ic ? Color.lkAccent : Color.white.opacity(0.08), lineWidth: icon == ic ? 1.5 : 1))
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(tr(ic.title))
                                .accessibilityAddTraits(icon == ic ? .isSelected : [])
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Уровень защиты").font(.lk(13, .bold)).foregroundStyle(Color.lkText2)
                        ForEach(SecurityLevel.allCases, id: \.self) { lv in
                            levelRow(lv)
                        }
                    }
                }
                .padding(.top, 4)
                .padding(.bottom, 8)
            }
            .scrollDismissesKeyboard(.interactively)

            Button {
                Task { await create() }
            } label: {
                if isCreating { ProgressView().tint(Color.lkBg) } else { Text("Создать ключ") }
            }
            .buttonStyle(.lkPrimary)
            .disabled(!canCreate)
            .accessibilityLabel(tr(isCreating ? "Создаём ключ" : "Создать ключ"))
        }
    }

    private func levelRow(_ lv: SecurityLevel) -> some View {
        let text: String = {
            switch lv {
            case .standard: return "Обычные документы. Открывается по Face ID или ключу."
            case .sensitive: return "Финансы и здоровье. Дополнительная проверка при открытии."
            case .critical: return "Самое важное. Строгие лимиты попыток и короткая автоблокировка."
            }
        }()
        let on = level == lv
        return Button { level = lv; Haptics.soft() } label: {
            HStack(spacing: 12) {
                Circle().fill(lv.tint).frame(width: 10, height: 10)
                VStack(alignment: .leading, spacing: 2) {
                    Text(lv.title).font(.lk(12, .heavy)).tracking(1).foregroundStyle(lv.tint)
                    Text(text).font(.lk(13, .medium)).foregroundStyle(Color.lkText2)
                        .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(on ? Color.lkAccent : Color.lkMuted)
            }
            .padding(.horizontal, 14).padding(.vertical, 12).frame(minHeight: 44)
            .background(Color.lkCard, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(on ? lv.tint : Color.white.opacity(0.08), lineWidth: on ? 1.5 : 1))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func create() async {
        guard canCreate else { return }
        nameFocused = false
        isCreating = true
        createError = nil
        defer { isCreating = false }
        do {
            let r = try await store.repo.createCase(name: trimmedName, icon: icon, level: level)
            Haptics.success()
            withAnimation(.easeOut(duration: 0.25)) { result = r }
        } catch {
            createError = (error as? VaultError)?.message ?? "Не удалось создать кейс"
            store.showError(error)
        }
    }

    // MARK: Шаг 2

    private func keyStep(_ r: NewCaseResult) -> some View {
        let groups = r.keyString.split(separator: "-").map(String.init)
        let half = (groups.count + 1) / 2
        let line1 = groups.prefix(half).joined(separator: "-")
        let line2 = groups.dropFirst(half).joined(separator: "-")
        return VStack(spacing: 12) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(verbatim: trf("Ключ кейса\n«%@» готов", r.vaultCase.name))
                            .font(.lk(28, .heavy)).tracking(-0.8).lineSpacing(1)
                        Text("Сохранён в Keychain. Сделайте запасную копию — мы её не храним.")
                            .font(.lk(14, .medium)).foregroundStyle(Color(hex: 0xA9B0B8))
                    }

                    VStack(alignment: .leading, spacing: 14) {
                        Text("КЛЮЧ · AES-256").font(.lk(11, .heavy)).tracking(1.1).foregroundStyle(Color.lkAccent)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(line1); Text(line2)
                        }
                        .font(.lkMono(17, .semibold)).tracking(0.7).lineSpacing(3)
                        .minimumScaleFactor(0.7).lineLimit(1)
                        .textSelection(.disabled)
                        .accessibilityLabel(trf("Ключ кейса: %@", r.keyString.replacingOccurrences(of: "-", with: " ")))
                        HStack(spacing: 8) {
                            Button { copyKey(r.keyString) } label: {
                                Label(tr(copied ? "Скопировано" : "Скопировать"), systemImage: copied ? "checkmark" : "doc.on.doc")
                                    .font(.lk(14, .heavy)).foregroundStyle(Color.lkBg)
                                    .frame(maxWidth: .infinity, minHeight: 44)
                                    .background(Color.lkAccent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            Button { exporting = true } label: {
                                Label("Сохранить .key", systemImage: "square.and.arrow.down")
                                    .font(.lk(14, .bold)).foregroundStyle(Color.lkText)
                                    .frame(maxWidth: .infinity, minHeight: 44)
                                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .stroke(Color.white.opacity(0.12), lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(16)
                    .background(alignment: .topTrailing) {
                        BrandMark(stem: .lkAccent, ring: .lkAccent).frame(width: 180).opacity(0.07)
                            .offset(x: 40, y: -18).accessibilityHidden(true)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .lkCard(fill: .lkCard, stroke: Color.lkAccent.opacity(0.35))

                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("Фраза восстановления").font(.lk(16, .heavy))
                            Spacer()
                            Text("12 слов").font(.lk(12, .semibold)).foregroundStyle(Color.lkMuted)
                        }
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                            ForEach(Array(r.recoveryWords.enumerated()), id: \.offset) { i, w in
                                HStack(spacing: 6) {
                                    Text("\(i + 1)").font(.lkMono(11, .semibold)).foregroundStyle(Color.lkMuted)
                                        .frame(width: 16, alignment: .leading)
                                    Text(w).font(.lk(13, .bold)).lineLimit(1).minimumScaleFactor(0.7)
                                }
                                .padding(.horizontal, 10).frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                                .background(Color.lkCard, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.white.opacity(0.05), lineWidth: 1))
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel(trf("Слово %lld: %@", i + 1, w))
                            }
                        }
                    }

                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(Color.lkWarn).padding(.top, 1)
                        Text("Без ключа и фразы файлы этого кейса не восстановить никому — даже поддержке loKEY.")
                            .font(.lk(13, .semibold)).foregroundStyle(Color(hex: 0xF6C795))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 12)
                    .background(Color.lkWarn.opacity(0.1), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color.lkWarn.opacity(0.3), lineWidth: 1))
                }
            }

            VStack(spacing: 12) {
                Button { confirmed.toggle(); Haptics.soft() } label: {
                    HStack(spacing: 12) {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(confirmed ? Color.lkAccent : Color(hex: 0x4A515B), lineWidth: 2)
                            .background(confirmed ? Color.lkAccent : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay { if confirmed { Image(systemName: "checkmark").font(.system(size: 13, weight: .heavy)).foregroundStyle(Color.lkBg) } }
                            .frame(width: 24, height: 24)
                        Text("Я сохранил ключ и фразу в надёжном месте")
                            .font(.lk(14, .semibold)).multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                    }
                    .frame(minHeight: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(.isButton)
                .accessibilityValue(tr(confirmed ? "включено" : "выключено"))

                Button { Task { await close(openCase: true) } } label: {
                    if isFinishing { ProgressView().tint(Color.lkBg) } else { Text("Готово") }
                }
                .buttonStyle(.lkPrimary)
                .disabled(!confirmed || isFinishing)
            }
        }
        .fileExporter(isPresented: $exporting, document: KeyFileDocument(data: r.keyFileData),
                      contentType: .data, defaultFilename: r.keyFileName) { res in
            if case .failure(let e) = res { store.showError(e) }
            else if case .success = res { store.showToast("Ключ сохранён") }
        }
    }

    private func copyKey(_ key: String) {
        UIPasteboard.general.setItems([[UTType.utf8PlainText.identifier: key]],
                                      options: [.expirationDate: Date().addingTimeInterval(60), .localOnly: true])
        Haptics.success()
        copied = true
        copyResetTask?.cancel()
        copyResetTask = Task {
            try? await Task.sleep(for: .seconds(60))
            if !Task.isCancelled { copied = false }
        }
    }

    private func close(openCase: Bool) async {
        guard !isFinishing else { return }
        isFinishing = true
        let id = result?.vaultCase.id
        copyResetTask?.cancel()
        await store.refreshCases()
        result = nil   // убираем ключ и слова из памяти
        dismiss()
        if openCase, let id { router.push(.vaultCase(caseID: id)) }
    }
}
