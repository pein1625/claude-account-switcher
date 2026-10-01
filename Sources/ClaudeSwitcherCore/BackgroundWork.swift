import Foundation

/// Background work a Claude Code session has started and not yet seen finish, read from its transcript.
/// SIGTERM at a turn boundary kills it with the process (background shells, subagents, monitors), and
/// `--resume` brings back the conversation but never their results, so the Stop hook defers a planned
/// restart while any is pending.
///
/// Only structured fields count: a launch is the `toolUseResult` of the tool that started it, an end is a
/// `<task-notification>` the harness queued or delivered, or a TaskStop result. Matching raw text instead
/// would count an id that merely appears in some command's output. A launch older than `maxAge` no longer
/// counts, so an end the parser missed can never hold a hop off forever; a monitor counts only for its own
/// timeout, and a persistent one never does (it has no end to wait for).
public enum BackgroundWork {
    static let ended = try! NSRegularExpression(
        pattern: #"<task-id>([A-Za-z0-9]+)</task-id>(?:(?!</task-notification>)[\s\S])*?<status>(?:completed|failed|killed|stopped)</status>"#)

    public static func pending(transcript: String, now: Date = Date(), maxAge: TimeInterval = 7200) -> [String] {
        var until: [String: Date] = [:]
        var order: [String] = []
        var done = Set<String>()
        for line in transcript.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = line.data(using: .utf8),
                  let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            let at = (o["timestamp"] as? String).flatMap(ISO8601.parse) ?? now
            if let r = o["toolUseResult"] as? [String: Any] {
                var launched: (String, TimeInterval)?
                if let id = r["backgroundTaskId"] as? String {
                    launched = (id, maxAge)
                } else if r["status"] as? String == "async_launched", let id = r["agentId"] as? String {
                    launched = (id, maxAge)
                } else if let id = r["taskId"] as? String, r["timeoutMs"] != nil, r["persistent"] as? Bool != true {
                    launched = (id, min(maxAge, ((r["timeoutMs"] as? Double) ?? 0) / 1000))
                }
                if let (id, life) = launched {
                    if until[id] == nil { order.append(id) }
                    until[id] = at.addingTimeInterval(life)
                }
                if let id = r["task_id"] as? String, (r["message"] as? String)?.hasPrefix("Successfully stopped") == true {
                    done.insert(id)
                }
            }
            for text in notificationTexts(o) {
                let range = NSRange(text.startIndex..., in: text)
                for m in ended.matches(in: text, range: range) {
                    if let r = Range(m.range(at: 1), in: text) { done.insert(String(text[r])) }
                }
            }
        }
        return order.filter { !done.contains($0) && now < (until[$0] ?? now) }
    }

    /// A notification reaches the transcript as a queued `queue-operation` and, when the session was idle, as a
    /// plain-string user message. Tool results are never read here: their text is output, not harness state.
    static func notificationTexts(_ o: [String: Any]) -> [String] {
        if o["type"] as? String == "queue-operation", let c = o["content"] as? String { return [c] }
        if o["type"] as? String == "user", o["toolUseResult"] == nil,
           let c = (o["message"] as? [String: Any])?["content"] as? String, c.contains("<task-notification>") {
            return [c]
        }
        return []
    }
}
