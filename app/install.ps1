# Downloads the Whispering Tiger engine (v1.3.20.1, ~5 GB) and unpacks it into the app's folder. Run by CaptionsApp.ps1
# on first start; safe to run again (resumes the download, never overwrites this app's own files).
# Models download on each mode's first Start (captions.ps1).
# URLs and SHA256: the engine's .current_platform.yaml (+ s3.libs.space, where the engine fetches its models); the zip unpacks flat (audioWhisper\, toolchain\, ...) like
# the official UI does it (whispering-ui UpdateUtility/UpdateCheck.go).
$ErrorActionPreference = "Stop"
$top = Split-Path $PSScriptRoot  # the app's folder: this script is in its app\
trap { Set-Content -LiteralPath "$top\.install-error.txt" -Value "$_"; exit 1 }  # shown by the app
Set-Location -LiteralPath $top
if (Test-Path -LiteralPath "audioWhisper\audioWhisper.exe") { return }
Remove-Item -LiteralPath ".install-step" -ErrorAction SilentlyContinue  # left by a run that a restart cut off
$zip = "engine-download.zip"
$sha256 = "A0BBD5DD59B5CC1014F473580F07EEBEFFC44309A343EADFD7A5C0935FC25545"
$urls = "https://eu2.contabostorage.com/bf1a89517e2643359087e5d8219c0c67:projects/whispering/whispering-tiger1.3.20.1_win.zip",
        "https://usc1.contabostorage.com/8fcf133c506f4e688c7ab9ad537b5c18:projects/whispering/whispering-tiger1.3.20.1_win.zip",
        "https://s3.libs.space:9000/projects/whispering/whispering-tiger1.3.20.1_win.zip"  # the engine author's own server, last: port 9000 is blocked on some networks
$curl, $tar = "$env:SystemRoot\System32\curl.exe", "$env:SystemRoot\System32\tar.exe"  # Windows' own: Git's tar can't unzip
$downloaded, $blocked = $false, $true
foreach ($url in $urls) {
    # retry here, not with curl's --retry: that throws away what the run downloaded, a re-run resumes it (-C -)
    for ($try = 1; $try -le 5; $try++) {
        & $curl -L --fail --connect-timeout 30 --speed-limit 1024 --speed-time 60 -C - -s -o $zip $url  # ends on a dead connection (no answer in 30 s, <1 KB/s for 60 s)
        if ($LASTEXITCODE -notin 18, 28, 56) { break }  # partial file, stalled, connection reset: try again
        Start-Sleep 5
    }
    if ($LASTEXITCODE -eq 0) { $downloaded = $true; break }
    if ($LASTEXITCODE -ne 6) { $blocked = $false }  # 6 = name lookup failed
}
# DNS filters (Cloudflare 1.1.1.1 for Families / WARP, some NextDNS or Pi-hole lists) answer 0.0.0.0 for the mirrors' host
$blocked = $blocked -and -not $downloaded -and (& $curl -s -o NUL -w "%{http_code}" --max-time 10 https://github.com) -ne "000"
# curl also fails when the zip was already complete (nothing left to resume), so the hash decides
Set-Content -LiteralPath ".install-step" -Value "verify"
$hash = if (Test-Path -LiteralPath $zip) { (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash }
if ($hash -ne $sha256) {
    Remove-Item -LiteralPath ".install-step"
    if ($blocked) { throw "Your DNS filter blocks contabostorage.com, where the engine is hosted (Cloudflare WARP / 1.1.1.1 for Families, NextDNS, Pi-hole or antivirus web protection). Allow that site or pause the filter while installing." }
    if (-not $downloaded) { throw "Download failed from all 3 mirrors. Check the internet connection." }  # keep the part to resume
    Remove-Item -LiteralPath $zip
    throw "The download was damaged and has been deleted."
}
Set-Content -LiteralPath ".install-step" -Value "unpack"
if (Test-Path -LiteralPath ".install") { Remove-Item -LiteralPath ".install" -Recurse -Force }
$tmp = New-Item -ItemType Directory ".install"
& $tar -xf $zip -C $tmp.FullName
if ($LASTEXITCODE -ne 0) { Expand-Archive -LiteralPath $zip -DestinationPath $tmp.FullName -Force }
$exe = Get-ChildItem -LiteralPath $tmp.FullName -Recurse -Filter "audioWhisper.exe" | Select-Object -First 1
if (-not $exe) { throw "The download has no audioWhisper.exe; delete $zip and press Install again." }
# Keep this app's own files (Plugins\, Profiles\, ...) where names clash.
# audioWhisper\ last: its .exe is what counts as installed, so a move that fails before it (toolchain\ locked by
# antivirus) runs again on the next Install instead of leaving the engine without ffmpeg
Get-ChildItem -LiteralPath $exe.Directory.Parent.FullName -Force | Where-Object { -not (Test-Path -LiteralPath $_.Name) } |
    Sort-Object { $_.Name -eq $exe.Directory.Name } | Move-Item -Destination $top
Remove-Item -LiteralPath ".install", $zip, ".install-step" -Recurse -Force
