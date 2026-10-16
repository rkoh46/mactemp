// ui.swift — MacTemp v1.4 UI: fan controls, expanded panel grid, menu-bar graph,
// threshold alerts, login item, settings window.
import AppKit
import ServiceManagement
import Security
import UserNotifications

// MARK: - Fan control (SMC writes need root → osascript admin + bundled fanctl helper)

// Shared XPC shape with the privileged fan helper (see tools/fanhelper.swift).
@objc(MacTempFanHelperProtocol)
public protocol MacTempFanHelperProtocol {
    func applyMode(_ mode: String, rpm: Double, withReply reply: @escaping (Bool, String) -> Void)
    func restoreAuto(withReply reply: @escaping (Bool) -> Void)
    func helperVersion(withReply reply: @escaping (String) -> Void)
}

final class FanController {
    enum Mode: Int { case auto = 0, blast = 1, custom = 2 }

    static let shared = FanController()

    private var cachedPath: String?
    var lastAppliedMode: Mode {
        get { Mode(rawValue: UserDefaults.standard.integer(forKey: "fanMode")) ?? .auto }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "fanMode") }
    }
    var customRPM: Double {
        get { let v = UserDefaults.standard.double(forKey: "fanCustomRPM"); return v > 0 ? v : 2500 }
        set { UserDefaults.standard.set(newValue, forKey: "fanCustomRPM") }
    }

    private func fanctlPath() -> String? {
        if let p = cachedPath, FileManager.default.isExecutableFile(atPath: p) { return p }
        // NB: Bundle.path(forResource:) does NOT index plain binaries in Contents/MacOS —
        // build the path directly from the executable/bundle location instead.
        var candidates: [String] = []
        if let exec = Bundle.main.executablePath {
            candidates.append((exec as NSString).deletingLastPathComponent + "/fanctl")
        }
        candidates.append(Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/fanctl").path)
        candidates.append("/Applications/MacTemp.app/Contents/MacOS/fanctl")
        candidates.append(FileManager.default.currentDirectoryPath + "/fanctl")
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) {
            cachedPath = c
            return c
        }
        return nil
    }

    // MARK: privileged helper path (SMJobBless: one admin approval, then silent forever)
    static let helperLabel = "local.mactemp.helper"

    /// One-shot XPC call to the installed root helper. nil = helper not reachable (not installed yet).
    private func callHelper(_ mode: String, rpm: Double, timeout: TimeInterval = 5) -> (Bool, String?)? {
        let conn = NSXPCConnection(machServiceName: Self.helperLabel, options: [])
        conn.remoteObjectInterface = NSXPCInterface(with: MacTempFanHelperProtocol.self)
        let sem = DispatchSemaphore(value: 0)
        var result: (Bool, String?)?
        let proxy = conn.remoteObjectProxyWithErrorHandler { _ in
            // Connection-level failure (helper not installed / launchd has no such
            // service): treat as "not reachable" so apply() can bless it. Returning
            // an error tuple here would surface the XPC message as a popup instead.
            result = nil
            sem.signal()
        } as? MacTempFanHelperProtocol
        guard let proxy else { conn.invalidate(); return nil }
        conn.resume()
        if mode == "auto" {
            proxy.restoreAuto { ok in result = (ok, ok ? nil : "helper write failed"); sem.signal() }
        } else {
            proxy.applyMode(mode, rpm: rpm) { ok, msg in result = (ok, ok ? nil : msg); sem.signal() }
        }
        if sem.wait(timeout: .now() + timeout) == .timedOut { conn.invalidate(); return nil }
        conn.invalidate()
        return result
    }

    /// Install the privileged helper via SMJobBless (admin password prompt, once per machine).
    private func blessHelper() -> (Bool, String?) {
        var auth: AuthorizationRef?
        guard AuthorizationCreate(nil, nil, [], &auth) == errAuthorizationSuccess, let authorization = auth else {
            return (false, "authorization setup failed")
        }
        var item = AuthorizationItem(name: kSMRightBlessPrivilegedHelper, valueLength: 0, value: nil, flags: 0)
        var itemSet = AuthorizationItemSet(count: 1, items: nil)
        let copyStatus = withUnsafeMutablePointer(to: &item) { itemPtr in
            itemSet.items = itemPtr
            return withUnsafePointer(to: &itemSet) { setPtr in
                AuthorizationCopyRights(authorization, setPtr, nil, [.interactionAllowed, .extendRights], nil)
            }
        }
        if copyStatus != errAuthorizationSuccess {
            AuthorizationFree(authorization, [])
            return (false, copyStatus == errAuthorizationCanceled ? "authorization cancelled" : "authorization failed (\(copyStatus))")
        }
        var errorRef: Unmanaged<CFError>?
        let ok = SMJobBless(kSMDomainSystemLaunchd, Self.helperLabel as CFString, authorization, &errorRef)
        AuthorizationFree(authorization, [])
        if ok { return (true, nil) }
        if let cfErr = errorRef?.takeRetainedValue() {
            return (false, (cfErr as! NSError).localizedDescription)
        }
        return (false, "helper install failed")
    }

    /// Apply a fan mode. Preferred: installed root helper (silent). First use blesses it
    /// with a single admin approval; osascript elevation remains only as a fallback.
    func apply(_ mode: Mode, rpm: Double? = nil, completion: @escaping (Bool, String?) -> Void) {
        let modeStr: String
        let targetRPM: Double
        switch mode {
        case .auto:   modeStr = "auto";  targetRPM = 0
        case .blast:  modeStr = "blast"; targetRPM = 0
        case .custom: modeStr = "set";   targetRPM = rpm ?? customRPM
        }
        DispatchQueue.global(qos: .userInitiated).async {
            if let r = self.callHelper(modeStr, rpm: targetRPM) {
                DispatchQueue.main.async { completion(r.0, r.1) }
                return
            }
            // Helper not installed: bless it once (single admin password prompt),
            // then retry the XPC call — launchd may take a moment to start the job.
            let (blessed, blessErr) = self.blessHelper()
            if blessed {
                for _ in 0..<6 {
                    if let r = self.callHelper(modeStr, rpm: targetRPM, timeout: 3) {
                        DispatchQueue.main.async { completion(r.0, r.1) }
                        return
                    }
                    usleep(500_000)
                }
            }
            self.applyViaOSAScript(modeStr, rpm: targetRPM) { ok, err in
                var finalErr = err ?? blessErr
                if !ok && blessed && finalErr == nil { finalErr = "helper installed but fan write failed" }
                DispatchQueue.main.async { completion(ok, finalErr) }
            }
        }
    }

    /// Legacy fallback: per-change osascript admin elevation.
    private func applyViaOSAScript(_ modeStr: String, rpm: Double, completion: @escaping (Bool, String?) -> Void) {
        guard let tool = fanctlPath() else { completion(false, "fanctl helper not found"); return }
        let arg = modeStr == "set" ? "set \(Int(rpm))" : modeStr
        let shell = "'\(tool)' \(arg)"
        let esc = shell.replacingOccurrences(of: "\\", with: "\\\\")
                       .replacingOccurrences(of: "\"", with: "\\\"")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "do shell script \"\(esc)\" with administrator privileges"]
        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            completion(false, error.localizedDescription)
            return
        }
        let errText = String(data: errPipe.fileDataToEnd(), encoding: .utf8) ?? ""
        if process.terminationStatus == 0 {
            completion(true, nil)
        } else if errText.contains("-128") {   // AppleScript errUserCanceled
            completion(false, "authorization cancelled")
        } else {
            completion(false, errText.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// Synchronous restore used on app quit (helper path: no dialogs).
    func applyAutoBlocking() {
        if callHelper("auto", rpm: 0, timeout: 3)?.0 == true { return }
        applyViaOSAScript("auto", rpm: 0) { _, _ in }
    }
}

extension Pipe {
    fileprivate func fileDataToEnd() -> Data { fileHandleForReading.readDataToEndOfFile() }
}

// MARK: - Fan controls row (NSMenuItem.view): Auto / Blast buttons + custom RPM slider

final class FanControlsRow: NSView {
    private let slider = NSSlider()
    private let targetLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    var onApply: ((FanController.Mode, Double) -> Void)?
    var sliderMax: Double = 2500

    init(minRPM: Double, maxRPM: Double, target: Double) {
        super.init(frame: NSRect(x: 0, y: 0, width: 360, height: 46))

        let autoBtn = NSButton(title: "Auto", target: nil, action: nil)
        let blastBtn = NSButton(title: "Full Blast", target: nil, action: nil)
        autoBtn.bezelStyle = .rounded
        blastBtn.bezelStyle = .rounded
        autoBtn.target = self; autoBtn.action = #selector(autoTapped)
        blastBtn.target = self; blastBtn.action = #selector(blastTapped)
        autoBtn.frame = NSRect(x: 8, y: 20, width: 58, height: 24)
        blastBtn.frame = NSRect(x: 72, y: 20, width: 90, height: 24)
        addSubview(autoBtn); addSubview(blastBtn)

        slider.minValue = minRPM
        slider.maxValue = maxRPM
        slider.doubleValue = min(max(target, minRPM), maxRPM)
        slider.isContinuous = false        // fire only on release: one auth prompt per change
        slider.frame = NSRect(x: 8, y: 2, width: 236, height: 18)
        slider.target = self; slider.action = #selector(sliderReleased)
        addSubview(slider)
        sliderMax = maxRPM

        targetLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        targetLabel.frame = NSRect(x: 250, y: 1, width: 102, height: 18)
        addSubview(targetLabel)

        statusLabel.font = NSFont.systemFont(ofSize: 10)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.frame = NSRect(x: 236, y: 22, width: 116, height: 18)
        statusLabel.alignment = .right
        addSubview(statusLabel)

        updateTargetLabel()
    }
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: 360, height: 46) }

    private func updateTargetLabel() {
        targetLabel.stringValue = "→ \(Int(slider.doubleValue)) RPM"
    }

    func setStatus(_ text: String) { statusLabel.stringValue = text }

    func sliderRange(minRPM: Double, maxRPM: Double) {
        guard minRPM > 0, maxRPM > minRPM else { return }
        slider.minValue = minRPM
        slider.maxValue = maxRPM
        sliderMax = maxRPM
    }

    @objc private func autoTapped() { onApply?(.auto, slider.doubleValue) }
    @objc private func blastTapped() { onApply?(.blast, slider.doubleValue) }
    @objc private func sliderReleased() {
        updateTargetLabel()
        onApply?(.custom, slider.doubleValue)
    }
}

