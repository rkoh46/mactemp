import AppKit
import IOKit
import CoreFoundation

// MARK: - SMC (Apple Silicon, in-process, no sudo)
// Protocol layout from exelban/stats; key classification (Tp/Te/Ts = CPU, Tg = GPU) from vladkens/macmon.

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

private enum SMCSelector: UInt8 {
    case kernelIndex = 2
    case readBytes = 5
    case readIndex = 8
    case readKeyInfo = 9
}

final class SMC {
    private var conn: io_connect_t = 0
    private(set) var isOK = false

    init() {
        var iterator: io_iterator_t = 0
        guard let matching = IOServiceMatching("AppleSMC"),
              IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == kIOReturnSuccess else { return }
        let device = IOIteratorNext(iterator)
        IOObjectRelease(iterator)
        guard device != 0 else { return }
        if IOServiceOpen(device, mach_task_self_, 0, &conn) == kIOReturnSuccess {
            isOK = true
        }
        IOObjectRelease(device)
    }

    private func call(_ index: UInt8, input: inout SMCKeyData_t, output: inout SMCKeyData_t) -> kern_return_t {
        let inputSize = MemoryLayout<SMCKeyData_t>.stride
        var outputSize = MemoryLayout<SMCKeyData_t>.stride
        return IOConnectCallStructMethod(conn, UInt32(index), &input, inputSize, &output, &outputSize)
    }

    private func keyInfo(_ key: String) -> (size: IOByteCount32, type: UInt32)? {
        var input = SMCKeyData_t(); var output = SMCKeyData_t()
        input.key = FourCharCode(fromString: key)
        input.data8 = SMCSelector.readKeyInfo.rawValue
        guard call(SMCSelector.kernelIndex.rawValue, input: &input, output: &output) == kIOReturnSuccess,
              output.result == 0 else { return nil }
        return (output.keyInfo.dataSize, output.keyInfo.dataType)
    }

    private func readBytes(_ key: String, size: IOByteCount32) -> [UInt8]? {
        var input = SMCKeyData_t(); var output = SMCKeyData_t()
        input.key = FourCharCode(fromString: key)
        input.keyInfo.dataSize = size
        input.data8 = SMCSelector.readBytes.rawValue
        guard call(SMCSelector.kernelIndex.rawValue, input: &input, output: &output) == kIOReturnSuccess,
              output.result == 0 else { return nil }
        var out = [UInt8](repeating: 0, count: 32)
        memcpy(&out, &output.bytes, Int(size))
        return out
    }

    private func decode(_ b: [UInt8], _ type: String) -> Double? {
        let u16 = Double(UInt16(bytes: (b[0], b[1])))
        let i16 = Double(Int16(bitPattern: UInt16(bytes: (b[0], b[1]))))
        switch type {
        case "ui8 ": return Double(b[0])
        case "ui16": return u16
        case "ui32": return Double(UInt32(bytes: (b[0], b[1], b[2], b[3])))
        case "sp1e": return u16 / 16384
        case "sp3c": return u16 / 4096
        case "sp4b": return u16 / 2048
        case "sp5a": return u16 / 1024
        case "sp69": return u16 / 512
        case "sp78": return i16 / 256
        case "sp87": return i16 / 128
        case "sp96": return i16 / 64
        case "spa5": return u16 / 32
        case "spb4": return i16 / 16
        case "spf0": return i16
        case "flt ": return b.withUnsafeBytes { Double($0.load(fromByteOffset: 0, as: Float.self)) }
        case "fpe2": return Double((Int(b[0]) << 6) + (Int(b[1]) >> 2))
        default: return nil
        }
    }

    /// Read one SMC key as a Double (its natural numeric type).
    func getValue(_ key: String) -> Double? {
        guard let (size, type) = keyInfo(key), size > 0, size <= 32 else { return nil }
        guard let b = readBytes(key, size: size) else { return nil }
        return decode(b, dataTypeString(type))
    }

