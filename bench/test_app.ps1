# Offline check that the app window builds: the XAML parses, startup runs without an error, Help draws README.md,
# and the theme and tab switches work. Before and after the engine's install. Runs a temp copy of the app (never the
# real folder, settings or shortcuts) and never shows the window. update.ps1 checks only that scripts parse, so this
# is what keeps a release that can't open from reaching auto-update.
# usage: powershell -File bench/test_app.ps1
$app = Resolve-Path "$PSScriptRoot\.."
function Fail($what) { "FAIL: $what"; Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue; exit 1 }
foreach ($installed in $false, $true) {
    $root = Join-Path ([IO.Path]::GetTempPath()) "pc-test-app-$PID"
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    $null = New-Item -ItemType Directory $root
    Copy-Item -LiteralPath ("CaptionsApp.ps1", "version.txt", "README.md", "LICENSE", "app", "Plugins" | ForEach-Object { "$app\$_" }) -Destination $root -Recurse
    Copy-Item -LiteralPath "$app\app\icon.ico" "$root\app.ico"  # left by 1.5.1 or older
    # an older updater installed app\ over 1.5.2: the old files stay, the users words are at the top
    Copy-Item -LiteralPath "$app\app\captions.ps1", "$app\app\Profiles", "$app\app\fonts" -Destination $root -Recurse
    [IO.File]::WriteAllLines("$root\glossary.txt", [string[]]"Mine = Mine$([char]0xE9)", [Text.Encoding]::Default)  # saved as ANSI
    $null = New-Item -ItemType Directory "$root\.update-backup"; Set-Content -LiteralPath "$root\.update-done" -Value "9.9.9"  # an older updater just ran
    Set-Content -LiteralPath "$root\app-settings.json" -Value '{"autoUpdate": false}'  # no update check from the copy
    $s = [IO.File]::ReadAllText("$app\CaptionsApp.ps1")
    $patches = @(
        @('if ($PSScriptRoot -like "$([IO.Path]::GetTempPath())*")', 'if ($false)'),  # the copy is in the temp folder
        @('"Local\PrivateCaptionsApp"', '"Local\PrivateCaptionsAppTest"'),          # an open app doesn't stop the test
        @('trap { [void][Windows.MessageBox]::Show("Hushsub Translate failed to start:`n$_", "Hushsub Translate"); break }',
          'trap { "$_ $($_.InvocationInfo.PositionMessage)" | Set-Content "$PSScriptRoot\fail.txt"; break }'),
        @('try { Build-Exe } catch {}', ''),                                            # test_exe.ps1 checks that
        @('[void]$win.ShowDialog()', @'
Show-Help $true
if ($helpBody.Children.Count -lt 10) { throw "Help has $($helpBody.Children.Count) parts" }
Show-Help $false
Set-Theme (-not $script:dark); Set-Theme (-not $script:dark)
$win.FindName("AppTabButton").IsChecked = $true; $win.FindName("CaptionTabButton").IsChecked = $true
& $tick
$wordsBox.Text += "`r`nx = y"; if (((Word-Lines $wordsBox.Text) -join "`n") -eq $script:savedWords) { throw "unsaved words not noticed" }
try { ([IO.File]::Open("$PSScriptRoot\app\icon.ico", "Open", "ReadWrite", "Read")).Close() } catch { throw "the open window locks icon.ico: updates would fail" }
if (@(Test-Path -LiteralPath "$PSScriptRoot\app.ico","$PSScriptRoot\captions.ps1", "$PSScriptRoot\Profiles", "$PSScriptRoot\fonts", "$PSScriptRoot\glossary.txt") -contains $true) { throw "an old file stayed at the top" }
if ("$(Get-Content -LiteralPath "$PSScriptRoot\app\glossary.txt" -Encoding UTF8)" -ne "Mine = Mine$([char]0xE9)") { throw "the users ANSI words didnt move into app as UTF-8" }
if (($wordsBox.Text -split "`r`n")[0] -ne "Mine = Mine$([char]0xE9)") { throw "an ANSI glossary read as: $($wordsBox.Text)" }
function Start-Best { $script:started = "Start-Best" }; function Start-Install { $script:started = "Start-Install" }; function Engine-Running { $false }
$click = { $script:clicked = $null; $script:started = $null; $button.RaiseEvent((New-Object Windows.RoutedEventArgs ([Windows.Controls.Primitives.ButtonBase]::ClickEvent))); $script:started }
$script:updater, $script:updateApply = (Get-Process -Id $PID), $true  # an update that began installing this second
$during = & $click
$script:updater, $script:updateApply = $null, $false
if ($during) { throw "Start pressed while an update installs ran $during" }
if (-not (& $click)) { throw "Start pressed with no update did nothing, so the check above checks nothing" }
# the Move buttons (for people who can't drag the captions): on only while captions show, each asks the plugin for its own move
if ($moveButtons.IsEnabled) { throw "Move buttons on while captions are off" }
function Ours-Open { $true }
& $tick
if (-not $moveButtons.IsEnabled) { throw "Move buttons off while captions are on" }
$asked = foreach ($b in $moveButtons.Children) { if ($b -is [Windows.Controls.Button]) {
    $b.RaiseEvent((New-Object Windows.RoutedEventArgs ([Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
    "$([Windows.Automation.AutomationProperties]::GetName($b)): $(Get-Content -LiteralPath "$PSScriptRoot\.captions-move")" } }
if (($asked -join "; ") -ne "Move captions left: -40 0; Move captions right: 40 0; Move captions up: 0 -40; Move captions down: 0 40") { throw "Move buttons asked for: $($asked -join '; ')" }
Set-Content -LiteralPath "$PSScriptRoot\.captions-paused" -Value ""
& $tick
if ($moveButtons.IsEnabled) { throw "Move buttons on while captions are paused" }
if (Engine-Installed) {  # Stop pauses the engine; after a failed start ("Press Stop, then Start") it closes it, so Start starts anew
    Remove-Item -LiteralPath "$PSScriptRoot\.captions-paused"
    $null = & $click
    if ($script:stopping -or -not (Test-Path -LiteralPath "$PSScriptRoot\.captions-paused")) { throw "Stop while captions run didn't pause them" }
    Remove-Item -LiteralPath "$PSScriptRoot\.captions-paused"; Set-Content -LiteralPath "$PSScriptRoot\.captions-failed" -Value "Download failed"
    $null = & $click
    if (-not $script:stopping) { throw "Stop after a failed start left its console open: Start would only resume it" }
    $script:stopping = $null; Remove-Item -LiteralPath "$PSScriptRoot\.captions-failed"
}
function Ours-Open { $false }  # nothing to stop as the test ends
# icons are decoration beside a label: on no page is a screen reader read their private-use characters, or Tab stopped on one
function Drawn($e) { $e; for ($i = 0; $i -lt [Windows.Media.VisualTreeHelper]::GetChildrenCount($e); $i++) { Drawn ([Windows.Media.VisualTreeHelper]::GetChild($e, $i)) } }
$icons = @{}; $stops = @()
foreach ($page in { }, { $win.FindName("AppTabButton").IsChecked = $true }, { Show-Help $true }) {
    & $page
    $win.Content.Measure((New-Object Windows.Size 800, 100000)); $win.Content.Arrange((New-Object Windows.Rect 0, 0, 800, 100000)); $win.Content.UpdateLayout()
    foreach ($e in Drawn $win.Content) {
        if ($e.GetType() -eq [Windows.Controls.Control] -and $e.Focusable) { $stops += $e }
        $peer = if ($e -is [Windows.UIElement]) { [Windows.Automation.Peers.UIElementAutomationPeer]::CreatePeerForElement($e) }
        if ($peer -and $peer.GetName() -match "[$([char]0xE000)-$([char]0xF8FF)]") { $icons[$e] = $peer.IsControlElement() -or $peer.IsContentElement() }
    }
}
$read = @($icons.Keys | Where-Object { $icons[$_] })
if ($icons.Count -lt 20) { throw "only $($icons.Count) icons found on the three pages: this check checks nothing" }
if ($read) { throw "a screen reader is read $($read.Count) of $($icons.Count) icons: $(($read | ForEach-Object { '{0:X}' -f [int]$_.Text[0] }) -join ' ')" }
if ($stops) { throw "Tab stops on $($stops.Count) icons" }
if ([Windows.Automation.AutomationProperties]::GetName($win.FindName("HelpBack")) -ne "Back to settings") { throw "the Back button (an arrow and Back) doesn't say where it goes" }
Set-Content "$PSScriptRoot\ok.txt" "ok"
'@))
    if ($installed) { $patches += , @('function Engine-Installed { Test-Path -LiteralPath "audioWhisper\audioWhisper.exe" }', 'function Engine-Installed { $true }') }
    foreach ($p in $patches) {
        if (-not $s.Contains($p[0])) { Fail "CaptionsApp.ps1 changed, update this test: $($p[0])" }
        $s = $s.Replace($p[0], $p[1])
    }
    [IO.File]::WriteAllText("$root\CaptionsApp.ps1", $s)
    $null = & powershell -NoProfile -STA -ExecutionPolicy Bypass -File "$root\CaptionsApp.ps1" 2>&1
    $what = if ($installed) { "installed" } else { "not installed" }
    if (Test-Path -LiteralPath "$root\fail.txt") { Fail "$what, startup: $(Get-Content -LiteralPath "$root\fail.txt" -Raw)" }
    if (Test-Path -LiteralPath "$root\.app-error.txt") { Fail "$what, handler: $(Get-Content -LiteralPath "$root\.app-error.txt" -Raw)" }
    if (-not (Test-Path -LiteralPath "$root\ok.txt")) { Fail "$what, the window didn't build" }
    if (Test-Path -LiteralPath "$root\.update-backup") { Fail "$what, the backup of a finished update stayed" }
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
"app ok"