// MARK: - Panel grid: 3x2 macmon-style bordered panels (CPU / GPU / SSD / RAM / FAN / NET)

final class PanelGridView2: NSView {
    private let history: [SystemSample]
    private let unit: TempUnit

    init(history: [SystemSample], unit: TempUnit, frame: NSRect) {
        self.history = history
        self.unit = unit
        super.init(frame: frame)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: 360, height: 318) }

    static func tempColor(_ c: Double) -> NSColor {
        c >= 80 ? .systemRed : (c >= 60 ? .systemYellow : .systemGreen)
    }
    static func pctColor(_ p: Double) -> NSColor {
        p >= 85 ? .systemRed : (p >= 60 ? .systemYellow : .systemGreen)
    }

    private struct Panel {
        let title: String
        let symbol: String
        let symbolColor: NSColor
        var header: [(String, NSColor)]      // values on the title line
        var sub: [(String, NSColor)] = []    // smaller second line
        let series: [Double]                 // 0...1 of max
        let barColors: [NSColor]
    }

    override func draw(_ dirtyRect: NSRect) {
        guard history.count > 1, let last = history.last else { return }
        let ramTotal = max(Double(last.ramTotal ?? 1), 1)
        let swapTotal = max(Double(last.swapTotal ?? 1), 1)

        func tempPanel(_ title: String, _ symbol: String, _ symbolColor: NSColor,
                       _ key: (SystemSample) -> Double?) -> Panel {
            let vals = history.compactMap(key)
            let cur = key(last) ?? 0
            return Panel(title: title, symbol: symbol, symbolColor: symbolColor,
                         header: [(key(last).map { unit.format($0) } ?? "--", PanelGridView2.tempColor(cur))],
                         series: vals.map { min(max($0 / 100.0, 0), 1) },
                         barColors: vals.map(PanelGridView2.tempColor))
        }
        func busyPanel(_ title: String, _ symbol: String, _ symbolColor: NSColor,
                       _ key: (SystemSample) -> Double?,
                       power: Double?, mhz: Double?) -> Panel {
            let vals = history.compactMap(key)
            let cur = key(last) ?? 0
            var sub: [(String, NSColor)] = []
            var subText = ""
            if let p = power { subText += String(format: "%.1fW", p) }
            if let m = mhz { subText += (subText.isEmpty ? "" : " · ") + String(format: "%.0fMHz", m) }
            if !subText.isEmpty { sub = [(subText, .secondaryLabelColor)] }
            return Panel(title: title, symbol: symbol, symbolColor: symbolColor,
                         header: [("\(Int(cur))%", PanelGridView2.pctColor(cur))],
                         sub: sub,
                         series: vals.map { min(max($0 / 100.0, 0), 1) },
                         barColors: vals.map(PanelGridView2.pctColor))
        }

        let ramPct = (last.ramUsed).map { Double($0) / ramTotal * 100 } ?? 0
        let swapPct = (last.swapUsed).map { Double($0) / swapTotal * 100 } ?? 0
        let ramSeries = history.compactMap { $0.ramUsed }.map { min(Double($0) / ramTotal, 1) }

        // CPU panel: hottest core temp header + busy bars + power/MHz sub
        var cpuP = busyPanel("CPU", "cpu", .systemOrange, { $0.cpuBusyPct }, power: last.cpuPowerW, mhz: last.cpuMaxMHz)
        let cpuT = (last.cpuMaxCoreTemp ?? last.cpuTemp) ?? 0
        cpuP.header = [(unit.format(cpuT), PanelGridView2.tempColor(cpuT))] + cpuP.header
        // GPU panel: temp + busy + power/MHz
        var gpuP = busyPanel("GPU", "cpu", .systemPurple, { $0.gpuBusyPct }, power: last.gpuPowerW, mhz: last.gpuMHz)
        let gpuT = last.gpuTemp ?? 0
        gpuP.header = [(unit.format(gpuT), PanelGridView2.tempColor(gpuT))] + gpuP.header

        // FAN panel
        let fanMax = max(last.fanMaxRpm, 1)
        let fanCur = last.fanRpm.first ?? 0
        let fanSeries = history.compactMap { $0.fanRpm.first }.map { min($0 / fanMax, 1) }
        let fanMode = last.fanManual ? "manual" : "auto"
        let fanColor = last.fanManual ? NSColor.systemYellow : NSColor.labelColor
        let fanPanel = Panel(
            title: "FAN", symbol: "fan", symbolColor: .secondaryLabelColor,
            header: [("\(Int(fanCur))", fanColor),
                     (fanMode, last.fanManual ? .systemYellow : .secondaryLabelColor)],
            sub: [(last.fanTargetRpm.map { "target \(Int($0)) RPM" } ?? "", .secondaryLabelColor)],
            series: fanSeries.isEmpty ? [0] : fanSeries,
            barColors: (fanSeries.isEmpty ? [0] : fanSeries).map { PanelGridView2.pctColor($0 * 100) })

        // NET panel (down throughput)
        let netSeries = history.compactMap { $0.netDownBps }
        let netScale = max(netSeries.max() ?? 1, 1)
        let downText = last.netDownBps.map(formatRate) ?? "--"
        let upText = last.netUpBps.map(formatRate) ?? "--"
        let netPanel = Panel(
            title: "NET", symbol: "network", symbolColor: .systemGreen,
            header: [("↓" + downText, .labelColor)],
            sub: [(upText + " ↑", .secondaryLabelColor)],
            series: netSeries.map { min($0 / netScale, 1) },
            barColors: netSeries.map { _ in NSColor.controlAccentColor })

        // SSD panel carries the disk free-space readout
        var ssdP = tempPanel("SSD", "internaldrive", .systemCyan, { $0.ssdTemp })
        if let free = last.diskFree, let tot = last.diskTotal, tot > 0 {
            let ratio = Double(free) / Double(tot)
            ssdP.sub = [("\(formatBytes(free)) free / \(formatBytes(tot))",
                        ratio < 0.10 ? .systemRed : (ratio < 0.20 ? .systemYellow : .secondaryLabelColor))]
        }
        let panels = [
            cpuP, gpuP,
            ssdP,
            Panel(title: "RAM", symbol: "memorychip", symbolColor: .systemIndigo,
                  header: [("\(Int(ramPct))%", PanelGridView2.pctColor(ramPct)),
                           ("SW \(Int(swapPct))%", PanelGridView2.pctColor(swapPct))],
                  sub: [((last.swapUsed.map { formatBytes($0) } ?? "--")
                        + " / " + (last.swapTotal.map { formatBytes($0) } ?? "--") + " swap", .secondaryLabelColor)],
                  series: ramSeries,
                  barColors: ramSeries.map { PanelGridView2.pctColor($0 * 100) }),
            fanPanel, netPanel,
        ]
        drawPanels(panels)
    }

    private func drawPanels(_ panels: [Panel]) {
        let w = bounds.width, h = bounds.height
        let outer: CGFloat = 2, gap: CGFloat = 8
        let cols = 2, rows = 3
        let pw = (w - outer * 2 - gap * CGFloat(cols - 1)) / CGFloat(cols)
        let ph = (h - outer * 2 - gap * CGFloat(rows - 1)) / CGFloat(rows)

        let titleFont = NSFont.systemFont(ofSize: 12, weight: .bold)
        let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        let subFont = NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .regular)

        for (i, p) in panels.enumerated() {
            let col = i % cols, row = i / cols
            let x = outer + CGFloat(col) * (pw + gap)
            let y = h - outer - ph * CGFloat(row + 1) - gap * CGFloat(row)
            let cell = NSRect(x: x, y: y, width: pw, height: ph)

            let border = NSBezierPath(roundedRect: cell.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
            NSColor.secondaryLabelColor.withAlphaComponent(0.55).set()
            border.lineWidth = 1
            border.stroke()

            var tx = cell.minX + 8
            let hy = cell.maxY - 18
            let symCfg = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [p.symbolColor]))
            if let img = NSImage(systemSymbolName: p.symbol, accessibilityDescription: p.title)?
                .withSymbolConfiguration(symCfg) {
                img.draw(in: NSRect(x: tx, y: hy - 1, width: 14, height: 14))
                tx += 17
            }
            let titleAttrs: [NSAttributedString.Key: Any] = [.font: titleFont, .foregroundColor: NSColor.labelColor]
            (p.title as NSString).draw(at: CGPoint(x: tx, y: hy), withAttributes: titleAttrs)
            tx += (p.title as NSString).size(withAttributes: titleAttrs).width + 6
            for (text, color) in p.header {
                let attrs: [NSAttributedString.Key: Any] = [.font: valueFont, .foregroundColor: color]
                (text as NSString).draw(at: CGPoint(x: tx, y: hy), withAttributes: attrs)
                tx += (text as NSString).size(withAttributes: attrs).width + 7
            }

            var subTop = hy
            if !p.sub.isEmpty {
                var sx = cell.minX + 8
                subTop = hy - 12
                let attrs: [NSAttributedString.Key: Any] = [.font: subFont, .foregroundColor: NSColor.secondaryLabelColor]
                for (text, color) in p.sub {
                    let a: [NSAttributedString.Key: Any] = [.font: subFont, .foregroundColor: color]
                    (text as NSString).draw(at: CGPoint(x: sx, y: subTop), withAttributes: a)
                    sx += (text as NSString).size(withAttributes: attrs).width + 7
                }
            }

            let plot = NSRect(x: cell.minX + 7, y: cell.minY + 7,
                              width: cell.width - 14, height: subTop - 6 - cell.minY - 7)
            guard !p.series.isEmpty, plot.width > 4, plot.height > 4 else { continue }
            let maxBars = max(Int(plot.width / 3), 4)
            let vals = Array(p.series.suffix(maxBars))
            let colorOff = p.barColors.count - vals.count
            let pitch = plot.width / CGFloat(vals.count)
            let barW = max(pitch - 1, 1)
            for (j, v) in vals.enumerated() {
                let bh = plot.height * CGFloat(min(max(v, 0), 1))
                if bh < 1 { continue }
                p.barColors[colorOff + j].setFill()
                NSBezierPath(rect: NSRect(x: plot.minX + CGFloat(j) * pitch, y: plot.minY,
                                          width: barW, height: bh)).fill()
            }
        }
    }
}

