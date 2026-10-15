// metrics_test.swift — harness: print IOReport power/usage/freq + network deltas.
import Foundation

@main struct Harness {
    static func main() {
        setbuf(stdout, nil); print("harness start")
        guard let m = IOReportMetrics() else { print("IOReportMetrics init FAILED"); exit(1) }
        print("IOReportMetrics init OK")
        for i in 0..<3 {
            usleep(1_500_000)
            let r = m.sample()
            func w(_ v: Double?) -> String { v.map { String(format: "%.1f", $0) } ?? "--" }
            print("sample\(i): CPU W=\(w(r.cpuPowerW)) busy=\(w(r.cpuBusyPct))% maxMHz=\(w(r.cpuMaxMHz)) | "
                + "GPU W=\(w(r.gpuPowerW)) busy=\(w(r.gpuBusyPct))% MHz=\(w(r.gpuMHz))")
        }
        let net = NetworkSampler()
        usleep(1_000_000)
        let (d, u) = net.sample()
        usleep(2_000_000)
        let (d2, u2) = net.sample()
        print("net idle: down=\(Int(d))B/s up=\(Int(u))B/s | down2=\(Int(d2))B/s up2=\(Int(u2))B/s")
    }
}