    /// Enumerate all SMC keys and split into CPU (Tp*/Te*/Ts*) and GPU (Tg*) lists,
    /// matching vladkens/macmon. Called once at startup; reads are per-key afterwards.
    func classifyTempKeys() -> (cpu: [String], gpu: [String]) {
        guard let count = getValue("#KEY") else { return ([], []) }
        var cpu: [String] = []; var gpu: [String] = []
        var input = SMCKeyData_t(); var output = SMCKeyData_t()
        for i in 0..<Int(count) {
            input = SMCKeyData_t(); output = SMCKeyData_t()
            input.data8 = SMCSelector.readIndex.rawValue
            input.data32 = UInt32(i)
            guard call(SMCSelector.kernelIndex.rawValue, input: &input, output: &output) == kIOReturnSuccess,
                  output.result == 0 else { continue }
            let name = fourCharCodeToString(output.key)
            guard name.count == 4, name.first == "T" else { continue }
            if name.hasPrefix("Tp") || name.hasPrefix("Te") || name.hasPrefix("Ts") { cpu.append(name) }
            else if name.hasPrefix("Tg") { gpu.append(name) }
        }
        return (cpu, gpu)
    }
}

// MARK: - FourCharCode helpers
extension FourCharCode {
    init(fromString str: String) { precondition(str.count == 4); self = str.utf8.reduce(0) { $0 << 8 | UInt32($1) } }
}
private func fourCharCodeToString(_ c: FourCharCode) -> String {
    let bytes: [UInt8] = [UInt8((c >> 24) & 0xff), UInt8((c >> 16) & 0xff), UInt8((c >> 8) & 0xff), UInt8(c & 0xff)]
    return String(decoding: bytes, as: UTF8.self)
}
private func dataTypeString(_ u: UInt32) -> String {
    String(format: "%c%c%c%c", CChar((u >> 24) & 0xff), CChar((u >> 16) & 0xff), CChar((u >> 8) & 0xff), CChar(u & 0xff))
}
extension UInt16 { init(bytes: (UInt8, UInt8)) { self = UInt16(bytes.0) << 8 | UInt16(bytes.1) } }
extension UInt32 { init(bytes: (UInt8, UInt8, UInt8, UInt8)) { self = UInt32(bytes.0) << 24 | UInt32(bytes.1) << 16 | UInt32(bytes.2) << 8 | UInt32(bytes.3) } }

// MARK: - System sample
struct SystemSample {
    var cpuTemp: Double?; var gpuTemp: Double?; var ssdTemp: Double?   // Celsius
    var ramUsed: UInt64?; var ramTotal: UInt64?                        // bytes
    var swapUsed: UInt64?; var swapTotal: UInt64?                      // bytes
    var cpuLoad: Double?                                               // 0-100 %
    var diskFree: UInt64?; var diskTotal: UInt64?                      // bytes (root volume)
    var pressure: Int?                                                 // 1 normal, 2 warn, 3 critical
}

func formatBytes(_ b: UInt64) -> String {
    let gb = Double(b) / 1_073_741_824.0
    if gb >= 10 { return String(format: "%.0fGB", gb) }
    if gb >= 1  { return String(format: "%.1fGB", gb) }
    return String(format: "%.0fMB", Double(b) / 1_048_576.0)
}

// MARK: - Temperature color thresholds (Celsius)
enum TempLevel {
    case normal, warning, hot

    static func level(_ celsius: Double) -> TempLevel {
        if celsius >= 80 { return .hot }
        if celsius >= 60 { return .warning }
        return .normal
    }

    var color: NSColor {
        switch self {
        case .normal:  return NSColor.labelColor
        case .warning: return NSColor.systemYellow
        case .hot:     return NSColor.systemRed
        }
    }

    fileprivate var rank: Int {
        switch self { case .normal: return 0; case .warning: return 1; case .hot: return 2 }
    }
}

// MARK: - Sampler (SMC temps + IOHID NAND + Mach VM stats + CPU ticks + statfs)
final class SystemSampler {
    private let smc = SMC()
    private var cpuKeys: [String] = []
    private var gpuKeys: [String] = []
    private let hidNameSlot = 64
    private let hidMax = 128
    private var prevTicks: [[UInt32]]? = nil
    var smcAvailable = false

    init() {
        smcAvailable = smc.isOK
        (cpuKeys, gpuKeys) = smc.classifyTempKeys()
    }

    private func average(_ keys: [String]) -> Double? {
        var sum = 0.0; var n = 0
        for k in keys {
            if let v = smc.getValue(k), v > -50, v < 150 { sum += v; n += 1 }
        }
        return n > 0 ? sum / Double(n) : nil
    }

