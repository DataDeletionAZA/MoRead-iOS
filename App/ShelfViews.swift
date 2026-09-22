import SwiftUI
import MoReadCore

struct ShelfFiltersView: View {
    @Binding var filter: ShelfFilter
    @Binding var sort: String
    @EnvironmentObject private var model: LibraryModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section("排序") { Picker("顺序", selection: $sort) { ForEach(ShelfSort.allCases, id: \.rawValue) { Text($0.rawValue).tag($0.rawValue) } } }
                Section("范围") {
                    Picker("阅读状态", selection: $filter.state) {
                        Text("全部状态").tag(nil as String?)
                        ForEach(["未读", "在读", "已读", "搁置"], id: \.self) { Text($0).tag(Optional($0)) }
                    }
                    Picker("分组", selection: $filter.groupID) {
                        Text("全部分组").tag(nil as UUID?)
                        ForEach(model.organization.groups) { Text(model.organization.groupPath($0.id)).tag(Optional($0.id)) }
                    }.onChange(of: filter.groupID) { _, value in if value != nil { filter.ungrouped = false } }
                    Toggle("只看未分组的书", isOn: $filter.ungrouped).onChange(of: filter.ungrouped) { _, value in if value { filter.groupID = nil } }
                    Picker("合集", selection: $filter.collectionID) {
                        Text("全部合集").tag(nil as UUID?)
                        ForEach(model.organization.collections) { Text($0.name).tag(Optional($0.id)) }
                    }
                }
                if !model.organization.tags.isEmpty {
                    Section("标签") {
                        Toggle("同时包含选中的所有标签", isOn: $filter.matchAllTags)
                        ForEach(model.organization.tags) { tag in
                            Toggle(isOn: Binding(get: { filter.tags.contains(tag.id) }, set: { if $0 { filter.tags.insert(tag.id) } else { filter.tags.remove(tag.id) } })) { TagLabel(tag: tag) }
                        }
                    }
                }
                Button("清除筛选") { filter = ShelfFilter() }
            }.navigationTitle("筛选与排序")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }
}

struct ShelfManager: View {
    @EnvironmentObject private var model: LibraryModel
    @State private var group: ShelfGroup?
    @State private var collection: ShelfCollection?
    @State private var tag: ShelfTag?
    var body: some View {
        List {
            Section {
                NavigationLink("批量整理书籍") { BulkBookOrganizer() }
            }
            Section {
                ForEach(model.organization.groups) { value in
                    Button { group = value } label: { Label(model.organization.groupPath(value.id), systemImage: "folder").foregroundStyle(.primary) }
                        .swipeActions { Button("删除", role: .destructive) { model.organize { try $0.deleteGroup(value.id) } } }
                }.onMove { from, to in model.organize { $0.groups.move(fromOffsets: from, toOffset: to) } }
                Button("新建分组", systemImage: "folder.badge.plus") { group = ShelfGroup(name: "") }.accessibilityIdentifier("new-shelf-group")
            } header: { Text("分组") } footer: { Text("删除分组会把其中的书籍和子分组移到上一级。") }
            Section {
                ForEach(model.organization.collections) { value in
                    Button { collection = value } label: { Label(value.name, systemImage: "square.stack").foregroundStyle(.primary) }
                        .swipeActions { Button("解散", role: .destructive) { model.organize { $0.collections.removeAll { $0.id == value.id } } } }
                }.onMove { from, to in model.organize { $0.collections.move(fromOffsets: from, toOffset: to) } }
                Button("新建合集", systemImage: "plus") { collection = ShelfCollection(name: "") }
            } header: { Text("合集") } footer: { Text("解散合集后，书籍仍保留在书架。") }
            Section("标签") {
                ForEach(model.organization.tags) { value in
                    Button { tag = value } label: { TagLabel(tag: value).foregroundStyle(.primary) }
                        .swipeActions { Button("删除", role: .destructive) { model.organize { $0.deleteTag(value.id) } } }
                        .contextMenu {
                            Menu("合并到") { ForEach(model.organization.tags.filter { $0.id != value.id }) { target in Button(target.name) { model.organize { $0.deleteTag(value.id, mergingInto: target.id) } } } }
                        }
                }.onMove { from, to in model.organize { $0.tags.move(fromOffsets: from, toOffset: to) } }
                Button("新建标签", systemImage: "tag") { tag = ShelfTag(name: "") }
            }
        }.navigationTitle("整理书架")
            .toolbar { EditButton() }
            .sheet(item: $group) { ShelfGroupEditor(value: $0) }
            .sheet(item: $collection) { ShelfCollectionEditor(value: $0) }
            .sheet(item: $tag) { ShelfTagEditor(value: $0) }
    }
}

