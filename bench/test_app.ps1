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
    Copy-Item -LiteralPath ("CaptionsApp.ps1", "app.ico", "version.txt", "launcher.cs", "glossary.txt", "fake-lines.txt", "README.md",
                            "LICENSE", "Profiles", "Plugins", "fonts" | ForEach-Object { "$app\$_" }) -Destination $root -Recurse
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
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
"app ok"
