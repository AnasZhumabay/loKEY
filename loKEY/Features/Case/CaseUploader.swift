import SwiftUI
import Observation

/// Один файл в очереди загрузки. Данные лежат только в памяти.
struct UploadItem: Identifiable {
    enum State: Equatable { case queued, active(UploadProgress.Stage, Double), done, failed(String) }
    let id = UUID()
    var name: String
    var kind: FileKind
    var data: Data?
    var note: String?
    /// Текст, распознанный на устройстве (для поиска внутри кейса)
    var ocrText: String? = nil
    var state: State = .queued
    var size: Int64
}

@MainActor
@Observable
final class UploadModel: Identifiable {
    let id = UUID()
    let caseID: String
    let caseName: String
    private(set) var items: [UploadItem]
    private(set) var finished = false

    init(caseID: String, caseName: String, items: [UploadItem]) {
        self.caseID = caseID; self.caseName = caseName; self.items = items
    }

    var doneCount: Int { items.filter { $0.state == .done }.count }
    var failedCount: Int { items.filter { if case .failed = $0.state { return true }; return false }.count }
    var totalBytes: Int64 { items.reduce(0) { $0 + $1.size } }

    static func weight(_ p: UploadProgress) -> Double {
        switch p.stage {
        case .encrypting: return 0.34 * p.fraction
        case .uploading: return 0.34 + 0.56 * p.fraction
        case .verifying: return 0.90 + 0.10 * p.fraction
        case .done: return 1
        }
    }

    /// Общий прогресс 0...1
    var overall: Double {
        guard !items.isEmpty else { return 0 }
        let sum = items.reduce(0.0) { acc, it in
            switch it.state {
            case .queued: return acc
            case .done, .failed: return acc + 1
            case .active(let s, let f): return acc + Self.weight(.init(stage: s, fraction: f))
            }
        }
        return sum / Double(items.count)
    }

    /// Текущий этап конвейера: 0 / 1 / 2, 3 — всё готово
    var stageIndex: Int {
        if finished { return 3 }
        for it in items { if case .active(let s, _) = it.state {
            switch s { case .encrypting: return 0; case .uploading: return 1; case .verifying, .done: return 2 }
        } }
        return 0
    }

    func run(store: AppStore) async {
        for i in items.indices {
            guard let data = items[i].data else { continue }
            items[i].state = .active(.encrypting, 0)
            do {
                _ = try await store.repo.addFile(caseID: caseID, name: items[i].name, kind: items[i].kind,
                                                 data: data, note: items[i].note, ocrText: items[i].ocrText) { [weak self] p in
                    Task { @MainActor in self?.apply(p, at: i) }
                }
                items[i].state = .done
            } catch {
                items[i].state = .failed(Self.message(error))
            }
            items[i].data = nil
            store.noteActivity()
        }
        finished = true
        await store.refreshCases()
        if failedCount == 0 { Haptics.success() } else { Haptics.warning() }
    }

    private func apply(_ p: UploadProgress, at i: Int) {
        guard items.indices.contains(i) else { return }
        if case .active = items[i].state { items[i].state = .active(p.stage, p.fraction) }
    }

    private static func message(_ e: Error) -> String {
        if case .quotaExceeded = e as? VaultError { return "Не хватает места в хранилище (1 ГБ)" }
        return (e as? VaultError)?.message ?? "Не удалось загрузить"
    }
}

struct UploadSheet: View {
    @Bindable var model: UploadModel
    let onClose: () -> Void
    @Environment(AppStore.self) private var store
    @State private var started = false

