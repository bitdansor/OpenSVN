import AppKit
import SwiftUI
import OpenSVNCore

/// 应用补丁 — `svn patch`.
///
/// The flow is preview-then-apply, and 应用 stays disabled until a preview has
/// been run **for the settings on screen**: a patch is a blind write otherwise,
/// and the one number that decides everything (strip) is invisible in the
/// patch file itself.
struct PatchSheet: View {
    @Bindable var session: RepositorySession
    @Environment(\.dismiss) private var dismiss

    @State private var patchFile: URL?
    @State private var strip = 0
    @State private var reverse = false
    @State private var ignoreWhitespace = false
    @State private var isPreviewing = false
    @State private var isApplying = false
    @State private var preview: PatchOutcome?
    @State private var previewedSignature: String?
    @State private var applied: PatchOutcome?
    @State private var note: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Form {
                Section(L.t("补丁文件")) {
                    LabeledContent(L.t("文件")) {
                        HStack(spacing: 6) {
                            Text(patchFile?.lastPathComponent ?? L.t("未选择"))
                                .foregroundStyle(patchFile == nil ? .secondary : .primary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Button(L.t("选择…")) { choosePatchFile() }
                                .disabled(isApplying)
                        }
                    }
                    LabeledContent(L.t("应用到")) {
                        Text(session.path.path)
                            .font(.caption.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                Section(L.t("选项")) {
                    Stepper(value: $strip, in: 0...6) {
                        Text(L.f("剥离路径层数：%@", String(describing: strip)))
                    }
                    Text(stripHint)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Toggle(L.t("反向应用（--reverse-diff，用来撤销补丁）"), isOn: $reverse)
                    Toggle(L.t("匹配时忽略空白差异（--ignore-whitespace）"), isOn: $ignoreWhitespace)
                }

                if let note {
                    Section {
                        Text(note)
                            .font(.caption2)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                resultSection
            }
            .formStyle(.grouped)
            Divider()
            footer
        }
        .frame(width: 620, height: 620)
        .onChange(of: strip) { invalidatePreview() }
        .onChange(of: reverse) { invalidatePreview() }
        .onChange(of: ignoreWhitespace) { invalidatePreview() }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "doc.badge.plus")
                .font(.system(size: 22))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 3) {
                Text(L.f("给「%@」应用补丁", String(describing: session.displayName)))
                    .font(.headline)
                Text(L.t("把 unidiff 补丁应用到工作副本。补丁可能新增或删除文件。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(16)
    }

    @ViewBuilder
    private var resultSection: some View {
        if let outcome = applied ?? preview {
            Section {
                HStack(spacing: 8) {
                    Image(systemName: resultIcon(outcome))
                        .foregroundStyle(resultColor(outcome))
                    Text(outcome.summary)
                        .font(.callout.weight(.medium))
                    Spacer()
                }
                pathRows(outcome)
                if let summary = outcome.conflictSummary {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !outcome.notes.isEmpty {
                    ForEach(Array(outcome.notes.enumerated()), id: \.offset) { _, note in
                        Text(note)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } header: {
                Text(outcome.isDryRun ? L.t("预览结果（未修改任何文件）") : L.t("结果"))
            } footer: {
                if let footerText = resultFooter(outcome) {
                    Text(footerText)
                        .font(.caption2)
                }
            }
        } else {
            Section {
                Text(L.t("先点「预览」，看清楚会改动哪些文件，再决定是否应用。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func pathRows(_ outcome: PatchOutcome) -> some View {
        ForEach(Array(rows(outcome).enumerated()), id: \.offset) { _, row in
            HStack(spacing: 8) {
                Text(row.marker)
                    .font(.caption.monospaced().weight(.bold))
                    .foregroundStyle(row.color)
                    .frame(width: 16, alignment: .leading)
                Text(row.path)
                    .font(.caption.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
            }
        }
    }

    private struct ResultRow {
        var marker: String
        var path: String
        var color: Color
    }

    private func rows(_ outcome: PatchOutcome) -> [ResultRow] {
        // Conflict first: it is the part that needs action.
        var rows = outcome.conflicted.map {
            ResultRow(marker: "C", path: $0, color: .red)
        }
        rows += outcome.skipped.map {
            ResultRow(marker: "?", path: $0, color: .orange)
        }
        rows += outcome.added.map { ResultRow(marker: "A", path: $0, color: .green) }
        rows += outcome.deleted.map { ResultRow(marker: "D", path: $0, color: .red) }
        rows += outcome.merged.map { ResultRow(marker: "G", path: $0, color: .blue) }
        rows += outcome.updated.map { ResultRow(marker: "U", path: $0, color: .primary) }
        return Array(rows.prefix(20))
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if isPreviewing || isApplying { ProgressView().controlSize(.small) }
            Spacer()
            Button(applied == nil ? L.t("取消") : L.t("关闭")) { dismiss() }
                .keyboardShortcut(.cancelAction)
                .disabled(isPreviewing || isApplying)
            Button(isPreviewing ? L.t("预览中…") : L.t("预览（不修改）")) {
                Task { await runPreview() }
            }
            .disabled(isPreviewing || isApplying || patchFile == nil)
            Button(isApplying ? L.t("应用中…") : L.t("应用")) {
                Task { await runApply() }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!canApply)
        }
        .padding(14)
    }

    private var canApply: Bool {
        guard !isPreviewing, !isApplying, applied == nil else { return false }
        guard let preview, preview.succeeded else { return false }
        // The guard that matters: the preview must describe these exact settings.
        return previewedSignature == signature
    }

    private var signature: String {
        [patchFile?.path ?? "", "\(strip)", "\(reverse)", "\(ignoreWhitespace)"].joined(separator: "|")
    }

    private var stripHint: String {
        if strip == 0 {
            return L.t("补丁里的路径原样使用。用 svn diff 在工作副本里生成的补丁通常带着工作副本目录名，需要 1 层。")
        }
        return L.f("去掉路径开头的 %@ 段。例如 doc/a.txt 去掉 1 层后是 a.txt。", String(describing: strip))
    }

    private func request(dryRun: Bool) -> PatchRequest? {
        guard let patchFile else { return nil }
        return PatchRequest(
            patchFile: patchFile,
            target: session.path,
            strip: strip,
            reverse: reverse,
            ignoreWhitespace: ignoreWhitespace,
            dryRun: dryRun
        )
    }

    private func invalidatePreview() {
        // A stale preview is worse than none: it would enable 应用 for settings
        // the user never looked at.
        preview = nil
        previewedSignature = nil
        applied = nil
    }

    private func choosePatchFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = L.t("选择要应用的补丁文件")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        patchFile = url
        note = nil
        invalidatePreview()
    }

    private func runPreview() async {
        guard let request = request(dryRun: true) else { return }
        note = nil
        isPreviewing = true
        defer { isPreviewing = false }
        do {
            try request.validate()
        } catch let error as SVNError {
            note = error.message
            return
        } catch {
            note = error.localizedDescription
            return
        }
        let outcome = await session.previewPatch(request)
        preview = outcome
        previewedSignature = outcome == nil ? nil : signature
        applied = nil
    }

    private func runApply() async {
        guard let request = request(dryRun: false) else { return }
        note = nil
        isApplying = true
        defer { isApplying = false }
        applied = await session.applyPatch(request)
        if let applied {
            preview = nil
            previewedSignature = nil
            note = applied.succeeded ? nil : L.t("补丁没有完全应用，详情见上方结果。")
        }
    }

    private func resultIcon(_ outcome: PatchOutcome) -> String {
        if outcome.hasConflicts { return "exclamationmark.triangle.fill" }
        if !outcome.skipped.isEmpty { return "questionmark.circle.fill" }
        return outcome.appliedCount > 0 ? "checkmark.circle.fill" : "info.circle"
    }

    private func resultColor(_ outcome: PatchOutcome) -> Color {
        if outcome.hasConflicts || !outcome.skipped.isEmpty { return .orange }
        return outcome.appliedCount > 0 ? .green : .secondary
    }

    private func resultFooter(_ outcome: PatchOutcome) -> String? {
        if !outcome.skipped.isEmpty {
            return L.t("有目标找不到，通常说明「剥离路径层数」不对。看一眼补丁开头的 --- 行是怎么写的，再调整这个数字。")
        }
        if outcome.hasConflicts {
            return L.t("没有匹配上的片段被写进了同目录的 .svnpatch.rej 文件，原文件保持不变。可以手工合并，或者用「还原」放弃这次改动。")
        }
        if outcome.appliedCount == 0 {
            return L.t("这个补丁没有匹配到任何文件。")
        }
        return outcome.isDryRun ? L.t("预览不会改动任何文件。") : L.t("打开「变更」页可以看到这些改动，提交前请先看一眼。")
    }
}
