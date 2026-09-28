import SwiftUI
import UserNotifications
import UIKit

// MARK: - Modèles de données

enum PaymentMode: String, Codable {
    case single
    case installments
}

struct Installment: Identifiable, Codable {
    var id = UUID()
    var date: Date
    var amount: Double
    var isPaid: Bool = false
}

struct Payment: Identifiable, Codable {
    var id = UUID()
    var name: String
    var mode: PaymentMode = .single

    // Mode "single"
    var amount: Double = 0
    var dueDate: Int = 1 // jour du mois (1 à 31)
    var isPaid: Bool = false

    // Mode "installments" (plusieurs fois)
    var installments: [Installment] = []

    // Infos pour payer manuellement (optionnel)
    var beneficiaryName: String = ""
    var beneficiaryIban: String = ""
    var communication: String = ""

    var totalAmount: Double {
        mode == .installments ? installments.reduce(0) { $0 + $1.amount } : amount
    }

    var paidAmount: Double {
        if mode == .installments {
            return installments.filter { $0.isPaid }.reduce(0) { $0 + $1.amount }
        }
        return isPaid ? amount : 0
    }
}

// MARK: - Gestionnaire de données et des notifications

class PaymentManager: ObservableObject {
    @Published var payments: [Payment] = [] {
        didSet { savePayments() }
    }

    private let saveKey = "SavedPayments"

    init() {
        requestNotificationPermission()
        loadPayments()
    }

    var totalAmount: Double { payments.reduce(0) { $0 + $1.totalAmount } }
    var totalPaid: Double { payments.reduce(0) { $0 + $1.paidAmount } }
    var totalRemaining: Double { totalAmount - totalPaid }

    func savePayments() {
        if let encoded = try? JSONEncoder().encode(payments) {
            UserDefaults.standard.set(encoded, forKey: saveKey)
        }
    }

    func loadPayments() {
        if let data = UserDefaults.standard.data(forKey: saveKey),
           let decoded = try? JSONDecoder().decode([Payment].self, from: data) {
            payments = decoded
        }
    }

    func togglePaid(paymentID: UUID) {
        guard let idx = payments.firstIndex(where: { $0.id == paymentID }) else { return }
        payments[idx].isPaid.toggle()
    }

    func toggleInstallment(paymentID: UUID, installmentID: UUID) {
        guard let pIdx = payments.firstIndex(where: { $0.id == paymentID }),
              let iIdx = payments[pIdx].installments.firstIndex(where: { $0.id == installmentID }) else { return }
        payments[pIdx].installments[iIdx].isPaid.toggle()
    }

    // Divise un montant total en "count" parts égales (le reste est ajouté à la dernière échéance)
    static func splitAmount(_ total: Double, into count: Int) -> [Double] {
        guard count > 0 else { return [] }
        let base = (total / Double(count) * 100).rounded() / 100
        var amounts = Array(repeating: base, count: count)
        let distributed = base * Double(count)
        let diff = ((total - distributed) * 100).rounded() / 100
        amounts[count - 1] += diff
        return amounts
    }

    // Génère "count" dates mensuelles à partir d'une date de départ, même jour chaque mois
    static func generateMonthlyDates(from start: Date, count: Int) -> [Date] {
        let calendar = Calendar.current
        var dates: [Date] = []
        for k in 0..<count {
            if let d = calendar.date(byAdding: .month, value: k, to: start) {
                dates.append(d)
            }
        }
        return dates
    }

    // --- GESTION DES NOTIFICATIONS ---

