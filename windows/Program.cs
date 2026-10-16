using System;
using System.Drawing;
using System.Management;
using System.Reflection;
using System.Windows.Forms;
using LibreHardwareMonitor.Hardware;
using Microsoft.Win32;

namespace MacTempWin;

/// Menu bar (system tray) temperature monitor — the Windows 11 counterpart of MacTemp.
/// CPU / GPU temperature via LibreHardwareMonitor, CPU + RAM load via LHM sensors,
/// WMI thermal-zone fallback when LHM exposes no CPU temperature sensor.
internal static class Program
{
    private const string RunKeyPath = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string RunValueName = "MacTempWin";

    private static ToolStripMenuItem cpuItem = null!;
    private static ToolStripMenuItem gpuItem = null!;
    private static ToolStripMenuItem sysItem = null!;
    private static ToolStripMenuItem startupItem = null!;

    [STAThread]
    private static void Main()
    {
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);

        var computer = new Computer
        {
            IsCpuEnabled = true,
            IsGpuEnabled = true,
            IsMemoryEnabled = true,
        };
        computer.Open();

        var menu = new ContextMenuStrip();
        cpuItem = new ToolStripMenuItem("CPU —") { Enabled = false };
        gpuItem = new ToolStripMenuItem("GPU —") { Enabled = false };
        sysItem = new ToolStripMenuItem("Load —") { Enabled = false };
        menu.Items.Add(cpuItem);
        menu.Items.Add(gpuItem);
        menu.Items.Add(sysItem);

        menu.Items.Add(new ToolStripSeparator());
        startupItem = new ToolStripMenuItem("Run at login") { Checked = StartupEnabled() };
        startupItem.Click += (_, _) =>
        {
            SetStartup(!startupItem.Checked);
            startupItem.Checked = StartupEnabled();
        };
        menu.Items.Add(startupItem);
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("Quit", null, (_, _) => Application.Exit());

        using var icon = LoadTrayIcon();
        using var tray = new NotifyIcon
        {
            Icon = icon,
            Visible = true,
            Text = "MacTemp",
            ContextMenuStrip = menu,
        };

        var timer = new System.Windows.Forms.Timer { Interval = 2000 };
        timer.Tick += (_, _) => RefreshReadings(computer, tray);
        timer.Start();
        RefreshReadings(computer, tray);

        Application.Run();
        timer.Stop();
        computer.Close();
    }

    private static void RefreshReadings(Computer computer, NotifyIcon tray)
    {
        float? cpuPackage = null;
        float? cpuAnyTemp = null;
        float? gpuTemp = null;
        float? cpuLoad = null;
        double memUsed = 0, memAvailable = 0;

        foreach (var hw in computer.Hardware)
        {
            hw.Update();
            foreach (var sensor in hw.Sensors)
            {
                if (sensor.Value == null)
                    continue;

                switch (hw.HardwareType)
                {
                    case HardwareType.Cpu:
                        if (sensor.SensorType == SensorType.Temperature)
                        {
                            cpuAnyTemp = Bigger(cpuAnyTemp, sensor.Value);
                            if (sensor.Name.Contains("Package", StringComparison.OrdinalIgnoreCase))
                                cpuPackage = Bigger(cpuPackage, sensor.Value);
                        }
                        else if (sensor.SensorType == SensorType.Load &&
                                 sensor.Name.Contains("Total", StringComparison.OrdinalIgnoreCase))
                        {
                            cpuLoad = sensor.Value;
                        }
                        break;

                    case HardwareType.GpuNvidia:
                    case HardwareType.GpuAmd:
                    case HardwareType.GpuIntel:
                        if (sensor.SensorType == SensorType.Temperature)
                            gpuTemp = Bigger(gpuTemp, sensor.Value);
                        break;

                    case HardwareType.Memory:
                        if (sensor.SensorType == SensorType.Data)
                        {
                            if (sensor.Name.Contains("Used", StringComparison.OrdinalIgnoreCase))
                                memUsed = sensor.Value.Value;
                            else if (sensor.Name.Contains("Available", StringComparison.OrdinalIgnoreCase))
                                memAvailable = sensor.Value.Value;
                        }
                        break;
                }
            }
        }

        var cpuTemp = cpuPackage ?? cpuAnyTemp ?? WmiThermalZoneTemp();
        var ramTotal = memUsed + memAvailable;

        cpuItem.Text = cpuTemp.HasValue ? $"CPU  {cpuTemp.Value:F0} °C" : "CPU  n/a";
        gpuItem.Text = gpuTemp.HasValue ? $"GPU  {gpuTemp.Value:F0} °C" : "GPU  n/a";
        sysItem.Text = cpuLoad.HasValue && ramTotal > 0
            ? $"Load  CPU {cpuLoad.Value:F0}% · RAM {memUsed / ramTotal * 100:F0}%"
            : "Load  n/a";
        tray.Text = cpuTemp.HasValue
            ? $"MacTemp — CPU {cpuTemp.Value:F0} °C"
            : "MacTemp";
        if (tray.Text.Length > 63)
            tray.Text = tray.Text[..63]; // NotifyIcon.Text is capped at 63 chars
    }

    private static float? Bigger(float? a, float? b) =>
        b == null ? a : a == null ? b : Math.Max(a.Value, b.Value);

    /// Fallback: ACPI thermal zones via WMI (root\WMI). Rough but works without LHM sensors.
    private static float? WmiThermalZoneTemp()
    {
        try
        {
            using var searcher = new ManagementObjectSearcher(
                "root\\WMI", "SELECT * FROM MSAcpi_ThermalZoneTemperature");
            foreach (ManagementObject mo in searcher.Get())
            {
                if (mo["CurrentTemperature"] is null)
                    continue;
                // Reported in tenths of Kelvin.
                var celsius = Convert.ToDouble(mo["CurrentTemperature"]) / 10.0 - 273.15;
                if (celsius > 0 && celsius < 200)
                    return (float)celsius;
            }
        }
        catch
        {
            // WMI provider unavailable — menu will show n/a.
        }
        return null;
    }

    private static Icon LoadTrayIcon()
    {
        var asm = Assembly.GetExecutingAssembly();
        using var stream = asm.GetManifestResourceStream("MacTempWin.tray.png")
            ?? throw new InvalidOperationException("Embedded tray.png missing");
        using var bmp = new Bitmap(stream);
        return (Icon)Icon.FromHandle(bmp.GetHicon()).Clone();
    }

    private static bool StartupEnabled()
    {
        using var key = Registry.CurrentUser.OpenSubKey(RunKeyPath);
        return key?.GetValue(RunValueName) != null;
    }

    private static void SetStartup(bool enable)
    {
        using var key = Registry.CurrentUser.OpenSubKey(RunKeyPath, writable: true);
        if (key is null)
            return;
        if (enable)
            key.SetValue(RunValueName, $"\"{Application.ExecutablePath}\"");
        else
            key.DeleteValue(RunValueName, throwOnMissingValue: false);
    }
}
