// MacTemp privileged fan helper.
// Installed once via SMJobBless as root launchd job "local.mactemp.helper".
// Fan writes are kernel-gated, so they happen here; the GUI app talks to this
// over XPC with no further prompts.
//
// IMPORTANT (verified on Mac17,15 / macOS 27): AppleSMC silently *ignores* fan
// mode/target writes made directly from a bare launchd system-daemon context —
// the write ioctl returns success (result=0) but the SMC state reverts within
// seconds. Writes from a root process attached to the console user's GUI
// session DO stick. So this helper does not touch IOKit itself: it execs the
// bundled fanctl binary via `launchctl asuser <console uid>`, which runs the
// write as root inside the console session context.
import Foundation
import Security

// MARK: - XPC interface (shared shape with the app)

@objc(MacTempFanHelperProtocol)
public protocol MacTempFanHelperProtocol {
    func applyMode(_ mode: String, rpm: Double, withReply reply: @escaping (Bool, String) -> Void)
    func restoreAuto(withReply reply: @escaping (Bool) -> Void)
    func helperVersion(withReply reply: @escaping (String) -> Void)
}

// MARK: - fanctl discovery + exec in console-session context

func consoleUID() -> uid_t {
    var st = stat()
    if stat("/dev/console", &st) == 0 && st.st_uid > 0 { return st.st_uid }
    return 501
}

func findFanctl(callerPath: String?) -> String? {
    let fm = FileManager.default
    var candidates: [String] = []
    // sibling of the calling app binary (covers non-/Applications installs)
    if let cp = callerPath {
        candidates.append((cp as NSString).deletingLastPathComponent + "/fanctl")
    }
    // sibling of the helper itself (/Library/PrivilegedHelperTools/)
    let helperDir = (CommandLine.arguments[0] as NSString).deletingLastPathComponent
    candidates.append(helperDir + "/fanctl")
    candidates.append("/Applications/MacTemp.app/Contents/MacOS/fanctl")
    for c in candidates where fm.isExecutableFile(atPath: c) { return c }
    return nil
}

@discardableResult
func runFanctl(_ args: [String], callerPath: String?, errorOut: inout String) -> Bool {
    guard let fanctl = findFanctl(callerPath: callerPath) else {
        errorOut = "fanctl binary not found"
        return false
    }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    p.arguments = ["asuser", String(consoleUID()), fanctl] + args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do { try p.run() } catch {
        errorOut = "exec failed: \(error.localizedDescription)"
        return false
    }
    DispatchQueue.global().asyncAfter(deadline: .now() + 10) { if p.isRunning { p.terminate() } }
    p.waitUntilExit()
    let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if p.terminationStatus != 0 || out.contains("FAIL") {
        errorOut = out.isEmpty ? "fanctl exit \(p.terminationStatus)" : out
        return false
    }
    return true
}

// MARK: - exported object

final class FanHelper: NSObject, MacTempFanHelperProtocol {
    let callerPath: String?
    init(callerPath: String?) { self.callerPath = callerPath }

    func applyMode(_ mode: String, rpm: Double, withReply reply: @escaping (Bool, String) -> Void) {
        var args: [String]
        switch mode {
        case "auto":  args = ["auto"]
        case "blast": args = ["blast"]
        case "set":   args = ["set", String(rpm)]
        default:      reply(false, "unknown mode \(mode)"); return
        }
        var err = ""
        let ok = runFanctl(args, callerPath: callerPath, errorOut: &err)
        reply(ok, ok ? "" : err)
    }
    func restoreAuto(withReply reply: @escaping (Bool) -> Void) {
        var err = ""
        reply(runFanctl(["auto"], callerPath: callerPath, errorOut: &err))
    }
    func helperVersion(withReply reply: @escaping (String) -> Void) {
        reply("1.7")  // keep in sync with build.sh / Info.plist
    }
}

// MARK: - listener + client validation

final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        guard let callerPath = clientPath(newConnection), validateClientSignature(callerPath) else {
            NSLog("mactemp-helper: rejected connection from pid \(newConnection.processIdentifier)")
            return false
        }
        newConnection.exportedInterface = NSXPCInterface(with: MacTempFanHelperProtocol.self)
        newConnection.exportedObject = FanHelper(callerPath: callerPath)
        newConnection.resume()
        return true
    }

    // Only processes whose code signature is the MacTemp app may drive the fans.
    private func clientPath(_ connection: NSXPCConnection) -> String? {
        var pathBuf = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(connection.processIdentifier, &pathBuf, UInt32(pathBuf.count)) > 0 else { return nil }
        return String(cString: pathBuf)
    }

    private func validateClientSignature(_ path: String) -> Bool {
        // must be the MacTemp binary inside a bundle named MacTemp.app
        guard path.hasSuffix("/MacTemp.app/Contents/MacOS/MacTemp") else { return false }
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &staticCode) == 0,
              let code = staticCode else { return false }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString("identifier \"local.mactemp\"" as CFString, [], &requirement) == 0,
              let req = requirement else { return false }
        return SecStaticCodeCheckValidity(code, [], req) == errSecSuccess
    }
}

let listener = NSXPCListener(machServiceName: "local.mactemp.helper")
let delegate = ListenerDelegate()
listener.delegate = delegate
listener.resume()
NSLog("mactemp-helper: listening on local.mactemp.helper (pid \(getpid()), uid \(getuid()))")
RunLoop.main.run()