    func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            if granted { print("Permission de notification accordée") }
        }
    }

    // Rappel mensuel récurrent pour un paiement simple (ex: loyer)
    func scheduleMonthlyNotification(for payment: Payment) {
        guard payment.mode == .single else { return }
        let content = UNMutableNotificationContent()
        content.title = "Rappel de paiement 💳"
        content.body = "N'oubliez pas de régler : \(payment.name) (\(String(format: "%.2f €", payment.amount)))"
        content.sound = .default

        var dateComponents = DateComponents()
        dateComponents.day = payment.dueDate
        dateComponents.hour = 9
        dateComponents.minute = 0

        let trigger = UNCalendarNotificationTrigger(dateMatching: dateComponents, repeats: true)
        let request = UNNotificationRequest(identifier: payment.id.uuidString, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request)
    }

    // Un rappel par échéance, à sa date précise, chaque mois automatiquement
    func scheduleInstallmentNotifications(for payment: Payment) {
        guard payment.mode == .installments else { return }
        let calendar = Calendar.current
        for installment in payment.installments {
            let content = UNMutableNotificationContent()
            content.title = "Rappel de paiement 💳"
            content.body = "Versement à régler : \(payment.name) (\(String(format: "%.2f €", installment.amount)))"
            content.sound = .default

            var comps = calendar.dateComponents([.year, .month, .day], from: installment.date)
            comps.hour = 9
            comps.minute = 0

            // repeats: false car chaque échéance a sa propre date unique
            let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
            let request = UNNotificationRequest(identifier: installment.id.uuidString, content: content, trigger: trigger)
            UNUserNotificationCenter.current().add(request)
        }
    }

    func cancelNotification(for payment: Payment) {
        var ids = [payment.id.uuidString]
        ids.append(contentsOf: payment.installments.map { $0.id.uuidString })
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
    }
}

// MARK: - Vue principale

struct ContentView: View {
    @StateObject private var manager = PaymentManager()
    @State private var showingAddPayment = false

    var body: some View {
        NavigationView {
            VStack {
                HStack(spacing: 15) {
                    SummaryCard(title: "Total", amount: manager.totalAmount, color: .blue)
                    SummaryCard(title: "Payé", amount: manager.totalPaid, color: .green)
                    SummaryCard(title: "Reste", amount: manager.totalRemaining, color: .orange)
                }
                .padding()

                List {
                    ForEach(manager.payments) { payment in
                        PaymentRow(payment: payment, manager: manager)
                    }
                    .onDelete(perform: deletePayment)
                }
            }
            .navigationTitle("Paiements du mois")
            .toolbar {
                Button(action: { showingAddPayment = true }) {
                    Image(systemName: "plus")
                }
            }
            .sheet(isPresented: $showingAddPayment) {
                AddPaymentView(manager: manager)
            }
        }
    }

    func deletePayment(at offsets: IndexSet) {
        for index in offsets {
            manager.cancelNotification(for: manager.payments[index])
        }
        manager.payments.remove(atOffsets: offsets)
    }
}

// MARK: - Ligne d'un paiement (simple ou en plusieurs fois)

struct PaymentRow: View {
    let payment: Payment
    @ObservedObject var manager: PaymentManager
    @State private var payDetail: (name: String, amount: Double)? = nil

