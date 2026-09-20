import Foundation

public struct LibraryOrganizationChange: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID { bookID }
    public let bookID: UUID
    public let title: String
    public let beforeTags: [ShelfTag]
    public let beforeGroup: ShelfGroup?
    public let addTags: [String]
    public let removeTags: [String]
    public let groupName: String?
    public let existingAddTags: [ShelfTag]
    public let targetGroup: ShelfGroup?
}

public struct LibraryOrganizationPlan: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public let changes: [LibraryOrganizationChange]
    private static let prefix = "待确认的书架整理方案，尚未修改书架。\n"
    private static func same(_ a: String, _ b: String) -> Bool { a.lowercased() == b.lowercased() }
    private static func validName(_ name: String, maximum: Int, tag: Bool) -> Bool {
        !name.isEmpty && name.utf16.count <= maximum && !name.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
            && name == (tag ? ShelfOrganization.normalizedTag(name) : name.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    public func validate() throws {
        guard (1...20).contains(changes.count), Set(changes.map(\.bookID)).count == changes.count else { throw MoReadError.invalid("每份方案需要 1–20 本不同的书。") }
        for change in changes {
            guard !change.title.isEmpty, change.title.count <= 120,
                  change.beforeTags.count <= 256, Set(change.beforeTags.map(\.id)).count == change.beforeTags.count,
                  change.existingAddTags.count <= 8, Set(change.existingAddTags.map(\.id)).count == change.existingAddTags.count,
                  change.addTags.count <= 8, change.removeTags.count <= 8,
                  Set(change.addTags.map { $0.lowercased() }).count == change.addTags.count,
                  Set(change.removeTags.map { $0.lowercased() }).count == change.removeTags.count,
                  (change.addTags + change.removeTags).allSatisfy({ Self.validName($0, maximum: 24, tag: true) }),
                  change.groupName.map({ Self.validName($0, maximum: 30, tag: false) }) ?? true,
                  !change.addTags.isEmpty || !change.removeTags.isEmpty || change.groupName != nil,
                  change.addTags.allSatisfy({ name in !change.beforeTags.contains { Self.same(name, $0.name) } && !change.removeTags.contains { Self.same(name, $0) } }),
                  change.removeTags.allSatisfy({ name in change.beforeTags.contains { Self.same(name, $0.name) } }),
                  change.existingAddTags.allSatisfy({ tag in change.addTags.contains { Self.same($0, tag.name) } }),
                  change.targetGroup == nil || (change.targetGroup?.parentID == nil && change.targetGroup?.name == change.groupName) else { throw MoReadError.invalid("书架整理方案的标签或分组无效。") }
            var snapshot = ShelfOrganization()
            snapshot.tags = change.beforeTags + change.existingAddTags
            // Only the immediate group snapshot is needed; its parent is checked against the live shelf before applying.
            for group in [change.beforeGroup, change.targetGroup].compactMap({ $0 }) {
                guard Self.validName(group.name, maximum: 80, tag: false), group.parentID != group.id else { throw MoReadError.invalid("方案中的分组无效。") }
            }
            try snapshot.validate()
        }
    }
    public func encoded() throws -> String {
        try validate()
        let data = try JSONEncoder().encode(self)
        guard data.count <= 48_000 else { throw MoReadError.invalid("整理方案过大，请减少书籍。") }
        return Self.prefix + String(decoding: data, as: UTF8.self)
    }
    public static func decode(_ text: String) throws -> Self {
        guard text.hasPrefix(prefix), text.utf8.count <= 49_000 else { throw MoReadError.invalid("书架整理方案格式无效。") }
        let plan = try JSONDecoder().decode(Self.self, from: Data(text.dropFirst(prefix.count).utf8))
        try plan.validate(); return plan
    }
    public static func preview(arguments: [String: Any], books: [Book], shelf: ShelfOrganization) throws -> Self {
        try shelf.validate()
        guard let rows = arguments["changes"] as? [[String: Any]], (1...20).contains(rows.count) else { throw MoReadError.invalid("请提供 1–20 本书的 changes。") }
        var seen = Set<UUID>(), changes: [LibraryOrganizationChange] = []
        for row in rows {
            guard let raw = row["book_id"] as? String, let id = UUID(uuidString: raw), seen.insert(id).inserted,
                  let book = books.first(where: { $0.id == id && !$0.removed }) else { throw MoReadError.invalid("书籍编号无效、重复或已移除。") }
            func names(_ key: String) throws -> [String] {
                guard let value = row[key] else { return [] }
                guard let strings = value as? [String], strings.count <= 8 else { throw MoReadError.invalid("每本书一次最多添加或移除 8 个标签。") }
                var unique = Set<String>()
                return try strings.map { raw in
                    let name = ShelfOrganization.normalizedTag(raw)
                    guard Self.validName(name, maximum: 24, tag: true) else { throw MoReadError.invalid("标签需要 1–24 个字，不能包含控制字符。") }
                    return name
                }.filter { unique.insert($0.lowercased()).inserted }
            }
            let add = try names("add_tags"), remove = try names("remove_tags")
            guard !add.contains(where: { name in remove.contains { Self.same(name, $0) } }) else { throw MoReadError.invalid("同一标签不能同时添加和移除。") }
            var group: String?
            if let value = row["group_name"] {
                guard let text = value as? String else { throw MoReadError.invalid("分组名需要是文字。") }
                let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard Self.validName(name, maximum: 30, tag: false) else { throw MoReadError.invalid("分组名需要 1–30 个字，不能包含控制字符。") }
                group = name
            }
            guard !add.isEmpty || !remove.isEmpty || group != nil else { throw MoReadError.invalid("方案没有变更。") }
            let beforeTags = shelf.tags.filter { (shelf.bookTags[id] ?? []).contains($0.id) }
            let beforeGroup = shelf.groups.first { $0.id == shelf.bookGroups[id] }
            guard remove.allSatisfy({ name in beforeTags.contains { Self.same(name, $0.name) } }) else { throw MoReadError.invalid("《\(book.title.prefix(24))》没有要移除的标签。") }
            let added = add.filter { name in !beforeTags.contains { Self.same(name, $0.name) } }
            let target = group.flatMap { name in shelf.groups.first { $0.parentID == nil && Self.same($0.name, name) } }
            if let target { group = target.name }
            if beforeGroup?.parentID == nil, beforeGroup?.name == group { group = nil }
            if added.isEmpty && remove.isEmpty && group == nil { continue }
            changes.append(.init(bookID: id, title: String(book.title.prefix(120)), beforeTags: beforeTags, beforeGroup: beforeGroup, addTags: added, removeTags: remove, groupName: group, existingAddTags: shelf.tags.filter { tag in added.contains { Self.same($0, tag.name) } }, targetGroup: group == nil ? nil : target))
        }
        guard !changes.isEmpty else { throw MoReadError.invalid("书架已经符合这个方案。") }
        let plan = Self(id: UUID(), changes: changes); _ = try plan.encoded(); return plan
    }
    public static func context(conversation: Conversation, shelf: ShelfOrganization) -> String {
        let plans = conversation.messages.flatMap { ($0.toolTrace ?? []).compactMap(\.organizationPlan) }.suffix(8)
        guard !plans.isEmpty else { return "" }
        return "\n\n【书架整理记录】以下是本机记录的处理结果；书架当前分类可用 find_books 核对。\n" + plans.map { plan in
            let state = shelf.organizationDecisions?[plan.id]
            let label = state == "applied" ? "用户已确认应用" : state == "cancelled" ? "用户已取消，未应用" : "等待用户确认，未应用"
            return "方案 \(plan.id)：\(label)；" + plan.changes.map { "《\($0.title.prefix(40))》" }.joined(separator: "、")
        }.joined(separator: "\n")
    }
    public func resolve(apply: Bool, books: [Book], shelf: inout ShelfOrganization) throws {
        try validate(); try shelf.validate()
        guard shelf.organizationDecisions?[id] == nil else { throw MoReadError.invalid("这份方案已处理。") }
        var updated = shelf
        if apply {
            for change in changes {
                guard let book = books.first(where: { $0.id == change.bookID && !$0.removed }), String(book.title.prefix(120)) == change.title,
                      shelf.bookGroups[book.id] == change.beforeGroup?.id,
                      shelf.groups.first(where: { $0.id == change.beforeGroup?.id }) == change.beforeGroup,
                      Set(shelf.tags.filter { (shelf.bookTags[book.id] ?? []).contains($0.id) }) == Set(change.beforeTags),
                      change.existingAddTags.allSatisfy({ old in shelf.tags.first { Self.same($0.name, old.name) } == old }),
                      change.targetGroup.map({ old in shelf.groups.first { $0.id == old.id } == old }) ?? true else { throw MoReadError.invalid("书架已变化，请重新生成整理方案。") }
            }
            for change in changes {
                var ids = Set(updated.bookTags[change.bookID] ?? [])
                for name in change.addTags {
                    let tag = updated.tags.first { Self.same($0.name, name) } ?? ShelfTag(name: name)
                    if !updated.tags.contains(where: { $0.id == tag.id }) { try updated.saveTag(tag) }
                    ids.insert(tag.id)
                }
                for tag in change.beforeTags where change.removeTags.contains(where: { Self.same($0, tag.name) }) { ids.remove(tag.id) }
                updated.bookTags[change.bookID] = ids.sorted { $0.uuidString < $1.uuidString }
                if let name = change.groupName {
                    let group = updated.groups.first { $0.parentID == nil && Self.same($0.name, name) } ?? ShelfGroup(name: name)
                    if !updated.groups.contains(where: { $0.id == group.id }) { try updated.saveGroup(group) }
                    updated.bookGroups[change.bookID] = group.id
                }
            }
        }
        if updated.organizationDecisions == nil { updated.organizationDecisions = [:] }
        updated.organizationDecisions?[id] = apply ? "applied" : "cancelled"
        try updated.validate(); shelf = updated
    }
}