    func sample() -> SystemSample {
        var s = SystemSample()
        if smcAvailable {
            s.cpuTemp = average(cpuKeys)
            s.gpuTemp = average(gpuKeys)
        }
        // SSD temp via IOHID (NAND sensor)
        var names = [Int8](repeating: 0, count: hidNameSlot * hidMax)
        var temps = [Double](repeating: 0, count: hidMax)
        _ = names.withUnsafeMutableBufferPointer { np -> Int in
            let resI = Int(temps.withUnsafeMutableBufferPointer { tp in
                hid_temp_get_sensors(np.baseAddress!, Int32(hidNameSlot), tp.baseAddress!, Int32(hidMax))
            })
            guard resI > 0 else { return resI }
            for i in 0..<resI {
                let slot = UnsafeMutableRawPointer(np.baseAddress!).advanced(by: i * hidNameSlot)
                let s2 = String(cString: slot.assumingMemoryBound(to: CChar.self))
                if s2.contains("NAND") || s2.contains("SSD") {
                    let v = temps[i]
                    if v > 0, v < 150, (s.ssdTemp == nil || v > s.ssdTemp!) { s.ssdTemp = v }
                }
            }
            return resI
        }

        // RAM via Mach host statistics
        s.ramTotal = ProcessInfo.processInfo.physicalMemory
        s.ramUsed = SystemSampler.readRAMUsed()

        // Swap via sysctl vm.swapusage (xsw_usage struct; sysctlbyname returns binary, not text)
        if let sw = SystemSampler.readSwap() {
            s.swapTotal = sw.total
            s.swapUsed  = sw.used
        }

        // Memory pressure via sysctl kern.memorystatus_vm_pressure_level
        s.pressure = SystemSampler.memoryPressure()

        // CPU load from per-core tick deltas
        s.cpuLoad = SystemSampler.cpuLoad(&prevTicks)

        // Disk (root volume)
        var st = statfs()
        if statfs("/", &st) == 0 {
            let bsize = UInt64(st.f_bsize)
            s.diskTotal = bsize * UInt64(st.f_blocks)
            s.diskFree  = bsize * UInt64(st.f_bavail)
        }
        return s
    }

    static func readRAMUsed() -> UInt64? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        // matches Activity Monitor "Memory Used": app + linked + wired + compressed (purgeable excluded)
        let pageSize = UInt64(vm_kernel_page_size)
        let used = UInt64(stats.active_count) + UInt64(stats.inactive_count)
                 + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)
        return used * pageSize
    }

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        sysctlbyname(name, nil, &size, nil, 0)
        guard size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        sysctlbyname(name, &buf, &size, nil, 0)
        return String(cString: buf)
    }

    struct xsw_usage_swift {
        var xsu_total: UInt64 = 0
        var xsu_avail: UInt64 = 0
        var xsu_used: UInt64 = 0
        var xsu_pagesize: UInt32 = 0
        var xsu_encrypted: UInt32 = 0
    }

    static func readSwap() -> (total: UInt64, used: UInt64)? {
        var x = xsw_usage_swift()
        var size = MemoryLayout<xsw_usage_swift>.stride
        guard sysctlbyname("vm.swapusage", &x, &size, nil, 0) == 0, x.xsu_total > 0 else { return nil }
        return (x.xsu_total, x.xsu_used)
    }

    static func memoryPressure() -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.stride
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &value, &size, nil, 0) == 0 else { return nil }
        return Int(value)   // 1 = normal, 2 = warning, 3 = critical (unpublished but stable)
    }

    /// CPU utilisation from PROCESSOR_CPU_LOAD_INFO deltas between calls (first call returns nil).
    static func cpuLoad(_ prev: inout [[UInt32]]?) -> Double? {
        var infoPtr: processor_info_array_t? = nil
        var numCPU: mach_msg_type_number_t = 0
        var cpuCount: natural_t = 0
        let kr = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &infoPtr, &numCPU)
        guard kr == KERN_SUCCESS, let info = infoPtr else { return nil }
        let n = Int(numCPU) / Int(CPU_STATE_MAX)
        var states: [[UInt32]] = []
        for i in 0..<n {
            let base = i * Int(CPU_STATE_MAX)
            states.append((0..<Int(CPU_STATE_MAX)).map { UInt32(info[base + $0]) })
        }
        vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info),
                      vm_size_t(Int(numCPU) * MemoryLayout<integer_t>.stride))
        let current = states
        defer { prev = current }
        guard let old = prev, old.count == n else { return nil }
        var busy: Double = 0, total: Double = 0
        for i in 0..<n {
            for j in 0..<Int(CPU_STATE_MAX) {
                let d = Double(current[i][j] &- old[i][j])
                total += d
                if j != Int(CPU_STATE_IDLE) { busy += d }
            }
        }
        return total > 0 ? busy / total * 100.0 : nil
    }
}

