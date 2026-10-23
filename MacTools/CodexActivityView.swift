import SwiftUI

struct CodexActivityGroup: View {
    let messages: [CodexMessage]
    let threadID: String
    @Binding var expansion: CodexActivityExpansionState
    private var running: Int { messages.filter { $0.activity?.isRunning == true }.count }
    var body: some View {
        DisclosureGroup(isExpanded: Binding(get: { expansion.group(thread:threadID, ids:messages.map(\.id), running:running > 0) }, set: { expansion.setGroup($0,thread:threadID,ids:messages.map(\.id)) })) {
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(messages) { message in
                    if let activity = message.activity { CodexActivityDetailView(activity: activity, itemID: message.id, threadID: threadID, expansion: $expansion).equatable() }
                    else { Label(message.text, systemImage: "terminal").font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled) }
                }
            }.padding(.top, 8)
        } label: {
            HStack { Label("\(messages.count) Aktivitäten", systemImage: "terminal"); if running > 0 { Text("\(running) läuft").foregroundStyle(.mint) } }.font(.system(size: 11)).foregroundStyle(.secondary)
        }.onAppear { expansion.rememberGroup(thread:threadID,ids:messages.map(\.id),running:running > 0) }
        .onChange(of: messages.map(\.id)) { ids in expansion.rememberGroup(thread:threadID,ids:ids,running:running > 0) }
    }
}
private struct CodexActivityDetailView: View, Equatable {
    static func ==(lhs:Self,rhs:Self) -> Bool {
        lhs.activity == rhs.activity && lhs.itemID == rhs.itemID && lhs.threadID == rhs.threadID && lhs.expansion.detail(thread:lhs.threadID,id:lhs.itemID,running:lhs.activity.isRunning) == rhs.expansion.detail(thread:rhs.threadID,id:rhs.itemID,running:rhs.activity.isRunning)
    }
    let activity: CodexActivityDetails
    let itemID: String
    let threadID: String
    @Binding var expansion: CodexActivityExpansionState
    var body: some View {
        DisclosureGroup(isExpanded: Binding(get: { expansion.detail(thread:threadID,id:itemID,running:activity.isRunning) }, set: { expansion.setDetail($0,thread:threadID,id:itemID) })) {
            VStack(alignment: .leading, spacing: 10) {
                if let cwd = activity.cwd { Label(cwd, systemImage: "folder").font(.system(size: 10)).foregroundStyle(.secondary).textSelection(.enabled) }
                if !activity.command.isEmpty { code(activity.command, height: 150) }
                if !activity.output.isEmpty {
                    HStack { Text("Ausgabe").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary); Spacer(); Button("Kopieren") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(activity.output, forType: .string) }.buttonStyle(.plain).font(.caption) }
                    code(activity.output, height: 260)
                    if activity.outputTruncated { Text("Ausgabe gekürzt · letzte 65’536 Zeichen").font(.caption2).foregroundStyle(.secondary) }
                } else { Text(activity.isRunning ? "Noch keine Ausgabe vorhanden." : "Keine Ausgabe übermittelt.").font(.caption).foregroundStyle(.secondary) }
            }.padding(.top, 8)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) { Image(systemName: activity.isRunning ? "terminal" : activity.failed ? "exclamationmark.circle" : "checkmark.circle").foregroundStyle(activity.failed ? Color.orange : activity.isRunning ? .mint : .secondary); Text(activity.title).font(.system(size: 12, weight: .medium)); Spacer(minLength: 4) }
                if activity.isRunning { TimelineView(.periodic(from: .now, by: 1)) { context in Text(activity.timingLabel(now: context.date)).font(.system(size: 10)).monospacedDigit().foregroundStyle(.mint) } }
                else { Text(activity.timingLabel(now: Date())).font(.system(size: 10)).foregroundStyle(activity.failed ? Color.orange : .secondary) }
                if !activity.command.isEmpty { Text(activity.command.components(separatedBy: .newlines).first ?? "").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1) }
            }
        }.padding(10).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10)).onAppear { expansion.rememberDetail(thread:threadID,id:itemID,running:activity.isRunning) }
    }
    private func code(_ text: String, height: CGFloat) -> some View {
        ScrollView(.vertical) { Text(text).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(10) }
            .frame(height: min(height, max(36, CGFloat(text.components(separatedBy: .newlines).count) * 15 + 20))).background(Color(nsColor: .textBackgroundColor).opacity(0.65), in: RoundedRectangle(cornerRadius: 8))
    }
}
