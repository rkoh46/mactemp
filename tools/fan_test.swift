// Fan control feasibility probe (M5 Ultra, no sudo).
// Reads fan keys, tries mode+target writes, watches RPM response, restores auto.
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
func unFourCC(_ c: UInt32) -> String {
    let b: [UInt8] = [UInt8((c >> 24) & 0xff), UInt8((c >> 16) & 0xff), UInt8((c >> 8) & 0xff), UInt8(c & 0xff)]
    return String(decoding: b, as: UTF8.self)
}
func typeStr(_ u: UInt32) -> String {
    String(format: "%c%c%c%c", CChar((u >> 24) & 0xff), CChar((u >> 16) & 0xff), CChar((u >> 8) & 0xff), CChar(u & 0xff))
}

final class SMCProbe {
    var conn: io_connect_t = 0
    init() {
        var it: io_iterator_t = 0
        guard let m = IOServiceMatching("AppleSMC"),
              IOServiceGetMatchingServices(kIOMainPortDefault, m, &it) == kIOReturnSuccess else { fatalError("no AppleSMC") }
        let dev = IOIteratorNext(it); IOObjectRelease(it)
        guard IOServiceOpen(dev, mach_task_self_, 0, &conn) == kIOReturnSuccess else { fatalError("open failed") }
        IOObjectRelease(dev)
    }
    func call(_ index: UInt8, _ input: inout SMCKeyData_t, _ output: inout SMCKeyData_t) -> kern_return_t {
        var osz = MemoryLayout<SMCKeyData_t>.stride
        return IOConnectCallStructMethod(conn, 2, &input, MemoryLayout<SMCKeyData_t>.stride, &output, &osz)
    }
    func keyInfo(_ key: String) -> (size: IOByteCount32, type: UInt32, attrs: UInt8)? {
        var i = SMCKeyData_t(), o = SMCKeyData_t()
        i.key = FourCC(key); i.data8 = 9
        guard call(2, &i, &o) == kIOReturnSuccess, o.result == 0 else { return nil }
        return (o.keyInfo.dataSize, o.keyInfo.dataType, o.keyInfo.dataAttributes)
    }
    func read(_ key: String) -> (bytes: [UInt8], type: String, size: Int)? {
        guard let (size, type, _) = keyInfo(key), size > 0, size <= 32 else { return nil }
        var i = SMCKeyData_t(), o = SMCKeyData_t()
        i.key = FourCC(key); i.keyInfo.dataSize = size; i.data8 = 5
        guard call(2, &i, &o) == kIOReturnSuccess, o.result == 0 else { return nil }
        var out = [UInt8](repeating: 0, count: 32)
        memcpy(&out, &o.bytes, Int(size))
        return (out, typeStr(type), Int(size))
    }
    /// writeBytes selector = 6 (stats protocol)
    func write(_ key: String, bytes: [UInt8], size: Int, type: String) -> (kr: kern_return_t, result: UInt8) {
        guard let (_, _, _) = keyInfo(key) else { return (kIOReturnBadArgument, 255) }
        var i = SMCKeyData_t(), o = SMCKeyData_t()
        i.key = FourCC(key)
        i.keyInfo.dataSize = IOByteCount32(size)
        i.keyInfo.dataType = FourCC(type)
        i.data8 = 6
        for j in 0..<min(bytes.count, 32) {
            withUnsafeMutableBytes(of: &i.bytes) { $0[j] = bytes[j] }
        }
        let kr = call(2, &i, &o)
        return (kr, o.result)
    }
    func floatVal(_ key: String) -> Double? {
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

let smc = SMCProbe()
let numFans = Int(smc.floatVal("FNum") ?? 0)
print("FNum = \(numFans)")

// list all F* keys with attributes
var it = SMCKeyData_t(), ot = SMCKeyData_t()
if let count = smc.floatVal("#KEY") {
    var fkeys: [String] = []
    for idx in 0..<Int(count) {
        var i = SMCKeyData_t(), o = SMCKeyData_t()
        i.data8 = 8; i.data32 = UInt32(idx)
        guard smc.call(2, &i, &o) == kIOReturnSuccess, o.result == 0 else { continue }
        let n = unFourCC(o.key)
        if n.hasPrefix("F") { fkeys.append(n) }
    }
    print("F keys: \(fkeys.sorted().joined(separator: " "))")
}
for k in ["Ftst", "FS! ", "F0md", "F0Md", "F0Fl", "F0Ac", "F0Mn", "F0Mx", "F0Tg", "F0Md", "F1Ac", "F1Mn", "F1Mx", "F1Tg", "F1md", "F1Md"] {
    if let (size, type, attrs) = smc.keyInfo(k) {
        print("\(k): size=\(size) type=\(typeStr(type)) attrs=\(attrs) val=\(smc.floatVal(k).map { String(format: "%.1f", $0) } ?? "?")")
    }
}

guard numFans > 0 else { print("no fans"); exit(0) }
let modeKey = smc.keyInfo("F0md") != nil ? "F0md" : "F0Md"
print("mode key = \(modeKey)")

func rpm(_ id: Int) -> Double? { smc.floatVal("F\(id)Ac") }
for id in 0..<numFans { print("fan\(id): current=\(rpm(id) ?? -1) min=\(smc.floatVal("F\(id)Mn") ?? -1) max=\(smc.floatVal("F\(id)Mx") ?? -1) target=\(smc.floatVal("F\(id)Tg") ?? -1) mode=\(smc.floatVal(id == 0 ? "F0md" : "F1md") ?? smc.floatVal("F\(id)Md") ?? -1)") }

if let ftst = smc.keyInfo("Ftst") {
    print("Ftst present, trying Ftst=1...")
    let r = smc.write("Ftst", bytes: [1,0,0,0], size: Int(ftst.size), type: typeStr(ftst.type))
    print("Ftst write: kr=\(r.kr == 0 ? "OK" : String(format: "0x%x", r.kr)) result=\(r.result)")
}

// try direct mode write on fan 0
let mx = smc.floatVal("F0Mx") ?? 5000
var modeInfo = smc.keyInfo(modeKey)!
var r = smc.write(modeKey, bytes: [1,0,0,0], size: Int(modeInfo.size), type: typeStr(modeInfo.type))
print("\(modeKey)=1 write: kr=\(r.kr == 0 ? "OK" : String(format: "0x%x", r.kr)) result=\(r.result)")
usleep(500_000)
if let back = smc.floatVal(modeKey) { print("\(modeKey) now = \(back)") }

// target 85% of max on fan 0
if let tgInfo = smc.keyInfo("F0Tg") {
    let target = mx * 0.85
    r = smc.write("F0Tg", bytes: fltBytes(target), size: Int(tgInfo.size), type: typeStr(tgInfo.type))
    print("F0Tg=\(Int(target)) write: kr=\(r.kr == 0 ? "OK" : String(format: "0x%x", r.kr)) result=\(r.result)")
}

for s in 1...5 {
    usleep(1_000_000)
    print("t=\(s)s rpm0=\(rpm(0) ?? -1)" + (numFans > 1 ? " rpm1=\(rpm(1) ?? -1)" : ""))
}

// restore auto
if let tgInfo = smc.keyInfo("F0Tg") {
    r = smc.write("F0Tg", bytes: fltBytes(0), size: Int(tgInfo.size), type: typeStr(tgInfo.type))
    print("F0Tg=0 restore: kr=\(r.kr == 0 ? "OK" : String(format: "0x%x", r.kr)) result=\(r.result)")
}
r = smc.write(modeKey, bytes: [0,0,0,0], size: Int(modeInfo.size), type: typeStr(modeInfo.type))
print("\(modeKey)=0 restore: kr=\(r.kr == 0 ? "OK" : String(format: "0x%x", r.kr)) result=\(r.result)")
usleep(500_000)
for id in 0..<numFans { print("after: fan\(id) rpm=\(rpm(id) ?? -1) mode=\(smc.floatVal("F\(id)md") ?? smc.floatVal("F\(id)Md") ?? -1)") }
