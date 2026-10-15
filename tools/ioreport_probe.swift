// IOReport probe: enumerate channels, subscribe, 1s delta, dump energy + performance states.
import Foundation
import CoreFoundation

let h = dlopen("libIOReport.dylib", RTLD_NOW)
guard h != nil else { print("dlopen failed"); exit(1) }

func sym<T>(_ name: String, _ type: T.Type) -> T {
    let p = dlsym(h!, name)!
    return unsafeBitCast(p, to: type)
}

typealias CopyAllFn = @convention(c) (UInt64, UInt64) -> Unmanaged<CFDictionary>?
typealias CreateSubFn = @convention(c) (UnsafeRawPointer?, Unmanaged<CFDictionary>?, UnsafeMutableRawPointer?, UInt64, UnsafeRawPointer?) -> UnsafeMutableRawPointer?
typealias CreateSamplesFn = @convention(c) (UnsafeRawPointer?, Unmanaged<CFDictionary>?, UnsafeRawPointer?) -> Unmanaged<CFDictionary>?
typealias CreateDeltaFn = @convention(c) (Unmanaged<CFDictionary>?, Unmanaged<CFDictionary>?, UnsafeRawPointer?) -> Unmanaged<CFDictionary>?
typealias GetStrFn = @convention(c) (Unmanaged<CFDictionary>?) -> Unmanaged<CFString>?
typealias SimpleIntFn = @convention(c) (Unmanaged<CFDictionary>?, Int32) -> Int64
typealias StateCountFn = @convention(c) (Unmanaged<CFDictionary>?) -> Int32
typealias StateNameFn = @convention(c) (Unmanaged<CFDictionary>?, Int32) -> Unmanaged<CFString>?
typealias StateResFn = @convention(c) (Unmanaged<CFDictionary>?, Int32) -> Int64

let copyAll = sym("IOReportCopyAllChannels", CopyAllFn.self)
let createSub = sym("IOReportCreateSubscription", CreateSubFn.self)
let createSamples = sym("IOReportCreateSamples", CreateSamplesFn.self)
let createDelta = sym("IOReportCreateSamplesDelta", CreateDeltaFn.self)
let getGroup = sym("IOReportChannelGetGroup", GetStrFn.self)
let getSub = sym("IOReportChannelGetSubGroup", GetStrFn.self)
let getName = sym("IOReportChannelGetChannelName", GetStrFn.self)
let getUnit = sym("IOReportChannelGetUnitLabel", GetStrFn.self)
let simpleInt = sym("IOReportSimpleGetIntegerValue", SimpleIntFn.self)
let stateCount = sym("IOReportStateGetCount", StateCountFn.self)
let stateName = sym("IOReportStateGetNameForIndex", StateNameFn.self)
let stateRes = sym("IOReportStateGetResidency", StateResFn.self)

func cfstr(_ s: Unmanaged<CFString>?) -> String { s?.takeUnretainedValue() as String? ?? "" }

guard let all = copyAll(0, 0) else { print("no channels"); exit(1) }
let allDict = all.takeUnretainedValue()
let keyOpaque = Unmanaged.passUnretained("IOReportChannels" as CFString).toOpaque()

func channelArray(_ dict: CFDictionary) -> [CFDictionary] {
    guard let arrRaw = CFDictionaryGetValue(dict, keyOpaque) else { return [] }
    let arr = unsafeBitCast(arrRaw, to: CFArray.self)
    let n = CFArrayGetCount(arr)
    var out: [CFDictionary] = []
    for i in 0..<n {
        out.append(unsafeBitCast(CFArrayGetValueAtIndex(arr, i)!, to: CFDictionary.self))
    }
    return out
}

let chanArray = channelArray(allDict)
print("total channels: \(chanArray.count)")

func meta(_ c: CFDictionary) -> (String, String, String, String) {
    let u = Unmanaged.passUnretained(c)
    return (cfstr(getGroup(u)), cfstr(getSub(u)), cfstr(getName(u)), cfstr(getUnit(u)).trimmingCharacters(in: .whitespaces))
}

var groups: [String: Int] = [:]
for c in chanArray { let (g, _, _, _) = meta(c); groups[g, default: 0] += 1 }
print("groups: \(groups.sorted { $0.value > $1.value }.map { "\($0.0):\($0.1)" }.joined(separator: " "))")

let interesting = chanArray.filter { c in
    let (g, s, n, _) = meta(c)
    return g.contains("Energy") || g.contains("CLPC") || g.contains("CPU") || g.contains("GPU") || s.contains("Performance") || n.contains("Energy")
}
for c in interesting {
    let (g, s, n, u) = meta(c)
    print("CH: \(g) | \(s) | \(n) | unit=\(u)")
}

guard let chanDict = CFDictionaryCreateMutableCopy(nil, 1, allDict) else { exit(1) }
guard let sel = CFArrayCreateMutable(nil, 0, nil) else { exit(1) }
for c in interesting { CFArrayAppendValue(sel, Unmanaged.passUnretained(c).toOpaque()) }
CFDictionarySetValue(chanDict, keyOpaque, Unmanaged.passUnretained(sel).toOpaque())

var subscribedRaw: UnsafeMutableRawPointer? = nil
guard let sub = createSub(nil, Unmanaged.passUnretained(chanDict), &subscribedRaw, 0, nil), let subRaw = subscribedRaw else { print("subscription failed"); exit(1) }
let subscribed = Unmanaged<CFDictionary>.fromOpaque(subRaw).takeUnretainedValue()
print("subscribed ok")

guard let s1u = createSamples(sub, Unmanaged.passUnretained(subscribed), nil) else { print("sample1 failed"); exit(1) }
usleep(1_500_000)
guard let s2u = createSamples(sub, Unmanaged.passUnretained(subscribed), nil) else { print("sample2 failed"); exit(1) }
guard let delta = createDelta(s1u, s2u, nil) else { print("delta failed"); exit(1) }
let deltaDict = delta.takeUnretainedValue()
let items = channelArray(deltaDict)
print("delta items: \(items.count)")

for c in items {
    let (g, s, n, u) = meta(c)
    let cnt = stateCount(Unmanaged.passUnretained(c))
    if cnt > 0 {
        var parts: [String] = []
        var i: Int32 = 0
        while i < min(cnt, 14) {
            let nm = cfstr(stateName(Unmanaged.passUnretained(c), i))
            let r = stateRes(Unmanaged.passUnretained(c), i)
            parts.append("\(nm)=\(r)")
            i += 1
        }
        print("STATE: \(g)|\(s)|\(n) unit=\(u) count=\(cnt) [\(parts.joined(separator: " "))]\(cnt > 14 ? " ..." : "")")
    } else {
        let v = simpleInt(Unmanaged.passUnretained(c), 0)
        print("VAL: \(g)|\(s)|\(n) unit=\(u) value=\(v)")
    }
}