// MARK: - Temperature unit
enum TempUnit: Int {
    case celsius, fahrenheit
    /// Celsius → display unit.
    func convert(_ celsius: Double) -> Double {
        self == .celsius ? celsius : celsius * 9.0 / 5.0 + 32.0
    }
    func format(_ celsius: Double) -> String {
        String(format: "%.0f°", convert(celsius))
    }
}

// MARK: - Menu bar display mode
enum BarMode: Int {
    case tempsOnly = 0     // CPU 62°  GPU 71°  SSD 33°
    case tempsPlusRAM = 1  // CPU 62°  GPU 71°  SSD 33°  RAM 45GB
    case compact = 2       // 62° 45GB (temp of hottest component + RAM)
    var title: String {
        switch self {
        case .tempsOnly: return "Temps only"
        case .tempsPlusRAM: return "Temps + RAM"
        case .compact: return "Compact (hot temp + RAM)"
        }
    }
}

// MARK: - App
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let sampler = SystemSampler()
    private var timer: Timer?
    private var history: [SystemSample] = []   // last N samples for menu graphs
    private var demoMode = false
    var demoSeed: [SystemSample]?
    private let historyMax = 90
    private let refreshSec: TimeInterval = 2.0
    private var unit: TempUnit {
        get { TempUnit(rawValue: UserDefaults.standard.integer(forKey: "tempUnit")) ?? .celsius }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "tempUnit") }
    }
    private var barMode: BarMode {
        get { BarMode(rawValue: UserDefaults.standard.integer(forKey: "barMode")) ?? .tempsPlusRAM }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "barMode") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.title = "MacTemp"
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        }
        statusItem.menu = buildMenu()
        if let seed = demoSeed { seedDemoHistory(seed) } else { refresh() }
        if !demoMode {
            timer = Timer.scheduledTimer(withTimeInterval: refreshSec, repeats: true) { [weak self] _ in self?.refresh() }
            RunLoop.main.add(timer!, forMode: .common)
        }
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let header = NSMenuItem(title: "MacTemp", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        let unitHeader = NSMenuItem(title: "Unit", action: nil, keyEquivalent: "")
        unitHeader.isEnabled = false
        menu.addItem(unitHeader)
        for u in [TempUnit.celsius, .fahrenheit] {
            let item = NSMenuItem(title: u == .celsius ? "Celsius (°C)" : "Fahrenheit (°F)",
                                  action: #selector(setUnit(_:)), keyEquivalent: "")
            item.tag = u.rawValue
            item.target = self
            item.state = (unit == u) ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())

        let barHeader = NSMenuItem(title: "Menu bar", action: nil, keyEquivalent: "")
        barHeader.isEnabled = false
        menu.addItem(barHeader)
        for m in [BarMode.tempsOnly, .tempsPlusRAM, .compact] {
            let item = NSMenuItem(title: m.title, action: #selector(setBarMode(_:)), keyEquivalent: "")
            item.tag = m.rawValue
            item.target = self
            item.state = (barMode == m) ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())

        for title in ["CPU:  --", "GPU:  --", "SSD:  --"] {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        for title in ["RAM:   --", "Swap:  --", "CPU load: --", "Disk:  --"] {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        menu.addItem(.separator())

        let model = NSMenuItem(title: Self.machineModel(), action: nil, keyEquivalent: "")
        model.isEnabled = false
        menu.addItem(model)

        menu.addItem(.separator())
        let panels = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        panels.view = PanelGridView(history: history, unit: unit,
                                    frame: NSRect(x: 0, y: 0, width: 286, height: 212))
        menu.addItem(panels)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit MacTemp", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        return menu
    }

    /// Seed fabricated history (README artwork / QA). Live sampling stops in demo mode.
    func seedDemoHistory(_ h: [SystemSample]) {
        demoMode = true
        history = h
        timer?.invalidate()
        timer = nil
        refresh()
    }

    private func refresh() {
        let s = demoMode ? (history.last ?? sampler.sample()) : sampler.sample()
        if !demoMode {
            history.append(s)
            if history.count > historyMax { history.removeFirst() }
        }

        func f(_ v: Double?) -> String { v.map { unit.format($0) } ?? "--" }
        func level(_ v: Double?) -> TempLevel { v.map { TempLevel.level($0) } ?? .normal }
        let ramText = (s.ramUsed.map { formatBytes($0) }) ?? "--"

        // Menu bar text, colored per temperature level (yellow = warning, red = hot).
        // Full-strength labelColor everywhere: secondaryLabelColor is unreadable over
        // a translucent bar on a busy wallpaper.
        let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        let attr = NSMutableAttributedString()
        func append(_ text: String, _ color: NSColor) {
            attr.append(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color]))
        }
        switch barMode {
        case .tempsOnly:
            append("CPU ", .labelColor); append(f(s.cpuTemp), level(s.cpuTemp).color)
            append("  GPU ", .labelColor); append(f(s.gpuTemp), level(s.gpuTemp).color)
            append("  SSD ", .labelColor); append(f(s.ssdTemp), level(s.ssdTemp).color)
        case .tempsPlusRAM:
            append("CPU ", .labelColor); append(f(s.cpuTemp), level(s.cpuTemp).color)
            append("  GPU ", .labelColor); append(f(s.gpuTemp), level(s.gpuTemp).color)
            append("  SSD ", .labelColor); append(f(s.ssdTemp), level(s.ssdTemp).color)
            append("  RAM ", .labelColor); append(ramText, .labelColor)
        case .compact:
            let temps = [s.cpuTemp, s.gpuTemp, s.ssdTemp].compactMap { $0 }
            let hottestColor = temps.map { TempLevel.level($0) }.max(by: { $0.rank < $1.rank })?.color ?? NSColor.labelColor
            let hottest = temps.max().map { unit.format($0) } ?? "--"
            append(hottest, hottestColor)
            append("  \(ramText)", .labelColor)
        }
        statusItem.button?.attributedTitle = attr

        // update menu values in place (menu stays open live), colored by level
        if let menu = statusItem.menu {
            let menuFont = NSFont.systemFont(ofSize: 13)
            func setRow(_ prefix: String, _ value: String, _ color: NSColor) {
                if let item = menu.items.first(where: { $0.title.hasPrefix(prefix) || ($0.attributedTitle?.string.hasPrefix(prefix) ?? false) }) {
                    let a = NSMutableAttributedString()
                    a.append(NSAttributedString(string: prefix, attributes: [.font: menuFont, .foregroundColor: NSColor.secondaryLabelColor]))
                    a.append(NSAttributedString(string: value, attributes: [.font: menuFont, .foregroundColor: color]))
                    item.attributedTitle = a
                }
            }
            setRow("CPU:  ", f(s.cpuTemp), level(s.cpuTemp).color)
            setRow("GPU:  ", f(s.gpuTemp), level(s.gpuTemp).color)
            setRow("SSD:  ", f(s.ssdTemp), level(s.ssdTemp).color)
            var ramColor = NSColor.labelColor
            var ramExtra = ""
            if let p = s.pressure {
                if p == 2 { ramColor = NSColor.systemYellow; ramExtra = "  (warning)" }
                if p == 3 { ramColor = NSColor.systemRed;   ramExtra = "  (critical)" }
            }
            setRow("RAM:   ", "\(ramText) / \(s.ramTotal.map { formatBytes($0) } ?? "--")\(ramExtra)", ramColor)
            setRow("Swap:  ", (s.swapUsed.map { formatBytes($0) } ?? "--")
                + " / " + (s.swapTotal.map { formatBytes($0) } ?? "--"), NSColor.labelColor)
            let load = s.cpuLoad ?? 0
            setRow("CPU load: ", (s.cpuLoad.map { String(format: "%.0f%%", $0) } ?? "--"),
                   load >= 85 ? NSColor.systemRed : (load >= 60 ? NSColor.systemYellow : NSColor.labelColor))
            let diskPct = (s.diskTotal ?? 1) > 0 ? Double(s.diskFree ?? 0) / Double(s.diskTotal!) : 1
            setRow("Disk:  ", (s.diskFree.map { formatBytes($0) } ?? "--")
                + " free / " + (s.diskTotal.map { formatBytes($0) } ?? "--"),
                diskPct < 0.10 ? NSColor.systemRed : (diskPct < 0.20 ? NSColor.systemYellow : NSColor.labelColor))
            if history.count > 2, let idx = menu.items.firstIndex(where: { $0.view is PanelGridView }) {
                menu.items[idx].view = PanelGridView(history: history, unit: unit,
                                                     frame: NSRect(x: 0, y: 0, width: 286, height: 212))
            }
        }
    }

    @objc private func setUnit(_ sender: NSMenuItem) {
        guard let u = TempUnit(rawValue: sender.tag), u != unit else { return }
        unit = u
        statusItem.menu = buildMenu()   // updates checkmarks
        refresh()
    }

    @objc private func setBarMode(_ sender: NSMenuItem) {
        guard let m = BarMode(rawValue: sender.tag), m != barMode else { return }
        barMode = m
        statusItem.menu = buildMenu()
        refresh()
    }

    @objc private func quit() { NSApp.terminate(nil) }

    /// Open the status menu on screen (for screenshots / QA).
    /// Blocks in modal menu tracking; the capture timer fires in event-tracking mode.
    func openMenuForScreenshot(captureAfter: TimeInterval = 1.2) {
        refresh()
        guard let button = statusItem.button, let menu = statusItem.menu else { return }
        // The status item lives in its own window — grab its id before the menu opens.
        var statusWinID = 0
        if let w = button.window { statusWinID = w.windowNumber }
        let capture = Timer(timeInterval: captureAfter, repeats: false) { _ in
            // full-screen pass FIRST, while the menu is still open
            let full = FileManager.default.currentDirectoryPath + "/win_full.png"
            let pf = Process()
            pf.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            pf.arguments = ["-x", full]
            try? pf.run()
            pf.waitUntilExit()
            if pf.terminationStatus == 0 { print("saved \(full)") }
            // Enumerate on-screen windows: capture only OUR app's windows
            // (status item + open menu) — nothing behind them.
            let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
            let info = (CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]]) ?? []
            var mine: [(id: Int, name: String, area: CGFloat)] = []
            for w in info {
                let owner = w[kCGWindowOwnerName as String] as? String ?? ""
                let num = w[kCGWindowNumber as String] as? Int ?? 0
                let layer = w[kCGWindowLayer as String] as? Int ?? -1
                let name = w[kCGWindowName as String] as? String ?? ""
                var area: CGFloat = 0
                var boundsDesc = ""
                if let bounds = w[kCGWindowBounds as String] as? [String: Any],
                   let ww = bounds["Width"] as? CGFloat, let hh = bounds["Height"] as? CGFloat {
                    area = ww * hh
                    boundsDesc = "x=\(bounds["X"] ?? 0) y=\(bounds["Y"] ?? 0) w=\(ww) h=\(hh)"
                }
                print("owner=\(owner) id=\(num) layer=\(layer) name=\(name) area=\(area) \(boundsDesc)")
                guard owner == "MacTemp" else { continue }
                if area > 100 { mine.append((num, name, area)) }
            }
            for w in mine {
                let tag = (w.id == statusWinID) ? "bar" : "menu"
                let path = FileManager.default.currentDirectoryPath + "/win_\(tag).png"
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                p.arguments = ["-x", "-o", "-l", String(w.id), path]
                try? p.run()
                p.waitUntilExit()
                if p.terminationStatus == 0 { print("saved \(path)") }
            }
            // The status item lives in Window Server's bar, so screencapture -l can't get
            // just our part — render the button itself to a PNG instead.
            if let rep = button.bitmapImageRepForCachingDisplay(in: button.bounds) {
                button.cacheDisplay(in: button.bounds, to: rep)
                let img = NSImage(size: button.bounds.size)
                img.addRepresentation(rep)
                if let tiff = img.tiffRepresentation,
                   let bmp = NSBitmapImageRep(data: tiff),
                   let png = bmp.representation(using: .png, properties: [:]) {
                    let path = FileManager.default.currentDirectoryPath + "/bar_button.png"
                    try? png.write(to: URL(fileURLWithPath: path))
                    print("saved \(path) (\(button.bounds))")
                }
            }
            exit(0)   // screencapture done; popUp blocks until we leave
        }
        RunLoop.main.add(capture, forMode: .common)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    static func machineModel() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var buf = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &buf, &size, nil, 0)
        return String(cString: buf)
    }
}

