// IP Switch Setup: installs the portable IpSwitch.exe (embedded as a resource) into %LOCALAPPDATA%\Programs\IpSwitch,
// makes the Desktop / Start menu icons and registers it in Windows "Apps" so it can be uninstalled there. No admin
// needed. Because the installed program is the portable exe itself, its in-app update keeps working after install.
// Installing over an older copy keeps config.json (this PC's IP). Built by installer\build-setup.ps1.
//   IpSwitch-Setup.exe [/silent] [/dir=C:\IpSwitch] [/noicons] [/open]
//   uninstall.exe /uninstall [/silent]        (what Windows "Apps" runs)
using System;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Windows.Forms;
using Microsoft.Win32;

[assembly: AssemblyTitle("IP Switch Setup")]
[assembly: AssemblyProduct("IP Switch")]
[assembly: AssemblyCompany("DevTeam, Information Technology, Faculty of Medicine Ramathibodi Hospital, Mahidol University")]
[assembly: AssemblyVersion("1.0.0.0")]

static class Setup
{
    public const string Title = "IP Switch Setup";
    const string UninstallKey = @"Software\Microsoft\Windows\CurrentVersion\Uninstall\IpSwitch";
    public const string Publisher = "DevTeam, Information Technology, Faculty of Medicine Ramathibodi Hospital, Mahidol University";

    [DllImport("user32.dll")] static extern bool SetProcessDPIAware();

    [STAThread]
    static int Main()
    {
        try { SetProcessDPIAware(); } catch { }
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        bool silent = false, icons = true, open = false, uninstall = false; string dir = null;
        string[] args = Environment.GetCommandLineArgs();
        for (int i = 1; i < args.Length; i++)
        {
            string a = args[i].ToLowerInvariant();
            if (a == "/silent") silent = true;
            else if (a == "/noicons") icons = false;
            else if (a == "/open") open = true;
            else if (a == "/uninstall") uninstall = true;
            else if (a.StartsWith("/dir=")) dir = args[i].Substring(5).Trim('"');
        }
        try
        {
            if (uninstall) return Uninstall(silent);
            if (!silent) { Application.Run(new SetupForm()); return 0; }
            dir = Path.GetFullPath(dir ?? InstalledDir() ?? DefaultDir());
            Install(dir, icons);
            Console.WriteLine("installed " + Version() + " in " + dir);
            if (open) Launch(dir);
            return 0;
        }
        catch (Exception ex)
        {
            if (silent) Console.Error.WriteLine("setup failed: " + ex.Message);
            else MessageBox.Show(ex.Message, Title, MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
    }

    public static string DefaultDir()
    {
        return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), @"Programs\IpSwitch");
    }

    public static string InstalledDir()
    {
        try { using (var k = Registry.CurrentUser.OpenSubKey(UninstallKey)) return k == null ? null : k.GetValue("InstallLocation") as string; }
        catch { return null; }
    }

    public static string Version()
    {
        using (var s = Assembly.GetExecutingAssembly().GetManifestResourceStream("VERSION"))
        using (var r = new StreamReader(s)) return r.ReadToEnd().Trim();
    }

    public static void Install(string dir, bool icons)
    {
        Directory.CreateDirectory(dir);
        string exe = Path.Combine(dir, "IpSwitch.exe");
        using (var s = Assembly.GetExecutingAssembly().GetManifestResourceStream("IpSwitch.exe"))
        using (var f = File.Create(exe)) s.CopyTo(f);
        // a copy of this setup stays as the uninstaller Windows "Apps" calls
        string me = Application.ExecutablePath, un = Path.Combine(dir, "uninstall.exe");
        if (!string.Equals(Path.GetFullPath(me), Path.GetFullPath(un), StringComparison.OrdinalIgnoreCase)) File.Copy(me, un, true);
        if (icons) foreach (string lnk in Shortcuts()) Shortcut(lnk, exe, dir);
        using (var k = Registry.CurrentUser.CreateSubKey(UninstallKey))
        {
            k.SetValue("DisplayName", "IP Switch");
            k.SetValue("DisplayVersion", Version());
            k.SetValue("Publisher", Publisher);
            k.SetValue("DisplayIcon", exe + ",0");
            k.SetValue("InstallLocation", dir);
            k.SetValue("UninstallString", "\"" + un + "\" /uninstall");
            k.SetValue("QuietUninstallString", "\"" + un + "\" /uninstall /silent");
            k.SetValue("EstimatedSize", (int)((new FileInfo(exe).Length + new FileInfo(un).Length) / 1024), RegistryValueKind.DWord);
            k.SetValue("NoModify", 1, RegistryValueKind.DWord);
            k.SetValue("NoRepair", 1, RegistryValueKind.DWord);
        }
    }

