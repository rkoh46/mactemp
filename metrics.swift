// metrics.swift — IOReport power / usage / frequency engine + network throughput.
// Ported from macmon's IOReport model (CLPC aggregate energy counters, macOS 27;
// residency → usage/frequency math mirrors macmon calc_freq_from_residencies).
import Foundation
import CoreFoundation
import IOKit

// MARK: - libIOReport dynamic linkage

private let ioreportHandle: UnsafeMutableRawPointer? = dlopen("libIOReport.dylib", RTLD_NOW)

private func ioreportSym<T>(_ name: String, _ type: T.Type) -> T? {
    guard let h = ioreportHandle, let p = dlsym(h, name) else { return nil }
    return unsafeBitCast(p, to: type)
}

private typealias CopyAllFn = @convention(c) (UInt64, UInt64) -> Unmanaged<CFDictionary>?
private typealias CreateSubFn = @convention(c) (UnsafeRawPointer?, Unmanaged<CFDictionary>?, UnsafeMutableRawPointer?, UInt64, UnsafeRawPointer?) -> UnsafeMutableRawPointer?
private typealias CreateSamplesFn = @convention(c) (UnsafeRawPointer?, Unmanaged<CFDictionary>?, UnsafeRawPointer?) -> Unmanaged<CFDictionary>?
private typealias CreateDeltaFn = @convention(c) (Unmanaged<CFDictionary>?, Unmanaged<CFDictionary>?, UnsafeRawPointer?) -> Unmanaged<CFDictionary>?
private typealias GetStrFn = @convention(c) (Unmanaged<CFDictionary>?) -> Unmanaged<CFString>?
private typealias GetIntFn = @convention(c) (Unmanaged<CFDictionary>?) -> Int64
private typealias SimpleIntFn = @convention(c) (Unmanaged<CFDictionary>?, Int32) -> Int64
private typealias StateCountFn = @convention(c) (Unmanaged<CFDictionary>?) -> Int32
private typealias StateNameFn = @convention(c) (Unmanaged<CFDictionary>?, Int32) -> Unmanaged<CFString>?
private typealias StateResFn = @convention(c) (Unmanaged<CFDictionary>?, Int32) -> Int64

private func ioCFString(_ s: Unmanaged<CFString>?) -> String {
    s?.takeUnretainedValue() as String? ?? ""
}

// MARK: - CLPC aggregate energy channel table (macOS 27; from macmon clpc.rs)

private struct ClpcKeys { let cpu: UInt32; let gpu: UInt32 }

private let clpcKeysTable: [String: ClpcKeys] = [
    "com.apple.driver.AppleT6000CLPCv3": ClpcKeys(cpu: 0x4747_9059, gpu: 0x4519_bf1e),
    "com.apple.driver.AppleT6002CLPC":   ClpcKeys(cpu: 0xb501_816b, gpu: 0x9e2c_3e8b),
    "com.apple.driver.AppleT6020CLPC":   ClpcKeys(cpu: 0xe301_cd75, gpu: 0x8f34_cc7a),
    "com.apple.driver.AppleT6022CLPC":   ClpcKeys(cpu: 0x76f5_fd21, gpu: 0x9062_4499),
    "com.apple.driver.AppleT6030CLPC":   ClpcKeys(cpu: 0xbe03_a01a, gpu: 0x472d_6c9c),
    "com.apple.driver.AppleT6031CLPC":   ClpcKeys(cpu: 0xd81e_0084, gpu: 0x1085_f98b),
    "com.apple.driver.AppleT6032CLPC":   ClpcKeys(cpu: 0xf4a2_1308, gpu: 0x85e8_0513),
    "com.apple.driver.AppleT6041CLPC":   ClpcKeys(cpu: 0x263c_f1f0, gpu: 0x22e4_cf59),
    "com.apple.driver.AppleT6050CLPC":   ClpcKeys(cpu: 0xd3ab_60bb, gpu: 0x27cd_4ce5),
    "com.apple.driver.AppleT6050dCLPC":  ClpcKeys(cpu: 0x18b3_010e, gpu: 0xedec_a11a),
    "com.apple.driver.AppleT8103CLPCv3": ClpcKeys(cpu: 0x2cdd_31f2, gpu: 0x21be_cf42),
    "com.apple.driver.AppleT8112CLPC":   ClpcKeys(cpu: 0xb543_5137, gpu: 0x638d_9d52),
    "com.apple.driver.AppleT8122CLPC":   ClpcKeys(cpu: 0x54b5_1c99, gpu: 0xce2d_d9dc),
    "com.apple.driver.AppleT8132CLPC":   ClpcKeys(cpu: 0x4a85_4d94, gpu: 0x3b3e_3b79),
    "com.apple.driver.AppleT8140CLPC":   ClpcKeys(cpu: 0x9bf5_4436, gpu: 0xef70_589c),
    "com.apple.driver.AppleT8142CLPC":   ClpcKeys(cpu: 0x4370_8744, gpu: 0x6a01_0933),
    "com.apple.driver.AppleT8152CLPC":   ClpcKeys(cpu: 0x485d_4bfc, gpu: 0x1178_4654),
]