private func formatRate(_ bps: Double) -> String {
    if bps >= 10_000_000 { return String(format: "%.1fMB/s", bps / 1_000_000) }
    if bps >= 10_000 { return String(format: "%.0fKB/s", bps / 1_000) }
    if bps >= 100 { return String(format: "%.0fKB/s", bps / 1_000) }
    return "idle"
}

// MARK: - Menu-bar sparkline (graph bar mode)

enum GraphMetric: Int {
    case cpuTemp = 0, gpuTemp = 1, ssdTemp = 2, cpuBusy = 3, netDown = 4

    var title: String {
        switch self {
        case .cpuTemp: return "CPU temp"
        case .gpuTemp: return "GPU temp"
        case .ssdTemp: return "SSD temp"
        case .cpuBusy: return "CPU busy %"
        case .netDown: return "Network ↓"
        }
    }
}

func barGraphImage(samples: [SystemSample], metric: GraphMetric, width: CGFloat = 46, height: CGFloat = 18) -> NSImage {
    let img = NSImage(size: NSSize(width: width, height: height))
    img.lockFocus()
    let vals: [Double]
    let colors: [NSColor]
    switch metric {
    case .cpuTemp: vals = samples.compactMap { $0.cpuMaxCoreTemp ?? $0.cpuTemp }; colors = vals.map { PanelGridView2.tempColor($0) }
    case .gpuTemp: vals = samples.compactMap { $0.gpuTemp }; colors = vals.map { PanelGridView2.tempColor($0) }
    case .ssdTemp: vals = samples.compactMap { $0.ssdTemp }; colors = vals.map { PanelGridView2.tempColor($0) }
    case .cpuBusy: vals = samples.compactMap { $0.cpuBusyPct }; colors = vals.map { PanelGridView2.pctColor($0) }
    case .netDown: vals = samples.compactMap { $0.netDownBps }; colors = vals.map { _ in NSColor.controlAccentColor }
    }
    let scale: Double
    switch metric {
    case .netDown: scale = max(vals.max() ?? 1, 1)
    default: scale = 100
    }
    defer { img.unlockFocus() }
    guard !vals.isEmpty else { return img }
    let take = Array(vals.suffix(16)), takeColors = Array(colors.suffix(16))
    let pitch = width / CGFloat(max(take.count, 1))
    let barW = max(pitch - 1, 1)
    // current value as a faint full-height band so the graph has a floor
    for (j, v) in take.enumerated() {
        let bh = height * CGFloat(min(max(v / scale, 0), 1))
        if bh < 1 { continue }
        takeColors[j].withAlphaComponent(0.85).setFill()
        NSBezierPath(rect: NSRect(x: CGFloat(j) * pitch, y: 0, width: barW, height: bh)).fill()
    }
    return img
}

