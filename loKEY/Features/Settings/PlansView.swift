import SwiftUI

/// Хранилище и тариф. Покупка — через StoreKit на устройстве, затем подтверждение на сервере (BillingAPI.purchase).
struct PlansView: View {
    @Environment(AppStore.self) private var store

    @State private var plans: [StoragePlan] = []
    @State private var sub: PlanSubscription?
    @State private var loading = true
    @State private var loadError: String?
    @State private var busyID: String?
    @State private var confirmCancel = false

    var body: some View {
        VStack(spacing: 0) {
            LKTopBar(title: "Хранилище и тариф") { Color.clear }.padding(.horizontal, 20).padding(.top, 8)
            content
        }
        .lkScreen()
        .navigationBarBackButtonHidden(true).toolbar(.hidden, for: .navigationBar)
        .task { await load() }
        .confirmationDialog("Отменить подписку?", isPresented: $confirmCancel, titleVisibility: .visible) {
            Button("Отменить подписку", role: .destructive) { Task { await cancel() } }
            Button("Оставить", role: .cancel) {}
        } message: { Text("Объём останется до конца оплаченного периода. Файлы не удаляются, но новые не загрузятся, если места не хватит.") }
    }

    @ViewBuilder private var content: some View {
        if loading && plans.isEmpty {
            Spacer(); ProgressView().tint(Color.lkAccent); Spacer()
        } else if let loadError, plans.isEmpty {
            Spacer()
            VStack(spacing: 14) {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 34)).foregroundStyle(Color.lkWarn)
                Text(loadError).font(.lk(15, .medium)).foregroundStyle(Color.lkText2).multilineTextAlignment(.center)
                Button("Повторить") { Task { await load() } }.buttonStyle(.lkSecondary).frame(maxWidth: 200)
            }.padding(24)
            Spacer()
        } else {
            ScrollView {
                VStack(spacing: 14) {
                    usage
                    ForEach(Array(plans.enumerated()), id: \.element.id) { i, p in card(p).lkAppear(i) }
                    Text("Шифрование одинаково на всех тарифах: сервер не видит содержимое файлов. Оплата проходит через App Store, подписку можно отменить в любой момент.")
                        .font(.lk(12, .medium)).foregroundStyle(Color.lkMuted).multilineTextAlignment(.center).padding(.top, 4)
                }
                .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 40)
            }
        }
    }

    private var usage: some View {
        let st = store.storage
        return VStack(alignment: .leading, spacing: 10) {
            Text("СЕЙЧАС ЗАНЯТО").font(.lk(11, .heavy)).tracking(0.8).foregroundStyle(Color.lkMuted)
            HStack(alignment: .firstTextBaseline) {
                Text(LKFormat.bytes(st?.usedBytes ?? 0)).font(.lk(28, .heavy)).tracking(-0.6)
                    .contentTransition(.numericText())
                Text(verbatim: trf("из %@", LKFormat.bytes(st?.limitBytes ?? 0))).font(.lk(15, .semibold)).foregroundStyle(Color.lkMuted)
            }
            ProgressView(value: st?.fraction ?? 0).tint(Color.lkAccent)
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading).lkCard(radius: 22)
    }

    private func card(_ p: StoragePlan) -> some View {
        let current = sub?.planID == p.id && sub?.state != .expired
        let rank = plans.firstIndex(where: { $0.id == p.id }) ?? 0
        let curRank = plans.firstIndex(where: { $0.id == sub?.planID }) ?? 0
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(tr(p.title)).font(.lk(18, .heavy))
                if current {
                    Text(sub?.state == .cancelled ? "ОТМЕНЁН" : "ТЕКУЩИЙ").font(.lk(10, .heavy)).tracking(0.6)
                        .foregroundStyle(sub?.state == .cancelled ? Color.lkWarn : Color.lkAccent)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background((sub?.state == .cancelled ? Color.lkWarn : Color.lkAccent).opacity(0.14), in: Capsule())
                }
                Spacer()
                Text(price(p)).font(.lk(16, .bold))
            }
            HStack(spacing: 6) {
                Image(systemName: "externaldrive.fill").foregroundStyle(Color.lkAccent)
                Text(verbatim: trf("%@ зашифрованного места", LKFormat.bytes(p.storageBytes))).font(.lk(14, .semibold)).foregroundStyle(Color.lkText2)
            }
            if current, let r = sub?.renewsAt {
                Text(verbatim: sub?.state == .cancelled ? trf("Действует до %@", Self.date.string(from: r)) : trf("Продление %@", Self.date.string(from: r)))
                    .font(.lk(12, .medium)).foregroundStyle(Color.lkMuted)
            }
            if current {
                if p.period != .free && sub?.state == .active {
                    Button("Отменить подписку") { confirmCancel = true }.buttonStyle(.lkSecondary).foregroundStyle(Color.lkDanger)
                }
            } else {
                Button { Task { await buy(p) } } label: {
                    if busyID == p.id { ProgressView().tint(Color.lkBg) }
                    else { Text(verbatim: rank > curRank ? trf("Перейти на «%@»", tr(p.title)) : trf("Выбрать «%@»", tr(p.title))) }
                }
                .buttonStyle(.lkPrimary).disabled(busyID != nil)
            }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .lkCard(radius: 22, stroke: current ? Color.lkAccent.opacity(0.6) : .lkBorderSoft)
    }

    private func price(_ p: StoragePlan) -> String {
        guard p.period != .free else { return "Бесплатно" }
        let f = NumberFormatter(); f.numberStyle = .currency; f.currencyCode = p.currency
        let v = f.string(from: NSNumber(value: Double(p.priceMinor) / 100)) ?? "\(p.priceMinor / 100) \(p.currency)"
        return v + " " + tr(p.period == .year ? "/ год" : "/ мес")
    }
    private static var date: DateFormatter {
        let f = DateFormatter(); f.locale = LKBundle.uiLocale; f.dateStyle = .medium; return f
    }

    private func load() async {
        loading = true; loadError = nil
        defer { loading = false }
        do {
            async let p = store.repo.plans(); async let s = store.repo.subscription()
            plans = try await p; sub = try await s
            await store.refreshCases()
        } catch { loadError = (error as? VaultError)?.message ?? "Не удалось загрузить тарифы" }
    }
    private func buy(_ p: StoragePlan) async {
        busyID = p.id; defer { busyID = nil }
        do {
            // TODO(StoreKit): здесь вызвать Product.purchase() и передать transaction.jwsRepresentation.
            sub = try await store.repo.purchase(planID: p.id, transaction: nil)
            await store.refreshCases(); Haptics.success(); store.showToast(trf("Тариф «%@» подключён", tr(p.title)))
        } catch { store.showError(error) }
    }
    private func cancel() async {
        do { sub = try await store.repo.cancelSubscription(); Haptics.success(); store.showToast("Подписка отменена") }
        catch { store.showError(error) }
    }
}
