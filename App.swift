import SwiftUI
import UserNotifications

// MARK: - Модели данных
struct Medication: Identifiable, Codable {
    let id: UUID
    var name: String
    var dosage: String
    var perDose: Int
    var scheduleTimes: [String]
    var totalCourse: Int
    
    init(id: UUID = UUID(), name: String, dosage: String = "", perDose: Int = 1, scheduleTimes: [String], totalCourse: Int = 0) {
        self.id = id
        self.name = name
        self.dosage = dosage
        self.perDose = perDose
        self.scheduleTimes = scheduleTimes
        self.totalCourse = totalCourse
    }
}

struct IntakeRecord: Codable {
    var medicationId: UUID
    var date: String
    var doseIndex: Int
    var taken: Bool
}

// MARK: - Data Manager
class DataManager: ObservableObject {
    @Published var medications: [Medication] = []
    @Published var intakes: [IntakeRecord] = []
    @Published var patientName: String = ""
    
    private let medicationsKey = "medications"
    private let intakesKey = "intakes"
    private let patientNameKey = "patientName"
    
    init() {
        loadData()
    }
    
    func loadData() {
        if let data = UserDefaults.standard.data(forKey: medicationsKey),
           let decoded = try? JSONDecoder().decode([Medication].self, from: data) {
            medications = decoded
        }
        
        if let data = UserDefaults.standard.data(forKey: intakesKey),
           let decoded = try? JSONDecoder().decode([IntakeRecord].self, from: data) {
            intakes = decoded
        }
        
        patientName = UserDefaults.standard.string(forKey: patientNameKey) ?? ""
    }
    
    func saveData() {
        if let encoded = try? JSONEncoder().encode(medications) {
            UserDefaults.standard.set(encoded, forKey: medicationsKey)
        }
        
        if let encoded = try? JSONEncoder().encode(intakes) {
            UserDefaults.standard.set(encoded, forKey: intakesKey)
        }
        
        UserDefaults.standard.set(patientName, forKey: patientNameKey)
    }
    
    func addMedication(_ medication: Medication) {
        medications.append(medication)
        medications.sort { $0.scheduleTimes.first ?? "00:00" < $1.scheduleTimes.first ?? "00:00" }
        saveData()
        scheduleNotifications(for: medication)
    }
    
    func deleteMedication(_ medication: Medication, keepHistory: Bool) {
        if !keepHistory {
            intakes.removeAll { $0.medicationId == medication.id }
        }
        medications.removeAll { $0.id == medication.id }
        saveData()
        cancelNotifications(for: medication.id)
    }
    
    func getTodaysDoses(for medication: Medication) -> [(index: Int, time: String, taken: Bool)] {
        let today = dateString()
        return medication.scheduleTimes.enumerated().map { index, time in
            let taken = intakes.contains { $0.medicationId == medication.id && $0.date == today && $0.doseIndex == index && $0.taken }
            return (index, time, taken)
        }
    }
    
    func markTaken(medicationId: UUID, doseIndex: Int) {
        let today = dateString()
        let record = IntakeRecord(medicationId: medicationId, date: today, doseIndex: doseIndex, taken: true)
        intakes.append(record)
        saveData()
        
        if let med = medications.first(where: { $0.id == medicationId }) {
            sendNotification(title: "✅ Принято!", body: patientName.isEmpty ? "Вы приняли \(med.name)" : "\(patientName), вы приняли \(med.name)")
        }
        
        checkAllTakenToday()
    }
    
    func checkAllTakenToday() {
        let today = dateString()
        var allTaken = true
        var hasAnyDose = false
        
        for med in medications {
            let doses = getTodaysDoses(for: med)
            if !doses.isEmpty { hasAnyDose = true }
            for dose in doses {
                if !dose.taken {
                    allTaken = false
                    break
                }
            }
            if !allTaken { break }
        }
        
        if hasAnyDose && allTaken && !medications.isEmpty {
            sendNotification(title: "🎉 Молодец! 🎉", body: patientName.isEmpty ? "На сегодня всё! Увидимся завтра ☀️" : "\(patientName), на сегодня всё! Увидимся завтра ☀️")
        }
    }
    