// macOS 27 report indices (macmon INDICES_27): full id = (index << 32) | key.
private let clpcIndexCPU: UInt64 = 16
private let clpcIndexGPU: UInt64 = 25

// MARK: - sysctl helpers

private func sysctlString(_ name: String) -> String? {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
    var buf = [CChar](repeating: 0, count: size)
    guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
    return String(cString: buf)
}

// MARK: - DVFS frequency tables (pmgr IORegistry properties)

private struct DVFSInfo {
    var cpuTiers: [[Double]]   // lowest -> highest perf tier
    var gpuFreqs: [Double]
}

private func isPmgrNode(_ name: String) -> Bool { name == "pmgr" || name == "pmgr-child" }

private func dictValue(_ dict: CFDictionary, _ key: String) -> UnsafeRawPointer? {
    let ks = key as CFString                       // keep the bridged CFString alive for the call
    return CFDictionaryGetValue(dict, Unmanaged.passUnretained(ks).toOpaque())
}

/// voltage-states tables are 8-byte [freq:u32][voltage:u32] pairs (macmon get_dvfs_mhz).
private func freqsFromDVFSBytes(_ bytes: [UInt8], scale: Double) -> [Double] {
    var out: [Double] = []
    var i = 0
    while i + 7 < bytes.count {
        let freq = UInt32(bytes[i]) | UInt32(bytes[i + 1]) << 8 | UInt32(bytes[i + 2]) << 16 | UInt32(bytes[i + 3]) << 24
        out.append(Double(freq) / scale)
        i += 8
    }
    return out
}

private func dvfsFromProps(_ props: CFDictionary, chipName: String) -> DVFSInfo? {
    func cfBytes(_ key: String) -> [UInt8]? {
        guard let v = dictValue(props, key) else { return nil }
        let obj = Unmanaged<AnyObject>.fromOpaque(v).takeUnretainedValue()
        return (obj as? Data).map { [UInt8]($0) }   // as? Data is runtime type-checked
    }

    // M1–M3 / A-series store Hz; M4+ store kHz (macmon cpu_freq_scale).
    let hzFreqs = chipName.contains("M1") || chipName.contains("M2") || chipName.contains("M3")
        || chipName.contains("A1")
    let cpuScale: Double = hzFreqs ? 1_000_000 : 1_000
    // M5+ : acc-clusters lists (voltage-states index, cluster type) 8-byte entries.
    var tierKeys: [String] = []
    if let bytes = cfBytes("acc-clusters") {
        var clusters: [(type: UInt32, key: String)] = []
        var i = 0
        while i + 7 < bytes.count {
            clusters.append((UInt32(bytes[i + 1]), "voltage-states\(bytes[i])-sram"))
            i += 8
        }
        clusters.sort { $0.type < $1.type }
        var seen = Set<String>()
        tierKeys = clusters.filter { seen.insert($0.key).inserted }.map { $0.key }
    }
    if tierKeys.isEmpty { tierKeys = ["voltage-states1-sram", "voltage-states5-sram"] }  // M1-M4 default

    var tiers: [[Double]] = []
    for key in tierKeys {
        guard let bytes = cfBytes(key) else { continue }
        let freqs = freqsFromDVFSBytes(bytes, scale: cpuScale)
        if !freqs.isEmpty { tiers.append(freqs) }
    }

    var gpu: [Double] = []
    if let bytes = cfBytes("voltage-states9-sram") ?? cfBytes("voltage-states9") {
        gpu = freqsFromDVFSBytes(bytes, scale: 1_000_000)
    }

    guard !tiers.isEmpty else { return nil }
    return DVFSInfo(cpuTiers: tiers, gpuFreqs: gpu)
}

