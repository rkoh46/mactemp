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

// MARK: - Temperature sampler (SMC CPU/GPU + IOHID NAND via C helper)
final class TempSampler {
    private let smc = SMC()
    private var cpuKeys: [String] = []
    private var gpuKeys: [String] = []
    private let hidNameSlot = 64
    private let hidMax = 128

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

    /// (cpu, gpu, storage) in Celsius; nil = unavailable.
    func sample() -> (cpu: Double?, gpu: Double?, storage: Double?) {
        var cpu: Double?; var gpu: Double?
        if smcAvailable {
            cpu = average(cpuKeys)
            gpu = average(gpuKeys)
        }
        var storage: Double?
        var names = [Int8](repeating: 0, count: hidNameSlot * hidMax)
        var temps = [Double](repeating: 0, count: hidMax)
        _ = names.withUnsafeMutableBufferPointer { np -> Int in
            let resI = Int(temps.withUnsafeMutableBufferPointer { tp in
                hid_temp_get_sensors(np.baseAddress!, Int32(hidNameSlot), tp.baseAddress!, Int32(hidMax))
            })
            guard resI > 0 else { return resI }
            for i in 0..<resI {
                let slot = UnsafeMutableRawPointer(np.baseAddress!).advanced(by: i * hidNameSlot)
                let name = slot.assumingMemoryBound(to: CChar.self)
                let s = String(cString: name)
                if s.contains("NAND") || s.contains("SSD") {
                    let v = temps[i]
                    if v > 0, v < 150, (storage == nil || v > storage!) { storage = v }
                }
            }
            return resI
        }
        return (cpu, gpu, storage)
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

// MARK: - App
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let sampler = TempSampler()
    private var timer: Timer?
    private var history: [(Double, Double, Double)] = []   // last N samples (Celsius) for menu sparkline
    private let refreshSec: TimeInterval = 2.0
    private var unit: TempUnit {
        get { TempUnit(rawValue: UserDefaults.standard.integer(forKey: "tempUnit")) ?? .celsius }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "tempUnit") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.title = "C -- G -- S --"
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        }
        statusItem.menu = buildMenu()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: refreshSec, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(timer!, forMode: .common)
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

        let cpu = NSMenuItem(title: "CPU:  --", action: nil, keyEquivalent: "")
        cpu.isEnabled = false
        let gpu = NSMenuItem(title: "GPU:  --", action: nil, keyEquivalent: "")
        gpu.isEnabled = false
        let ssd = NSMenuItem(title: "SSD:  --", action: nil, keyEquivalent: "")
        ssd.isEnabled = false
        menu.addItem(cpu); menu.addItem(gpu); menu.addItem(ssd)
        menu.addItem(.separator())

        let model = NSMenuItem(title: Self.machineModel(), action: nil, keyEquivalent: "")
        model.isEnabled = false
        menu.addItem(model)

        if !history.isEmpty {
            menu.addItem(.separator())
            let graph = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            graph.view = SparklineView(history: history, unit: unit, frame: NSRect(x: 0, y: 0, width: 260, height: 72))
            menu.addItem(graph)
        }
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit MacTemp", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        return menu
    }

    private func refresh() {
        let (cpu, gpu, ssd) = sampler.sample()
        func f(_ v: Double?) -> String { v.map { unit.format($0) } ?? "--" }
        statusItem.button?.title = "C \(f(cpu))  G \(f(gpu))  S \(f(ssd))"

        if let c = cpu, let g = gpu, let s = ssd { history.append((c, g, s)); if history.count > 90 { history.removeFirst() } }

        // rebuild menu items in place (menu stays open live)
        if let menu = statusItem.menu {
            let titles = ["CPU:  ", "GPU:  ", "SSD:  "]
            let vals = [f(cpu), f(gpu), f(ssd)]
            for i in 0..<3 {
                if let item = menu.items.first(where: { $0.title.hasPrefix(titles[i]) }) {
                    item.title = titles[i] + vals[i]
                }
            }
            if history.count > 2,
               let idx = menu.items.firstIndex(where: { $0.view is SparklineView }) {
                menu.items[idx].view = SparklineView(history: history, unit: unit, frame: NSRect(x: 0, y: 0, width: 260, height: 72))
            }
        }
    }

    @objc private func setUnit(_ sender: NSMenuItem) {
        guard let u = TempUnit(rawValue: sender.tag), u != unit else { return }
        unit = u
        statusItem.menu = buildMenu()   // updates checkmarks
        refresh()
    }

    @objc private func quit() { NSApp.terminate(nil) }

    static func machineModel() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var buf = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &buf, &size, nil, 0)
        return String(cString: buf)
    }
}

// MARK: - Sparkline (CPU/GPU/SSD over time)
final class SparklineView: NSView {
    private let history: [(Double, Double, Double)]   // stored in Celsius
    private let unit: TempUnit
    private let colors: [(NSColor, String)] = [(NSColor.systemRed, "CPU"), (NSColor.systemOrange, "GPU"), (NSColor.systemGreen, "SSD")]

    init(history: [(Double, Double, Double)], unit: TempUnit, frame: NSRect) {
        self.history = history
        self.unit = unit
        super.init(frame: frame)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        guard history.count > 1 else { return }
        let seriesValues: [[Double]] = [history.map(\.0), history.map(\.1), history.map(\.2)]
        let all = seriesValues.flatMap { $0 }
        let lo = (all.min() ?? 0) - 4, hi = (all.max() ?? 100) + 4
        let w = bounds.width, h = bounds.height
        for (i, v) in seriesValues.enumerated() {
            let color = colors[i].0
            let path = NSBezierPath()
            for (j, val) in v.enumerated() {
                let x = w * CGFloat(j) / CGFloat(v.count - 1)
                let y = (h - 18) * CGFloat((val - lo) / (hi - lo))
                if j == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.line(to: CGPoint(x: x, y: y)) }
            }
            color.set()
            path.lineWidth = 1.5
            path.stroke()
        }
        // legend
        let font = NSFont.systemFont(ofSize: 10)
        var x: CGFloat = 6
        for (i, _) in colors.enumerated() {
            let label = colors[i].1
            let last = history.last
            let v = label == "CPU" ? last?.0 : (label == "GPU" ? last?.1 : last?.2)
            let text = "\(label) \(v.map { unit.format($0) } ?? "--")"
            (text as NSString).draw(at: CGPoint(x: x, y: 2), withAttributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor])
            x += (text as NSString).size(withAttributes: [.font: font]).width + 14
        }
    }
}

// MARK: - main
// MAC_TEMP_DUMP=1: run N=3 samples, print (Celsius), exit (headless verification / debug).
if ProcessInfo.processInfo.environment["MAC_TEMP_DUMP"] != nil {
    let s = TempSampler()
    print("smcAvailable=\(s.smcAvailable)")
    for i in 0..<3 {
        let (c, g, ss) = s.sample()
        func f(_ v: Double?) -> String { v.map { String(format: "%.1f", $0) } ?? "--" }
        print("sample\(i): CPU=\(f(c)) GPU=\(f(g)) SSD=\(f(ss))")
        usleep(1_000_000)
    }
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
