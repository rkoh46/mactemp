// fanctl — fan read/blast/auto CLI. blast/auto need root (SMC writes).
// Usage: fanctl [read|blast|auto] [maxRPM]
import Foundation
import IOKit

typealias SMCBytes_t = (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                        UInt8, UInt8, UInt8, UInt8)

struct SMCKeyData_t {
    struct vers_t { var major: CUnsignedChar = 0; var minor: CUnsignedChar = 0; var build: CUnsignedChar = 0; var reserved: CUnsignedChar = 0; var release: CUnsignedShort = 0 }
    struct LimitData_t { var version: UInt16 = 0; var length: UInt16 = 0; var cpuPLimit: UInt32 = 0; var gpuPLimit: UInt32 = 0; var memPLimit: UInt32 = 0 }
    struct keyInfo_t { var dataSize: IOByteCount32 = 0; var dataType: UInt32 = 0; var dataAttributes: UInt8 = 0 }
    var key: UInt32 = 0
    var vers = vers_t()
    var pLimitData = LimitData_t()
    var keyInfo = keyInfo_t()
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: SMCBytes_t = (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)
}

func FourCC(_ s: String) -> UInt32 { precondition(s.count == 4); return s.utf8.reduce(0) { $0 << 8 | UInt32($1) } }
func typeStr(_ u: UInt32) -> String {
    String(format: "%c%c%c%c", CChar((u >> 24) & 0xff), CChar((u >> 16) & 0xff), CChar((u >> 8) & 0xff), CChar(u & 0xff))
}

final class SMC {
    var conn: io_connect_t = 0
    var isOK = false
    init() {
        var it: io_iterator_t = 0
        guard let m = IOServiceMatching("AppleSMC"),
              IOServiceGetMatchingServices(kIOMainPortDefault, m, &it) == kIOReturnSuccess else { return }
        let dev = IOIteratorNext(it); IOObjectRelease(it)
        guard dev != 0, IOServiceOpen(dev, mach_task_self_, 0, &conn) == kIOReturnSuccess else { isOK = false; IOObjectRelease(dev); return }
        isOK = true
        IOObjectRelease(dev)
    }
    func call(_ data8: UInt8, _ input: inout SMCKeyData_t, _ output: inout SMCKeyData_t) -> kern_return_t {
        input.data8 = data8
        var osz = MemoryLayout<SMCKeyData_t>.stride
        return IOConnectCallStructMethod(conn, 2, &input, MemoryLayout<SMCKeyData_t>.stride, &output, &osz)
    }
    func keyInfo(_ key: String) -> (size: IOByteCount32, type: UInt32)? {
        var i = SMCKeyData_t(), o = SMCKeyData_t()
        i.key = FourCC(key)
        guard call(9, &i, &o) == kIOReturnSuccess, o.result == 0 else { return nil }
        return (o.keyInfo.dataSize, o.keyInfo.dataType)
    }
    func read(_ key: String) -> (bytes: [UInt8], type: String, size: Int)? {
        guard let (size, type) = keyInfo(key), size > 0, size <= 32 else { return nil }
        var i = SMCKeyData_t(), o = SMCKeyData_t()
        i.key = FourCC(key); i.keyInfo.dataSize = size
        guard call(5, &i, &o) == kIOReturnSuccess, o.result == 0 else { return nil }
        var out = [UInt8](repeating: 0, count: 32)
        memcpy(&out, &o.bytes, Int(size))
        return (out, typeStr(type), Int(size))
    }
    func write(_ key: String, bytes: [UInt8]) -> Bool {
        guard let (size, type) = keyInfo(key), size > 0, size <= 32 else { return false }
        var i = SMCKeyData_t(), o = SMCKeyData_t()
        i.key = FourCC(key)
        i.keyInfo.dataSize = size
        i.keyInfo.dataType = type
        for j in 0..<Int(size) { withUnsafeMutableBytes(of: &i.bytes) { $0[j] = bytes[j] } }
        let kr = call(6, &i, &o)
        return kr == kIOReturnSuccess && o.result == 0
    }
    func flt(_ key: String) -> Double? {
        guard let r = read(key) else { return nil }
        if r.type == "flt " { return Double(r.bytes.withUnsafeBytes { $0.load(as: Float.self) }) }
        if r.type == "fpe2" { return Double((Int(r.bytes[0]) << 6) + (Int(r.bytes[1]) >> 2)) }
        if r.type == "ui8 " { return Double(r.bytes[0]) }
        return nil
    }
}