// MARK: - macmon-style metric panels: one bordered box with its own bar graph per metric
final class PanelGridView: NSView {
    private let history: [SystemSample]
    private let unit: TempUnit

    init(history: [SystemSample], unit: TempUnit, frame: NSRect) {
        self.history = history
        self.unit = unit
        super.init(frame: frame)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: 286, height: 212) }

    /// Load gradient (macmon-style, but high-contrast macOS system colors).
    private static func tempColor(_ c: Double) -> NSColor {
        c >= 80 ? .systemRed : (c >= 60 ? .systemYellow : .systemGreen)
    }
    private static func pctColor(_ p: Double) -> NSColor {
        p >= 85 ? .systemRed : (p >= 60 ? .systemYellow : .systemGreen)
    }

    private struct Panel {
        let title: String
        let header: [(String, NSColor)]   // value fragments drawn after the title
        let series: [Double]              // values normalized 0...1 of max
        let barColors: [NSColor]          // per-bar color, same length as series
    }

    override func draw(_ dirtyRect: NSRect) {
        guard history.count > 1, let last = history.last else { return }
        let ramTotal = max(Double(last.ramTotal ?? 1), 1)
        let swapTotal = max(Double(last.swapTotal ?? 1), 1)

        func tempPanel(_ title: String, _ key: (SystemSample) -> Double?) -> Panel {
            let vals = history.compactMap(key)
            let cur = key(last) ?? 0
            return Panel(title: title,
                         header: [(key(last).map { unit.format($0) } ?? "--", PanelGridView.tempColor(cur))],
                         series: vals.map { min(max($0 / 100.0, 0), 1) },
                         barColors: vals.map(PanelGridView.tempColor))
        }
        let ramPct = (last.ramUsed).map { Double($0) / ramTotal * 100 } ?? 0
        let swapPct = (last.swapUsed).map { Double($0) / swapTotal * 100 } ?? 0
        let ramSeries = history.compactMap { $0.ramUsed }.map { min(Double($0) / ramTotal, 1) }
        let panels = [
            tempPanel("CPU", { $0.cpuTemp }),
            tempPanel("GPU", { $0.gpuTemp }),
            tempPanel("SSD", { $0.ssdTemp }),
            Panel(title: "RAM",
                  header: [("\(Int(ramPct))%", PanelGridView.pctColor(ramPct)),
                           ("SW \(Int(swapPct))%", PanelGridView.pctColor(swapPct))],
                  series: ramSeries,
                  barColors: ramSeries.map { PanelGridView.pctColor($0 * 100) }),
        ]
        drawPanels(panels)
    }

    private func drawPanels(_ panels: [Panel]) {
        let w = bounds.width, h = bounds.height
        let outer: CGFloat = 2, gap: CGFloat = 8
        let cols = 2, rows = 2
        let pw = (w - outer * 2 - gap * CGFloat(cols - 1)) / CGFloat(cols)
        let ph = (h - outer * 2 - gap * CGFloat(rows - 1)) / CGFloat(rows)

        let titleFont = NSFont.systemFont(ofSize: 12, weight: .bold)
        let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)

        for (i, p) in panels.enumerated() {
            let col = i % cols, row = i / cols
            let x = outer + CGFloat(col) * (pw + gap)
            let y = h - outer - ph * CGFloat(row + 1) - gap * CGFloat(row)
            let cell = NSRect(x: x, y: y, width: pw, height: ph)

            let border = NSBezierPath(roundedRect: cell.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
            NSColor.secondaryLabelColor.withAlphaComponent(0.55).set()
            border.lineWidth = 1
            border.stroke()

            // header: bold title, then colored current values
            var tx = cell.minX + 8
            let hy = cell.maxY - 19
            let titleAttrs: [NSAttributedString.Key: Any] = [.font: titleFont, .foregroundColor: NSColor.labelColor]
            (p.title as NSString).draw(at: CGPoint(x: tx, y: hy), withAttributes: titleAttrs)
            tx += (p.title as NSString).size(withAttributes: titleAttrs).width + 6
            for (text, color) in p.header {
                let attrs: [NSAttributedString.Key: Any] = [.font: valueFont, .foregroundColor: color]
                (text as NSString).draw(at: CGPoint(x: tx, y: hy), withAttributes: attrs)
                tx += (text as NSString).size(withAttributes: attrs).width + 8
            }

            // bars: macmon-style solid columns, newest sample on the right
            let plot = NSRect(x: cell.minX + 7, y: cell.minY + 7, width: cell.width - 14, height: cell.height - 30)
            guard !p.series.isEmpty, plot.width > 4 else { continue }
            let maxBars = max(Int(plot.width / 3), 4)
            let vals = Array(p.series.suffix(maxBars))
            let colorOff = p.barColors.count - vals.count
            let pitch = plot.width / CGFloat(vals.count)
            let barW = max(pitch - 1, 1)
            for (j, v) in vals.enumerated() {
                let bh = plot.height * CGFloat(min(max(v, 0), 1))
                if bh < 1 { continue }   // zero leaves the column blank, like macmon
                p.barColors[colorOff + j].setFill()
                NSBezierPath(rect: NSRect(x: plot.minX + CGFloat(j) * pitch, y: plot.minY,
                                          width: barW, height: bh)).fill()
            }
        }
    }
}