    static string[] Shortcuts()
    {
        return new[] {
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory), "IP Switch.lnk"),
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Programs), "IP Switch.lnk") };
    }

    public static void Launch(string dir)
    {
        Process.Start(new ProcessStartInfo(Path.Combine(dir, "IpSwitch.exe")) { WorkingDirectory = dir, UseShellExecute = true });
    }

    // removes the program, its settings, icons, unpacked copies and the "Apps" entry; the folder goes after this exits
    static int Uninstall(bool silent)
    {
        string dir = InstalledDir() ?? Path.GetDirectoryName(Application.ExecutablePath);
        if (!silent && MessageBox.Show("ถอนการติดตั้ง IP Switch และลบค่าที่บันทึกไว้ในเครื่องนี้?\n\n" + dir, Title,
                MessageBoxButtons.OKCancel, MessageBoxIcon.Question) != DialogResult.OK) return 1;
        foreach (string lnk in Shortcuts()) try { File.Delete(lnk); } catch { }
        try { Registry.CurrentUser.DeleteSubKeyTree(UninstallKey, false); } catch { }
        string cache = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "IpSwitch");
        try { if (Directory.Exists(cache)) Directory.Delete(cache, true); } catch { }
        foreach (string f in new[] { "IpSwitch.exe", "config.json", "last-run.log" })
            try { File.Delete(Path.Combine(dir, f)); } catch { }
        Process.Start(new ProcessStartInfo("cmd.exe", "/c ping 127.0.0.1 -n 3 >nul & rmdir /s /q \"" + dir + "\"")
            { CreateNoWindow = true, UseShellExecute = false, WindowStyle = ProcessWindowStyle.Hidden });
        if (!silent) MessageBox.Show("ถอนการติดตั้ง IP Switch แล้ว", Title, MessageBoxButtons.OK, MessageBoxIcon.Information);
        return 0;
    }

    static void Shortcut(string lnk, string exe, string dir)
    {
        Type t = Type.GetTypeFromProgID("WScript.Shell");
        object shell = Activator.CreateInstance(t);
        try
        {
            object sc = t.InvokeMember("CreateShortcut", BindingFlags.InvokeMethod, null, shell, new object[] { lnk });
            Type st = sc.GetType();
            st.InvokeMember("TargetPath", BindingFlags.SetProperty, null, sc, new object[] { exe });
            st.InvokeMember("WorkingDirectory", BindingFlags.SetProperty, null, sc, new object[] { dir });
            st.InvokeMember("IconLocation", BindingFlags.SetProperty, null, sc, new object[] { exe + ",0" });
            st.InvokeMember("Description", BindingFlags.SetProperty, null, sc, new object[] { "สลับ IP ระหว่าง LAN, Wi-Fi และ DHCP" });
            st.InvokeMember("Save", BindingFlags.InvokeMethod, null, sc, null);
            Marshal.ReleaseComObject(sc);
        }
        finally { Marshal.ReleaseComObject(shell); }
    }
}

class SetupForm : Form
{
    readonly string version = Setup.Version();
    readonly TextBox dirBox = new TextBox();
    readonly CheckBox iconBox = new CheckBox(), openBox = new CheckBox();
    readonly Button installBtn = new Button(), cancelBtn = new Button(), browseBtn = new Button();

    public SetupForm()
    {
        string installed = Setup.InstalledDir();
        Text = "ติดตั้ง IP Switch " + version;
        Font = new Font("Segoe UI", 9.75f);
        AutoScaleMode = AutoScaleMode.Dpi;
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = false; MinimizeBox = false;
        StartPosition = FormStartPosition.CenterScreen;
        BackColor = Color.White;
        try { Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath); } catch { }
        ClientSize = new Size(540, 290);