struct ShelfGroupEditor: View {
    @State var value: ShelfGroup
    @EnvironmentObject private var model: LibraryModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                TextField("分组名称", text: $value.name).accessibilityIdentifier("group-name")
                Picker("上级分组", selection: $value.parentID) {
                    Text("顶层").tag(nil as UUID?)
                    ForEach(model.organization.groups.filter { !model.organization.descendants(of: value.id).contains($0.id) }) { Text(model.organization.groupPath($0.id)).tag(Optional($0.id)) }
                }
            }.navigationTitle("分组")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("保存") { if model.organize({ try $0.saveGroup(value) }) { dismiss() } }.disabled(value.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
                }
        }
    }
}

struct ShelfCollectionEditor: View {
    @State var value: ShelfCollection
    @EnvironmentObject private var model: LibraryModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form { TextField("合集名称", text: $value.name) }
                .navigationTitle("合集")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("保存") { if model.organize({ try $0.saveCollection(value) }) { dismiss() } }.disabled(value.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
                }
        }
    }
}

struct ShelfTagEditor: View {
    @State var value: ShelfTag
    @EnvironmentObject private var model: LibraryModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                TextField("标签名称", text: $value.name)
                TextField("标签分组", text: $value.group)
                Picker("颜色", selection: $value.color) {
                    Text("绿").tag("green"); Text("蓝").tag("blue"); Text("紫").tag("purple"); Text("橙").tag("orange"); Text("粉").tag("pink"); Text("灰").tag("gray")
                }
            }.navigationTitle("标签")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("保存") { if model.organize({ try $0.saveTag(value) }) { dismiss() } }.disabled(value.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
                }
        }
    }
}

struct TagLabel: View {
    let tag: ShelfTag
    var body: some View {
        HStack {
            Circle().fill(color).frame(width: 9, height: 9)
            Text(tag.name)
            if !tag.group.isEmpty { Text(tag.group).font(.caption).foregroundStyle(.secondary) }
        }
    }
    private var color: Color {
        switch tag.color { case "blue": return .blue; case "purple": return .purple; case "orange": return .orange; case "pink": return .pink; case "gray": return .gray; default: return .green }
    }
}