// MARK: - Threshold alerts

final class AlertManager {
    private var lastFired: [String: Date] = [:]
    private var wasAbove: [String: Bool] = [:]

    /// Check one sample against the threshold (°C); fires a macOS notification on crossing.
    func evaluate(cpu: Double?, gpu: Double?, ssd: Double?, thresholdC: Double) {
        guard thresholdC > 0 else { return }
        let now = Date()
        func check(_ name: String, _ v: Double?) {
            guard let v else { wasAbove[name] = false; return }
            let above = v >= thresholdC
            let crossed = above && !(wasAbove[name] ?? false)
            wasAbove[name] = above
            guard crossed else { return }
            if let last = lastFired[name], now.timeIntervalSince(last) < 300 { return }   // 5-min cooldown
            lastFired[name] = now
            let content = UNMutableNotificationContent()
            content.title = "MacTemp: \(name) hot"
            content.body = "\(name) at \(Int(v))°C (threshold \(Int(thresholdC))°C)"
            content.sound = .default
            let req = UNNotificationRequest(identifier: "mactemp.\(name)", content: content, trigger: nil)
            UNUserNotificationCenter.current().add(req)
        }
        check("CPU", cpu)               // caller passes the hottest CPU value
        check("GPU", gpu)
        check("SSD", ssd)
    }
}