        var head = new Label { Text = "IP Switch " + version, Font = new Font("Segoe UI Semibold", 15f), AutoSize = true, Location = new Point(24, 20) };
        var sub = new Label
        {
            Text = "สลับ IP static ระหว่างสาย LAN, Wi-Fi และ DHCP ด้วยการกดปุ่มเดียว\nติดตั้งให้ผู้ใช้คนนี้ ไม่ต้องใช้สิทธิ์ admin ตอนติดตั้ง",
            ForeColor = Color.FromArgb(90, 90, 100), AutoSize = true, Location = new Point(26, 58)
        };
        var dirLabel = new Label { Text = installed != null ? "ติดตั้งไว้แล้วที่ (จะอัปเดตทับ ค่า IP เดิมยังอยู่)" : "ติดตั้งที่", AutoSize = true, Location = new Point(26, 108) };
        dirBox.Text = installed ?? Setup.DefaultDir();
        dirBox.Location = new Point(26, 130); dirBox.Width = 390;
        browseBtn.Text = "เลือก…"; browseBtn.Location = new Point(426, 128); browseBtn.Size = new Size(88, 30);
        browseBtn.Click += (s, e) =>
        {
            using (var d = new FolderBrowserDialog { Description = "เลือกโฟลเดอร์ที่จะติดตั้ง IP Switch", SelectedPath = dirBox.Text })
                if (d.ShowDialog(this) == DialogResult.OK) dirBox.Text = Path.Combine(d.SelectedPath, "IpSwitch");
        };
        iconBox.Text = "สร้างไอคอนบน Desktop และเมนู Start"; iconBox.Checked = true; iconBox.AutoSize = true; iconBox.Location = new Point(26, 172);
        openBox.Text = "เปิด IP Switch เมื่อติดตั้งเสร็จ"; openBox.Checked = true; openBox.AutoSize = true; openBox.Location = new Point(26, 200);
        installBtn.Text = installed != null ? "อัปเดต" : "ติดตั้ง"; installBtn.Size = new Size(110, 34); installBtn.Location = new Point(286, 240);
        cancelBtn.Text = "ยกเลิก"; cancelBtn.Size = new Size(110, 34); cancelBtn.Location = new Point(404, 240);
        installBtn.Click += (s, e) => DoInstall();
        cancelBtn.Click += (s, e) => Close();
        AcceptButton = installBtn; CancelButton = cancelBtn; ActiveControl = installBtn;
        Controls.AddRange(new Control[] { head, sub, dirLabel, dirBox, browseBtn, iconBox, openBox, installBtn, cancelBtn });
    }

    void DoInstall()
    {
        string dir;
        try { dir = Path.GetFullPath(dirBox.Text.Trim()); }
        catch { MessageBox.Show(this, "ที่ติดตั้งไม่ถูกต้อง", Text, MessageBoxButtons.OK, MessageBoxIcon.Warning); return; }
        installBtn.Enabled = cancelBtn.Enabled = browseBtn.Enabled = dirBox.Enabled = false;
        try { Setup.Install(dir, iconBox.Checked); }
        catch (Exception ex)
        {
            MessageBox.Show(this, "ติดตั้งไม่สำเร็จ: " + ex.Message, Text, MessageBoxButtons.OK, MessageBoxIcon.Error);
            installBtn.Enabled = cancelBtn.Enabled = browseBtn.Enabled = dirBox.Enabled = true;
            return;
        }
        if (openBox.Checked)
        {
            try { Setup.Launch(dir); }
            catch (Exception ex) { MessageBox.Show(this, "ติดตั้งแล้ว แต่เปิดโปรแกรมไม่ได้: " + ex.Message, Text, MessageBoxButtons.OK, MessageBoxIcon.Warning); }
        }
        else MessageBox.Show(this, "ติดตั้ง IP Switch " + version + " แล้ว\n" + dir, Text, MessageBoxButtons.OK, MessageBoxIcon.Information);
        Close();
    }
}
