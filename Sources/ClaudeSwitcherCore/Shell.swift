import Foundation

public struct ShellResult {
    public var status: Int32
    public var stdout: String
    public var stderr: String
    public var ok: Bool { status == 0 }
    public var trimmedOut: String { stdout.trimmingCharacters(in: .whitespacesAndNewlines) }
    public var trimmedErr: String { stderr.trimmingCharacters(in: .whitespacesAndNewlines) }
}

public struct ShellError: LocalizedError {
    public var message: String
    public init(_ m: String) { message = m }
    public var errorDescription: String? { message }
}

/// PATH the app hands to every subprocess. A menu bar app launched by Finder/launchd gets a bare PATH,
/// but the `claude-account` shim needs `jq` (Homebrew) and `claude` (nvm or ~/.local/bin).
public enum Environment {
    public static var extraPath: String = ""

    public static var path: String {
        var dirs: [String] = []
        func add(_ d: String) { if !d.isEmpty, !dirs.contains(d) { dirs.append(d) } }
        // Order matters for `claude`: the native installer (~/.local/bin) and nvm's global install are the
        // ones people keep current; a Homebrew copy is often a stale leftover, so it comes last.
        extraPath.split(separator: ":").forEach { add(String($0)) }
        add(Paths.localBin.path)
        nvmBinDirs().forEach(add)
        (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").forEach { add(String($0)) }
        add("/opt/homebrew/bin")
        add("/usr/local/bin")
        ["/usr/bin", "/bin", "/usr/sbin", "/sbin"].forEach(add)
        return dirs.joined(separator: ":")
    }

    /// Newest installed node under ~/.nvm first; the shim's `claude` may live there.
    public static func nvmBinDirs() -> [String] {
        let root = Paths.home.appendingPathComponent(".nvm/versions/node")
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return [] }
        return names
            .filter { $0.hasPrefix("v") }
            .sorted { versionTuple($0).lexicographicallyPrecedes(versionTuple($1)) }
            .reversed()
            .map { root.appendingPathComponent("\($0)/bin").path }
    }

    private static func versionTuple(_ v: String) -> [Int] {
        v.dropFirst().split(separator: ".").map { Int($0) ?? 0 }
    }

    public static func which(_ name: String) -> String? {
        for d in path.split(separator: ":") {
            let p = "\(d)/\(name)"
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }
}

public enum Shell {
    public static func run(_ exe: String, _ args: [String], stdin: String? = nil,
                           extraEnv: [String: String] = [:], timeout: TimeInterval = 60) async throws -> ShellResult {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                do { cont.resume(returning: try runSync(exe, args, stdin: stdin, extraEnv: extraEnv, timeout: timeout)) }
                catch { cont.resume(throwing: error) }
            }
        }
    }

    public static func runSync(_ exe: String, _ args: [String], stdin: String? = nil,
                               extraEnv: [String: String] = [:], timeout: TimeInterval = 60) throws -> ShellResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = Environment.path
        if env["HOME"] == nil { env["HOME"] = Paths.home.path }
        if env["USER"] == nil { env["USER"] = NSUserName() }
        for (k, v) in extraEnv { env[k] = v }
        p.environment = env

        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        var inPipe: Pipe?
        if stdin != nil { inPipe = Pipe(); p.standardInput = inPipe }

        do { try p.run() } catch { throw ShellError("cannot run \(exe): \(error.localizedDescription)") }

        if let inPipe, let stdin {
            inPipe.fileHandleForWriting.write(Data(stdin.utf8))
            try? inPipe.fileHandleForWriting.close()
        }

        let group = DispatchGroup()
        var outData = Data(), errData = Data()
        group.enter()
        DispatchQueue.global().async { outData = out.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter()
        DispatchQueue.global().async { errData = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }

        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        p.waitUntilExit()
        killer.cancel()
        group.wait()

        return ShellResult(status: p.terminationStatus,
                           stdout: String(decoding: outData, as: UTF8.self),
                           stderr: String(decoding: errData, as: UTF8.self))
    }
}
