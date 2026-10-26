# Offline check of update.ps1: installs release zips built from this folder over a fake older copy in %TEMP%.
# Run with no caption engine running: powershell -NoProfile -ExecutionPolicy Bypass -File bench\test_update.ps1
$ErrorActionPreference = "Stop"
if (Get-Process audioWhisper -ErrorAction SilentlyContinue) { "not run: stop captions first (update.ps1 waits while an engine runs)"; exit 2 }
$src = Split-Path $PSScriptRoot
$t = Join-Path ([IO.Path]::GetTempPath()) "wt-update-test"
function Check($ok, $what) { if (-not $ok) { throw "FAIL: $what" }; "ok: $what" }
function Lines($f) { [IO.File]::ReadAllLines($f) }
function Release($ver, $broken) {
    # a GitHub-style release zip: one top folder holding the app
    $rel = "$t\rel-$ver\hushsub-translate-$ver"
    [void](New-Item -ItemType Directory -Force "$rel\Profiles")
    foreach ($f in "CaptionsApp.ps1", "captions.ps1", "update.ps1", "Profiles\balanced.yaml") { Copy-Item "$src\$f" "$rel\$f" }
    [IO.File]::WriteAllLines("$rel\glossary.txt", [string[]]("# a new comment", "MyWord = Different", "NewWord = New"))
    [IO.File]::WriteAllLines("$rel\version.txt", [string[]]$ver)
    if ($broken) { Set-Content "$rel\captions.ps1" "function {" }
    & "$env:SystemRoot\System32\tar.exe" -a -cf "$t\$ver.zip" -C "$t\rel-$ver" "hushsub-translate-$ver"
    "$t\$ver.zip"
}
function Run($zip, $ver) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File "$t\app\update.ps1" -Apply -Zip $zip -Version $ver
    "$(Get-Content "$t\app\.update-error.txt" -ErrorAction SilentlyContinue)"
}

if (Test-Path $t) { Remove-Item $t -Recurse -Force }
[void](New-Item -ItemType Directory "$t\app")
Copy-Item "$src\update.ps1" "$t\app\"
Set-Content "$t\app\CaptionsApp.ps1" "# old"
[IO.File]::WriteAllLines("$t\app\glossary.txt", [string[]]("MyWord = Mine"))
[IO.File]::WriteAllLines("$t\app\version.txt", [string[]]"1.0.0")

$err = Run (Release "2.0.0" $true) "2.0.0"
Check ($err -like "*broken script*") "a release with a broken script is refused ($err)"
Check ((Get-Content "$t\app\CaptionsApp.ps1") -eq "# old") "...and nothing changed"
Check (-not (Test-Path "$t\app\.update")) "...and its temp folder doesn't stay"
$lock = [IO.File]::Open("$t\app\update.ps1", "Open", "Read", "Read")  # held open, as a window holds its icon; after glossary.txt
$err = Run (Release "2.0.0" $false) "2.0.0"
$lock.Close()
Check ($err -like "*nothing was changed*" -and "$(Get-Content "$t\app\version.txt")" -eq "1.0.0") "a file in use: nothing changed ($err)"
Check ("$(Lines "$t\app\glossary.txt")" -eq "MyWord = Mine") "...and the user's words are restored"
$err = Run (Release "2.0.0" $false) "2.1.0"
Check ($err -like "*isn't version 2.1.0*") "a zip of another version is refused"

$err = Run (Release "2.0.0" $false) "2.0.0"
Check (-not $err) "a good release installs ($err)"
Check ("$(Get-Content "$t\app\version.txt")" -eq "2.0.0" -and "$(Get-Content "$t\app\.update-done")" -eq "2.0.0") "version.txt and .update-done say 2.0.0"
Check ((Get-FileHash "$t\app\CaptionsApp.ps1").Hash -eq (Get-FileHash "$src\CaptionsApp.ps1").Hash) "CaptionsApp.ps1 replaced"
Check (Test-Path "$t\app\Profiles\balanced.yaml") "new folders created"
Check (-not (Test-Path "$t\app\.update-backup")) "the backup doesn't stay after a good update"
$g = Lines "$t\app\glossary.txt"
Check ("$g" -eq "MyWord = Mine NewWord = New") "glossary keeps the user's line and adds only new words ($g)"
Check (-not (Test-Path "$t\app\.update")) "temp folder cleaned"

$err = Run (Release "2.0.0" $false) "2.0.0"
Check ("$(Lines "$t\app\glossary.txt")" -eq "MyWord = Mine NewWord = New") "the same version again changes nothing"
Remove-Item $t -Recurse -Force
"ALL PASSED"
