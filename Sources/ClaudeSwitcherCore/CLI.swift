import Foundation

public struct CLIError: LocalizedError {
    public var message: String
    public init(_ m: String) { message = m }
    public var errorDescription: String? { message }
}

/// The `claude-account` CLI is the single writer for snapshots and the live login. The app only calls it.
public struct CLI {
    public let path: String

    public init(path: String) { self.path = path }

    public static func locate() -> CLI? {
        if FileManager.default.isExecutableFile(atPath: Paths.cliShim.path) { return CLI(path: Paths.cliShim.path) }
        if let p = Environment.which("claude-account") { return CLI(path: p) }
        return nil
    }

    public func run(_ args: [String], timeout: TimeInterval = 90) async throws -> ShellResult {
        try await Shell.run("/bin/bash", [path] + args, timeout: timeout)
    }

    private func expectOK(_ r: ShellResult, _ what: String) throws -> String {
        guard r.ok else {
            let msg = r.trimmedErr.isEmpty ? r.trimmedOut : r.trimmedErr
            throw CLIError(msg.isEmpty ? "\(what) failed (exit \(r.status))" : msg.replacingOccurrences(of: "claude-account: ", with: ""))
        }
        return r.trimmedOut
    }

    public func version() async -> String? {
        guard let r = try? await run(["--version"], timeout: 20), r.ok else { return nil }
        return r.trimmedOut
    }

    public func use(_ name: String) async throws -> String { try expectOK(try await run(["use", name]), "use \(name)") }
    public func save(_ name: String) async throws -> String { try expectOK(try await run(["save", name]), "save \(name)") }
    public func remove(_ name: String) async throws -> String { try expectOK(try await run(["remove", name]), "remove \(name)") }
    public func rename(_ old: String, _ new: String) async throws -> String { try expectOK(try await run(["rename", old, new]), "rename") }
    public func names() async throws -> [String] {
        try expectOK(try await run(["names"], timeout: 20), "names").split(separator: "\n").map(String.init)
    }
    public func doctor() async -> String {
        guard let r = try? await run(["doctor"], timeout: 30) else { return "cannot run doctor" }
        return r.stdout + r.stderr
    }

    public static func isValidName(_ n: String) -> Bool {
        !n.isEmpty && n.range(of: "^[A-Za-z0-9._@-]+$", options: .regularExpression) != nil
    }
}
