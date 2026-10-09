// procstat: per-process CPU, wakeups and energy over an interval, read from the
// kernel's rusage counters (proc_pid_rusage, RUSAGE_INFO_V6). Works without root
// for processes owned by the same user.
//
// Usage: procstat <seconds> <pid> [<pid> ...]
//        procstat <seconds> --tree <rootpid>     (root plus all descendants)
import Darwin
import Foundation

struct Sample {
    var user: UInt64 = 0, system: UInt64 = 0          // mach absolute-time units → converted below
    var idleWakeups: UInt64 = 0, interruptWakeups: UInt64 = 0
    var billedEnergy: UInt64 = 0                        // nJ
    var footprint: UInt64 = 0                           // bytes
    var instructions: UInt64 = 0, cycles: UInt64 = 0
}

func sample(_ pid: pid_t) -> Sample? {
    var info = rusage_info_v6()
    let rc = withUnsafeMutablePointer(to: &info) { ptr in
        ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V6, $0) }
    }
    guard rc == 0 else { return nil }
    return Sample(user: info.ri_user_time, system: info.ri_system_time,
                  idleWakeups: info.ri_pkg_idle_wkups, interruptWakeups: info.ri_interrupt_wkups,
                  billedEnergy: info.ri_billed_energy, footprint: info.ri_phys_footprint,
                  instructions: info.ri_instructions, cycles: info.ri_cycles)
}

func name(_ pid: pid_t) -> String {
    var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
    proc_name(pid, &buf, UInt32(buf.count))
    return String(cString: buf)
}

func children(of pid: pid_t) -> [pid_t] {
    var pids = [pid_t](repeating: 0, count: 4096)
    let n = proc_listchildpids(pid, &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
    guard n > 0 else { return [] }
    return Array(pids.prefix(Int(n)))
}

func tree(_ root: pid_t) -> [pid_t] {
    var out = [root], queue = [root]
    while let p = queue.popLast() { let c = children(of: p); out += c; queue += c }
    return out
}

let args = CommandLine.arguments
guard args.count >= 3, let seconds = Double(args[1]) else {
    print("usage: procstat <seconds> <pid>... | procstat <seconds> --tree <rootpid>"); exit(2)
}
let pids: [pid_t] = args[2] == "--tree" ? tree(pid_t(args[3])!) : args.dropFirst(2).compactMap { pid_t($0) }

var tb = mach_timebase_info_data_t(); mach_timebase_info(&tb)
func ns(_ t: UInt64) -> Double { Double(t) * Double(tb.numer) / Double(tb.denom) }

let before = Dictionary(uniqueKeysWithValues: pids.compactMap { p in sample(p).map { (p, $0) } })
Thread.sleep(forTimeInterval: seconds)
var total = (cpu: 0.0, idle: 0.0, intr: 0.0, fp: 0.0)
func pad(_ s: String, _ n: Int, left: Bool = true) -> String { left ? s.padding(toLength: n, withPad: " ", startingAt: 0) : String(repeating: " ", count: max(0, n - s.count)) + s }
print(pad("pid", 8) + pad("name", 27) + pad("cpu%", 8, left: false) + pad("idle wk/s", 12, left: false) + pad("intr wk/s", 12, left: false) + pad("footprint", 13, left: false))
for p in pids {
    guard let a = before[p], let b = sample(p) else { continue }
    let cpu = (ns(b.user - a.user) + ns(b.system - a.system)) / (seconds * 1e9) * 100
    let idle = Double(b.idleWakeups - a.idleWakeups) / seconds
    let intr = Double(b.interruptWakeups - a.interruptWakeups) / seconds
    let fp = Double(b.footprint) / 1_048_576
    total.cpu += cpu; total.idle += idle; total.intr += intr; total.fp += fp
    print(pad(String(p), 8) + pad(String(name(p).prefix(26)), 27) + pad(String(format: "%.2f", cpu), 8, left: false) + pad(String(format: "%.2f", idle), 12, left: false) + pad(String(format: "%.2f", intr), 12, left: false) + pad(String(format: "%.1f MB", fp), 13, left: false))
}
print(pad("TOTAL", 35) + pad(String(format: "%.2f", total.cpu), 8, left: false) + pad(String(format: "%.2f", total.idle), 12, left: false) + pad(String(format: "%.2f", total.intr), 12, left: false) + pad(String(format: "%.1f MB", total.fp), 13, left: false))
