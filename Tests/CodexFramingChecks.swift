import Foundation

@main struct CodexFramingChecks {
    static func main() throws {
        let size = 16 * 1024 * 1024
        let text = String(repeating: "x", count: size)
        let line = try JSONSerialization.data(withJSONObject: ["id": 1, "result": ["text": text]]) + Data([10])
        let semaphore = DispatchSemaphore(value: 0)
        let started = Date()
        let reader = CodexJSONLineReader { message in
            precondition(!Thread.isMainThread, "JSON decoding must stay off the UI thread")
            precondition(((message["result"] as? [String: Any])?["text"] as? String)?.count == size)
            semaphore.signal()
        }
        for offset in stride(from: 0, to: line.count, by: 4096) { reader.receive(line.subdata(in: offset..<min(line.count, offset + 4096))) }
        precondition(semaphore.wait(timeout: .now() + 10) == .success, "Large fragmented reply must complete without quadratic rescanning")
        print("PASS: 16 MiB / 4096-byte fragments, exact readback, background decode in \(Date().timeIntervalSince(started)) s")
    }
}
