import SwiftUI
import OpenSVNCore

/// Reads and edits the versioned properties of one path.
///
/// Properties are the one part of a working copy the file list can only hint at
/// ("属性" badge, no detail), and `svn:ignore` is the reason people kept a
/// terminal open next to the app.
struct PropertyEditorView: View {
    @Bindable var session: RepositorySession
    @Environment(\.dismiss) private var dismiss

    @State private var newName = ""
    @State private var newValue = ""
    @State private var addError: String?

    private var editor: RepositorySession.PropertyEditorState? { session.propertyEditor }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            if let editor {
                if let loadError = editor.loadError {
                    failure(loadError)
                } else if editor.isLoading && editor.properties.isEmpty {
                    ProgressView("正在读取属性…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    rows(editor)
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Divider()
            addForm
            Divider()
            footer
        }
        .frame(width: 620, height: 600)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "tag")
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 3) {
                Text("属性")
                    .font(.headline)
                Text(editor?.displayPath ?? "")
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer()
            if editor?.isLoading == true {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func failure(_ message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.title2)
                .foregroundStyle(.orange)
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("重试") {
                Task { await session.reloadProperties() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private func rows(_ editor: RepositorySession.PropertyEditorState) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                if editor.properties.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("这个路径没有设置任何属性。")
                            .foregroundStyle(.secondary)
                        Text("要忽略文件，在下方添加 svn:ignore，每行一个通配符模式；也可以在「变更」页右键未纳入版本控制的文件，直接选择「忽略」。")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 8)
                }

                ForEach(editor.properties) { property in
                    PropertyRow(
                        property: property,
                        onApply: { value in
                            Task { await session.setProperty(name: property.name, value: value) }
                        },
                        onDelete: {
                            Task { await session.deleteProperty(name: property.name) }
                        }
                    )
                }
            }
            .padding(16)
        }
    }

    private var addForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                TextField("属性名，例如 custom:owner", text: $newName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
                TextField("值", text: $newValue)
                    .textFieldStyle(.roundedBorder)
                Button("添加") { add() }
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let addError {
                Text(addError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("自定义属性必须带命名空间，例如 custom:owner。以 svn: 开头的是 Subversion 的保留属性。")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var footer: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("属性是版本化元数据，会随下一次提交一起提交；改动可以用「还原」撤销。")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("关闭") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func add() {
        do {
            try SVNPropertyName.validate(newName)
        } catch let error as SVNError {
            addError = error.message
            return
        } catch {
            addError = error.localizedDescription
            return
        }
        addError = nil
        let name = newName
        let value = newValue
        newName = ""
        newValue = ""
        Task { await session.setProperty(name: name, value: value) }
    }
}

/// One property: name, editable value, and the two actions that matter.
private struct PropertyRow: View {
    let property: SVNProperty
    let onApply: (String) -> Void
    let onDelete: () -> Void

    @State private var draft: String

    init(
        property: SVNProperty,
        onApply: @escaping (String) -> Void,
        onDelete: @escaping () -> Void
    ) {
        self.property = property
        self.onApply = onApply
        self.onDelete = onDelete
        _draft = State(initialValue: Self.editableValue(of: property))
    }

    /// svn normalises `svn:ignore` to end with a newline. Showing that newline in
    /// a text editor would look like an empty rule and invite the user to delete
    /// a line that is not there.
    private static func editableValue(of property: SVNProperty) -> String {
        property.isIgnoreList
            ? property.ignoreEntries.joined(separator: "\n")
            : property.value
    }

    private var isChanged: Bool { draft != Self.editableValue(of: property) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(property.name)
                    .font(.system(.callout, design: .monospaced).weight(.medium))
                if property.isReserved {
                    Label("内部", systemImage: "lock.fill")
                        .labelStyle(.titleAndIcon)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .help("Subversion 内部使用的属性，只读")
                }
                if property.isIgnoreList {
                    Text("每行一个通配符模式")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                if isChanged {
                    Button("应用") { onApply(draft) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    Button("撤销") { draft = Self.editableValue(of: property) }
                        .controlSize(.small)
                }
                if !property.isReserved {
                    Button(role: .destructive) {
                        onDelete()
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .help("移除这个属性（可用「还原」恢复）")
                }
            }

            TextEditor(text: $draft)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: property.isIgnoreList ? 68 : 44, maxHeight: 110)
                .padding(4)
                .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 6))
                .disabled(property.isReserved)
                .opacity(property.isReserved ? 0.6 : 1)
        }
        .padding(10)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
        // After a write the sheet reloads and the value changes underneath; the
        // row keeps its identity, so the editor has to be told to follow.
        .onChange(of: property.value) { _, _ in
            draft = Self.editableValue(of: property)
        }
    }
}
