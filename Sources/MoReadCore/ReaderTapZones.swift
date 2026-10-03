import Foundation

public enum ReaderTapAction: String, Codable, CaseIterable, Sendable {
    case none, previousPage, nextPage, menu, contents, bookmarks, toggleBookmark, settings
    case previousChapter, nextChapter, search, toggleTranslations, englishLearning
    public var label: String {
        switch self {
        case .none: return "无操作"
        case .previousPage: return "上一页"
        case .nextPage: return "下一页"
        case .menu: return "显示／收起菜单"
        case .contents: return "目录／人物"
        case .bookmarks: return "书签"
        case .toggleBookmark: return "添加／移除书签"
        case .settings: return "阅读设置"
        case .previousChapter: return "上一章"
        case .nextChapter: return "下一章"
        case .search: return "书内搜索"
        case .toggleTranslations: return "显示／隐藏译文"
        case .englishLearning: return "英语学习／词典"
        }
    }
}

public struct ReaderTapZones: Codable, Equatable, Sendable {
    public var actions: [ReaderTapAction]
    public static let labels = ["正文左上", "正文上方", "正文右上", "正文左侧", "正文中央", "正文右侧", "正文左下", "正文下方", "正文右下", "页眉左侧", "页眉右侧", "页脚左侧", "页脚右侧"]
    public init() { actions = (0..<9).map { [.previousPage, .menu, .nextPage][$0 % 3] } + Array(repeating: .none, count: 4) }
    public var isValid: Bool { actions.count == 13 && actions.contains(.menu) }
    public init?(data: Data) {
        guard let value = try? JSONDecoder().decode(Self.self, from: data), value.isValid else { return nil }
        self = value
    }
    public func encoded() -> Data { isValid ? (try? JSONEncoder().encode(self)) ?? Data() : Data() }
    public static func index(x: Double, y: Double, width: Double, height: Double) -> Int {
        guard x.isFinite, y.isFinite, width.isFinite, height.isFinite, width > 0, height > 0 else { return 4 }
        let nx = min(0.999999, max(0, x / width)), ny = min(0.999999, max(0, y / height))
        if ny < 0.08 { return 9 + Int(nx * 2) }
        if ny >= 0.92 { return 11 + Int(nx * 2) }
        return min(2, Int((ny - 0.08) / 0.84 * 3)) * 3 + Int(nx * 3)
    }
    public func action(x: Double, y: Double, width: Double, height: Double) -> ReaderTapAction {
        guard isValid else { return .menu }
        return actions[Self.index(x: x, y: y, width: width, height: height)]
    }
}