    func getStats(for period: String) -> (total: Int, taken: Int, percent: Double, dailyStats: [(date: String, taken: Int, total: Int)]) {
        let calendar = Calendar.current
        let today = Date()
        var startDate: Date
        
        switch period {
        case "week": startDate = calendar.date(byAdding: .day, value: -7, to: today)!
        case "month": startDate = calendar.date(byAdding: .month, value: -1, to: today)!
        case "halfyear": startDate = calendar.date(byAdding: .month, value: -6, to: today)!
        case "year": startDate = calendar.date(byAdding: .year, value: -1, to: today)!
        default: startDate = calendar.date(byAdding: .day, value: -7, to: today)!
        }
        
        var dailyStats: [(date: String, taken: Int, total: Int)] = []
        var totalDoses = 0
        var totalTaken = 0
        
        var currentDate = startDate
        while currentDate <= today {
            let dateStr = dateString(from: currentDate)
            var dayTotal = 0
            var dayTaken = 0
            
            for med in medications {
                for (index, _) in med.scheduleTimes.enumerated() {
                    dayTotal += 1
                    if intakes.contains(where: { $0.medicationId == med.id && $0.date == dateStr && $0.doseIndex == index && $0.taken }) {
                        dayTaken += 1
                    }
                }
            }
            
            dailyStats.append((date: dateStr, taken: dayTaken, total: dayTotal))
            totalDoses += dayTotal
            totalTaken += dayTaken
            currentDate = calendar.date(byAdding: .day, value: 1, to: currentDate)!
        }
        
        let percent = totalDoses > 0 ? Double(totalTaken) / Double(totalDoses) * 100 : 0
        return (totalDoses, totalTaken, percent, dailyStats)
    }
    
    func clearAllStats() {
        intakes.removeAll()
        saveData()
    }
    
    func clearStats(for medicationId: UUID) {
        intakes.removeAll { $0.medicationId == medicationId }
        saveData()
    }
    
    private func dateString(from date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
    
    private func scheduleNotifications(for medication: Medication) {
        let center = UNUserNotificationCenter.current()
        
        for (index, timeStr) in medication.scheduleTimes.enumerated() {
            let components = timeStr.split(separator: ":").map(String.init)
            guard components.count == 2,
                  let hour = Int(components[0]),
                  let minute = Int(components[1]) else { continue }
            
            var dateComponents = DateComponents()
            dateComponents.hour = hour
            dateComponents.minute = minute
            
            let trigger = UNCalendarNotificationTrigger(dateMatching: dateComponents, repeats: true)
            
            let content = UNMutableNotificationContent()
            content.title = patientName.isEmpty ? "💊 Пора принять таблетки!" : "💊 \(patientName), пора принять таблетки!"
            content.body = "\(medication.name) \(medication.dosage) (\(medication.perDose) шт)"
            content.sound = .default
            content.userInfo = ["medicationId": medication.id.uuidString, "doseIndex": index]
            
            let identifier = "\(medication.id.uuidString)_\(index)"
            let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
            
            center.add(request)
        }
    }
    
    private func cancelNotifications(for medicationId: UUID) {
        let center = UNUserNotificationCenter.current()
        for i in 0..<10 {
            center.removePendingNotificationRequests(withIdentifiers: ["\(medicationId.uuidString)_\(i)"])
        }
    }
    
    private func sendNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: trigger)
        
        UNUserNotificationCenter.current().add(request)
    }
    
    func rescheduleAllNotifications() {
        let center = UNUserNotificationCenter.current()
        center.removeAllPendingNotificationRequests()
        for med in medications {
            scheduleNotifications(for: med)
        }
    }
}

// MARK: - Content View
struct ContentView: View {
    @StateObject private var dataManager = DataManager()
    
    var body: some View {
        TabView {
            HomeView(dataManager: dataManager)
                .tabItem {
                    Label("Главная", systemImage: "pill")
                }
            HistoryView(dataManager: dataManager)
                .tabItem {
                    Label("История", systemImage: "calendar")
                }
            StatsView(dataManager: dataManager)
                .tabItem {
                    Label("Статистика", systemImage: "chart.bar")
                }
        }
        .onAppear {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        }
    }
}