// MARK: - main
// MAC_TEMP_DUMP=1: run N=3 samples, print, exit (headless verification / debug).
if ProcessInfo.processInfo.environment["MAC_TEMP_DUMP"] != nil {
    let s = SystemSampler()
    print("smcAvailable=\(s.smcAvailable)")
    for i in 0..<3 {
        let x = s.sample()
        func f(_ v: Double?) -> String { v.map { String(format: "%.1f", $0) } ?? "--" }
        print("sample\(i): CPU=\(f(x.cpuTemp)) GPU=\(f(x.gpuTemp)) SSD=\(f(x.ssdTemp)) "
            + "RAM=\(x.ramUsed.map { formatBytes($0) } ?? "--")/\(x.ramTotal.map { formatBytes($0) } ?? "--") "
            + "Swap=\(x.swapUsed.map { formatBytes($0) } ?? "--") Pressure=\(x.pressure.map(String.init) ?? "--") "
            + "CPULoad=\(x.cpuLoad.map { String(format: "%.1f%%", $0) } ?? "--") "
            + "Disk=\(x.diskFree.map { formatBytes($0) } ?? "--") free")
        usleep(1_000_000)
    }
    exit(0)
}

// Demo mode: fabricate a plausible history (used for README artwork).
private func demoHistory(count: Int) -> [SystemSample] {
    var h: [SystemSample] = []
    let total = ProcessInfo.processInfo.physicalMemory
    for i in 0..<count {
        let t = Double(i)
        h.append(SystemSample(
            cpuTemp: 72 + 12 * sin(t / 9) + (i % 7 == 0 ? 8 : 0),      // swings into yellow/red
            gpuTemp: 62 + 8  * sin(t / 13 + 1),                        // warning zone
            ssdTemp: 38 + 2  * sin(t / 20),                            // normal (green/white)
            ramUsed: UInt64(Double(total) * (0.62 + 0.22 * sin(t / 11) + 0.03 * sin(t / 3))),
            ramTotal: total,
            swapUsed: UInt64(2.0e9 + 1.2e9 * (0.5 + 0.5 * sin(t / 17))),
            swapTotal: 8_000_000_000,
            cpuLoad: 45 + 35 * sin(t / 7 + 0.5),
            diskFree: 696 * 1_073_741_824,
            diskTotal: 994 * 1_073_741_824,
            pressure: 1))
    }
    return h
}

// MAC_TEMP_SELFTEST=1: open the menu programmatically, screenshot the screen, print paths, exit.
// MAC_TEMP_DEMO=1 (with selftest): use fabricated data so graphs/coloring show in shots.
if ProcessInfo.processInfo.environment["MAC_TEMP_SELFTEST"] != nil {
    let demo = ProcessInfo.processInfo.environment["MAC_TEMP_DEMO"] != nil
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    app.delegate = delegate
    if demo { delegate.demoSeed = demoHistory(count: 40) }
    DispatchQueue.main.asyncAfter(deadline: .now() + (demo ? 0.5 : 4)) {
        delegate.openMenuForScreenshot()
        exit(0)
    }
    app.run()
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