private func loadDVFS() -> DVFSInfo? {
    let chipName = sysctlString("machdep.cpu.brand_string") ?? ""
    guard let matching = IOServiceMatching("AppleARMIODevice") else { return nil }
    var it: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &it) == kIOReturnSuccess else { return nil }
    defer { IOObjectRelease(it) }
    while true {
        let entry = IOIteratorNext(it)
        if entry == 0 { break }
        defer { IOObjectRelease(entry) }
        var nameBuf = [CChar](repeating: 0, count: 128)
        IORegistryEntryGetName(entry, &nameBuf)
        guard isPmgrNode(String(cString: nameBuf)) else { continue }
        var propsRef: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(entry, &propsRef, kCFAllocatorDefault, 0) == kIOReturnSuccess,
              let props = propsRef?.takeRetainedValue(),
              let info = dvfsFromProps(props, chipName: chipName) else { continue }
        return info
    }
    return nil
}

// MARK: - residency → usage / frequency (macmon calc_freq_from_residencies)

private struct ResidencyCalc { var avgFreq: Double; var activeRatio: Double }

private func calcResidencies(_ items: [(String, Int64)], freqs: [Double]) -> ResidencyCalc? {
    // Layouts: [IDLE, freq...] / [DOWN, IDLE, freq...] / GPU [OFF, freq...]
    guard let offset = items.firstIndex(where: { $0.0 != "IDLE" && $0.0 != "DOWN" && $0.0 != "OFF" }) else { return nil }
    let active = items.count - offset
    guard active > 0, !freqs.isEmpty else { return nil }
    let n = min(freqs.count, active)

    var usage = 0.0, total = 0.0
    for i in 0..<items.count { total += Double(items[i].1) }
    for i in offset..<offset + n { usage += Double(items[i].1) }
    guard usage > 0, total > 0 else { return ResidencyCalc(avgFreq: 0, activeRatio: 0) }

    var avgFreq = 0.0
    for i in 0..<n {
        avgFreq += (Double(items[offset + i].1) / usage) * freqs[i]
    }
    return ResidencyCalc(avgFreq: avgFreq, activeRatio: usage / total)
}

// Pick the DVFS table whose length best matches the channel's active state count.
private func bestTierTable(_ tiers: [[Double]], activeStates: Int) -> [Double]? {
    guard !tiers.isEmpty else { return nil }
    return tiers.max { a, b in
        let pa = (a.count <= activeStates ? 1 : 0, a.count)
        let pb = (b.count <= activeStates ? 1 : 0, b.count)
        return pa < pb
    }
}

// MARK: - IOReport metrics engine

struct PowerReading {
    var cpuPowerW: Double?
    var gpuPowerW: Double?
    var cpuBusyPct: Double?     // mean per-core active ratio, 0...100
    var cpuMaxMHz: Double?      // highest residency-weighted core frequency
    var gpuBusyPct: Double?
    var gpuMHz: Double?
}

final class IOReportMetrics {
    private let copyAll = ioreportSym("IOReportCopyAllChannels", CopyAllFn.self)
    private let createSub = ioreportSym("IOReportCreateSubscription", CreateSubFn.self)
    private let createSamples = ioreportSym("IOReportCreateSamples", CreateSamplesFn.self)
    private let createDelta = ioreportSym("IOReportCreateSamplesDelta", CreateDeltaFn.self)
    private let getGroup = ioreportSym("IOReportChannelGetGroup", GetStrFn.self)
    private let getSub = ioreportSym("IOReportChannelGetSubGroup", GetStrFn.self)
    private let getName = ioreportSym("IOReportChannelGetChannelName", GetStrFn.self)
    private let getUnit = ioreportSym("IOReportChannelGetUnitLabel", GetStrFn.self)
    private let getChanID = ioreportSym("IOReportChannelGetChannelID", GetIntFn.self)
    private let simpleInt = ioreportSym("IOReportSimpleGetIntegerValue", SimpleIntFn.self)
    private let stateCount = ioreportSym("IOReportStateGetCount", StateCountFn.self)
    private let stateName = ioreportSym("IOReportStateGetNameForIndex", StateNameFn.self)
    private let stateRes = ioreportSym("IOReportStateGetResidency", StateResFn.self)

    private var subscription: UnsafeMutableRawPointer?
    private var subscribed: CFDictionary?          // resolved channel dict for sampling
    private var prevSample: CFDictionary?
    private var prevTime: CFAbsoluteTime = 0