func fltBytes(_ v: Double) -> [UInt8] {
    var f = Float(v)
    return withUnsafeBytes(of: &f) { Array($0) }
}

let cmd = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "read"
let smc = SMC()
guard smc.isOK else { print("SMC unavailable"); exit(2) }
let numFans = Int(smc.flt("FNum") ?? 0)

func modeKey(_ id: Int) -> String { smc.keyInfo("F\(id)md") != nil ? "F\(id)md" : "F\(id)Md" }

func show() {
    print("FNum=\(numFans)")
    for id in 0..<numFans {
        print("fan\(id): rpm=\(String(format: "%.0f", smc.flt("F\(id)Ac") ?? -1)) min=\(String(format: "%.0f", smc.flt("F\(id)Mn") ?? -1)) max=\(String(format: "%.0f", smc.flt("F\(id)Mx") ?? -1)) target=\(String(format: "%.0f", smc.flt("F\(id)Tg") ?? -1)) mode=\(smc.flt(modeKey(id)) ?? -1)")
    }
}

switch cmd {
case "read": show()
case "blast":
    let pct = CommandLine.arguments.count > 2 ? (Double(CommandLine.arguments[2]) ?? 1.0) : 1.0
    for id in 0..<numFans {
        let mk = modeKey(id)
        var ok = false
        for _ in 0..<10 { if smc.write(mk, bytes: [1,0,0,0]) { ok = true; break }; usleep(50_000) }
        print("fan\(id) mode->manual: \(ok ? "OK" : "FAIL")")
        if let mx = smc.flt("F\(id)Mx") {
            var ok2 = false
            for _ in 0..<10 { if smc.write("F\(id)Tg", bytes: fltBytes(mx * pct)) { ok2 = true; break }; usleep(50_000) }
            print("fan\(id) target->\(Int(mx * pct)): \(ok2 ? "OK" : "FAIL")")
        }
    }
case "set":
    let rpm = CommandLine.arguments.count > 2 ? (Double(CommandLine.arguments[2]) ?? 0) : 0
    guard rpm > 0 else { print("set requires <rpm>"); exit(1) }
    for id in 0..<numFans {
        let mk = modeKey(id)
        var ok = false
        for _ in 0..<10 { if smc.write(mk, bytes: [1,0,0,0]) { ok = true; break }; usleep(50_000) }
        print("fan\(id) mode->manual: \(ok ? "OK" : "FAIL")")
        if let mn = smc.flt("F\(id)Mn"), let mx = smc.flt("F\(id)Mx") {
            let clamped = min(max(rpm, mn), mx)
            var ok2 = false
            for _ in 0..<10 { if smc.write("F\(id)Tg", bytes: fltBytes(clamped)) { ok2 = true; break }; usleep(50_000) }
            print("fan\(id) target->\(Int(clamped)): \(ok2 ? "OK" : "FAIL")")
        }
    }
case "auto":
    for id in 0..<numFans {
        let _ = smc.write("F\(id)Tg", bytes: fltBytes(0))
        var ok = false
        for _ in 0..<10 { if smc.write(modeKey(id), bytes: [0,0,0,0]) { ok = true; break }; usleep(50_000) }
        print("fan\(id) ->auto: \(ok ? "OK" : "FAIL")")
    }
default: print("usage: fanctl [read|blast [0-1]|set <rpm>|auto]"); exit(1)
}