// MARK: - Home View
struct HomeView: View {
    @ObservedObject var dataManager: DataManager
    @State private var showingAddMedication = false
    @State private var showingSettings = false
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 16) {
                    VStack(spacing: 8) {
                        Text("💊 Напоминалка")
                            .font(.largeTitle)
                            .fontWeight(.bold)
                            .foregroundStyle(LinearGradient(colors: [.purple, .blue], startPoint: .leading, endPoint: .trailing))
                        
                        if !dataManager.patientName.isEmpty {
                            Text("Привет, \(dataManager.patientName)! 🌸")
                                .font(.title2)
                        }
                        
                        Text(formatDate(Date()))
                            .font(.subheadline)
                            .foregroundColor(.gray)
                    }
                    .padding(.top)
                    
                    let todayStats = getTodayStats()
                    RoundedRectangle(cornerRadius: 20)
                        .fill(LinearGradient(colors: [.blue, .purple], startPoint: .leading, endPoint: .trailing))
                        .frame(height: 100)
                        .overlay(
                            HStack {
                                VStack(alignment: .leading) {
                                    Text("Сегодняшний прогресс")
                                        .font(.caption)
                                        .opacity(0.9)
                                    Text("\(todayStats.taken)/\(todayStats.total)")
                                        .font(.system(size: 32, weight: .bold))
                                }
                                Spacer()
                                Text("\(todayStats.percent)%")
                                    .font(.system(size: 28, weight: .bold))
                            }
                            .padding(.horizontal)
                            .foregroundColor(.white)
                        )
                        .padding(.horizontal)
                    
                    if dataManager.medications.isEmpty {
                        ContentUnavailableView(
                            "Нет лекарств",
                            systemImage: "pill",
                            description: Text("Нажмите + чтобы добавить")
                        )
                    } else {
                        ForEach(dataManager.medications) { med in
                            MedicationCardView(medication: med, dataManager: dataManager)
                        }
                    }
                }
                .padding(.bottom, 20)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: { showingAddMedication = true }) {
                        Image(systemName: "plus")
                    }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: { showingSettings = true }) {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .sheet(isPresented: $showingAddMedication) {
                AddMedicationView(dataManager: dataManager)
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView(dataManager: dataManager)
            }
        }
    }
    
    func getTodayStats() -> (total: Int, taken: Int, percent: Int) {
        var total = 0
        var taken = 0
        for med in dataManager.medications {
            let doses = dataManager.getTodaysDoses(for: med)
            total += doses.count
            taken += doses.filter { $0.taken }.count
        }
        let percent = total > 0 ? Int((Double(taken) / Double(total)) * 100) : 0
        return (total, taken, percent)
    }
    
    func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "EEEE, d MMMM"
        return formatter.string(from: date).capitalized
    }
}

// MARK: - Medication Card
struct MedicationCardView: View {
    let medication: Medication
    @ObservedObject var dataManager: DataManager
    @State private var showingDeleteOptions = false
    
    var body: some View {
        let doses = dataManager.getTodaysDoses(for: medication)
        let allTaken = doses.allSatisfy { $0.taken }
        let takenCount = doses.filter { $0.taken }.count
        
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading) {
                    Text(medication.name)
                        .font(.headline)
                    if !medication.dosage.isEmpty {
                        Text(medication.dosage)
                            .font(.caption)
                            .foregroundColor(.gray)
                    }
                    Text("\(medication.perDose) шт/прием")
                        .font(.caption2)
                        .foregroundColor(.blue)
                }
                Spacer()
                if medication.totalCourse > 0 {
                    Text("Курс: \(medication.totalCourse) шт")
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.orange.opacity(0.2))
                        .cornerRadius(8)
                }
            }
            
            HStack(spacing: 12) {
                ForEach(Array(doses.enumerated()), id: \.offset) { idx, dose in
                    Button(action: {
                        if !dose.taken {
                            dataManager.markTaken(medicationId: medication.id, doseIndex: dose.index)
                        }
                    }) {
                        ZStack {
                            Circle()
                                .fill(dose.taken ? Color.green : (dose.isPast ? Color.red.opacity(0.3) : Color.blue.opacity(0.3)))
                                .frame(width: 44, height: 44)
                            Text(dose.taken ? "✅" : (dose.isPast ? "❌" : "💊"))
                                .font(.title2)
                        }
                    }
                    .disabled(dose.taken)
                }
            }
            
            HStack {
                ForEach(medication.scheduleTimes, id: \.self) { time in
                    Text(formatTime(time))
                        .font(.caption)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color.gray.opacity(0.1))
                        .cornerRadius(12)
                }
            }
            
            HStack {
                Text(allTaken ? "✅ Все выпито" : "⏳ \(takenCount)/\(doses.count) приемов")
                    .font(.caption)
                    .foregroundColor(allTaken ? .green : .orange)
                Spacer()
                Button(action: { showingDeleteOptions = true }) {
                    Image(systemName: "trash")
                        .foregroundColor(.red)
                        .font(.caption)
                }
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(16)
        .shadow(color: .black.opacity(0.05), radius: 5)
        .padding(.horizontal)
        .confirmationDialog("Удалить \(medication.name)?", isPresented: $showingDeleteOptions) {
            Button("Удалить с историей", role: .destructive) {
                dataManager.deleteMedication(medication, keepHistory: false)
            }
            Button("Удалить без истории") {
                dataManager.deleteMedication(medication, keepHistory: true)
            }
            Button("Отмена", role: .cancel) { }
        }
    }
    
    func formatTime(_ time: String) -> String {
        let parts = time.split(separator: ":")
        guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]) else { return time }
        let hour12 = hour % 12 == 0 ? 12 : hour % 12
        let ampm = hour >= 12 ? "PM" : "AM"
        return "\(hour12):\(String(format: "%02d", minute)) \(ampm)"
    }
}

