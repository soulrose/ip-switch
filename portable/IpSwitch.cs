// IP Switch portable: one exe, nothing to install. The app files ride inside as an embedded zip (payload.zip, made by
// build-portable.ps1). Each launch unpacks them to %LOCALAPPDATA%\IpSwitch\app-<version> (only when that version is
// not there yet) and starts IpSwitch.ps1. Settings (config.json, last-run.log) live next to the exe when that folder
// is writable, so a copy on a USB stick keeps its own IP; otherwise in %LOCALAPPDATA%\IpSwitch.
// Built by build-portable.ps1 with the C# compiler that ships with Windows (.NET Framework 4).
using System;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Reflection;
using System.Windows.Forms;

[assembly: AssemblyTitle("IP Switch")]
[assembly: AssemblyProduct("IP Switch")]
[assembly: AssemblyCompany("DevTeam, Information Technology, Faculty of Medicine Ramathibodi Hospital, Mahidol University")]
[assembly: AssemblyVersion("1.0.0.0")]

static class Portable
{
    [STAThread]
    static int Main()
    {
        try
        {
            string local = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "IpSwitch");
            string app;
            using (Stream payload = Assembly.GetExecutingAssembly().GetManifestResourceStream("payload.zip"))
            using (var zip = new ZipArchive(payload, ZipArchiveMode.Read))
            {
                app = Path.Combine(local, "app-" + Version(zip));
                if (!File.Exists(Path.Combine(app, "IpSwitch.ps1"))) Unpack(zip, app);
            }
            string data = Writable(Path.GetDirectoryName(Application.ExecutablePath)) ?? local;
            Directory.CreateDirectory(data);
            string ps = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), @"WindowsPowerShell\v1.0\powershell.exe");
            string args = "-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File \"" + Path.Combine(app, "IpSwitch.ps1") +
                          "\" -ConfigDir \"" + data.TrimEnd('\\') + "\" -ExePath \"" + Application.ExecutablePath + "\"";
            Process.Start(new ProcessStartInfo(ps, args) { WorkingDirectory = app, UseShellExecute = false, CreateNoWindow = true });
            return 0;
        }
        catch (Exception ex)
        {
            MessageBox.Show("เปิด IP Switch ไม่ได้: " + ex.Message, "IP Switch", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
    }

    static string Version(ZipArchive zip)
    {
        var e = zip.GetEntry("VERSION");
        if (e == null) return "0";
        using (var r = new StreamReader(e.Open())) return r.ReadToEnd().Trim();
    }

    // unpack into a temp folder first, then move it in, so a half-written copy is never used
    static void Unpack(ZipArchive zip, string app)
    {
        string tmp = app + ".tmp" + Process.GetCurrentProcess().Id;
        if (Directory.Exists(tmp)) Directory.Delete(tmp, true);
        zip.ExtractToDirectory(tmp);
        if (Directory.Exists(app)) Directory.Delete(app, true);
        Directory.Move(tmp, app);
        foreach (string old in Directory.GetDirectories(Path.GetDirectoryName(app), "app-*"))
            if (!old.Equals(app, StringComparison.OrdinalIgnoreCase))
                try { Directory.Delete(old, true); } catch { }   // still open in another window: next time
    }

    static string Writable(string dir)
    {
        try
        {
            string probe = Path.Combine(dir, ".ipswitch-write-test");
            File.WriteAllText(probe, "");
            File.Delete(probe);
            return dir;
        }
        catch { return null; }
    }
}