struct BookMetadataEditor: View {
    let bookID: UUID
    @EnvironmentObject private var model: LibraryModel
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var author = ""
    @State private var state = "未读"
    @State private var pinned = false
    @State private var group: UUID?
    @State private var collection: UUID?
    @State private var selectedTags: Set<UUID> = []
    @State private var newTag = ""
    @State private var pendingTags: [ShelfTag] = []
    @State private var loaded = false
    var body: some View {
        NavigationStack {
            Form {
                Section { NavigationLink("书籍封面") { BookCoverEditor(bookID: bookID) } }
                Section { NavigationLink("插图廊") { IllustrationGallery(bookID: bookID) } }
                Section("书籍资料") {
                    TextField("书名", text: $title).accessibilityIdentifier("book-title")
                    TextField("作者", text: $author)
                    Picker("阅读状态", selection: $state) { ForEach(["未读", "在读", "已读", "搁置"], id: \.self) { Text($0).tag($0) } }
                    Toggle("置顶", isOn: $pinned)
                }
                Section("归类") {
                    Picker("分组", selection: $group) {
                        Text("未分组").tag(nil as UUID?)
                        ForEach(model.organization.groups) { Text(model.organization.groupPath($0.id)).tag(Optional($0.id)) }
                    }
                    Picker("合集", selection: $collection) {
                        Text("不放入合集").tag(nil as UUID?)
                        ForEach(model.organization.collections) { Text($0.name).tag(Optional($0.id)) }
                    }
                }
                Section("标签") {
                    ForEach(model.organization.tags + pendingTags) { tag in
                        Toggle(isOn: Binding(get: { selectedTags.contains(tag.id) }, set: { if $0 { selectedTags.insert(tag.id) } else { selectedTags.remove(tag.id) } })) { TagLabel(tag: tag) }
                    }
                    HStack {
                        TextField("新标签", text: $newTag)
                        Button("添加") {
                            let name = ShelfOrganization.normalizedTag(newTag)
                            guard !name.isEmpty, name.count <= 80 else { model.error = "标签名称需要在 1 到 80 个字之间。"; return }
                            let existing = (model.organization.tags + pendingTags).first { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }
                            let tag = existing ?? ShelfTag(name: name)
                            if existing == nil { pendingTags.append(tag) }
                            selectedTags.insert(tag.id); newTag = ""
                        }.disabled(newTag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }.navigationTitle("编辑书籍")
                .task {
                    guard !loaded, let book = model.books.first(where: { $0.id == bookID }) else { return }
                    loaded = true
                    title = book.title; author = book.author; state = book.state; pinned = book.pinned
                    group = model.organization.bookGroups[bookID]
                    collection = model.organization.collections.first { $0.bookIDs.contains(bookID) }?.id
                    selectedTags = Set(model.organization.bookTags[bookID] ?? [])
                }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("保存") { save() }.disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
                }
        }
    }
    private func save() {
        guard var book = model.books.first(where: { $0.id == bookID }) else { return }
        book.title = title.trimmingCharacters(in: .whitespacesAndNewlines); book.author = author.trimmingCharacters(in: .whitespacesAndNewlines)
        book.state = state; book.pinned = pinned
        guard model.update(book, immediate: true) else { return }
        if model.organize({
            for tag in pendingTags { try $0.saveTag(tag) }
            $0.bookGroups[bookID] = group
            $0.bookTags[bookID] = $0.tags.map(\.id).filter(selectedTags.contains)
            $0.setCollection(collection, for: [bookID])
        }) { dismiss() }
    }
}

struct BulkBookOrganizer: View {
    @EnvironmentObject private var model: LibraryModel
    @State private var selected: Set<UUID> = []
    @State private var query = ""
    private var books: [Book] { model.books.filter { !$0.removed && (query.isEmpty || $0.title.localizedCaseInsensitiveContains(query)) } }
    var body: some View {
        List(books) { book in
            Button {
                if selected.contains(book.id) { selected.remove(book.id) } else { selected.insert(book.id) }
            } label: {
                HStack { Image(systemName: selected.contains(book.id) ? "checkmark.circle.fill" : "circle"); Text(book.title).foregroundStyle(.primary) }
            }.accessibilityValue(selected.contains(book.id) ? "已选中" : "未选中")
        }.navigationTitle("已选 \(selected.count) 本")
            .toolbar(.hidden, for: .tabBar)
            .searchable(text: $query, prompt: "书名")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(Set(books.map(\.id)).isSubset(of: selected) ? "取消全选" : "全选") {
                        let visible = Set(books.map(\.id))
                        if visible.isSubset(of: selected) { selected.subtract(visible) } else { selected.formUnion(visible) }
                    }
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    Menu("分组", systemImage: "folder") {
                        Button("移到未分组") { model.organize { shelf in for id in selected { shelf.bookGroups[id] = nil } } }
                        ForEach(model.organization.groups) { group in Button(model.organization.groupPath(group.id)) { model.organize { shelf in for id in selected { shelf.bookGroups[id] = group.id } } } }
                    }.disabled(selected.isEmpty)
                    Spacer()
                    Menu("合集", systemImage: "square.stack") {
                        Button("移出合集") { model.organize { $0.setCollection(nil, for: selected) } }
                        ForEach(model.organization.collections) { collection in Button(collection.name) { model.organize { $0.setCollection(collection.id, for: selected) } } }
                    }.disabled(selected.isEmpty)
                    Spacer()
                    Menu("标签", systemImage: "tag") {
                        ForEach(model.organization.tags) { tag in
                            Menu(tag.name) {
                                Button("添加") { model.organize { shelf in for id in selected where shelf.bookTags[id]?.contains(tag.id) != true { shelf.bookTags[id, default: []].append(tag.id) } } }
                                Button("移除") { model.organize { shelf in for id in selected { shelf.bookTags[id]?.removeAll { $0 == tag.id } } } }
                            }
                        }
                    }.disabled(selected.isEmpty)
                }
            }
    }
}
