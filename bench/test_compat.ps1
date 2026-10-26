# Offline check: the app finds the right NVIDIA GPU, picks a mode for it (CPU without one), maps default browsers,
# and picks the captions language from Windows'. Loads those functions from CaptionsApp.ps1 with nvidia-smi and the registry faked (nothing else runs).
# Also captions.ps1's device lookup and how it points the profile at the audio.
# usage: powershell -File bench/test_compat.ps1
$ast = [Management.Automation.Language.Parser]::ParseFile("$PSScriptRoot\..\CaptionsApp.ps1", [ref]$null, [ref]$null)
foreach ($name in "Get-Gpu", "Gpu-Problem", "Pick-Mode", "Default-Browser", "Caption-Language") {
    $fn = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true)
    Invoke-Expression $fn.Extent.Text
}
foreach ($s in $ast.FindAll({ param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and
                                     "$($n.Left)" -in '$languages', '$modes', '$autoPercent', '$headroomGB' }, $true)) {
    Set-Variable "$($s.Left)".TrimStart('$') (Invoke-Expression $s.Right.Extent.Text)
}
function Fail($what) { "FAIL: $what"; exit 1 }

# two GPUs: the bigger one, whatever order nvidia-smi lists them in
$script:smi = "NVIDIA GeForce GTX 1050, 2048, 100, 560.94, 6.1", "NVIDIA GeForce RTX 3060, 12288, 1024, 560.94, 8.6"
function nvidia-smi { $global:LASTEXITCODE = 0; $script:smi }
$g = Get-Gpu
if ($g.Name -ne "NVIDIA GeForce RTX 3060" -or $g.Total -ne 12 -or $g.Free -ne 11 -or $g.Cap -ne 8.6 -or $g.Driver -ne 560.94) { Fail "two GPUs: $($g | Out-String)" }
$script:smi = "NVIDIA GeForce RTX 4060 Laptop GPU, 8188, 400, 581.15, 8.9"
if ((Get-Gpu).Name -ne "NVIDIA GeForce RTX 4060 Laptop GPU") { Fail "one GPU" }
$script:smi = $null
if ($null -ne (Get-Gpu)) { Fail "no GPU" }
"gpu ok"

# modes: the best that fits; CPU without a usable NVIDIA GPU or when not even Lite fits
$script:ceiling = $null
$gpu8 = @{ Name = "RTX 4060"; Total = 8; Free = 7.6; Driver = 581; Cap = 8.9 }
foreach ($case in @(@("Auto", $gpu8, "Balanced"), @("100", $gpu8, "Accurate"), @("25", $gpu8, "CPU"),
                    @("Auto", @{ Name = "GTX 1650"; Total = 4; Free = 3.5; Driver = 581; Cap = 7.5 }, "Lite"),
                    @("Auto", @{ Name = "RTX 4060"; Total = 8; Free = 1; Driver = 581; Cap = 8.9 }, "CPU"), @("Auto", $null, "CPU"))) {
    $got = Pick-Mode $case[0] $case[1]
    if ($got -ne $case[2]) { Fail "mode for $($case[0]) on $($case[1].Name): $got" }
}
foreach ($g in $null, @{ Name = "GTX 960"; Total = 4; Free = 4; Driver = 581; Cap = 5.2 }, @{ Name = "GTX 1060"; Total = 6; Free = 6; Driver = 472; Cap = 6.1 }) {
    if ((Gpu-Problem $g) -notmatch "processor") { Fail "problem for $($g.Name): $(Gpu-Problem $g)" }
}
if (Gpu-Problem $gpu8) { Fail "problem for a good GPU" }
"modes ok"

$script:progId = $null
function Get-ItemProperty { [pscustomobject]@{ ProgId = $script:progId } }
foreach ($case in @(@($null, "msedge"), @("MSEdgeHTM", "msedge"), @("ChromeHTML", "chrome"), @("FirefoxURL-308046B0AF4A39CB", "firefox"),
                    @("BraveHTML", "brave"), @("OperaStable", "opera"), @("Opera GXStable", "opera"), @("VivaldiHTM.ABC", "vivaldi"),
                    @("SomeOtherBrowserURL", "system"))) {
    $script:progId = $case[0]
    if ((Default-Browser) -ne $case[1]) { Fail "browser $($case[0]): $(Default-Browser)" }
}
"browsers ok"

$script:captionLang = "Auto"
foreach ($case in @(@("zh-TW", "Chinese (Traditional)"), @("zh-HK", "Chinese (Traditional)"), @("zh-CN", "Chinese"),
                    @("vi-VN", "Vietnamese"), @("nl-NL", "Dutch"), @("ja-JP", "Japanese"), @("sv-SE", "English"))) {
    $got = & { [Threading.Thread]::CurrentThread.CurrentUICulture = $case[0]; Caption-Language }
    if ($got -ne $case[1]) { Fail "captions language for $($case[0]): $got" }
}
"languages ok"

# captions.ps1's lookup of the default speakers (0) and microphone (1) compiles, and answers a name or null, never
# throws: CI has no audio devices, a PC has both
$cap = [Management.Automation.Language.Parser]::ParseFile("$PSScriptRoot\..\captions.ps1", [ref]$null, [ref]$null)
$add = $cap.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] -and "$($n.GetCommandName())" -eq "Add-Type" }, $true) |
    Where-Object { "$_" -like "*-Name Speakers*" }
Invoke-Expression $add.Extent.Text
foreach ($flow in 0, 1) {
    $n = [W.Speakers]::Name($flow); $r = [W.Speakers]::Rate($flow)
    if (($null -ne $n -and $n -isnot [string]) -or $r -lt 0) { Fail "device $flow`: $n @ $r" }
}
"devices ok"

# captions.ps1 points the profile at the audio: only those four lines change, and a device name stays one quoted value
$fn = $cap.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq "Write-Profile" }, $true)
Invoke-Expression $fn.Extent.Text
$yaml = Join-Path ([IO.Path]::GetTempPath()) "test_compat_profile.yaml"
$before = "audio_api: WASAPI", "audio_input_device: ''", "audio_input_process: brave.exe", "phrase_time_limit: 30",
          "plugin_settings:", "  audio_input_device: keep", "whisper_cpu_threads: 0"
[IO.File]::WriteAllLines($yaml, [string[]]$before)
Write-Profile $yaml "" "Bob's Mic: USB [Loopback]" 10 8
$after = [IO.File]::ReadAllLines($yaml)
$want = "audio_api: WASAPI", "audio_input_device: 'Bob''s Mic: USB [Loopback]'", "audio_input_process: ''", "phrase_time_limit: 10",
        "plugin_settings:", "  audio_input_device: keep", "whisper_cpu_threads: 8"
if (($after -join "`n") -cne ($want -join "`n")) { Fail "profile for a device:`n$($after -join "`n")" }
Write-Profile $yaml "vrchat.exe" "" 30 0
$after = [IO.File]::ReadAllLines($yaml)
if ($after[1] -cne "audio_input_device: ''" -or $after[2] -cne "audio_input_process: 'vrchat.exe'" -or $after[3] -cne "phrase_time_limit: 30") {
    Fail "profile for an app:`n$($after -join "`n")"
}
Remove-Item -LiteralPath $yaml
"profile ok"