    private let dvfs: DVFSInfo
    private var cpuEnergyID: UInt32?
    private var gpuEnergyID: UInt32?

    init?() {
        guard ioreportHandle != nil,
              let copyAll, let createSub, let createSamples, let getGroup, let getSub,
              let dvfs = loadDVFS() else { return nil }
        self.dvfs = dvfs;

        guard let all = copyAll(0, 0) else { return nil }

        let allDict = all.takeUnretainedValue()
        let channelsKey = "IOReportChannels" as CFString
        let keyOpaque = Unmanaged.passUnretained(channelsKey).toOpaque()
        guard let arrRaw = CFDictionaryGetValue(allDict, keyOpaque) else { return nil }
        let chanArray = unsafeBitCast(arrRaw, to: CFArray.self)

        // selected MUST retain its channel dicts (kCFTypeArrayCallBacks): with nil
        // callbacks the array stores raw pointers, ARC frees the dicts underneath and
        // IOReportCreateSubscription traps on the freed objects (__CF_IS_OBJC).
        var selCB = kCFTypeArrayCallBacks
        guard let chanDict = CFDictionaryCreateMutableCopy(nil, CFDictionaryGetCount(allDict), allDict),
              let selected = CFArrayCreateMutable(nil, 0, &selCB) else { return nil }

        // Subscribe: CPU + GPU performance-state residency channels.
        for i in 0..<CFArrayGetCount(chanArray) {
            let c = unsafeBitCast(CFArrayGetValueAtIndex(chanArray, i)!, to: CFDictionary.self)
            let u = Unmanaged.passUnretained(c)
            let g = ioCFString(getGroup(u)), s = ioCFString(getSub(u))
            if (g == "CPU Stats" && s == "CPU Core Performance States")
                || (g == "GPU Stats" && s == "GPU Performance States") {
                CFArrayAppendValue(selected, Unmanaged.passUnretained(c).toOpaque())
            }
        }

        // Append synthetic CLPC aggregate energy channels (macOS 27 AppleCLPC).
        if let osVer = sysctlString("kern.osproductversion"),
           osVer.split(separator: ".").first == "27",
           let matching = IOServiceMatching("AppleCLPC") {
            var it: io_iterator_t = 0
            if IOServiceGetMatchingServices(kIOMainPortDefault, matching, &it) == kIOReturnSuccess {
                while true {
                    let entry = IOIteratorNext(it)
                    if entry == 0 { break }
                    defer { IOObjectRelease(entry) }
                    var driverID: UInt64 = 0
                    guard IORegistryEntryGetRegistryEntryID(entry, &driverID) == kIOReturnSuccess else { continue }
                    var propsRef: Unmanaged<CFMutableDictionary>?
                    guard IORegistryEntryCreateCFProperties(entry, &propsRef, kCFAllocatorDefault, 0) == kIOReturnSuccess,
                          let props = propsRef?.takeRetainedValue()
                    else { continue }
                    let bundleKey = "CFBundleIdentifier" as CFString
                    guard let bundle = ioCFStringUnret(CFDictionaryGetValue(props, Unmanaged.passUnretained(bundleKey).toOpaque())) else { continue }
                    guard let keys = clpcKeysTable[bundle] else { continue }
                    let ids: [(id: UInt64, key: UInt32, name: String)] = [
                        ((clpcIndexCPU << 32) | UInt64(keys.cpu), keys.cpu, "CPU Energy"),
                        ((clpcIndexGPU << 32) | UInt64(keys.gpu), keys.gpu, "GPU Energy"),
                    ]
                    for entrySpec in ids {
                        if makeCLPCChannel(driverID, entrySpec.id, entrySpec.name)
                            .map({ ch in CFArrayAppendValue(selected, Unmanaged.passUnretained(ch).toOpaque()); return ch }) != nil {
                            if entrySpec.name == "CPU Energy" { cpuEnergyID = entrySpec.key }
                            else { gpuEnergyID = entrySpec.key }
                        }
                    }
                }
                IOObjectRelease(it)
            }
        }
        CFDictionarySetValue(chanDict, keyOpaque, Unmanaged.passUnretained(selected).toOpaque())

        var subscribedRaw: UnsafeMutableRawPointer? = nil
        guard let sub = createSub(nil, Unmanaged.passUnretained(chanDict), &subscribedRaw, 0, nil),
              let subRaw = subscribedRaw else { return nil }
        subscription = sub;

        subscribed = Unmanaged<CFDictionary>.fromOpaque(subRaw).takeUnretainedValue()

        guard let s1 = createSamples(sub, Unmanaged.passUnretained(subscribed!), nil) else { return nil }
        prevSample = s1.takeRetainedValue();

        prevTime = CFAbsoluteTimeGetCurrent()
    }

