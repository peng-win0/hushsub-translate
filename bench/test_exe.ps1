# Offline check of Hushsub Translate.exe: CaptionsApp.ps1's Build-Exe compiles launcher.cs in a temp folder, rebuilds
# it (also while the old .exe runs) only when launcher.cs's version changes, and the .exe runs the CaptionsApp.ps1 next
# to it like powershell.exe would: STA thread, execution policy Bypass, its own folder. A stub script stands in for the
# app (no window). Never touches the real app folder or shortcuts.
# usage: powershell -File bench/test_exe.ps1
$app = Resolve-Path "$PSScriptRoot\.."
$root = Join-Path ([IO.Path]::GetTempPath()) "pc-test-exe-$PID"
$null = New-Item -ItemType Directory "$root\app" -Force
Copy-Item -LiteralPath "$app\app\launcher.cs", "$app\app\icon.ico" -Destination "$root\app"
$ast = [Management.Automation.Language.Parser]::ParseFile("$app\CaptionsApp.ps1", [ref]$null, [ref]$null)
$fn = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq "Build-Exe" }, $true)
Invoke-Expression ($fn.Extent.Text -replace '\$PSScriptRoot', '$root')
$exePath, $appIcon = "$root\Hushsub Translate.exe", "$root\app\icon.ico"
function Fail($what) { "FAIL: $what"; Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue; exit 1 }
function Version { "$([Reflection.AssemblyName]::GetAssemblyName($exePath).Version)" }

Build-Exe
if (-not (Test-Path -LiteralPath $exePath)) { Fail "not built" }
$built = (Get-Item -LiteralPath $exePath).LastWriteTimeUtc
Build-Exe
if ((Get-Item -LiteralPath $exePath).LastWriteTimeUtc -ne $built) { Fail "rebuilt without a change" }
"build ok"

# the stub app: writes what it sees, waits for a file (so the .exe is running during the rebuild below)
Set-Content -LiteralPath "$root\CaptionsApp.ps1" -Value @'
"$PSScriptRoot|$((Get-Location).Path)|$(Get-ExecutionPolicy)|$([Threading.Thread]::CurrentThread.GetApartmentState())|$((Get-Process -Id $PID).ProcessName)" | Set-Content "$PSScriptRoot\probe.txt"
Write-Host "dropped"; Write-Error "dropped"
while (-not (Test-Path "$PSScriptRoot\go")) { Start-Sleep -Milliseconds 100 }
'@
$p = Start-Process -FilePath $exePath -PassThru
for ($i = 0; $i -lt 100 -and -not (Test-Path "$root\probe.txt"); $i++) { Start-Sleep -Milliseconds 100 }
$want = "$root|$root|Bypass|STA|Hushsub Translate"
if ("$(Get-Content -LiteralPath "$root\probe.txt" -ErrorAction SilentlyContinue)" -ne $want) { Fail "runs the script: $(Get-Content "$root\probe.txt")" }
"runs ok"

(Get-Content -LiteralPath "$root\app\launcher.cs") -replace 'AssemblyVersion\("[\d.]+"\)', 'AssemblyVersion("9.9.9.9")' | Set-Content "$root\app\launcher.cs"
Build-Exe  # while the old one runs
if ((Version) -ne "9.9.9.9") { Fail "rebuild while running: $(Version)" }
$null = New-Item -ItemType File "$root\go"
if (-not $p.WaitForExit(10000)) { Fail "did not exit" }
if ($p.ExitCode -ne 0) { Fail "exit code $($p.ExitCode)" }
Build-Exe  # now the old one is gone
if (Test-Path -LiteralPath "$root\Hushsub Translate.old.exe") { Fail "old .exe left" }
"rebuild ok"
Remove-Item -LiteralPath $root -Recurse -Force