    var body: some View {
        Group {
            if payment.mode == .installments {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(payment.name).font(.headline)
                            let paidCount = payment.installments.filter { $0.isPaid }.count
                            Text("📅 \(paidCount)/\(payment.installments.count) versements payés")
                                .font(.caption)
                                .foregroundColor(.gray)
                        }
                        Spacer()
                        Text(String(format: "%.2f €", payment.totalAmount))
                            .font(.callout).bold()
                    }
                    ForEach(payment.installments) { installment in
                        HStack {
                            Button(action: {
                                manager.toggleInstallment(paymentID: payment.id, installmentID: installment.id)
                            }) {
                                Image(systemName: installment.isPaid ? "checkmark.circle.fill" : "circle")
                                    .foregroundColor(installment.isPaid ? .green : .gray)
                            }
                            .buttonStyle(BorderlessButtonStyle())
                            Text(installment.date, style: .date)
                                .font(.caption)
                                .foregroundColor(.gray)
                            Spacer()
                            Text(String(format: "%.2f €", installment.amount))
                                .font(.caption).bold()
                            if !payment.beneficiaryIban.isEmpty {
                                Button(action: { payDetail = (payment.name, installment.amount) }) {
                                    Image(systemName: "building.columns")
                                        .foregroundColor(.blue)
                                }
                                .buttonStyle(BorderlessButtonStyle())
                            }
                        }
                        .padding(.leading, 8)
                    }
                }
                .padding(.vertical, 4)
            } else {
                HStack {
                    VStack(alignment: .leading) {
                        Text(payment.name).font(.headline)
                        HStack {
                            Image(systemName: "bell.fill").font(.caption2).foregroundColor(.blue)
                            Text("Rappel le \(payment.dueDate) du mois à 09:00")
                                .font(.caption).foregroundColor(.gray)
                        }
                    }
                    Spacer()
                    Text(String(format: "%.2f €", payment.amount)).font(.callout).bold()
                    if !payment.beneficiaryIban.isEmpty {
                        Button(action: { payDetail = (payment.name, payment.amount) }) {
                            Image(systemName: "building.columns")
                                .foregroundColor(.blue)
                        }
                        .buttonStyle(BorderlessButtonStyle())
                    }
                    Button(action: { manager.togglePaid(paymentID: payment.id) }) {
                        Image(systemName: payment.isPaid ? "checkmark.circle.fill" : "circle")
                            .foregroundColor(payment.isPaid ? .green : .gray)
                            .font(.title2)
                    }
                    .buttonStyle(BorderlessButtonStyle())
                }
            }
        }
        .sheet(item: Binding(
            get: { payDetail.map { PayDetailItem(name: $0.name, amount: $0.amount) } },
            set: { _ in payDetail = nil }
        )) { item in
            PaymentDetailSheet(
                beneficiaryName: payment.beneficiaryName.isEmpty ? item.name : payment.beneficiaryName,
                iban: payment.beneficiaryIban,
                amount: item.amount,
                communication: payment.communication
            )
        }
    }
}

struct PayDetailItem: Identifiable {
    let name: String
    let amount: Double
    var id: String { name + String(amount) }
}

// MARK: - Fenêtre "payer manuellement" avec copier-coller

struct PaymentDetailSheet: View {
    let beneficiaryName: String
    let iban: String
    let amount: Double
    let communication: String
    @Environment(\.dismiss) var dismiss
    @State private var copiedField: String? = nil

    var body: some View {
        NavigationView {
            List {
                Section(footer: Text("Ouvre ton app bancaire, crée un virement, et colle chaque info.")) {
                    copyRow(label: "Bénéficiaire", value: beneficiaryName)
                    if !iban.isEmpty { copyRow(label: "IBAN", value: iban) }
                    copyRow(label: "Montant", value: String(format: "%.2f €", amount))
                    if !communication.isEmpty { copyRow(label: "Communication", value: communication) }
                }
            }
            .navigationTitle("Payer manuellement")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fermer") { dismiss() }
                }
            }
        }
    }

    func copyRow(label: String, value: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.caption).foregroundColor(.gray)
                Text(value).font(.body)
            }
            Spacer()
            Button(copiedField == label ? "✓ Copié" : "Copier") {
                UIPasteboard.general.string = value
                copiedField = label
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    if copiedField == label { copiedField = nil }
                }
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

struct SummaryCard: View {
    let title: String
    let amount: Double
    let color: Color

    var body: some View {
        VStack {
            Text(title).font(.caption).foregroundColor(.secondary)
            Text(String(format: "%.0f €", amount)).font(.headline).foregroundColor(color)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(10)
    }
}

// MARK: - Ajout d'un paiement

struct AddPaymentView: View {
    @ObservedObject var manager: PaymentManager
    @Environment(\.dismiss) var dismiss

