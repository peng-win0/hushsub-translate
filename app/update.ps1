# Updates this app (scripts, plugin, profiles) to its newest GitHub release. Run hidden by CaptionsApp.ps1:
# - always: writes the newest released version to .update-latest (the app compares it with version.txt)
# - with -Apply, if that is newer and no caption engine runs: downloads the release, checks it, backs up the files
#   it replaces to .update-backup\ and copies the new ones in (all restored if one fails), then writes .update-done.
#   version.txt goes last, so an update that didn't finish is tried again. The download and temp folder never stay;
#   the backup stays only after a failure (it may hold the only copy of the user's words).
# Never touches the engine, models or settings (they aren't in a release). glossary.txt and fake-lines.txt
# keep the user's lines: only lines for new words are added. A git checkout (developer copy) is never changed.
# -Zip <file> -Version <x.y.z> installs a local release zip instead (bench/test_update.ps1).
param([switch]$Apply, [string]$Zip, [string]$Version)
$ErrorActionPreference = "Stop"
$top = Split-Path $PSScriptRoot  # the app's folder: this script is in its app\
trap {  # shown by the app
    Set-Content -LiteralPath "$top\.update-error.txt" -Value "$_"
    Remove-Item -LiteralPath "$top\.update", "$top\.update.zip" -Recurse -Force -ErrorAction SilentlyContinue
    exit 1
}
Set-Location -LiteralPath $top
Remove-Item -LiteralPath ".update-error.txt" -ErrorAction SilentlyContinue
$repo = "peng-win0/hushsub-translate"
$curl, $tar = "$env:SystemRoot\System32\curl.exe", "$env:SystemRoot\System32\tar.exe"  # Windows' own: Git's tar can't unzip
$current = try { [version]"$(Get-Content -LiteralPath 'version.txt')".Trim() } catch { [version]"0.0.0" }

if (-not $Zip) {
    # a timeout, DNS miss, 429 or 5xx is retried at once, not reported as "No connection" until tomorrow's check.
    # A reset isn't: --retry-all-errors needs curl 7.71, and an unpatched Windows 10 has 7.55 (it would fail every check)
    $code = & $curl -sL --max-time 20 --retry 2 --retry-delay 2 --retry-max-time 30 -o ".update-check.json" -w "%{http_code}" -H "Accept: application/vnd.github+json" "https://api.github.com/repos/$repo/releases/latest"
    $release = if ($code -eq "200") { Get-Content -LiteralPath ".update-check.json" -Raw | ConvertFrom-Json }
    Remove-Item -LiteralPath ".update-check.json" -ErrorAction SilentlyContinue
    if ($code -eq "000") { throw "No connection to GitHub." }
    if ($code -eq "404") { throw "No released version found." }  # also while the repository is private
    if ($code -ne "200") { throw "GitHub answered $code; trying again later." }
    if ("$($release.tag_name)" -notmatch '^v?(\d+\.\d+\.\d+)$') { throw "Unexpected release name: $($release.tag_name)" }
    $Version = $Matches[1]
    Set-Content -LiteralPath ".update-latest" -Value $Version
}
if (-not $Apply -or [version]$Version -le $current) { return }
if (Test-Path -LiteralPath ".git") { throw "This folder is a git checkout: update it with git pull." }
if (Get-Process audioWhisper -ErrorAction SilentlyContinue) { return }  # the app tries again once captions are off

if (-not $Zip) {
    $Zip = ".update.zip"
    # Start waits for this: a retry starts only in the first 2 min, so the worst case is ~7 min (one try was 5)
    & $curl -sL --fail --connect-timeout 30 --max-time 300 --retry 2 --retry-delay 3 --retry-max-time 120 -o $Zip "https://github.com/$repo/archive/refs/tags/$($release.tag_name).zip"
    if ($LASTEXITCODE) { throw "Download failed (curl $LASTEXITCODE)." }
}
if (Test-Path -LiteralPath ".update") { Remove-Item -LiteralPath ".update" -Recurse -Force }
$tmp = New-Item -ItemType Directory ".update"
& $tar -xf $Zip -C $tmp.FullName
if ($LASTEXITCODE) { throw "The download is damaged." }
$root = @(Get-ChildItem -LiteralPath $tmp.FullName -Directory)
if ($root.Count -ne 1 -or "$(Get-Content -LiteralPath "$($root[0].FullName)\version.txt" -ErrorAction SilentlyContinue)".Trim() -ne $Version) {
    throw "The download isn't version $Version of this app."
}
$root = $root[0].FullName
foreach ($ps1 in Get-ChildItem -LiteralPath $root -Recurse -Filter "*.ps1") {  # never install a script that can't run
    $errors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($ps1.FullName, [ref]$null, [ref]$errors)
    if ($errors) { throw "The download has a broken script ($($ps1.Name))." }
}

$merge = "app\glossary.txt", "app\fake-lines.txt"  # the user may have added lines
$files = @(Get-ChildItem -LiteralPath $root -Recurse -File | ForEach-Object { $_.FullName.Substring($root.Length + 1) } | Where-Object { $_ -ne "version.txt" }) + "version.txt"
if (Test-Path -LiteralPath ".update-backup") { Remove-Item -LiteralPath ".update-backup" -Recurse -Force }
$done = @()
try {
    foreach ($f in $files) {
        $dir = Split-Path $f
        if (Test-Path -LiteralPath $f) {
            [void](New-Item -ItemType Directory -Force (Join-Path ".update-backup" $dir))
            Copy-Item -LiteralPath $f -Destination ".update-backup\$f"
        }
        $done += $f
        if ($merge -contains $f -and (Test-Path -LiteralPath $f)) {
            # add lines whose word (left of " = ", or the whole line) the user's file doesn't have; skip comments
            $key = { param($l) ($l -split '=', 2)[0].Trim() }
            $path = (Resolve-Path -LiteralPath $f).Path
            # saved by hand as ANSI or Shift-JIS: read in the PC's code page, so the rewrite below (UTF-8) keeps its words
            $mine = @(try { [IO.File]::ReadAllLines($path, (New-Object Text.UTF8Encoding $false, $true)) } catch [Text.DecoderFallbackException] { [IO.File]::ReadAllLines($path, [Text.Encoding]::Default) })
            $have = @{}; foreach ($l in $mine) { $have[(& $key $l)] = 1 }
            $new = @([IO.File]::ReadAllLines("$root\$f") | Where-Object { $_.Trim() -and -not $_.TrimStart().StartsWith("#") -and -not $have.ContainsKey((& $key $_)) })
            if ($new) { [IO.File]::WriteAllLines($path, [string[]]($mine + $new)) }  # UTF-8 without BOM
        } else {
            if ($dir) { [void](New-Item -ItemType Directory -Force $dir) }
            Copy-Item -LiteralPath "$root\$f" -Destination $f -Force
        }
    }
} catch {
    $why = $_
    foreach ($f in $done) {  # each on its own: a file in use mustn't stop the rest (its copy failed, so it's unchanged)
        try {
            if (Test-Path -LiteralPath ".update-backup\$f") { Copy-Item -LiteralPath ".update-backup\$f" -Destination $f -Force }
            else { Remove-Item -LiteralPath $f }
        } catch {}
    }
    throw "Update to $Version failed, nothing was changed: $why"
}
Remove-Item -LiteralPath ".update", ".update-backup" -Recurse -Force -ErrorAction SilentlyContinue
if ($Zip -eq ".update.zip") { Remove-Item -LiteralPath $Zip }
Set-Content -LiteralPath ".update-done" -Value $Version