    private func ioCFStringUnret(_ ptr: UnsafeRawPointer?) -> String? {
        guard let ptr else { return nil }
        return Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
    }

    private func makeCLPCChannel(_ driver: UInt64, _ id: UInt64, _ name: String) -> CFDictionary? {
        // IOReportTypes.h: simple integer, power category, one element; energy in nJ.
        let channelType: Int64 = 1 | (2 << 16) | (1 << 32)
        var unit: Int64 = (3 << 56) | (118 << 32)
        var infoKeyCB = kCFTypeDictionaryKeyCallBacks
        var infoValCB = kCFTypeDictionaryValueCallBacks
        var arrCB = kCFTypeArrayCallBacks
        var numID = Int64(bitPattern: id)
        var numType = channelType
        let legend = CFArrayCreateMutable(nil, 3, &arrCB)
        let numUnit = CFNumberCreate(nil, .sInt64Type, &unit)
        guard let legend,
              let n1 = CFNumberCreate(nil, .sInt64Type, &numID),
              let n2 = CFNumberCreate(nil, .sInt64Type, &numType),
              let numUnit,
              let info = CFDictionaryCreateMutable(nil, 1, &infoKeyCB, &infoValCB)
        else { return nil }
        CFArrayAppendValue(legend, Unmanaged.passRetained(n1).toOpaque())
        CFArrayAppendValue(legend, Unmanaged.passRetained(n2).toOpaque())
        CFArrayAppendValue(legend, Unmanaged.passRetained(name as CFString).toOpaque())
        let unitKey = "IOReportChannelUnit" as CFString
        CFDictionarySetValue(info,
            Unmanaged.passUnretained(unitKey).toOpaque(),
            Unmanaged.passRetained(numUnit).toOpaque())

        var keyCB = kCFTypeDictionaryKeyCallBacks
        var valCB = kCFTypeDictionaryValueCallBacks
        guard let channel = CFDictionaryCreateMutable(nil, 6, &keyCB, &valCB) else { return nil }
        var numDriver = Int64(bitPattern: driver)
        guard let nDriver = CFNumberCreate(nil, .sInt64Type, &numDriver) else { return nil }
        func setV(_ key: String, _ value: UnsafeMutableRawPointer) {
            let ks = key as CFString
            CFDictionarySetValue(channel, Unmanaged.passUnretained(ks).toOpaque(), value)
        }
        setV("DriverID", Unmanaged.passRetained(nDriver).toOpaque())
        setV("DriverName", Unmanaged.passRetained("AppleCLPC" as CFString).toOpaque())
        setV("IOReportGroupName", Unmanaged.passRetained("CLPC" as CFString).toOpaque())
        setV("IOReportSubGroupName", Unmanaged.passRetained("Energy Counters" as CFString).toOpaque())
        setV("IOReportChannelInfo", Unmanaged.passRetained(info).toOpaque())
        setV("LegendChannel", Unmanaged.passRetained(legend).toOpaque())
        return channel
    }