extension Date {
    var isPast: Bool {
        return self < Date()
    }
}

extension MedicationCardView {
    struct DoseStatus {
        let taken: Bool
        let isPast: Bool
    }
}

// MARK: - Add Medication View
struct AddMedicationView: View {
    @ObservedObject var dataManager: DataManager
    @Environment(\.dismiss) var dismiss
    
    @State private var name = ""
    @State private var dosage = ""
    @State private var perDose = 1
    @State private var totalCourse = 0
    @State private var scheduleTimes: [String] = ["09:00"]
    @State private var newTime = ""
    
    var body: some View {
        NavigationView {
            Form {
                Section("Информация") {
                    TextField("Название", text: $name)
                    TextField("Дозировка (например: 500мг)", text: $dosage)
                    Stepper("\(perDose) шт за прием", value: $perDose, in: 1...10)
                    Stepper(totalCourse > 0 ? "Курс: \(totalCourse) шт" : "Без курса", value: $totalCourse, in: 0...1000, step: 10)
                }
                
                Section("Время приема") {
                    ForEach(Array(scheduleTimes.enumerated()), id: \.offset) { idx, time in
                        HStack {
                            Text(time)
                            Spacer()
                            Button(action: {
                                scheduleTimes.remove(at: idx)
                            }) {
                                Image(systemName: "minus.circle")
                                    .foregroundColor(.red)
                            }
                        }
                    }
                    
                    HStack {
                        TextField("Новое время (09:00)", text: $newTime)
                            .keyboardType(.numbersAndPunctuation)
                        Button(action: addTime) {
                            Image(systemName: "plus.circle")
                                .foregroundColor(.green)
                        }
                        .disabled(!isValidTime(newTime))
                    }
                }
            }
            .navigationTitle("Добавить лекарство")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить") {
                        saveMedication()
                    }
                    .disabled(name.isEmpty || scheduleTimes.isEmpty)
                }
            }
        }
    }
    
    func addTime() {
        if isValidTime(newTime) && !scheduleTimes.contains(newTime) {
            scheduleTimes.append(newTime)
            scheduleTimes.sort()
            newTime = ""
        }
    }
    
    func isValidTime(_ time: String) -> Bool {
        let regex = try? NSRegularExpression(pattern: "^([01]?[0-9]|2[0-3]):[0-5][0-9]$")
        let range = NSRange(location: 0, length: time.utf16.count)
        return regex?.firstMatch(in: time, options: [], range: range) != nil
    }
    
    func saveMedication() {
        let med = Medication(
            name: name,
            dosage: dosage,
            perDose: perDose,
            scheduleTimes: scheduleTimes,
            totalCourse: totalCourse
        )
        dataManager.addMedication(med)
        dismiss()
    }
}

// MARK: - History View
struct HistoryView: View {
    @ObservedObject var dataManager: DataManager
    @State private var selectedPeriod = "week"
    
    let periods = ["week", "month", "halfyear", "year"]
    let periodNames = ["Неделя", "Месяц", "6 мес", "Год"]
    
