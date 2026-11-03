import Foundation
import Combine

struct LogLine: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let isError: Bool
    let timestamp: Date
    static func == (lhs: LogLine, rhs: LogLine) -> Bool { lhs.id == rhs.id }
}

@MainActor
class LogTailService: ObservableObject {
    @Published var lines: [LogLine] = []
    @Published var isActive = false
    @Published var errorMessage: String?

    private struct WatchedFile {
        let path: String
        let handle: FileHandle
        let source: DispatchSourceFileSystemObject
        let generation: UUID
        var tail = Data()
    }
    private var watched: [Bool: WatchedFile] = [:]
    private var session = UUID()
    private var retryTasks: [Bool: Task<Void, Never>] = [:]
    private let maxLines = 5000

    func startTailing(stdoutPath: String?, stderrPath: String?) {
        stop()
        lines = []
        errorMessage = nil
        isActive = true
        if let path = stdoutPath { openFile(path: path, isError: false) }
        if let path = stderrPath { openFile(path: path, isError: true) }
        if watched.isEmpty {
            errorMessage = "Log files are unavailable. Start the service or create the configured log paths, then resume."
            isActive = false
        }
    }

    func stop() {
        session = UUID()
        retryTasks.values.forEach { $0.cancel() }
        retryTasks.removeAll()
        for file in watched.values {
            file.source.cancel() // Cancel handler exclusively owns the monitoring descriptor.
            try? file.handle.close()
        }
        watched.removeAll()
        isActive = false
    }
    func clear() { lines = [] }

    private func openFile(path: String, isError: Bool) {
        let expanded = NSString(string: path).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded)
        guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
              let handle = try? FileHandle(forReadingFrom: url) else { return }
        let fd = Darwin.open(expanded, O_EVTONLY)
        guard fd >= 0 else { try? handle.close(); return }
        let generation = UUID()
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd,
            eventMask: [.write, .extend, .delete, .rename], queue: .main)
        source.setCancelHandler { Darwin.close(fd) }
        watched[isError] = WatchedFile(path: expanded, handle: handle, source: source, generation: generation)
        do {
            let size = try handle.seekToEnd()
            try handle.seek(toOffset: size > 102400 ? size - 102400 : 0)
            read(file: watched[isError]!, isError: isError, dropFirst: size > 102400)
        } catch { errorMessage = error.localizedDescription }
        source.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, let file = self.watched[isError], file.generation == generation, self.isActive else { return }
                if source.data.contains(.delete) || source.data.contains(.rename) {
                    self.rotate(file: file, isError: isError)
                } else { self.read(file: file, isError: isError) }
            }
        }
        source.resume()
    }

    private func read(file: WatchedFile, isError: Bool, dropFirst: Bool = false) {
        do {
            let offset = try file.handle.offset()
            let size = try file.handle.seekToEnd()
            var wasRewritten = size < offset
            if !wasRewritten && !file.tail.isEmpty && offset >= UInt64(file.tail.count) {
                try file.handle.seek(toOffset: offset - UInt64(file.tail.count))
                let checkpoint = try file.handle.read(upToCount: file.tail.count)
                wasRewritten = checkpoint != file.tail
            }
            try file.handle.seek(toOffset: wasRewritten ? 0 : offset)
            guard let data = try file.handle.read(upToCount: 512_000), !data.isEmpty else { return }
            watched[isError]?.tail = Data((wasRewritten ? data : file.tail + data).suffix(64))
            var entries = String(decoding: data, as: UTF8.self).components(separatedBy: .newlines)
            if dropFirst { entries = Array(entries.dropFirst()) }
            lines.append(contentsOf: entries.filter { !$0.isEmpty }.map { LogLine(text: $0, isError: isError, timestamp: Date()) })
            if lines.count > maxLines { lines.removeFirst(lines.count - maxLines) }
        } catch { errorMessage = "Log read failed: \(error.localizedDescription)" }
    }

    private func rotate(file: WatchedFile, isError: Bool) {
        watched.removeValue(forKey: isError)
        file.source.cancel()
        try? file.handle.close()
        let expectedSession = session
        retryTasks[isError]?.cancel()
        retryTasks[isError] = Task { @MainActor [weak self] in
            for _ in 0..<20 {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled, let self, self.session == expectedSession, self.isActive else { return }
                self.openFile(path: file.path, isError: isError)
                if self.watched[isError] != nil { return }
            }
            self?.errorMessage = "Rotated log did not reappear. Resume log following to retry."
        }
    }
}
