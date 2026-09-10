import Foundation
import CodexTopCore

@main struct Inspect {
    static func main() async {
        let arguments = CommandLine.arguments
        let root: URL
        if let index = arguments.firstIndex(of: "--root"), index + 1 < arguments.count { root = URL(fileURLWithPath: arguments[index + 1]) }
        else { root = LocalCodexSource.defaultRoot }
        if arguments.contains("--account-usage") {
            do {
                let start = Date()
                let quota = try await AccountUsageClient(root: root).snapshot()
                let output: [String: Any] = ["origin": quota.origin.rawValue,
                                           "observedAt": ISO8601DateFormatter().string(from: quota.observedAt),
                                           "windowMinutes": quota.windows.map(\.minutes),
                                           "elapsedSeconds": Date().timeIntervalSince(start)]
                let data = try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
                print(String(decoding: data, as: UTF8.self))
            } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
            return
        }
        let source = LocalCodexSource(root: root)
        do {
            let start = Date(); let first = try await source.snapshot()
            let elapsed = Date().timeIntervalSince(start)
            let second = try await source.snapshot()
            let counts = Dictionary(grouping: first.tasks, by: { $0.activity.phase.rawValue }).mapValues(\.count)
            let output: [String: Any] = ["tasks": first.tasks.count, "rootTasks": MonitoringPolicy.roots(in: first.tasks).count,
                                       "phases": counts, "coldBytesRead": first.bytesRead, "nextBytesRead": second.bytesRead,
                                       "coldSeconds": elapsed, "quotaWindows": first.quota?.windows.map(\.minutes) ?? [],
                                       "warning": first.warning ?? ""]
            let data = try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
            print(String(decoding: data, as: UTF8.self))
        } catch {
            fputs("\(error.localizedDescription)\n", stderr); exit(1)
        }
    }
}