// MARK: - Settings window (replaces defaults-write menu pickers)

final class SettingsWindowController: NSWindowController {
    private weak var app: AppDelegate?
    private var fanSlider: NSSlider?
    private var fanStatusLabel: NSTextField?
    private var refreshValueLabel: NSTextField?
    private var alertValueLabel: NSTextField?

    init(app: AppDelegate) {
        self.app = app
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 430),
                              styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = "MacTemp Settings"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        buildContent()
        window.center()
    }
    required init?(coder: NSCoder) { fatalError() }

    func show() {
        refreshFanUI()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func label(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: 12)
        return l
    }

    private func buildContent() {
        guard let app, let content = window?.contentView else { return }

        // Unit
        let unitSeg = NSSegmentedControl(labels: ["°C", "°F"], trackingMode: .selectOne, target: nil, action: nil)
        unitSeg.selectedSegment = app.unit == .celsius ? 0 : 1
        unitSeg.target = self; unitSeg.action = #selector(unitChanged(_:))
        // Bar mode
        let barPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        for m in [BarMode.tempsOnly, .tempsPlusRAM, .compact, .graph] { barPopup.addItem(withTitle: m.title) }
        barPopup.selectItem(at: app.barMode.rawValue)
        barPopup.target = self; barPopup.action = #selector(barModeChanged(_:))
        // Graph metric
        let metricPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        for m in [GraphMetric.cpuTemp, .gpuTemp, .ssdTemp, .cpuBusy, .netDown] { metricPopup.addItem(withTitle: m.title) }
        metricPopup.selectItem(at: app.graphMetric.rawValue)
        metricPopup.target = self; metricPopup.action = #selector(metricChanged(_:))
        // Refresh interval
        let refreshSlider = NSSlider(value: app.refreshSec, minValue: 1, maxValue: 10, target: nil, action: nil)
        refreshSlider.target = self; refreshSlider.action = #selector(refreshChanged(_:))
        let refreshValue = NSTextField(labelWithString: String(format: "%.0fs", app.refreshSec))
        refreshValueLabel = refreshValue
        // Alerts
        let alertCheck = NSButton(checkboxWithTitle: "Notify when a temperature crosses", target: self, action: #selector(alertEnabledChanged(_:)))
        alertCheck.state = app.alertEnabled ? .on : .off
        let alertStepper = NSStepper()
        alertStepper.minValue = 50; alertStepper.maxValue = 99; alertStepper.increment = 1
        alertStepper.integerValue = Int(app.alertTempC)
        alertStepper.target = self; alertStepper.action = #selector(alertTempChanged(_:))
        let alertValue = NSTextField(labelWithString: "\(Int(app.alertTempC))°C")
        alertValueLabel = alertValue
        // Login item + restore-on-quit
        let loginCheck = NSButton(checkboxWithTitle: "Launch MacTemp at login", target: self, action: #selector(loginToggled(_:)))
        if #available(macOS 13.0, *) {
            loginCheck.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        }
        let quitCheck = NSButton(checkboxWithTitle: "Restore fans to auto when MacTemp quits", target: self, action: #selector(quitToggled(_:)))
        quitCheck.state = app.restoreFansOnQuit ? .on : .off

        // Fan controls
        let fanStatus = NSTextField(labelWithString: "—")
        fanStatus.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        fanStatusLabel = fanStatus
        let slider = NSSlider(value: FanController.shared.customRPM, minValue: 1000, maxValue: 3625, target: nil, action: nil)
        slider.isContinuous = false
        slider.target = self; slider.action = #selector(fanApplyCustom(_:))
        fanSlider = slider
        let blastBtn = NSButton(title: "Full Blast", target: self, action: #selector(fanBlast(_:)))
        blastBtn.bezelStyle = .rounded
        let autoBtn = NSButton(title: "Back to Auto", target: self, action: #selector(fanAuto(_:)))
        autoBtn.bezelStyle = .rounded

        func hstack(_ views: [NSView]) -> NSStackView {
            let st = NSStackView(views: views)
            st.orientation = .horizontal
            st.spacing = 8
            return st
        }
        let leftLabels = [label("Menu bar units"), label("Menu bar shows"), label("Graph metric"),
                          label("Refresh every"), label("Hot alerts"), label(""), label(""),
                          label("Fan speed"), label("Custom RPM"), label("Fans")]
        let rightViews: [NSView] = [unitSeg, barPopup, metricPopup,
                                    hstack([refreshSlider, refreshValue]),
                                    hstack([alertCheck, alertStepper, alertValue]),
                                    loginCheck, quitCheck, fanStatus, slider,
                                    hstack([blastBtn, autoBtn])]
        let grid = NSGridView(numberOfColumns: 2, rows: 0)
        for i in 0..<leftLabels.count {
            grid.addRow(with: [leftLabels[i], rightViews[i]])
        }
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 12
        grid.columnSpacing = 10
        content.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -16),
        ])
    }

    private func refreshFanUI() {
        guard let s = app?.lastSample else { return }
        fanStatusLabel?.stringValue = s.fanRpm.isEmpty ? "no fans detected"
            : s.fanRpm.map { Int($0) }.map(String.init).joined(separator: " / ") + " RPM · " + (s.fanManual ? "MANUAL" : "auto")
        if let slider = fanSlider {
            slider.minValue = max(s.fanMinRpm, 100)
            slider.maxValue = max(s.fanMaxRpm, s.fanMinRpm + 100)
            slider.doubleValue = min(max(FanController.shared.customRPM, slider.minValue), slider.maxValue)
        }
    }

    @objc private func unitChanged(_ s: NSSegmentedControl) { app?.unit = s.selectedSegment == 0 ? .celsius : .fahrenheit }
    @objc private func barModeChanged(_ p: NSPopUpButton) { app?.barMode = BarMode(rawValue: p.indexOfSelectedItem) ?? .tempsPlusRAM }
    @objc private func metricChanged(_ p: NSPopUpButton) { app?.graphMetric = GraphMetric(rawValue: p.indexOfSelectedItem) ?? .cpuTemp }
    @objc private func refreshChanged(_ s: NSSlider) {
        app?.refreshSec = s.doubleValue
        refreshValueLabel?.stringValue = String(format: "%.0fs", s.doubleValue)
    }
    @objc private func alertEnabledChanged(_ b: NSButton) { app?.alertEnabled = (b.state == .on) }
    @objc private func alertTempChanged(_ st: NSStepper) {
        app?.alertTempC = Double(st.integerValue)
        alertValueLabel?.stringValue = "\(st.integerValue)°C"
    }
    @objc private func loginToggled(_ b: NSButton) {
        guard #available(macOS 13.0, *) else { return }
        do {
            if b.state == .on { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            let a = NSAlert(); a.messageText = "Login item"; a.informativeText = error.localizedDescription
            a.runModal()
        }
    }
    @objc private func quitToggled(_ b: NSButton) { app?.restoreFansOnQuit = (b.state == .on) }

    @objc private func fanApplyCustom(_ s: NSSlider) {
        FanController.shared.customRPM = s.doubleValue
        applyFan(.custom, rpm: s.doubleValue)
    }
    @objc private func fanBlast(_ sender: Any?) { applyFan(.blast, rpm: nil) }
    @objc private func fanAuto(_ sender: Any?) { applyFan(.auto, rpm: nil) }

    private func applyFan(_ mode: FanController.Mode, rpm: Double?) {
        FanController.shared.apply(mode, rpm: rpm) { [weak self] ok, err in
            if !ok, let err, err != "authorization cancelled" {
                let a = NSAlert(); a.messageText = "Fan control"; a.informativeText = err
                a.runModal()
            }
            self?.refreshFanUI()
        }
    }
}