    var body: some View {
        NavigationView {
            VStack {
                Picker("Период", selection: $selectedPeriod) {
                    ForEach(0..<periods.count, id: \.self) { i in
                        Text(periodNames[i]).tag(periods[i])
                    }
                }
                .pickerStyle(.segmented)
                .padding()
                
                let stats = dataManager.getStats(for: selectedPeriod)
                
                List {
                    Section {
                        VStack(spacing: 8) {
                            Text("\(Int(stats.percent))%")
                                .font(.system(size: 48, weight: .bold))
                                .foregroundColor(stats.percent >= 80 ? .green : .orange)
                            Text("выполнено")
                                .font(.caption)
                            Text("\(stats.taken) из \(stats.total) приемов")
                                .font(.subheadline)
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                    }
                    
                    Section("По дням") {
                        ForEach(stats.dailyStats.reversed(), id: \.date) { day in
                            let percent = day.total > 0 ? Int((Double(day.taken) / Double(day.total)) * 100) : 0
                            HStack {
                                Text(formatShortDate(day.date))
                                Spacer()
                                Text("\(day.taken)/\(day.total)")
                                    .font(.caption)
                                Text("(\(percent)%)")
                                    .font(.caption)
                                    .foregroundColor(percent == 100 ? .green : (percent > 0 ? .orange : .red))
                            }
                        }
                    }
                }
            }
            .navigationTitle("📊 История")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
    
    func formatShortDate(_ dateStr: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: dateStr) else { return dateStr }
        formatter.dateFormat = "d MMM"
        formatter.locale = Locale(identifier: "ru_RU")
        return formatter.string(from: date)
    }
}

// MARK: - Stats View
struct StatsView: View {
    @ObservedObject var dataManager: DataManager
    @State private var selectedPeriod = "week"
    
    let periods = ["week", "month", "halfyear", "year"]
    let periodNames = ["Неделя", "Месяц", "6 мес", "Год"]
    
    var body: some View {
        NavigationView {
            VStack {
                Picker("Период", selection: $selectedPeriod) {
                    ForEach(0..<periods.count, id: \.self) { i in
                        Text(periodNames[i]).tag(periods[i])
                    }
                }
                .pickerStyle(.segmented)
                .padding()
                
                let stats = dataManager.getStats(for: selectedPeriod)
                
                List {
                    Section("Общая статистика") {
                        HStack {
                            VStack {
                                Text("\(stats.total)")
                                    .font(.title2)
                                    .bold()
                                Text("всего приемов")
                                    .font(.caption)
                            }
                            Spacer()
                            VStack {
                                Text("\(stats.taken)")
                                    .font(.title2)
                                    .bold()
                                Text("выполнено")
                                    .font(.caption)
                            }
                            Spacer()
                            VStack {
                                Text("\(Int(stats.percent))%")
                                    .font(.title2)
                                    .bold()
                                Text("эффективность")
                                    .font(.caption)
                            }
                        }
                        .padding()
                    }
                    
                    Section("По лекарствам") {
                        ForEach(dataManager.medications) { med in
                            let medStats = getMedicationStats(med)
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text(med.name)
                                        .font(.headline)
                                    Spacer()
                                    Text("\(medStats.taken)/\(medStats.total)")
                                        .font(.caption)
                                    Text("(\(Int(medStats.percent))%)")
                                        .font(.caption)
                                        .foregroundColor(medStats.percent >= 80 ? .green : .orange)
                                }
                                
                                ProgressView(value: medStats.percent, total: 100)
                                    .tint(medStats.percent >= 80 ? .green : .orange)
                            }
                            .padding(.vertical, 4)
                            .swipeActions {
                                Button("Очистить статистику", role: .destructive) {
                                    dataManager.clearStats(for: med.id)
                                }
                            }
                        }
                    }
                    
                    Button("Очистить всю статистику", role: .destructive) {
                        dataManager.clearAllStats()
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("📈 Статистика")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
    
    func getMedicationStats(_ med: Medication) -> (total: Int, taken: Int, percent: Double) {
        let stats = dataManager.getStats(for: selectedPeriod)
        var total = 0
        var taken = 0
        
        for day in stats.dailyStats {
            for doseIndex in 0..<med.scheduleTimes.count {
                total += 1
                if dataManager.intakes.contains(where: { $0.medicationId == med.id && $0.date == day.date && $0.doseIndex == doseIndex && $0.taken }) {
                    taken += 1
                }
            }
        }
        
        let percent = total > 0 ? Double(taken) / Double(total) * 100 : 0
        return (total, taken, percent)
    }
}

// MARK: - Settings View
struct SettingsView: View {
    @ObservedObject var dataManager: DataManager
    @Environment(\.dismiss) var dismiss
    @State private var tempName: String = ""
    
    var body: some View {
        NavigationView {
            Form {
                Section("Персонализация") {
                    TextField("Как к вам обращаться?", text: $tempName)
                        .textInputAutocapitalization(.words)
                    Text("Будет использоваться в приветствиях и уведомлениях")
                        .font(.caption)
                        .foregroundColor(.gray)
                }
                
                Section("Данные") {
                    Button("Экспорт данных") {
                        exportData()
                    }
                    Button("Импорт данных") {
                        importData()
                    }
                }
                
                Section("О приложении") {
                    HStack {
                        Text("Версия")
                        Spacer()
                        Text("1.0.0")
                            .foregroundColor(.gray)
                    }
                }
            }
            .navigationTitle("Настройки")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить") {
                        dataManager.patientName = tempName
                        dataManager.saveData()
                        dataManager.rescheduleAllNotifications()
                        dismiss()
                    }
                }
            }
            .onAppear {
                tempName = dataManager.patientName
            }
        }
    }
    
    func exportData() {
        let data: [String: Any] = [
            "medications": dataManager.medications.map { ["id": $0.id.uuidString, "name": $0.name, "dosage": $0.dosage, "perDose": $0.perDose, "scheduleTimes": $0.scheduleTimes, "totalCourse": $0.totalCourse] },
            "intakes": dataManager.intakes.map { ["medicationId": $0.medicationId.uuidString, "date": $0.date, "doseIndex": $0.doseIndex, "taken": $0.taken] },
            "patientName": dataManager.patientName
        ]
        
        if let jsonData = try? JSONSerialization.data(withJSONObject: data, options: .prettyPrinted),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "yyyyMMdd_HHmmss"
            let filename = "medications_\(dateFormatter.string(from: Date())).json"
            
            let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
            try? jsonString.write(to: tempURL, atomically: true, encoding: .utf8)
            
            let activityVC = UIActivityViewController(activityItems: [tempURL], applicationActivities: nil)
            if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
               let rootVC = windowScene.windows.first?.rootViewController {
                rootVC.present(activityVC, animated: true)
            }
        }
    }
    
    func importData() {
        let documentPicker = UIDocumentPickerViewController(forOpeningContentTypes: [.json])
        documentPicker.allowsMultipleSelection = false
        
        documentPicker.delegate = ImportDelegate(dataManager: dataManager)
        
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let rootVC = windowScene.windows.first?.rootViewController {
            rootVC.present(documentPicker, animated: true)
        }
    }
}

class ImportDelegate: NSObject, UIDocumentPickerDelegate {
    let dataManager: DataManager
    
