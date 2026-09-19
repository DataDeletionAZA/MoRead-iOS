import Foundation

public struct ShelfGroup: Codable, Identifiable, Hashable, Sendable {
    public var id = UUID()
    public var name: String
    public var parentID: UUID?
    public init(name: String, parentID: UUID? = nil) { self.name = name; self.parentID = parentID }
}
public struct ShelfCollection: Codable, Identifiable, Hashable, Sendable {
    public var id = UUID()
    public var name: String
    public var bookIDs: [UUID] = []
    public init(name: String) { self.name = name }
}
public struct ShelfTag: Codable, Identifiable, Hashable, Sendable {
    public var id = UUID()
    public var name: String
    public var group = ""
    public var color = "green"
    public init(name: String) { self.name = name }
}
public enum ShelfSort: String, CaseIterable, Codable, Sendable {
    case recent = "最近阅读", imported = "最近导入", title = "书名", author = "作者", manual = "手动排序"
}
public struct ShelfFilter: Equatable, Sendable {
    public var groupID: UUID?
    public var collectionID: UUID?
    public var ungrouped = false
    public var state: String?
    public var tags: Set<UUID> = []
    public var matchAllTags = false
    public init() {}
    public var isActive: Bool { groupID != nil || collectionID != nil || ungrouped || state != nil || !tags.isEmpty }
}

public struct ShelfOrganization: Codable, Equatable, Sendable {
    public var groups: [ShelfGroup] = []
    public var collections: [ShelfCollection] = []
    public var tags: [ShelfTag] = []
    public var bookGroups: [UUID: UUID] = [:]
    public var bookTags: [UUID: [UUID]] = [:]
    public var bookOrder: [UUID] = []
    public init() {}

