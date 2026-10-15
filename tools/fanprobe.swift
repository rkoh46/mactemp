// fanprobe — dev CLI: XPC round-trip test against local.mactemp.helper.
// Usage: fanprobe [auto|blast|set <rpm>]
import Foundation

@objc(MacTempFanHelperProtocol)
public protocol MacTempFanHelperProtocol {
    func applyMode(_ mode: String, rpm: Double, withReply reply: @escaping (Bool, String) -> Void)
    func restoreAuto(withReply reply: @escaping (Bool) -> Void)
    func helperVersion(withReply reply: @escaping (String) -> Void)
}

let args = CommandLine.arguments
let mode = args.count > 1 ? args[1] : "auto"
let rpm = args.count > 2 ? (Double(args[2]) ?? 0) : 0

let conn = NSXPCConnection(machServiceName: "local.mactemp.helper", options: [])
conn.remoteObjectInterface = NSXPCInterface(with: MacTempFanHelperProtocol.self)

let sem = DispatchSemaphore(value: 0)
var result = "no-reply"
let proxy = conn.remoteObjectProxyWithErrorHandler { err in
    result = "XPC error: \(err.localizedDescription)"
    sem.signal()
} as? MacTempFanHelperProtocol

if proxy == nil {
    print("could not reach helper")
    exit(2)
}

var version = "?"
proxy?.helperVersion { v in version = v }
switch mode {
case "auto":
    proxy?.restoreAuto { ok in result = "restoreAuto ok=\(ok)"; sem.signal() }
case "blast":
    proxy?.applyMode("blast", rpm: 0) { ok, msg in result = "blast ok=\(ok) msg=\(msg)"; sem.signal() }
case "set":
    proxy?.applyMode("set", rpm: rpm) { ok, msg in result = "set \(rpm) ok=\(ok) msg=\(msg)"; sem.signal() }
default:
    print("usage: fanprobe [auto|blast|set <rpm>]"); exit(1)
}

if sem.wait(timeout: .now() + 8) == .timedOut {
    print("timeout")
    exit(3)
}
// drain the version reply too
Thread.sleep(forTimeInterval: 0.3)
print("helper version: \(version)")
print(result)
conn.invalidate()
exit(0)