    init(dataManager: DataManager) {
        self.dataManager = dataManager
    }
    
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        
        do {
            let data = try Data(contentsOf: url)
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let medicationsData = json["medications"] as? [[String: Any]] {
                    var newMedications: [Medication] = []
                    for medData in medicationsData {
                        if let idString = medData["id"] as? String,
                           let id = UUID(uuidString: idString),
                           let name = medData["name"] as? String,
                           let scheduleTimes = medData["scheduleTimes"] as? [String] {
                            let med = Medication(
                                id: id,
                                name: name,
                                dosage: medData["dosage"] as? String ?? "",
                                perDose: medData["perDose"] as? Int ?? 1,
                                scheduleTimes: scheduleTimes,
                                totalCourse: medData["totalCourse"] as? Int ?? 0
                            )
                            newMedications.append(med)
                        }
                    }
                    dataManager.medications = newMedications
                }
                
                if let intakesData = json["intakes"] as? [[String: Any]] {
                    var newIntakes: [IntakeRecord] = []
                    for intakeData in intakesData {
                        if let idString = intakeData["medicationId"] as? String,
                           let id = UUID(uuidString: idString),
                           let date = intakeData["date"] as? String,
                           let doseIndex = intakeData["doseIndex"] as? Int,
                           let taken = intakeData["taken"] as? Bool {
                            let intake = IntakeRecord(medicationId: id, date: date, doseIndex: doseIndex, taken: taken)
                            newIntakes.append(intake)
                        }
                    }
                    dataManager.intakes = newIntakes
                }
                
                if let patientName = json["patientName"] as? String {
                    dataManager.patientName = patientName
                }
                
                dataManager.saveData()
                dataManager.rescheduleAllNotifications()
                
                let alert = UIAlertController(title: "✅ Импорт выполнен", message: "Данные успешно загружены", preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "OK", style: .default))
                if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                   let rootVC = windowScene.windows.first?.rootViewController {
                    rootVC.present(alert, animated: true)
                }
            }
        } catch {
            let alert = UIAlertController(title: "Ошибка", message: "Не удалось импортировать данные", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
               let rootVC = windowScene.windows.first?.rootViewController {
                rootVC.present(alert, animated: true)
            }
        }
    }
}

@main
struct PillReminderApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
