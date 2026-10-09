import Darwin
import Foundation
import os

/// A process identified by pid plus start time, so a reused pid never gets signalled.
public struct ProcessIdentity: Sendable, Hashable, Codable {
    public var pid: pid_t
    public var startTime: UInt64

    /// Nil when the process is gone.
    public static func of(_ pid: pid_t) -> ProcessIdentity? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return ProcessIdentity(pid: pid, startTime: info.pbi_start_tvsec &* 1_000_000 &+ info.pbi_start_tvusec)
    }

    /// Same pid and same start time.
    public var isAlive: Bool { ProcessIdentity.of(pid) == self }

    /// Signals only if this is still the same process.
    @discardableResult
    public func signal(_ sig: Int32) -> Bool {
        guard isAlive else { return false }
        return kill(pid, sig) == 0
    }
}

public enum ProcessTools {
    public static func children(of pid: pid_t) -> [pid_t] {
        var pids = [pid_t](repeating: 0, count: 1024)
        let n = proc_listchildpids(pid, &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard n > 0 else { return [] }
        return Array(pids.prefix(Int(n))).filter { $0 > 0 }
    }

    /// Every descendant, breadth first. Provider CLIs and terminal shells live here.
    public static func descendants(of pid: pid_t) -> [pid_t] {
        var result: [pid_t] = []
        var queue = children(of: pid)
        while let next = queue.first {
            queue.removeFirst()
            guard !result.contains(next) else { continue }
            result.append(next)
            queue.append(contentsOf: children(of: next))
        }
        return result
    }

    /// `PRIO_DARWIN_BG` on the process and its descendants, or back to normal. Background puts
    /// them on efficiency cores with throttled I/O. Returns the pids it changed.
    @discardableResult
    public static func setBackground(_ background: Bool, root: pid_t) -> [pid_t] {
        let value: Int32 = background ? PRIO_DARWIN_BG : 0
        return ([root] + descendants(of: root)).filter {
            setpriority(PRIO_DARWIN_PROCESS, id_t($0), value) == 0
        }
    }

    /// The task's base scheduling priority: 31 normally, 4 in Darwin background.
    /// (`getpriority(PRIO_DARWIN_PROCESS)` only reports the caller's own state.)
    public static func basePriority(_ pid: pid_t) -> Int32? {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size else { return nil }
        return info.pti_priority
    }

    public static func isBackground(_ pid: pid_t) -> Bool {
        (basePriority(pid) ?? 31) <= 4
    }

    /// Binds 127.0.0.1:0 and returns the port the kernel picked.
    // ponytail: the port can be taken between close and the server's bind; the launch then fails
    // fast and the caller retries. Pass the listening socket over a fd if that ever shows up.
    public static func freeLoopbackPort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let ok = withUnsafeMutablePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, len) == 0 && getsockname(fd, $0, &len) == 0
            }
        }
        guard ok else { throw POSIXError(.init(rawValue: errno) ?? .EADDRINUSE) }
        return Int(UInt16(bigEndian: addr.sin_port))
    }

    /// The user's login shell from the password database, for the server's PATH hydration.
    public static var loginShell: String {
        if let pw = getpwuid(getuid()), let shell = pw.pointee.pw_shell { return String(cString: shell) }
        return "/bin/zsh"
    }
}

/// Watches a child we spawned and reaps it. Event driven (kqueue via a dispatch process
/// source), so waiting costs nothing.
final class ChildExitWatcher: Sendable {
    let pid: pid_t
    private struct State {
        var status: Int32?
        var waiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let source: DispatchSourceProcess

    init(pid: pid_t) {
        self.pid = pid
        source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .global(qos: .utility))
        source.setEventHandler { [weak self] in self?.reap() }
        source.resume()
        // The child may have exited before the source was armed.
        reap()
    }

    deinit { source.cancel() }

    var exitStatus: Int32? { state.withLock { $0.status } }

    /// Waits until the child exits, or `timeout` passes. True when it exited.
    func waitForExit(timeout: Duration? = nil) async -> Bool {
        let id = UUID()
        let timer: Task<Void, Never>? = timeout.map { timeout in
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                self?.resume(id, with: false)
            }
        }
        defer { timer?.cancel() }
        return await withCheckedContinuation { continuation in
            let done: Bool = state.withLock { s in
                if s.status != nil { return true }
                s.waiters[id] = continuation
                return false
            }
            if done { continuation.resume(returning: true) }
        }
    }

    private func resume(_ id: UUID, with value: Bool) {
        state.withLock { $0.waiters.removeValue(forKey: id) }?.resume(returning: value)
    }

    private func reap() {
        var raw: Int32 = 0
        guard waitpid(pid, &raw, WNOHANG) == pid else { return }
        let exit = (raw & 0x7f) == 0 ? (raw >> 8) & 0xff : -(raw & 0x7f)
        let waiters = state.withLock { s in
            s.status = exit
            defer { s.waiters = [:] }
            return s.waiters
        }
        source.cancel()
        for w in waiters.values { w.resume(returning: true) }
    }
}
