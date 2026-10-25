import AppKit
import SwiftUI
import OpenSVNCore

/// A repository seen as a tree, with no working copy involved.
struct RepositoryBrowserView: View {
    @Bindable var browser: RepositoryBrowser
    @State private var selectedName: String?
    @State private var isExporting = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            breadcrumb
            Divider()
            content
            Divider()
            statusBar
        }
        .task {
            if browser.listing == nil {
                await browser.loadRoot()
            }
        }
        .sheet(item: $browser.actionRequest) { request in
            RemoteActionSheet(browser: browser, request: request)
        }
        .alert(
            "操作失败",
            isPresented: Binding(
                get: { browser.presentedError != nil },
                set: { if !$0 { browser.dismissError() } }
            ),
            presenting: browser.presentedError
        ) { _ in
            Button("好", role: .cancel) { browser.dismissError() }
        } message: { message in
            Text(message)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "shippingbox")
                .font(.system(size: 22))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(browser.displayName)
                    .font(.title3.weight(.semibold))
                Text(browser.location.url)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }

            Spacer()

            if browser.isLoading || browser.isPerforming {
                ProgressView().controlSize(.small)
            }
            if let revision = browser.revision {
                Text("r\(revision)")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Button {
                Task { await browser.refresh() }
            } label: {
                Label("刷新", systemImage: "arrow.clockwise")
            }
            .disabled(browser.isLoading)

            actionsMenu
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var actionsMenu: some View {
        Menu {
            Button("新建目录…") { browser.beginMakeDirectory() }
            Button("在此创建 tag…") { browser.beginTag(from: nil) }
            Divider()
            Button("导出此目录…") { exportCurrent() }
            Button("导入本地目录…") { promptImport() }
        } label: {
            Label("操作", systemImage: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    // MARK: - Breadcrumb

    private var breadcrumb: some View {
        HStack(spacing: 2) {
            Button {
                Task { await browser.goUp() }
            } label: {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.borderless)
            .disabled(browser.location.parent() == nil)
            .help("上一级")

            let items = browser.location.breadcrumb()
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                if index > 0 {
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                let isLast = index == items.count - 1
                Button(item.name) {
                    Task { await browser.navigate(to: item.path) }
                }
                .buttonStyle(.plain)
                .font(isLast ? .callout.weight(.semibold) : .callout)
                .foregroundStyle(isLast ? Color.primary : Color.accentColor)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(.bar)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if browser.isLoading, browser.listing == nil {
            ProgressView("正在读取仓库…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let listing = browser.listing, listing.isEmpty {
            ContentUnavailableView {
                Label("空目录", systemImage: "folder")
            } description: {
                Text("这个目录里没有任何文件或子目录。")
            } actions: {
                Button("新建目录…") { browser.beginMakeDirectory() }
            }
        } else if let listing = browser.listing {
            List(selection: $selectedName) {
                ForEach(listing.sortedEntries) { entry in
                    row(entry)
                        .tag(entry.name)
                        .contextMenu { contextMenu(for: entry) }
                }
            }
            .listStyle(.inset)
        } else {
            Color.clear
        }
    }

    private func row(_ entry: RemoteEntry) -> some View {
        HStack(spacing: 8) {
            Image(systemName: entry.isDirectory ? "folder.fill" : "doc.text")
                .foregroundStyle(entry.isDirectory ? Color.accentColor : .secondary)
                .frame(width: 16)
            Text(entry.name)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 8)

            if let size = entry.size, !entry.isDirectory {
                Text(ByteCountFormatStyle().format(Int64(size)))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            if let revision = entry.revision {
                Text("r\(revision)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            if let date = entry.date {
                Text(RelativeTime.string(date))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(width: 70, alignment: .trailing)
            }
            if let author = entry.author {
                Text(author)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: 90, alignment: .trailing)
                    .lineLimit(1)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            guard entry.isDirectory else { return }
            Task { await browser.navigate(into: entry) }
        }
        .help(entry.isDirectory ? "双击进入" : entry.name)
    }

    @ViewBuilder
    private func contextMenu(for entry: RemoteEntry) -> some View {
        if entry.isDirectory {
            Button("进入") { Task { await browser.navigate(into: entry) } }
            Divider()
            Button("创建 tag…") { browser.beginTag(from: entry) }
        }
        Button("复制到…") { browser.beginCopy(of: entry) }
        Button("移动到…") { browser.beginMove(of: entry) }
        if entry.isDirectory {
            Button("导出…") { export(entry: entry) }
        }
        Divider()
        Button("删除…", role: .destructive) { browser.beginDelete(entry) }
    }

    private var statusBar: some View {
        HStack(spacing: 10) {
            if let message = browser.lastMessage {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(message)
                    .font(.caption)
                Button {
                    browser.dismissLastMessage()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .controlSize(.mini)
            }
            Spacer()
            Text(countLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private var countLabel: String {
        guard let listing = browser.listing else { return "" }
        let directories = listing.entries.filter(\.isDirectory).count
        return "\(directories) 个目录 · \(listing.entries.count - directories) 个文件"
    }

    // MARK: - Export

    /// `svn import` needs three answers — which directory, what name, what
    /// message — so it asks in sequence rather than in one crowded sheet.
    private func promptImport() {
        let picker = NSOpenPanel()
        picker.canChooseDirectories = true
        picker.canChooseFiles = false
        picker.allowsMultipleSelection = false
        picker.prompt = "导入"
        picker.message = "选择一个尚未纳入版本控制的本地目录"
        guard picker.runModal() == .OK, let source = picker.url else { return }

        let alert = NSAlert()
        alert.messageText = "导入「\(source.lastPathComponent)」"
        alert.informativeText = "目标路径与提交说明。导入是一次提交，目标不能已存在。"
        let stack = NSStackView(frame: NSRect(x: 0, y: 0, width: 380, height: 56))
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        let nameField = NSTextField(frame: NSRect(x: 0, y: 0, width: 380, height: 24))
        nameField.stringValue = source.lastPathComponent
        nameField.placeholderString = "目录名"
        let messageField = NSTextField(frame: NSRect(x: 0, y: 0, width: 380, height: 24))
        messageField.placeholderString = "提交说明"
        stack.addArrangedSubview(nameField)
        stack.addArrangedSubview(messageField)
        alert.accessoryView = stack
        alert.addButton(withTitle: "导入")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let message = messageField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !message.isEmpty else { return }
        Task {
            await browser.importDirectory(from: source, name: name, message: message)
        }
    }

    private func exportCurrent() {
        export(from: browser.location.url)
    }

    private func export(entry: RemoteEntry) {
        guard entry.isDirectory else { return }
        export(from: browser.location.appending(entry.name).url)
    }

    private func export(from url: String) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "导出到此处"
        panel.message = "选择一个空目录：svn export 不会覆盖已有文件"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        Task {
            await browser.export(from: url, to: destination, revision: browser.revision)
        }
    }
}
