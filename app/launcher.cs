// Hushsub Translate.exe: the app as a real Windows program. It runs CaptionsApp.ps1 inside itself (Windows PowerShell
// 5.1's engine, part of Windows), so the taskbar, Task Manager and pins show Hushsub Translate with its own icon, not
// PowerShell, and no console window ever opens. CaptionsApp.ps1 builds this file into the .exe with Windows' own C#
// compiler (.NET Framework 4) the first time and when this version changes: nothing prebuilt, nothing downloaded.
using System;
using System.IO;
using System.Management.Automation;
using System.Management.Automation.Runspaces;
using System.Reflection;
using System.Runtime.InteropServices;

[assembly: AssemblyTitle("Hushsub Translate")]
[assembly: AssemblyProduct("Hushsub Translate")]
[assembly: AssemblyVersion("1.1.0.0")]  // bump when this file changes: the app then rebuilds the .exe

static class Launcher {
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    static extern int MessageBoxW(IntPtr owner, string text, string caption, uint type);

    [STAThread]  // WPF windows need a single-threaded apartment
    static int Main() {
        string dir = AppDomain.CurrentDomain.BaseDirectory;
        string script = Path.Combine(dir, "CaptionsApp.ps1");
        try {
            Directory.SetCurrentDirectory(dir);
            InitialSessionState state = InitialSessionState.CreateDefault();
            state.ExecutionPolicy = Microsoft.PowerShell.ExecutionPolicy.Bypass;  // this process only, like -ExecutionPolicy Bypass
            using (Runspace runspace = RunspaceFactory.CreateRunspace(state)) {
                runspace.ApartmentState = System.Threading.ApartmentState.STA;
                runspace.ThreadOptions = PSThreadOptions.UseCurrentThread;  // the window's events run on this thread
                runspace.Open();
                using (PowerShell ps = PowerShell.Create()) {
                    ps.Runspace = runspace;
                    // returns when the window closes. Its output, errors and Write-Host text are dropped (a console
                    // would have scrolled them away; kept here they would pile up in memory while the app runs).
                    ps.AddScript("param($p) & $p *> $null").AddArgument(script).Invoke();
                }
            }
            return 0;
        } catch (Exception e) {
            MessageBoxW(IntPtr.Zero, "Hushsub Translate failed to start:\n" + e.Message, "Hushsub Translate", 0x10);
            return 1;
        }
    }
}