    private static let steps: [(String, String)] = [
        ("Шифруем на iPhone", "AES-256-GCM, ключ кейса остаётся в Keychain"),
        ("Отправляем на сервер", "Уходит только шифртекст и контрольный хэш"),
        ("Проверяем целостность", "Хэш на сервере совпадает с хэшем на телефоне")
    ]

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(verbatim: trf("ЗАГРУЗКА · %@", model.caseName.uppercased())).font(.lk(11, .heavy)).tracking(1.2).foregroundStyle(Color.lkMuted)
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text("\(Int((model.overall * 100).rounded()))").font(.lk(64, .heavy)).monospacedDigit()
                        Text("%").font(.lk(28, .heavy)).foregroundStyle(Color.lkMuted)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(trf("Загружено %lld процентов", Int((model.overall * 100).rounded())))
                    Text(verbatim: "\(tr(stageLabel))  ·  \(trf("%lld из %lld", model.doneCount, model.items.count)) \(tr(plural(model.items.count)))  ·  \(LKFormat.bytes(model.totalBytes))")
                        .font(.lk(12, .heavy)).tracking(0.6).foregroundStyle(model.failedCount > 0 ? Color.lkWarn : Color.lkAccent)
                    steps
                    VStack(spacing: 8) { ForEach(model.items) { row($0) } }
                    Text("Сначала файл шифруется на iPhone, потом уходит на сервер. Сервер видит только шифртекст и размер.")
                        .font(.lk(13, .medium)).foregroundStyle(Color.lkMuted)
                }
                .padding(20)
            }
            if model.finished {
                Button(tr(model.failedCount > 0 ? "Закрыть" : "Готово")) { onClose() }
                    .buttonStyle(.lkPrimary).padding(20)
            }
        }
        .background(Color.lkBg).foregroundStyle(Color.lkText).preferredColorScheme(.dark)
        .interactiveDismissDisabled(!model.finished)
        .task {
            guard !started else { return }
            started = true
            await model.run(store: store)
        }
    }

    private func plural(_ n: Int) -> String {
        let m10 = n % 10, m100 = n % 100
        if m10 == 1 && m100 != 11 { return "файла" }
        return "файлов"
    }

    private var stageLabel: String {
        if model.finished { return model.failedCount > 0 ? "ЗАВЕРШЕНО С ОШИБКАМИ" : "ГОТОВО" }
        return ["ШИФРУЕМ…", "ОТПРАВЛЯЕМ…", "ПРОВЕРЯЕМ…"][min(model.stageIndex, 2)]
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(0..<3, id: \.self) { i in
                let done = model.stageIndex > i, active = model.stageIndex == i
                HStack(alignment: .top, spacing: 12) {
                    VStack(spacing: 0) {
                        Circle().fill(done ? Color.lkAccent : (active ? Color.clear : Color.lkRaised)).frame(width: 14, height: 14)
                            .overlay(Circle().stroke(done || active ? Color.lkAccent : Color.lkTrack, lineWidth: 2))
                        if i < 2 { Rectangle().fill(done ? Color.lkAccent : Color.lkTrack).frame(width: 2).frame(minHeight: 28) }
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Self.steps[i].0).font(.lk(15, .bold)).foregroundStyle(done || active ? Color.lkText : Color.lkMuted)
                        Text(Self.steps[i].1).font(.lk(12, .medium)).foregroundStyle(Color.lkMuted)
                    }
                    Spacer()
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func row(_ it: UploadItem) -> some View {
        let (tag, color): (String, Color) = {
            switch it.state {
            case .queued: return ("В ОЧЕРЕДИ", .lkMuted)
            case .done: return ("ГОТОВО", .lkAccent)
            case .failed: return ("ОШИБКА", .lkDanger)
            case .active(let s, let f): return ("\(Int((UploadModel.weight(.init(stage: s, fraction: f)) * 100).rounded()))%", .lkWarn)
            }
        }()
        let frac: Double = {
            switch it.state {
            case .queued: return 0
            case .done, .failed: return 1
            case .active(let s, let f): return UploadModel.weight(.init(stage: s, fraction: f))
            }
        }()
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text(it.kind.label).font(.lkMono(10, .bold)).foregroundStyle(it.kind.tint)
                    .frame(width: 40, height: 40).background(Color.lkRaised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                Text(it.name).font(.lk(15, .bold)).lineLimit(1)
                Spacer()
                Text(tag).font(.lk(11, .heavy)).foregroundStyle(color)
            }
            ProgressView(value: frac).tint(color)
            if case .failed(let m) = it.state {
                Label(tr(m), systemImage: "exclamationmark.circle").font(.lk(13, .semibold)).foregroundStyle(Color.lkDanger)
            }
        }
        .padding(12).lkCard(radius: 16)
        .accessibilityElement(children: .combine)
    }
}
