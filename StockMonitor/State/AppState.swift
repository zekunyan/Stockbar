import SwiftUI
import Combine
import AppKit
import os

@MainActor
final class AppState: ObservableObject {

    // MARK: - 持久化（settings.json）

    @Published var config: AppSettings = AppSettings() {
        didSet { saveSettings(config); refreshStatusBarSegments() }
    }

    // MARK: - 持久化（stocks.json）

    @Published var stocks: [Stock] = [] {
        didSet { saveStocks(stocks); refreshStatusBarSegments() }
    }

    // MARK: - 持久化（watchlists.json）

    @Published var watchlists: [Watchlist] = [] {
        didSet { saveWatchlists(watchlists) }
    }

    // MARK: - 实时状态

    @Published var quotes: [String: Quote]      = [:] { didSet { refreshStatusBarSegments() } }
    @Published var exchangeRates: ExchangeRates = ExchangeRates()
    @Published var isLoading: Bool              = false
    @Published var lastUpdateTime: Date?        = nil
    @Published var hasError: Bool               = false

    /// 状态栏展示片段（@Published，quotes/config/stocks 变化时自动更新）
    @Published var statusBarSegments: [StatusBarSegment] = []
    /// 当前轮播索引
    @Published var statusBarCurrentIndex: Int = 0

    private var rotationTimer: Timer?

    // MARK: - 文件路径

    private static var appSupportDir: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = support.appendingPathComponent("Stockbar")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static var stocksFileURL:     URL { appSupportDir.appendingPathComponent("stocks.json")     }
    private static var settingsFileURL:   URL { appSupportDir.appendingPathComponent("settings.json")   }
    private static var watchlistsFileURL: URL { appSupportDir.appendingPathComponent("watchlists.json") }

    // MARK: - 加载

    private static func loadStocks() -> [Stock] {
        guard let data = try? Data(contentsOf: stocksFileURL),
              let val  = try? JSONDecoder().decode([Stock].self, from: data) else { return [] }
        return val
    }

    private static func loadSettings() -> AppSettings {
        guard let data = try? Data(contentsOf: settingsFileURL),
              let val  = try? JSONDecoder().decode(AppSettings.self, from: data) else { return AppSettings() }
        return val
    }

    private static func loadWatchlists() -> [Watchlist] {
        guard let data = try? Data(contentsOf: watchlistsFileURL),
              let val  = try? JSONDecoder().decode([Watchlist].self, from: data) else { return [] }
        return val
    }

    // MARK: - 保存

    private func saveStocks(_ stocks: [Stock]) {
        if stocks.isEmpty, !Self.loadStocks().isEmpty { return }
        guard let data = try? JSONEncoder().encode(stocks) else { return }
        Self.backupIfNeeded()
        do {
            try data.write(to: Self.stocksFileURL, options: .atomic)
        } catch {
            logToFile("saveStocks: failed to write stocks.json: \(error)")
        }
    }

    private func saveWatchlists(_ list: [Watchlist]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        guard let data = try? encoder.encode(list) else { return }
        try? data.write(to: Self.watchlistsFileURL, options: .atomic)
    }