    @State private var name = ""
    @State private var isInstallments = false
    @State private var beneficiaryName = ""
    @State private var beneficiaryIban = ""
    @State private var communication = ""

    // Mode simple
    @State private var amount = ""
    @State private var dueDate = 1

    // Mode plusieurs fois
    @State private var totalAmount = ""
    @State private var installmentCount = 3
    @State private var firstDate = Date()

    private var previewText: String {
        guard let total = Double(totalAmount.replacingOccurrences(of: ",", with: ".")), total > 0 else {
            return "Complète le montant total ci-dessus."
        }
        let amounts = PaymentManager.splitAmount(total, into: installmentCount)
        let dates = PaymentManager.generateMonthlyDates(from: firstDate, count: installmentCount)
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        let first = dates.first.map { formatter.string(from: $0) } ?? ""
        let last = dates.last.map { formatter.string(from: $0) } ?? ""
        return "\(installmentCount)x \(String(format: "%.2f €", amounts.first ?? 0)) environ, du \(first) au \(last)."
    }

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Détails du paiement")) {
                    TextField("Nom (ex: Loyer, Netflix, Canapé)", text: $name)
                    Toggle("Payer en plusieurs fois", isOn: $isInstallments)
                }

                Section(header: Text("Pour payer manuellement (optionnel)")) {
                    TextField("Nom du bénéficiaire", text: $beneficiaryName)
                    TextField("IBAN du bénéficiaire", text: $beneficiaryIban)
                        .autocapitalization(.allCharacters)
                    TextField("Communication", text: $communication)
                }

                if isInstallments {
                    Section(header: Text("Plusieurs fois")) {
                        TextField("Montant total (€)", text: $totalAmount)
                            .keyboardType(.decimalPad)
                        Stepper("Nombre de fois : \(installmentCount)", value: $installmentCount, in: 2...60)
                        DatePicker("Date du 1er prélèvement", selection: $firstDate, displayedComponents: .date)
                        Text(previewText)
                            .font(.caption)
                            .foregroundColor(.gray)
                    }
                } else {
                    Section(header: Text("Montant et rappel")) {
                        TextField("Montant (€)", text: $amount)
                            .keyboardType(.decimalPad)
                        Stepper("Jour du prélèvement : \(dueDate)", value: $dueDate, in: 1...31)
                        Text("Une notification vous sera envoyée automatiquement tous les mois le \(dueDate) à 09:00.")
                            .font(.caption)
                            .foregroundColor(.gray)
                    }
                }
            }
            .navigationTitle("Nouveau paiement")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Ajouter") { addPayment() }
                }
            }
        }
    }

    func addPayment() {
        guard !name.isEmpty else { return }
        let cleanIban = beneficiaryIban.replacingOccurrences(of: " ", with: "").uppercased()

        if isInstallments {
            guard let total = Double(totalAmount.replacingOccurrences(of: ",", with: ".")), total > 0 else { return }
            let amounts = PaymentManager.splitAmount(total, into: installmentCount)
            let dates = PaymentManager.generateMonthlyDates(from: firstDate, count: installmentCount)
            let installments = zip(dates, amounts).map { Installment(date: $0, amount: $1) }
            let newPayment = Payment(name: name, mode: .installments, installments: installments,
                                      beneficiaryName: beneficiaryName, beneficiaryIban: cleanIban, communication: communication)
            manager.payments.append(newPayment)
            manager.scheduleInstallmentNotifications(for: newPayment)
        } else {
            guard let doubleAmount = Double(amount.replacingOccurrences(of: ",", with: ".")) else { return }
            let newPayment = Payment(name: name, mode: .single, amount: doubleAmount, dueDate: dueDate, isPaid: false,
                                      beneficiaryName: beneficiaryName, beneficiaryIban: cleanIban, communication: communication)
            manager.payments.append(newPayment)
            manager.scheduleMonthlyNotification(for: newPayment)
        }

        dismiss()
    }
}
