# Offline check of opening the app inside the downloaded ZIP (Explorer runs it from a temp copy): it installs that
# copy in %LOCALAPPDATA%\Programs without asking and opens it there with Install started, the next time opens the installed one, and an
# incomplete copy only says to extract the ZIP. Runs CaptionsApp.ps1's own block with a fake LOCALAPPDATA, dialog and
# Start-Process: never installs or opens anything for real.
# usage: powershell -File bench/test_zip.ps1
$app = Resolve-Path "$PSScriptRoot\.."
$t = Join-Path ([IO.Path]::GetTempPath()) "pc-test-zip-$PID"
$src = "$t\Temp1_hushsub-translate-main.zip\hushsub-translate-main"
function Fail($what) { "FAIL: $what"; Set-Location $app; Remove-Item -LiteralPath $t -Recurse -Force -ErrorAction SilentlyContinue; exit 1 }
$null = New-Item -ItemType Directory $src -Force
Copy-Item -LiteralPath "$app\CaptionsApp.ps1", "$app\app", "$app\Plugins" -Destination $src -Recurse
$ast = [Management.Automation.Language.Parser]::ParseFile("$app\CaptionsApp.ps1", [ref]$null, [ref]$null)
$block = $ast.Find({ param($n) $n -is [Management.Automation.Language.IfStatementAst] -and $n.Clauses[0].Item1.Extent.Text -like '*GetTempPath*' }, $false)
if (-not $block) { Fail "CaptionsApp.ps1 changed, update this test: no ZIP check" }
class Dialog {
    static [string[]] $Asked = @()
    static [string] Show([string]$text, [string]$title, [string]$buttons) { [Dialog]::Asked += $text; return "Yes" }
    static [string] Show([string]$text, [string]$title) { [Dialog]::Asked += $text; return "OK" }
}
$script:launched = $null
function Start-Process { $script:launched = "$args" }
Invoke-Expression ("function Open-Zip {`n" + ($block.Extent.Text -replace '\$PSScriptRoot', '$src' -replace '\[Windows\.MessageBox\]', '[Dialog]') + "`n}")
$env:LOCALAPPDATA = "$t\local"
$target = "$t\local\Programs\Hushsub Translate"
Set-Location -LiteralPath $src

Open-Zip
if ([Dialog]::Asked.Count) { Fail "asked: $([Dialog]::Asked)" }
if (@(Test-Path -LiteralPath "$target\CaptionsApp.ps1", "$target\app\Profiles\balanced.yaml", "$target\Plugins\subtitle_display_plugin.py") -contains $false) { Fail "not copied" }
if (-not "$script:launched".Contains("$target\CaptionsApp.ps1")) { Fail "opened: $script:launched" }
if (-not (Test-Path -LiteralPath "$target\.install-now")) { Fail "Install not started with the same double-click" }
"install ok"

[Dialog]::Asked = @(); $script:launched = $null
$null = New-Item -ItemType File "$target\Hushsub Translate.exe"
Open-Zip
if ([Dialog]::Asked.Count) { Fail "asked again" }
if ("$script:launched" -notlike "*$target\Hushsub Translate.exe*") { Fail "opened: $script:launched" }
Remove-Item -LiteralPath "$target\.install-now"
"open installed ok"

[Dialog]::Asked = @()
Remove-Item -LiteralPath $target, "$src\app\fonts" -Recurse -Force
Open-Zip
if ([Dialog]::Asked.Count -ne 1 -or [Dialog]::Asked[0] -notlike "Extract the ZIP first*") { Fail "incomplete copy: $([Dialog]::Asked)" }
if (Test-Path -LiteralPath $target) { Fail "installed an incomplete copy" }
"incomplete ok"
Set-Location $app
Remove-Item -LiteralPath $t -Recurse -Force
"zip ok"