    public func validate() throws {
        guard groups.count <= 1024, tags.count <= 8192, collections.count <= 8192 else { throw MoReadError.invalid("书架分类数量过多。") }
        let groupIDs = Set(groups.map(\.id)), tagIDs = Set(tags.map(\.id))
        guard groupIDs.count == groups.count, tagIDs.count == tags.count, Set(collections.map(\.id)).count == collections.count,
              Set(bookOrder).count == bookOrder.count else { throw MoReadError.invalid("书架分类包含重复标识。") }
        var siblings: Set<String> = []
        let indexedGroups = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0) })
        for group in groups {
            try validateName(group.name)
            guard siblings.insert((group.parentID?.uuidString ?? "") + ":" + group.name.lowercased()).inserted else { throw MoReadError.invalid("同一层级已有同名分组。") }
            if let parent = group.parentID, !groupIDs.contains(parent) { throw MoReadError.invalid("找不到上级分组。") }
            var seen: Set<UUID> = [group.id]
            var parent = group.parentID
            while let id = parent {
                guard seen.insert(id).inserted else { throw MoReadError.invalid("分组不能放入自己或自己的子分组。") }
                guard seen.count <= 64 else { throw MoReadError.invalid("分组层级过深。") }
                parent = indexedGroups[id]?.parentID
            }
        }
        var collectionNames: Set<String> = [], tagNames: Set<String> = []
        var collectedBooks: Set<UUID> = []
        for collection in collections {
            try validateName(collection.name)
            guard collectionNames.insert(collection.name.lowercased()).inserted, collection.bookIDs.allSatisfy({ collectedBooks.insert($0).inserted }) else { throw MoReadError.invalid("合集名称或其中的书籍重复。") }
        }
        for tag in tags {
            try validateName(tag.name)
            guard tagNames.insert(tag.name.lowercased()).inserted, tag.group.count <= 80, ["green", "blue", "purple", "orange", "pink", "gray"].contains(tag.color) else { throw MoReadError.invalid("标签名称、分组或颜色无效。") }
        }
        guard bookGroups.values.allSatisfy(groupIDs.contains), bookTags.values.allSatisfy({ Set($0).count == $0.count && Set($0).isSubset(of: tagIDs) }) else { throw MoReadError.invalid("书架分类引用了不存在的分组或标签。") }
    }
    private func validateName(_ name: String) throws {
        guard !name.isEmpty, name == name.trimmingCharacters(in: .whitespacesAndNewlines), name.count <= 80 else { throw MoReadError.invalid("名称需要在 1 到 80 个字之间，首尾不能留空。") }
    }
    public func groupPath(_ id: UUID) -> String {
        var names: [String] = [], current: UUID? = id, visited: Set<UUID> = []
        while let id = current, visited.insert(id).inserted, let group = groups.first(where: { $0.id == id }) { names.insert(group.name, at: 0); current = group.parentID }
        return names.joined(separator: " / ")
    }
    public func descendants(of id: UUID) -> Set<UUID> {
        var result: Set<UUID> = [id]
        var frontier = [id]
        while let parent = frontier.popLast() {
            for group in groups where group.parentID == parent && result.insert(group.id).inserted { frontier.append(group.id) }
        }
        return result
    }
    public mutating func saveGroup(_ group: ShelfGroup) throws {
        var copy = self, group = group
        group.name = group.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let index = copy.groups.firstIndex(where: { $0.id == group.id }) { copy.groups[index] = group } else { copy.groups.append(group) }
        try copy.validate(); self = copy
    }
    public mutating func deleteGroup(_ id: UUID) throws {
        guard let group = groups.first(where: { $0.id == id }) else { return }
        var copy = self
        copy.groups.removeAll { $0.id == id }
        for index in copy.groups.indices where copy.groups[index].parentID == id { copy.groups[index].parentID = group.parentID }
        for book in copy.bookGroups.keys where copy.bookGroups[book] == id { copy.bookGroups[book] = group.parentID }
        try copy.validate(); self = copy
    }
    public mutating func saveCollection(_ collection: ShelfCollection) throws {
        var copy = self, collection = collection
        collection.name = collection.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let index = copy.collections.firstIndex(where: { $0.id == collection.id }) { copy.collections[index] = collection } else { copy.collections.append(collection) }
        try copy.validate(); self = copy
    }
    public mutating func setCollection(_ id: UUID?, for books: Set<UUID>) {
        guard id == nil || collections.contains(where: { $0.id == id }) else { return }
        for index in collections.indices {
            if collections[index].id == id {
                collections[index].bookIDs += books.sorted { $0.uuidString < $1.uuidString }.filter { !collections[index].bookIDs.contains($0) }
            } else { collections[index].bookIDs.removeAll(where: books.contains) }
        }
    }
    public mutating func saveTag(_ tag: ShelfTag) throws {
        var copy = self, tag = tag
        tag.name = Self.normalizedTag(tag.name)
        tag.group = Self.normalizedTag(tag.group)
        if let index = copy.tags.firstIndex(where: { $0.id == tag.id }) { copy.tags[index] = tag } else { copy.tags.append(tag) }
        try copy.validate(); self = copy
    }
    public static func normalizedTag(_ name: String) -> String { name.split(whereSeparator: \.isWhitespace).joined(separator: " ").replacingOccurrences(of: "，", with: ",") }
    public mutating func deleteTag(_ id: UUID, mergingInto target: UUID? = nil) {
        guard target != id, target == nil || tags.contains(where: { $0.id == target }) else { return }
        for book in bookTags.keys {
            if bookTags[book]?.contains(id) == true, let target, bookTags[book]?.contains(target) == false { bookTags[book]?.append(target) }
            bookTags[book]?.removeAll { $0 == id }
        }
        tags.removeAll { $0.id == id }
    }
    public mutating func prune(keeping books: Set<UUID>) {
        bookGroups = bookGroups.filter { books.contains($0.key) }
        bookTags = bookTags.filter { books.contains($0.key) }
        bookOrder.removeAll { !books.contains($0) }
        for index in collections.indices { collections[index].bookIDs.removeAll { !books.contains($0) } }
    }
    public mutating func move(_ id: UUID, before target: UUID, among books: [Book], collection: UUID? = nil) {
        guard id != target, books.contains(where: { $0.id == id }), books.contains(where: { $0.id == target }) else { return }
        if let collection, let index = collections.firstIndex(where: { $0.id == collection }), collections[index].bookIDs.contains(id), collections[index].bookIDs.contains(target) {
            collections[index].bookIDs.removeAll { $0 == id }
            if let destination = collections[index].bookIDs.firstIndex(of: target) { collections[index].bookIDs.insert(id, at: destination) }
        } else if collection == nil {
            let order = sorted(books, by: .manual).map(\.id)
            bookOrder = order.filter { $0 != id }
            if let destination = bookOrder.firstIndex(of: target) { bookOrder.insert(id, at: destination) }
        }
    }
    public func sorted(_ books: [Book], by sort: ShelfSort, collection: UUID? = nil) -> [Book] {
        let order = collection.flatMap { id in collections.first { $0.id == id }?.bookIDs } ?? bookOrder
        let ranks = Dictionary(order.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: min)
        return books.sorted { a, b in
            if a.pinned != b.pinned { return a.pinned }
            if sort == .manual, ranks[a.id, default: Int.max] != ranks[b.id, default: Int.max] { return ranks[a.id, default: Int.max] < ranks[b.id, default: Int.max] }
            if sort == .title, a.title != b.title { return a.title.localizedStandardCompare(b.title) == .orderedAscending }
            if sort == .author, a.author != b.author { return a.author.localizedStandardCompare(b.author) == .orderedAscending }
            let first = sort == .imported ? a.importedAt : a.lastOpened ?? a.importedAt
            let second = sort == .imported ? b.importedAt : b.lastOpened ?? b.importedAt
            return first == second ? a.id.uuidString < b.id.uuidString : first > second
        }
    }
    public func filtered(_ books: [Book], query: String, filter: ShelfFilter) -> [Book] {
        let collection = filter.collectionID.flatMap { id in collections.first { $0.id == id } }.map { Set($0.bookIDs) }
        let tagNames = Dictionary(tags.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        return books.filter { book in
            let assigned = Set(bookTags[book.id] ?? [])
            let matchesTags = filter.tags.isEmpty || (filter.matchAllTags ? filter.tags.isSubset(of: assigned) : !filter.tags.isDisjoint(with: assigned))
            let matchesQuery = query.isEmpty || ([book.title, book.author] + assigned.compactMap { tagNames[$0] }).contains { $0.localizedCaseInsensitiveContains(query) }
            return !book.removed && matchesQuery && matchesTags && (filter.state == nil || book.state == filter.state)
                && (filter.groupID == nil || bookGroups[book.id] == filter.groupID) && (!filter.ungrouped || bookGroups[book.id] == nil)
                && (filter.collectionID == nil || collection?.contains(book.id) == true)
        }
    }
}
