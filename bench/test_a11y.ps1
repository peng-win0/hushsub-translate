# Offline check: a screen reader (Narrator, NVDA) hears each new app status once, not every tick of a download
# (WCAG 4.1.3). Runs CaptionsApp.ps1's own .NET switch line and Set-Status on a small off-screen window, and listens
# the way screen readers do (UI Automation). usage: powershell -File bench/test_a11y.ps1
$ast = [Management.Automation.Language.Parser]::ParseFile("$PSScriptRoot\..\CaptionsApp.ps1", [ref]$null, [ref]$null)
function Fail($what) { "FAIL: $what"; exit 1 }
$switch = $ast.Find({ param($n) $n -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $n.Member.Value -eq "SetSwitch" }, $true)
if (-not $switch) { Fail "no accessibility switch: screen readers never hear a status change" }
Invoke-Expression $switch.Extent.Text  # before WPF loads, as in the app
$fn = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq "Set-Status" }, $true)
if (-not $fn) { Fail "no Set-Status" }
Invoke-Expression $fn.Extent.Text
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, UIAutomationClient, UIAutomationTypes
$refs = [Windows.Automation.AutomationElement].Assembly.Location, [Windows.Automation.AutomationElementIdentifiers].Assembly.Location
Add-Type -ReferencedAssemblies $refs -TypeDefinition @'
using System; using System.Threading; using System.Windows.Automation;
public static class Hear {  // a UI Automation client on its own thread, as a screen reader is
    public static int Count; public static string Error = ""; public static ManualResetEvent Ready = new ManualResetEvent(false);
    public static void Listen(IntPtr hwnd) {
        Thread t = new Thread(() => {
            try { Automation.AddAutomationEventHandler(AutomationElementIdentifiers.LiveRegionChangedEvent, AutomationElement.FromHandle(hwnd),
                                                       TreeScope.Subtree, (s, e) => Interlocked.Increment(ref Count)); }
            catch (Exception x) { Error = x.Message; }
            Ready.Set();
        });
        t.SetApartmentState(ApartmentState.MTA); t.IsBackground = true; t.Start();
    }
}
'@
$statusTitle, $statusText, $panel = (New-Object Windows.Controls.TextBlock), (New-Object Windows.Controls.TextBlock), (New-Object Windows.Controls.StackPanel)
[void]$panel.Children.Add($statusTitle); [void]$panel.Children.Add($statusText)
$w = New-Object Windows.Window -Property @{ Content = $panel; Width = 300; Height = 100; Left = -3000; Top = -3000
    WindowStartupLocation = "Manual"; ShowActivated = $false; ShowInTaskbar = $false }
$w.Show()
function Pump($ms) { $end = [DateTime]::Now.AddMilliseconds($ms); while ([DateTime]::Now -lt $end) { $w.Dispatcher.Invoke([Action]{}, "Background"); Start-Sleep -Milliseconds 10 } }
[Hear]::Listen((New-Object Windows.Interop.WindowInteropHelper $w).Handle)
$t0 = [DateTime]::Now
while (([DateTime]::Now - $t0).TotalSeconds -lt 10 -and -not ([Hear]::Ready.WaitOne(0) -and [Windows.Automation.Peers.AutomationPeer]::ListenerExists("LiveRegionChanged"))) { Pump 50 }
if ([Hear]::Error) { Fail "listener: $([Hear]::Error)" }
# a new title is said; the same title with new text (a download's progress) is not
foreach ($step in @("Off", "Press Start.", $true), @("Off", "Play audio.", $false), @("Starting", "Loading models.", $true),
                  @("Starting", "Loading models.", $false), @("On: Fast", "Captions appear when someone speaks.", $true)) {
    $before = [Hear]::Count
    Set-Status $step[0] $step[1]
    Pump 800
    if (([Hear]::Count -gt $before) -ne $step[2]) { Fail "$($step[0]) / $($step[1]): heard $([Hear]::Count - $before) times, want $(if ($step[2]) { 'some' } else { 'none' })" }
}
if ($statusText.Text -cne "Captions appear when someone speaks.") { Fail "status text: $($statusText.Text)" }
$peer = [Windows.Automation.Peers.UIElementAutomationPeer]::CreatePeerForElement($statusTitle)
if ("$($peer.GetLiveSetting())" -ne "Polite") { Fail "live setting: $($peer.GetLiveSetting()): screen readers skip it" }
if ($peer.GetName() -cne "On: Fast. Captions appear when someone speaks.") { Fail "what is said: $($peer.GetName())" }
$w.Close()
"a11y ok"
