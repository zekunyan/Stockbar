import Foundation

enum DisplayCurrency: String, Codable, CaseIterable {
    case cny = "CNY"
    case hkd = "HKD"
    case usd = "USD"

    var symbol: String {
        switch self {
        case .cny: return "¥"
        case .hkd: return "HK$"
        case .usd: return "$"
        }
    }

    var displayName: String {
        switch self {
        case .cny: return "人民币 ¥"
        case .hkd: return "港币 HK$"
        case .usd: return "美元 $"
        }
    }
}

enum SortRule: String, Codable, CaseIterable {
    case changeDesc = "changeDesc"
    case changeAsc  = "changeAsc"

    var displayName: String {
        switch self {
        case .changeDesc: return "涨跌幅降序"
        case .changeAsc:  return "涨跌幅升序"
        }
    }
}

enum USPriceMode: String, Codable, CaseIterable {
    case sessionPrice = "session"
    case regularPrice = "regular"

    var displayName: String {
        switch self {
        case .sessionPrice: return "当前价（时段价格）"
        case .regularPrice: return "盘中价"
        }
    }
}

enum ColorTheme: String, Codable, CaseIterable {
    case chinese = "chinese"  // 红涨绿跌
    case western = "western"  // 绿涨红跌

    var displayName: String {
        switch self {
        case .chinese: return "红涨绿跌"
        case .western: return "绿涨红跌"
        }
    }
}

struct AppSettings {
    /// 状态栏显示的股票 ID 列表（多选）。特殊值同旧版：
    /// "__none__"  不显示；"__daily_pnl__" 日盈亏；"__total_pnl__" 总盈亏；"__both_pnl__" 两者；
    /// "" 自动选第一只；其余为股票 id
    var statusBarStockIds: [String]      = ["__none__"]
    var refreshInterval: Int             = 5
    var colorScheme: ColorTheme          = .chinese
    var displayCurrency: DisplayCurrency = .cny
    var sortRule: SortRule               = .changeDesc
    var usPriceMode: USPriceMode         = .sessionPrice
    var groupHoldings: Bool              = false
    var activeWatchlistId: String?       = nil    // nil = 真实持仓

    /// 状态栏股票显示内容控制
    var statusBarShowName: Bool   = true
    var statusBarShowPrice: Bool  = true
    var statusBarShowChange: Bool = true

    /// 多股票轮播间隔（秒），仅选了多只时生效
    var rotationInterval: Int = 4

    static let validRefreshIntervals  = [3, 5, 10, 30]
    static let validRotationIntervals = [2, 4, 6, 10]

    var upColorName: String   { colorScheme == .chinese ? "upRed"   : "upGreen" }
    var downColorName: String { colorScheme == .chinese ? "downGreen" : "downRed" }

    /// 向后兼容：读取第一个非 __none__ 的 id
    var statusBarStockId: String {
        get { statusBarStockIds.first(where: { $0 != "__none__" }) ?? "__none__" }
        set { statusBarStockIds = [newValue] }
    }
}

// MARK: - Codable（容错：缺失字段使用默认值）
extension AppSettings: Codable {
    enum CodingKeys: String, CodingKey {
        case statusBarStockIds, statusBarStockId
        case refreshInterval, colorScheme, displayCurrency, sortRule, usPriceMode, groupHoldings, activeWatchlistId
        case statusBarShowName, statusBarShowPrice, statusBarShowChange
        case rotationInterval
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let ids = try? c.decodeIfPresent([String].self, forKey: .statusBarStockIds), !ids.isEmpty {
            // 迁移：过滤掉旧版「自动选第一只」的空串
            statusBarStockIds = ids.filter { !$0.isEmpty }
            if statusBarStockIds.isEmpty { statusBarStockIds = ["__none__"] }
        } else {
            let oldId = (try? c.decodeIfPresent(String.self, forKey: .statusBarStockId)) ?? "__none__"
            statusBarStockIds = oldId.isEmpty ? ["__none__"] : [oldId]
        }
        refreshInterval       = (try? c.decodeIfPresent(Int.self,             forKey: .refreshInterval))       ?? 5
        colorScheme           = (try? c.decodeIfPresent(ColorTheme.self,      forKey: .colorScheme))           ?? .chinese
        displayCurrency       = (try? c.decodeIfPresent(DisplayCurrency.self, forKey: .displayCurrency))       ?? .cny
        sortRule              = (try? c.decodeIfPresent(SortRule.self,        forKey: .sortRule))               ?? .changeDesc
        usPriceMode           = (try? c.decodeIfPresent(USPriceMode.self,     forKey: .usPriceMode))           ?? .sessionPrice
        groupHoldings         = (try? c.decodeIfPresent(Bool.self,            forKey: .groupHoldings))         ?? false
        activeWatchlistId     =  try? c.decodeIfPresent(String.self,          forKey: .activeWatchlistId)
        statusBarShowName     = (try? c.decodeIfPresent(Bool.self,            forKey: .statusBarShowName))     ?? true
        statusBarShowPrice    = (try? c.decodeIfPresent(Bool.self,            forKey: .statusBarShowPrice))    ?? true
        statusBarShowChange   = (try? c.decodeIfPresent(Bool.self,            forKey: .statusBarShowChange))   ?? true
        rotationInterval      = (try? c.decodeIfPresent(Int.self,             forKey: .rotationInterval))      ?? 4
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(statusBarStockIds,    forKey: .statusBarStockIds)
        try c.encode(refreshInterval,      forKey: .refreshInterval)
        try c.encode(colorScheme,          forKey: .colorScheme)
        try c.encode(displayCurrency,      forKey: .displayCurrency)
        try c.encode(sortRule,             forKey: .sortRule)
        try c.encode(usPriceMode,          forKey: .usPriceMode)
        try c.encode(groupHoldings,        forKey: .groupHoldings)
        try c.encodeIfPresent(activeWatchlistId, forKey: .activeWatchlistId)
        try c.encode(statusBarShowName,    forKey: .statusBarShowName)
        try c.encode(statusBarShowPrice,   forKey: .statusBarShowPrice)
        try c.encode(statusBarShowChange,  forKey: .statusBarShowChange)
        try c.encode(rotationInterval,     forKey: .rotationInterval)
    }
}