    func sample() -> PowerReading {
        var out = PowerReading()
        guard let sub = subscription, let subscribed, let createSamples, let createDelta else { return out }

        let now = CFAbsoluteTimeGetCurrent()
        guard let s2u = createSamples(sub, Unmanaged.passUnretained(subscribed), nil) else { return out }
        let s2 = s2u.takeRetainedValue()
        guard let prev = prevSample else { prevSample = s2; prevTime = now; return out }
        let elapsed = max(now - prevTime, 0.001)
        prevTime = now

        guard let deltaU = createDelta(Unmanaged.passUnretained(prev), Unmanaged.passUnretained(s2), nil) else {
            prevSample = s2
            return out
        }
        let delta = deltaU.takeRetainedValue()
        prevSample = s2

        guard let getGroup, let getSub, let getName, let getUnit, let getChanID,
              let simpleInt, let stateCount, let stateName, let stateRes else { return out }

        let channelsKey = "IOReportChannels" as CFString
        let keyOpaque = Unmanaged.passUnretained(channelsKey).toOpaque()
        guard let arrRaw = CFDictionaryGetValue(delta, keyOpaque) else { return out }
        let items = unsafeBitCast(arrRaw, to: CFArray.self)

        var busySum = 0.0, busyCount = 0
        var maxMHz = 0.0

        for i in 0..<CFArrayGetCount(items) {
            let item = unsafeBitCast(CFArrayGetValueAtIndex(items, i)!, to: CFDictionary.self)
            let u = Unmanaged.passUnretained(item)
            let g = ioCFString(getGroup(u)), s = ioCFString(getSub(u)), n = ioCFString(getName(u))

            if g == "CLPC" && s == "Energy Counters" { let id = getChanID(u)
                let unit = ioCFString(getUnit(u)).trimmingCharacters(in: .whitespaces)
                let scale: Double = unit == "mJ" ? 1e3 : (unit == "uJ" ? 1e6 : 1e9)
                let watts = Double(simpleInt(u, 0)) / scale / elapsed
                let low = UInt32(truncatingIfNeeded: id)
                if low == cpuEnergyID { out.cpuPowerW = max(watts, 0) }
                else if low == gpuEnergyID { out.gpuPowerW = max(watts, 0) }
            } else if g == "CPU Stats" && s == "CPU Core Performance States" {
                let cnt = stateCount(u)
                guard cnt > 0 else { continue }
                var residencies: [(String, Int64)] = []
                for j in 0..<Int(cnt) {
                    let nm = ioCFString(stateName(u, Int32(j)))
                    residencies.append((nm.isEmpty ? "S\(j)" : nm, stateRes(u, Int32(j))))
                }
                let active = residencies.drop(while: { ["IDLE", "DOWN", "OFF"].contains($0.0) }).count
                guard let table = bestTierTable(dvfs.cpuTiers, activeStates: max(active, 1)),
                      let calc = calcResidencies(residencies, freqs: table) else { continue }
                busySum += calc.activeRatio
                busyCount += 1
                maxMHz = max(maxMHz, calc.avgFreq)
            } else if g == "GPU Stats" && s == "GPU Performance States" && n == "GPUPH" {
                let cnt = stateCount(u)
                guard cnt > 0, !dvfs.gpuFreqs.isEmpty else { continue }
                var residencies: [(String, Int64)] = []
                for j in 0..<Int(cnt) {
                    let nm = ioCFString(stateName(u, Int32(j)))
                    residencies.append((nm.isEmpty ? "S\(j)" : nm, stateRes(u, Int32(j))))
                }
                if let calc = calcResidencies(residencies, freqs: dvfs.gpuFreqs) {
                    out.gpuBusyPct = calc.activeRatio * 100
                    out.gpuMHz = calc.avgFreq
                }
            }
        }

        if busyCount > 0 { out.cpuBusyPct = busySum / Double(busyCount) * 100 }
        if maxMHz > 0 { out.cpuMaxMHz = maxMHz }
        return out
    }
}

// MARK: - Network throughput (getifaddrs byte-counter deltas)

final class NetworkSampler {
    private var prev: [String: (UInt64, UInt64)] = [:]

    /// Returns (downBytesPerSec, upBytesPerSec) since the previous call.
    func sample() -> (down: Double, up: Double) {
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let start = ifap else { return (0, 0) }
        defer { freeifaddrs(ifap) }

        var totals: [UInt64] = [0, 0]
        var ptr: UnsafeMutablePointer<ifaddrs>? = start
        while let cur = ptr {
            let ifa = cur.pointee
            let name = String(cString: ifa.ifa_name)
            // Physical/user-facing interfaces only (skip lo0, utun, awdl, bridge internals).
            let include = name.hasPrefix("en") || name.hasPrefix("eth") || name.hasPrefix("bridge")
            if include, (ifa.ifa_flags & UInt32(IFF_RUNNING)) != 0, let data = ifa.ifa_data {
                let d = data.assumingMemoryBound(to: if_data.self).pointee
                let ib = UInt64(d.ifi_ibytes), ob = UInt64(d.ifi_obytes)
                let bits = UInt64(MemoryLayout.size(ofValue: d.ifi_ibytes)) * 8
                let wrap = UInt64(1) << bits
                if let p = prev[name] {
                    totals[0] &+= ib >= p.0 ? ib - p.0 : (wrap - p.0) + ib
                    totals[1] &+= ob >= p.1 ? ob - p.1 : (wrap - p.1) + ob
                }
                prev[name] = (ib, ob)
            }
            ptr = ifa.ifa_next
        }
        return (Double(totals[0]), Double(totals[1]))
    }
}