    private func saveSettings(_ settings: AppSettings) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        guard let data = try? encoder.encode(settings) else { return }
        do {
            try data.write(to: Self.settingsFileURL, options: .atomic)
        } catch {
            logToFile("saveSettings: failed to write settings.json: \(error)")
        }
    }

    /// 滚动备份 stocks.json，最多保留 10 份
    private static func backupIfNeeded() {
        let fm  = FileManager.default
        let src = stocksFileURL
        guard fm.fileExists(atPath: src.path) else { return }
        let dir = src.deletingLastPathComponent()
        for i in stride(from: 9, through: 1, by: -1) {
            let from = dir.appendingPathComponent("stocks.\(i).json")
            let to   = dir.appendingPathComponent("stocks.\(i + 1).json")
            if fm.fileExists(atPath: from.path) {
                do { try fm.removeItem(at: to) } catch { logToFile("backupIfNeeded: removeItem \(to.lastPathComponent) failed: \(error)") }
                do { try fm.moveItem(at: from, to: to) } catch { logToFile("backupIfNeeded: moveItem \(from.lastPathComponent) -> \(to.lastPathComponent) failed: \(error)") }
            }
        }
        let backup = dir.appendingPathComponent("stocks.1.json")
        do { try fm.removeItem(at: backup) } catch { logToFile("backupIfNeeded: removeItem \(backup.lastPathComponent) failed: \(error)") }
        do { try fm.copyItem(at: src, to: backup) } catch { logToFile("backupIfNeeded: copyItem to \(backup.lastPathComponent) failed: \(error)") }
    }

    // MARK: - 设置快捷访问（视图直接绑定这些属性）

    var statusBarStockId: String {
        get { config.statusBarStockId }
        set { config.statusBarStockId = newValue }
    }

    var statusBarStockIds: [String] {
        get { config.statusBarStockIds }
        set { config.statusBarStockIds = newValue }
    }

    var refreshInterval: Int {
        get { config.refreshInterval }
        set { config.refreshInterval = newValue }
    }

    var colorScheme: ColorTheme {
        get { config.colorScheme }
        set { config.colorScheme = newValue }
    }

    var displayCurrency: DisplayCurrency {
        get { config.displayCurrency }
        set { config.displayCurrency = newValue }
    }

    // MARK: - 刷新调度

    private var scheduler: RefreshScheduler?

    init() {
        appLogger.info("AppState init start")
        logToFile("AppState init start")
        _stocks     = Published(wrappedValue: Self.loadStocks())
        _config     = Published(wrappedValue: Self.loadSettings())
        _watchlists = Published(wrappedValue: Self.loadWatchlists())
        appLogger.info("AppState stocks loaded: \(self.stocks.count)")
        logToFile("AppState stocks loaded: \(self.stocks.count)")
        setupScheduler()
        appLogger.info("AppState init complete")
        logToFile("AppState init complete")
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.restartScheduler() }
        }
    }

    func setupScheduler() {
        scheduler = RefreshScheduler { [weak self] in await self?.refresh() }
        scheduler?.start(interval: TimeInterval(refreshInterval))
    }

    func restartScheduler() {
        scheduler?.stop()
        setupScheduler()
    }

    func forceRefresh() { scheduler?.forceRefresh() }

    // MARK: - 数据拉取

    func refresh() async {
        isLoading = true
        hasError  = false
        do {
            let all       = stocks.map(\.id)
            let sinaCodes = all.filter { !$0.hasPrefix("hk") }
            let hkCodes   = all.filter {  $0.hasPrefix("hk") }

            let isOvernight = Self.usMarketSession() == "夜盘"
            let usCodes = isOvernight ? all.filter { $0.hasPrefix("usr_") } : []

            // 所有数据源并行请求
            async let sinaResult      = DataService.fetchSinaQuotes(codes: sinaCodes)
            async let hkResult        = DataService.fetchTencentHKQuotes(codes: hkCodes)
            async let ratesResult     = CurrencyService.fetchRates()
            async let overnightResult = PythService.fetchOvernightPrices(codes: usCodes)

            let (s, h) = try await (sinaResult, hkResult)
            let rates     = await ratesResult
            let overnight = await overnightResult

            // 夜盘时段：清除新浪的盘后旧价格，用夜盘实时价替换
            var merged = s
            if isOvernight {
                for key in merged.keys where key.hasPrefix("usr_") {
                    merged[key]?.extendedPrice = overnight[key]
                }
            }

            var newQuotes = quotes
            newQuotes.merge(merged) { $1 }
            newQuotes.merge(h) { $1 }
            quotes         = newQuotes   // 整体赋值，触发 didSet → refreshStatusBarSegments
            exchangeRates  = rates
            lastUpdateTime = Date()
            syncStockNamesFromQuotes()
        } catch {
            hasError = true
        }
        isLoading = false
    }

    private func syncStockNamesFromQuotes() {
        var updated = stocks
        var changed = false
        for i in updated.indices {
            if let q = quotes[updated[i].id], !q.name.isEmpty, q.name != updated[i].name {
                updated[i].name = q.name
                changed = true
            }
        }
        if changed { stocks = updated }
    }

    // MARK: - 观察仓

    var activeWatchlist: Watchlist? {
        guard let id = config.activeWatchlistId else { return nil }
        return watchlists.first(where: { $0.id == id })
    }

    var activeWatchlistName: String {
        activeWatchlist?.name ?? "真实持仓"
    }

    func effectiveCostPrice(for stock: Stock) -> Double? {
        if let wl = activeWatchlist, let entry = wl.entries[stock.id] {
            return entry.costPrice
        }
        return stock.costPrice
    }

    func effectiveShares(for stock: Stock) -> Double? {
        if let wl = activeWatchlist, let entry = wl.entries[stock.id] {
            return entry.holdingShares
        }
        return stock.holdingShares
    }

    func effectivePnl(stock: Stock, quote: Quote) -> Double? {
        guard let cost = effectiveCostPrice(for: stock),
              let shares = effectiveShares(for: stock) else { return nil }
        return (quote.price - cost) * shares
    }

    func effectiveDailyPnl(stock: Stock, quote: Quote) -> Double? {
        guard let shares = effectiveShares(for: stock) else { return nil }
        return quote.change * shares
    }

    func effectivePnlPercent(stock: Stock, quote: Quote) -> Double? {
        guard let cost = effectiveCostPrice(for: stock), cost > 0 else { return nil }
        return (quote.price - cost) / cost * 100
    }

    // MARK: - 持仓汇总

    var totalPnL: Double {
        stocks.compactMap { s -> Double? in
            guard let q = quotes[s.id], let pnl = effectivePnl(stock: s, quote: q) else { return nil }
            return exchangeRates.convert(pnl, from: s.market, to: displayCurrency)
        }.reduce(0, +)
    }

    var totalDailyPnL: Double {
        stocks.compactMap { s -> Double? in
            guard let q = quotes[s.id], let pnl = effectiveDailyPnl(stock: s, quote: q) else { return nil }
            return exchangeRates.convert(pnl, from: s.market, to: displayCurrency)
        }.reduce(0, +)
    }

    var totalCost: Double {
        stocks.compactMap { s -> Double? in
            guard let cost = effectiveCostPrice(for: s),
                  let shares = effectiveShares(for: s) else { return nil }
            return exchangeRates.convert(cost * shares, from: s.market, to: displayCurrency)
        }.reduce(0, +)
    }

    var totalPnLPercent: Double {
        guard totalCost > 0 else { return 0 }
        return totalPnL / totalCost * 100
    }

    var totalDailyPnLPercent: Double {
        guard totalCost > 0 else { return 0 }
        return totalDailyPnL / totalCost * 100
    }

    var hasPnLData: Bool {
        stocks.contains { effectiveCostPrice(for: $0) != nil && effectiveShares(for: $0) != nil }
    }

    // MARK: - 状态栏

    var statusBarStock: Stock? {
        if statusBarStockId.hasPrefix("__") { return nil }
        return stocks.first(where: { $0.id == statusBarStockId }) ?? stocks.first
    }

    var statusBarQuote: Quote? {
        guard let s = statusBarStock else { return nil }
        return quotes[s.id]
    }

    /// 状态栏每个片段的数据（供 MenuBarLabel 渲染）
    struct StatusBarSegment {
        let text: String
        let isUp: Bool
        let isDown: Bool
        let isSecondary: Bool   // 用于 pnl "--" 等中性色
    }

    /// 重新计算并发布 statusBarSegments（在 quotes/config/stocks 变化时调用）
    func refreshStatusBarSegments() {
        let ids = config.statusBarStockIds

        guard !ids.isEmpty, !ids.allSatisfy({ $0 == "__none__" }) else {
            statusBarSegments = []
            return
        }

        var segments: [StatusBarSegment] = []

        for id in ids {
            guard id != "__none__" else { continue }

            if id == "__daily_pnl__" || id == "__total_pnl__" || id == "__both_pnl__" {
                if !hasPnLData {
                    segments.append(StatusBarSegment(text: "--", isUp: false, isDown: false, isSecondary: true))
                    continue
                }
                let sym = displayCurrency.symbol
                var parts: [String] = []
                if id == "__daily_pnl__" || id == "__both_pnl__" {
                    let d = totalDailyPnL
                    parts.append("日\(d >= 0 ? "+" : "")\(sym)\(String(format: "%.0f", d))")
                }
                if id == "__total_pnl__" || id == "__both_pnl__" {
                    let p = totalPnL
                    parts.append("浮\(p >= 0 ? "+" : "")\(sym)\(String(format: "%.0f", p))")
                }
                let val = (id == "__daily_pnl__") ? totalDailyPnL : totalPnL
                segments.append(StatusBarSegment(
                    text: parts.joined(separator: " "),
                    isUp: val > 0, isDown: val < 0, isSecondary: false
                ))
                continue
            }

            // 普通股票（空串已废弃，直接按 id 查找）
            guard !id.isEmpty else { continue }
            guard let stock = stocks.first(where: { $0.id == id }),
                  let q = quotes[stock.id] else { continue }
            let s = stock
            var parts: [String] = []
            if config.statusBarShowName  { parts.append(s.name) }
            if config.statusBarShowPrice { parts.append(q.formattedPrice) }
            if config.statusBarShowChange { parts.append(q.formattedPercent) }
            let text = parts.isEmpty ? s.name : parts.joined(separator: " ")
            segments.append(StatusBarSegment(text: text, isUp: q.isUp, isDown: q.isDown, isSecondary: false))
        }
        let oldCount = statusBarSegments.count
        statusBarSegments = segments

        // 防止索引越界
        if statusBarCurrentIndex >= segments.count {
            statusBarCurrentIndex = 0
        }
        // 只有 segments 数量变化时才重建 Timer（行情价格更新不重置）
        if segments.count != oldCount {
            restartRotationTimer()
        }
    }

    /// 重建轮播 Timer，使用 .common RunLoop 确保菜单打开时也能正常触发
    func restartRotationTimer() {
        rotationTimer?.invalidate()
        rotationTimer = nil
        guard statusBarSegments.count > 1 else { return }
        let interval = TimeInterval(config.rotationInterval)
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.statusBarSegments.count > 1 else { return }
                self.statusBarCurrentIndex = (self.statusBarCurrentIndex + 1) % self.statusBarSegments.count
            }
        }
        RunLoop.main.add(t, forMode: .common)
        rotationTimer = t
    }

    // MARK: - 颜色辅助

    func quoteColor(for quote: Quote) -> Color {
        if quote.isUp   { return Color(config.upColorName) }
        if quote.isDown { return Color(config.downColorName) }
        return .secondary
    }

    func pnlColor(_ pnl: Double) -> Color {
        if pnl > 0 { return Color(config.upColorName) }
        if pnl < 0 { return Color(config.downColorName) }
        return .secondary
    }

    // MARK: - 美股交易时段

    static func usMarketSession() -> String? {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        let now   = Date()
        let comps = cal.dateComponents([.weekday, .hour, .minute], from: now)
        // Swift Calendar weekday: 1=周日, 2=周一, 3=周二, ..., 6=周五, 7=周六
        let wd = comps.weekday ?? 1
        let t  = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
        switch t {
        case 0..<240:
            // ET 00:00–04:00 凌晨段（前一晚夜盘延续）
            // 周一凌晨(wd=2)=周日夜盘, 周二~周五凌晨(wd=3~6), 周六凌晨(wd=7)=周五夜盘
            guard wd >= 2 else { return nil }  // 周日凌晨无交易
            return "夜盘"
        case 240..<570:
            guard wd >= 2, wd <= 6 else { return nil }  // 周一~周五
            return "盘前"    // ET 04:00–09:30
        case 570..<960:
            guard wd >= 2, wd <= 6 else { return nil }
            return "盘中"    // ET 09:30–16:00
        case 960..<1200:
            guard wd >= 2, wd <= 6 else { return nil }
            return "盘后"    // ET 16:00–20:00
        case 1200..<1440:
            // ET 20:00–24:00 晚间段
            // 周日晚(wd=1)=周一夜盘开始, 周一~周五晚(wd=2~6)
            guard wd >= 1, wd <= 6 else { return nil }  // 仅排除周六晚(wd=7)
            return "夜盘"    // ET 20:00–24:00
        default:
            return nil
        }
    }
}
