import SwiftUI
import AppKit

struct LogViewerView: View {
    let stdoutPath: String?
    let stderrPath: String?

    @StateObject private var logService = LogTailService()
    @State private var autoScroll = true
    @State private var searchText = ""

    private var filteredLines: [LogLine] {
        if searchText.isEmpty { return logService.lines }
        return logService.lines.filter { $0.text.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack(spacing: 8) {
                Image(systemName: "doc.text")
                    .foregroundStyle(.secondary)
                Text("Live Logs")
                    .font(.system(.caption, weight: .semibold))

                if logService.isActive {
                    Circle()
                        .fill(.green)
                        .frame(width: 6, height: 6)
                        .symbolEffect(.pulse, isActive: true)
                }

                Spacer()
                Button(logService.isActive ? "Pause" : "Resume") {
                    if logService.isActive { logService.stop() }
                    else { logService.startTailing(stdoutPath: stdoutPath, stderrPath: stderrPath) }
                }.controlSize(.small)

                TextField("Filter...", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 180)
                    .controlSize(.small)

                Toggle(isOn: $autoScroll) {
                    Image(systemName: "arrow.down.to.line")
                }
                .toggleStyle(.button)
                .controlSize(.small)
                .help("Auto-scroll")

                Button {
                    logService.clear()
                } label: {
                    Image(systemName: "trash")
                }
                .controlSize(.small)
                .help("Clear the displayed lines; the log file is retained")

                Button {
                    copyLogs()
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .controlSize(.small)
                .help("Copy all logs")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)

            Divider()

            // Log content
            if let error = logService.errorMessage {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredLines.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "text.page")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                    Text(logService.lines.isEmpty ? "Waiting for log output..." : "No matching lines")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView([.horizontal, .vertical]) {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(filteredLines) { line in
                                logLineView(line)
                                    .id(line.id)
                            }
                        }
                        .padding(8)
                    }
                    .onChange(of: filteredLines.count) {
                        if autoScroll, let last = filteredLines.last {
                            withAnimation(.easeOut(duration: 0.15)) {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                    }
                }
            }
        }
        .background(.fill.quinary, in: RoundedRectangle(cornerRadius: 8))
        .frame(minHeight: 200, maxHeight: 400)
        .onAppear {
            logService.startTailing(stdoutPath: stdoutPath, stderrPath: stderrPath)
        }
        .onDisappear {
            logService.stop()
        }
    }

    private func logLineView(_ line: LogLine) -> some View {
        Text(line.text)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(line.isError ? .red : .primary)
            .lineLimit(nil)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 1)
            .padding(.horizontal, 4)
            .background(line.isError ? Color.red.opacity(0.05) : .clear)
            .textSelection(.enabled)
    }

    private func copyLogs() {
        let text = filteredLines.map { $0.text }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
