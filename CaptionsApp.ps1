# Hushsub Translate: the app window. The first time, Install downloads the engine (install.ps1); then pick how much of
# the GPU captions may use (Auto is recommended) and press Start. The budget picks the best mode that fits this GPU
# (any size) and its free memory. Auto also steps down a mode while running if the GPU fills up (another app needs it)
# or translates too slowly. The engine runs in captions.ps1 (waits for the browser, restarts after a crash) in a
# hidden console window; its text shows in this window (Show log). Stop closes that console: the same graceful stop as
# its X. Never force-kills.
# The window is WPF (part of Windows) styled after Google's apps (Material 3): their colors, shapes and controls, light/dark.
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Drawing
trap { [void][Windows.MessageBox]::Show("Hushsub Translate failed to start:`n$_", "Hushsub Translate"); break }  # no console to show it
Add-Type -Name Win -Namespace W -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
[DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint msg, IntPtr w, IntPtr l);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(IntPtr h, System.Text.StringBuilder s, int n);
[DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(IntPtr h, int attr, ref int value, int size);
[DllImport("kernel32.dll")] public static extern IntPtr GetCurrentThread();
[DllImport("kernel32.dll")] public static extern bool SetThreadPriority(IntPtr t, int priority);
'@
Set-Location -LiteralPath $PSScriptRoot
if ($PSScriptRoot -like "$([IO.Path]::GetTempPath())*") {  # opened inside the ZIP: Explorer runs it from a temp copy
    # install that copy where apps go for one user (no administrator), or open the one already there (it updates itself).
    # No question: the double-click was the choice, and Install still warns when the disk is short of the ~20 GB.
    $target = Join-Path $env:LOCALAPPDATA "Programs\Hushsub Translate"
    if (-not (Test-Path -LiteralPath "$target\CaptionsApp.ps1")) {
        if (@(Test-Path -LiteralPath "app\captions.ps1", "app\install.ps1", "app\update.ps1", "app\launcher.cs", "app\Profiles", "app\fonts", "Plugins") -contains $false) {
            [void][Windows.MessageBox]::Show("Extract the ZIP first: right-click it, Extract all, then open Hushsub Translate.bat in the extracted folder.", "Hushsub Translate")
            return
        }
        $null = New-Item -ItemType Directory $target -Force
        Get-ChildItem -LiteralPath $PSScriptRoot -Force | Copy-Item -Destination $target -Recurse -Force
        $null = New-Item -ItemType File "$target\.install-now" -Force  # the double-click was the Install press too: one click to captions
    }
    $exe = "$target\Hushsub Translate.exe"
    if (Test-Path -LiteralPath $exe) { Start-Process -FilePath $exe }
    else { Start-Process "$env:WINDIR\System32\conhost.exe" -ArgumentList "--headless `"$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe`" -NoProfile -ExecutionPolicy Bypass -File `"$target\CaptionsApp.ps1`"" }
    return
}
Remove-Item -LiteralPath "Live Captions.bat", "Private Captions.bat" -ErrorAction SilentlyContinue  # the launcher's names before 1.3.0 and 1.5.0 (updates never remove files)
# 1.6.0 moved this app's own files into app\, so the folder shows only what a user opens. An older updater installed
# app\ beside the old files: the user's words move in, the old copies go (app.ico: the icon's name before 1.5.2).
if (Test-Path -LiteralPath "app\captions.ps1") {
    foreach ($f in "glossary.txt", "fake-lines.txt") { if (Test-Path -LiteralPath $f) { Move-Item -LiteralPath $f "app\$f" -Force -ErrorAction SilentlyContinue } }
    Remove-Item -LiteralPath "captions.ps1", "install.ps1", "update.ps1", "launcher.cs", "icon.ico", "app.ico", "Profiles", "fonts" -Recurse -Force -ErrorAction SilentlyContinue
}
# One window, like any app: starting it again brings the open window to the front (two windows would fight over one engine)
$instance = New-Object Threading.Mutex($false, "Local\PrivateCaptionsApp")
try { $first = $instance.WaitOne(0) } catch [Threading.AbandonedMutexException] { $first = $true }  # the last one crashed
if (-not $first) {
    $open = Get-Process "Hushsub Translate", "Private Captions", powershell -ErrorAction SilentlyContinue |
        Where-Object { $_.Id -ne $PID -and $_.MainWindowTitle -in "Hushsub Translate", "Private Captions" } | Select-Object -First 1  # the name before 1.5.0
    if ($open) { [void](New-Object -ComObject WScript.Shell).AppActivate($open.Id) }
    return
}

# Best first. GB = peak GPU memory measured with bench/bench.sh (RTX 4060 Laptop; times are English on screen).
# CPU: no NVIDIA card (AMD, Intel, none), or no room on it. Whisper large-v3-turbo can't keep up with live audio on a
# processor, Whisper small can (Ryzen 7 7840HS: English ~3 s, recognition errors 36% instead of 25%).
$modes = [ordered]@{
    Accurate = @{ Profile = "accurate"; GB = 6.2; Text = "~1.5 s, polished but skips more fast speech" }
    Balanced = @{ Profile = "balanced"; GB = 3.6; Text = "~0.7 s, good translation" }
    Fast     = @{ Profile = "fast";     GB = 3.0; Text = "~1 s, a second model for Japanese-English (NLLB: non-commercial use only)" }
    Lite     = @{ Profile = "lite";     GB = 2.3; Text = "~0.7 s, basic translation (NLLB: non-commercial use only)" }
    CPU      = @{ Profile = "cpu";      GB = 0;   Text = "~3 s, misses more words (NLLB: non-commercial use only)" }
}
# Downloaded models (paths in .cache, wildcards include a model's partial download zip), and the file that marks each complete
$models = [ordered]@{
    "Speech recognition (Whisper)" = @{ Use = "graphics card modes"; Paths = "whisper\large-v3-turbo-ct2-fp16*"; Done = "whisper\large-v3-turbo-ct2-fp16\model.bin" }
    "Speech recognition, small"    = @{ Use = "CPU"; Paths = "whisper\small-ct2-fp16*"; Done = "whisper\small-ct2-fp16\model.bin" }
    "Language detection"           = @{ Use = "nothing (safe to remove)"; Paths = "lid"; Done = "lid\lid218e.bin" }
    "MiLMMT-4B translation"        = @{ Use = "Accurate"; Paths = "milmmt\MiLMMT-46-4B-v1.0*", "milmmt_ct2\MiLMMT-46-4B-v1.0*"; Done = "milmmt_ct2\MiLMMT-46-4B-v1.0\model.bin" }
    "MiLMMT-1B translation"        = @{ Use = "Balanced"; Paths = "milmmt\MiLMMT-46-1B-v1.0*", "milmmt_ct2\MiLMMT-46-1B-v1.0*"; Done = "milmmt_ct2\MiLMMT-46-1B-v1.0\model.bin" }
    "NLLB-600M translation"        = @{ Use = "Fast, Lite and CPU"; Paths = "nllb200_ct2"; Done = "nllb200_ct2\small\model.bin" }
    "LFM2-350M translation"        = @{ Use = "Fast"; Paths = "lfm2_enjp"; Done = "lfm2_enjp\LFM2-350M-ENJP-MT\model.safetensors" }
}
$budgets = "Auto", "25", "50", "75", "100"
$autoPercent = 50  # Auto = half the GPU (room left for other apps), Balanced at most: on real streams it beat Accurate
                   # (English 2.1 vs 2.7 s, Accurate left out ~40% of what was said; scored against clippers' subtitles)
$headroomGB = 0.3  # keep this much GPU memory free for the browser/desktop
$slowMs = 1200     # Auto steps down if a line takes longer than this to translate (RTX 4060: 0.2-0.6 s)
# process name = label; system = the default speakers, mic = the default microphone. Apps' process names: VRChat.exe, Discord.exe, Zoom.exe,
# ms-teams.exe (the new Teams), vlc.exe; opera.exe is Opera and Opera GX. A web app (YouTube installed from the
# browser) plays in its browser.
$browsers = [ordered]@{ auto = "Auto"; brave = "Brave"; chrome = "Chrome"; msedge = "Edge"; firefox = "Firefox"; opera = "Opera"; vivaldi = "Vivaldi"
                        vrchat = "VRChat"; discord = "Discord"; zoom = "Zoom"; "ms-teams" = "Teams"; vlc = "VLC"; system = "All PC sound"; mic = "Microphone" }
# name = Whisper code, NLLB code (the profile's src_lang/trg_lang; MiLMMT reads them too). Whisper, NLLB and MiLMMT know all.
# Listed English first, then by total speakers (Ethnologue 2025); Chinese (Traditional) = Chinese in Taiwan and Hong Kong's script.
$languages = [ordered]@{
    English = "en", "eng_Latn"; Chinese = "zh", "zho_Hans"; "Chinese (Traditional)" = "zh", "zho_Hant"; Spanish = "es", "spa_Latn"
    French = "fr", "fra_Latn"; Portuguese = "pt", "por_Latn"; Russian = "ru", "rus_Cyrl"; Indonesian = "id", "ind_Latn"
    German = "de", "deu_Latn"; Japanese = "ja", "jpn_Jpan"; Vietnamese = "vi", "vie_Latn"; Turkish = "tr", "tur_Latn"
    Korean = "ko", "kor_Hang"; Italian = "it", "ita_Latn"; Polish = "pl", "pol_Latn"; Dutch = "nl", "nld_Latn"
}
# Caption style: YouTube's caption options and choices, same names. Saved in app-settings.json; the caption window
# (the plugin) applies changes live. Colors and fonts are the same in the plugin.
$colors = [ordered]@{ White = "#FFFFFF"; Yellow = "#FFFF00"; Green = "#00FF00"; Cyan = "#00FFFF"; Blue = "#0000FF"
                      Magenta = "#FF00FF"; Red = "#FF0000"; Black = "#080808" }
$fonts = [ordered]@{ "Proportional Sans-Serif" = "Roboto, Arial"; "Monospaced Sans-Serif" = "Lucida Console, Consolas"
                     "Proportional Serif" = "Times New Roman"; "Monospaced Serif" = "Courier New"; Casual = "Comic Sans MS"
                     Cursive = "Monotype Corsiva, Segoe Script"; "Small Capitals" = "Arial" }
function Choices($list, $suffix) { $o = [ordered]@{}; foreach ($c in $list) { $o["$c"] = "$c$suffix" }; $o }
$styleOptions = [ordered]@{  # app-settings.json key = label, choices (key = shown), YouTube's default
    captionFont            = @{ Label = "Font family";          Items = Choices $fonts.Keys "";                     Default = "Proportional Sans-Serif" }
    captionColor           = @{ Label = "Font color";           Items = Choices $colors.Keys "";                    Default = "White" }
    captionSize            = @{ Label = "Font size";            Items = Choices (50, 75, 100, 150, 200, 300, 400) "%"; Default = "100" }
    captionBackgroundColor = @{ Label = "Background color";     Items = Choices $colors.Keys "";                    Default = "Black" }
    captionBackground      = @{ Label = "Background opacity";   Items = Choices (0, 25, 50, 75, 100) "%";           Default = "75" }
    captionWindowColor     = @{ Label = "Window color";         Items = Choices $colors.Keys "";                    Default = "Black" }
    captionWindow          = @{ Label = "Window opacity";       Items = Choices (0, 25, 50, 75, 100) "%";           Default = "0" }
    captionEdge            = @{ Label = "Character edge style"; Items = Choices ("None", "Drop Shadow", "Raised", "Depressed", "Outline") ""; Default = "None" }
    captionOpacity         = @{ Label = "Font opacity";         Items = Choices (25, 50, 75, 100) "%";              Default = "100" }
}
$settingsFile = Join-Path $PSScriptRoot "app-settings.json"
$saved = try { Get-Content -LiteralPath $settingsFile -Raw -ErrorAction Stop | ConvertFrom-Json } catch { $null }
function Saved($name, $valid, $default) { if ($saved -and @($valid) -contains "$($saved.$name)") { "$($saved.$name)" } else { $default } }
$budget = Saved budget $budgets "Auto"
$script:spoken = Saved spoken (@("Auto") + $languages.Keys) "Japanese"  # Auto: ~4 points more errors, ~0.4 s slower
$script:captionLang = Saved captions (@("Auto") + $languages.Keys) "Auto"
$script:style = @{}; foreach ($k in $styleOptions.Keys) { $script:style[$k] = Saved $k $styleOptions[$k].Items.Keys $styleOptions[$k].Default }
$version = "$(Get-Content -LiteralPath 'version.txt' -ErrorAction SilentlyContinue)".Trim()
$script:updater = $null   # update.ps1 process this window started
$script:updateApply = $false
$script:applied = $null   # the version auto-update already tried (once per version and session)
$updated = "$(Get-Content -LiteralPath '.update-done' -ErrorAction SilentlyContinue)".Trim()  # left by the update that reopened us
Remove-Item -LiteralPath ".update-done" -ErrorAction SilentlyContinue
if ($updated) { Remove-Item -LiteralPath ".update-backup" -Recurse -Force -ErrorAction SilentlyContinue }  # updaters before 1.5.2 left it
$script:conhost = $null   # the console window process we started
$script:running = if ($saved) { $saved.running } else { $null }  # mode of the captions now running
$script:restart = $false  # start again (new budget / step down) once the running engine has exited
$script:startKey = $null  # the settings the running captions started with: a paused engine resumes only with the same
$script:pausedAt = [DateTime]::Now
$script:ceiling = $null   # Auto: best mode allowed after a step-down (reset by Start and budget changes)
$script:note = ""         # why Auto stepped down
$script:full = 0          # checks in a row with the GPU memory full
function Engine-Installed { Test-Path -LiteralPath "audioWhisper\audioWhisper.exe" }
# install.ps1 process (one started before this window was last closed keeps downloading: adopt it). Only looked for
# until the engine is in place: the process list costs 0.2 s of every start.
$script:installer = if (-not (Engine-Installed)) { Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { "$($_.CommandLine)".Contains("$PSScriptRoot\app\install.ps1") } | ForEach-Object { Get-Process -Id $_.ProcessId -ErrorAction SilentlyContinue } | Select-Object -First 1 }

function Model-Items($name) { $models[$name].Paths | ForEach-Object { Get-Item -Path ".cache\$_" -Force -ErrorAction SilentlyContinue } }

function Stop-Install {
    # Pause the engine download: install.ps1 first (else it moves on to the next mirror), then its curl. Install resumes.
    $kids = Get-CimInstance Win32_Process -Filter "ParentProcessId=$($script:installer.Id)" -ErrorAction SilentlyContinue
    Stop-Process -Id $script:installer.Id -ErrorAction SilentlyContinue
    $kids | ForEach-Object { Stop-Process -Id $_.ProcessId -ErrorAction SilentlyContinue }
    $script:installer = $null
}
function Engine-Running { [bool](Get-Process audioWhisper -ErrorAction SilentlyContinue) }

function Console-Window {
    # captions.ps1's console window, or 0. The class check guards against a stale handle now used by another window.
    try { $h = [IntPtr][long](Get-Content -LiteralPath ".captions-window" -ErrorAction Stop) } catch { return [IntPtr]::Zero }
    $class = New-Object Text.StringBuilder 64
    if ([W.Win]::IsWindow($h) -and [W.Win]::GetClassName($h, $class, 64) -and "$class" -eq "ConsoleWindowClass") { return $h }
    [IntPtr]::Zero
}
function Ours-Open { ($script:conhost -and -not $script:conhost.HasExited) -or (Console-Window) -ne [IntPtr]::Zero }

function Get-Gpu {
    # The NVIDIA GPU with the most memory (with two, the one CUDA uses first: the fastest): memory in GB, driver
    # version, compute capability. $null without an NVIDIA GPU / driver.
    try {
        # nvidia-smi is in System32; older "Standard" driver packages put it in NVSMI only
        $smi = if (Get-Command nvidia-smi -ErrorAction SilentlyContinue) { "nvidia-smi" } else { "$env:ProgramFiles\NVIDIA Corporation\NVSMI\nvidia-smi.exe" }
        $q = "name,memory.total,memory.used,driver_version"
        $line = & $smi --query-gpu=$q,compute_cap --format=csv,noheader,nounits 2>$null
        if ($LASTEXITCODE) { $line = & $smi --query-gpu=$q --format=csv,noheader,nounits 2>$null }  # old drivers lack compute_cap
        $best = @($line) | ForEach-Object { ,($_ -split ',\s*') } | Sort-Object { -($_[1] -as [double]) } | Select-Object -First 1
        $name, $total, $used, $driver, $cap = $best
        if ([double]$total -gt 0) {
            return @{ Name = $name; Total = [double]$total / 1024; Free = ([double]$total - [double]$used) / 1024
                      Driver = [double]$driver; Cap = if ($cap -match '^\d+\.\d+$') { [double]$cap } else { $null } }
        }
    } catch {}
    $null
}

function Gpu-Problem($gpu) {
    # Why captions can't use the graphics card (they then run on the processor), or $null. The engine needs CUDA 12
    # (driver 528+); its CTranslate2 needs int8 support (compute capability 6.1+ = GTX 10 series or newer). AMD and
    # Intel GPUs have no CUDA.
    if (-not $gpu) { return "No NVIDIA graphics card: captions run on the processor (CPU mode)." }
    if ($gpu.Driver -lt 528) { return "Your NVIDIA driver ($($gpu.Driver)) is too old, so captions run on the processor. Update it from nvidia.com/drivers, then reopen this app." }
    if ($gpu.Cap -and $gpu.Cap -lt 6.1) { return "$($gpu.Name) is too old for captions (GTX 10 series or newer): they run on the processor." }
    $null
}

function Pick-Mode($b, $gpu, $extraFreeGB = 0) {
    # The best mode whose peak fits both the budget and the memory free now (+ what our running engine holds); CPU
    # when none does or there is no usable GPU ($null).
    if (-not $gpu) { return "CPU" }
    # Auto = half the GPU, but never less than Lite needs (small GPUs still get captions if they fit)
    $budgetGB = if ($b -eq "Auto") { [Math]::Max([double]$gpu.Total * $autoPercent / 100, [double]$modes["Lite"].GB) } else { $gpu.Total * [double]$b / 100 }
    $limit = [Math]::Min([double]$budgetGB, $gpu.Free + $extraFreeGB - $headroomGB)
    $allowed = -not $script:ceiling
    foreach ($m in $modes.Keys) {
        if ($m -eq $script:ceiling) { $allowed = $true }
        if ($allowed -and $modes[$m].GB -le $limit -and -not ($b -eq "Auto" -and $m -eq "Accurate")) { return $m }
    }
    "CPU"  # not even Lite fits
}

function Save-Settings {
    $all = @{ budget = $script:budget; browser = $script:browser; live = [bool]$live.IsChecked; running = $script:running
              showOriginal = [bool]$showOriginal.IsChecked; vrchatChatbox = [bool]$chatbox.IsChecked
              spoken = $script:spoken; captions = $script:captionLang; autoUpdate = [bool]$autoUpdate.IsChecked; theme = $script:look }
    foreach ($k in $script:style.Keys) { $all[$k] = $script:style[$k] }
    $all | ConvertTo-Json | Set-Content -LiteralPath $settingsFile
}

function Start-Update($apply) {
    # update.ps1 checks GitHub for a newer release; with -Apply it also installs it (then this window reopens itself)
    if ($script:managed -or ($script:updater -and -not $script:updater.HasExited)) { return }
    $script:updateApply = $apply
    $script:updater = Start-Process powershell -WindowStyle Hidden -PassThru `
        -ArgumentList ("-NoProfile -ExecutionPolicy Bypass -File `"$PSScriptRoot\app\update.ps1`"" + $(if ($apply) { " -Apply" }))
}

function Start-Captions($m) {
    $script:running = $m
    $script:full = 0  # a count left from the last run must not cut this one's three checks short
    Save-Settings
    # live line on/off (the engine's realtime drafts) and the languages; the engine isn't running here, so the profile is safe to edit
    $to = $languages[(Caption-Language)]
    # spoken Auto: Whisper detects each line's language and the plugin translates from it; src_lang only has to
    # differ from the captions' language, so the plugin loads its translator
    $from = if ($script:spoken -ne "Auto") { $languages[$script:spoken] } elseif ($to[1] -eq "jpn_Jpan") { "auto", "eng_Latn" } else { "auto", "jpn_Jpan" }
    $script:app = Resolve-Browser
    $script:startKey = Start-Key $script:app
    $yamlPath = "$PSScriptRoot\app\Profiles\$($modes[$m].Profile).yaml"
    $yaml = (Get-Content -LiteralPath $yamlPath -Encoding UTF8) -replace '^realtime: .*', "realtime: $("$([bool]$live.IsChecked)".ToLower())" `
        -replace '^current_language: .*', "current_language: $($from[0])" -replace '^src_lang: .*', "src_lang: $($from[1])" -replace '^trg_lang: .*', "trg_lang: $($to[1])"
    [IO.File]::WriteAllLines($yamlPath, [string[]]$yaml)  # UTF-8 without BOM
    Remove-Item -LiteralPath ".captions-window", ".captions-stats", ".captions-failed", ".captions-log", ".captions-download", ".captions-ready", ".captions-restart" -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath ".captions-paused" -ErrorAction SilentlyContinue
    $ps = "powershell -NoLogo -NoProfile -NoExit -ExecutionPolicy Bypass -File `"$PSScriptRoot\app\captions.ps1`"" +
          " -ProfilePath `"app\Profiles\$($modes[$m].Profile).yaml`" -App $script:app -Title `"Hushsub Translate - $m (close to stop)`""
    # conhost: a classic console window we can hide, show and close gracefully (a Windows Terminal tab can't)
    $script:conhost = Start-Process conhost.exe -ArgumentList $ps -WindowStyle Hidden -PassThru
}

function Start-Best {
    $gpu = Get-Gpu
    Start-Captions (Pick-Mode $script:budget $(if (-not (Gpu-Problem $gpu)) { $gpu }))
}

function Pause-Captions {
    # Stop: the captions hide and the engine stops listening (the plugin watches this file), its models still
    # loaded, so Start shows captions again at once
    Set-Content -LiteralPath ".captions-paused" -Value ""
    $script:pausedAt = [DateTime]::Now
}
function Start-Key($app) { "$script:budget|$app|$script:spoken|$script:captionLang|$([bool]$live.IsChecked)" }

function Stop-Captions {
    # Close captions.ps1's console (= its X): the engine then exits by itself, in a few seconds; its captions vanish at
    # once (paused). Its window appears a moment after Start: until then "asked", and the tick tries again.
    Set-Content -LiteralPath ".captions-paused" -Value ""
    if (-not $script:stopping) { $script:stopAt = [DateTime]::Now }
    $h = Console-Window
    $script:stopping = if ($h -eq [IntPtr]::Zero) { "asked" } else { [void][W.Win]::PostMessage($h, 0x10, [IntPtr]::Zero, [IntPtr]::Zero); "sent" }  # WM_CLOSE
}

function Check-Auto {
    # Auto: step down one mode if the GPU memory stays full (another app started) or this GPU translates too slowly.
    if ($script:budget -ne "Auto" -or $script:restart -or -not $script:running -or $script:running -in "Lite", "CPU") { return }
    $gpu = Get-Gpu
    $script:full = if ($gpu -and $gpu.Free -lt 0.25) { $script:full + 1 } else { 0 }
    $ms = 0
    [void][int]::TryParse("$(Get-Content -LiteralPath '.captions-stats' -ErrorAction SilentlyContinue)", [ref]$ms)
    $why = if ($script:full -ge 3) { "GPU memory full" } elseif ($ms -gt $slowMs) { "this GPU took $ms ms per line in $script:running" }
    if (-not $why) { return }
    $names = @($modes.Keys)
    $script:ceiling = $names[$names.IndexOf($script:running) + 1]
    $script:note = "Auto stepped down: $why."
    $script:full = 0
    $script:restart = $true
    Stop-Captions
}

function Default-Browser {
    $id = (Get-ItemProperty "HKCU:\Software\Microsoft\Windows\Shell\Associations\UrlAssociations\https\UserChoice" -ErrorAction SilentlyContinue).ProgId
    # no choice saved = Edge, Windows' own; a browser the app doesn't list: all PC sound, so captions still work
    switch -Wildcard ("$id") { "" { "msedge" } "MSEdge*" { "msedge" } "Brave*" { "brave" } "Chrome*" { "chrome" } "Firefox*" { "firefox" }
                               "Opera*" { "opera" } "Vivaldi*" { "vivaldi" } default { "system" } }
}
$script:browser = if ($saved -and $browsers.Contains("$($saved.browser)")) { "$($saved.browser)" } else { "auto" }
$script:app = $null  # the browser the running captions listen to
function Resolve-Browser {
    # Auto: the one browser that is running, else (none or several) the default browser
    if ($script:browser -ne "auto") { return $script:browser }
    $running = @($browsers.Keys | Where-Object { $_ -in "brave", "chrome", "msedge", "firefox", "opera", "vivaldi" -and (Get-Process -Name $_ -ErrorAction SilentlyContinue) })
    if ($running.Count -eq 1) { $running[0] } else { Default-Browser }
}
function Caption-Language {
    # Auto: the Windows display language when the app has it, else English
    if ($script:captionLang -ne "Auto") { return $script:captionLang }
    $ui = [Globalization.CultureInfo]::CurrentUICulture
    if ($ui.Name -match '^zh-(Hant|TW|HK|MO)') { return "Chinese (Traditional)" }
    $hit = @($languages.Keys | Where-Object { $languages[$_][0] -eq $ui.TwoLetterISOLanguageName })
    if ($hit) { $hit[0] } else { "English" }
}

# ---------- Look: Google's Material 3 (the colors of Gmail, Drive, Gemini), light or dark ----------
$looks = [ordered]@{ System = "System"; Light = "Light"; Dark = "Dark" }
$script:look = Saved theme $looks.Keys "Dark"
function Want-Dark {  # System = Windows' app mode, followed live
    if ($script:look -ne "System") { return $script:look -eq "Dark" }
    (Get-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize" -ErrorAction SilentlyContinue).AppsUseLightTheme -eq 0
}
function Get-Theme($dark) {
    # Bg = surface (light: surface container low, so white tiles stand out), Card = surface container, Stroke = outline variant, Sub = on-surface variant, ControlStroke = outline,
    # Accent = primary, Selected = secondary container (chosen chips), Track = an off switch's track
    $theme = if ($dark) { @{ Bg = "#131314"; Card = "#1E1F20"; CardStroke = "Transparent"; Stroke = "#444746"; Text = "#E3E3E3"; Sub = "#C4C7C5"
                             ControlStroke = "#8E918F"; Hover = "#14E3E3E3"; Accent = "#A8C7FA"; OnAccent = "#062E6F"; Selected = "#004A77"
                             OnSelected = "#C2E7FF"; Track = "#333537"; On = "#6DD58C"; Busy = "#FDD663"; Off = "#8E918F"; Bad = "#F2B8B5" } }
             else { @{ Bg = "#F0F4F9"; Card = "#FFFFFF"; CardStroke = "Transparent"; Stroke = "#C4C7C5"; Text = "#1F1F1F"; Sub = "#444746"
                       ControlStroke = "#747775"; Hover = "#141F1F1F"; Accent = "#0B57D0"; OnAccent = "#FFFFFF"; Selected = "#C2E7FF"
                       OnSelected = "#001D35"; Track = "#E1E3E1"; On = "#146C2E"; Busy = "#8C5000"; Off = "#747775"; Bad = "#B3261E" } }
    if ([Windows.SystemParameters]::HighContrast) {  # Windows contrast themes: their colors
        $c = { param($x) "#{0:X2}{1:X2}{2:X2}" -f $x.R, $x.G, $x.B }
        $sc = [Windows.SystemColors]
        $back, $text, $face, $faceText, $hi, $hiText = (& $c $sc::WindowColor), (& $c $sc::WindowTextColor), (& $c $sc::ControlColor),
                                                        (& $c $sc::ControlTextColor), (& $c $sc::HighlightColor), (& $c $sc::HighlightTextColor)
        $theme = @{ Bg = $back; Card = $back; CardStroke = $text; Stroke = $text; Text = $text; Sub = $text; ControlStroke = $faceText; Hover = $face
                    Accent = $hi; OnAccent = $hiText; Selected = $hi; OnSelected = $hiText; Track = $face; On = $text; Busy = $text; Off = $text; Bad = $text }
    }
    $theme
}
$script:dark = Want-Dark
$theme = Get-Theme $script:dark

$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Hushsub Translate" SizeToContent="WidthAndHeight" ResizeMode="CanResize" WindowStartupLocation="CenterScreen"
        Background="__Bg__" Foreground="__Text__" FontFamily="Segoe UI Variable Text, Segoe UI" FontSize="14" UseLayoutRounding="True">
  <Window.Resources>
    <BackEase x:Key="Spring" EasingMode="EaseOut" Amplitude="0.35"/>
    <!-- settings tiles, grouped as in Google's apps: 2 px apart, round outer corners on a group's first (Top) and last (Bottom) tile -->
    <Style x:Key="Card" TargetType="Border">
      <Setter Property="Background" Value="__Card__"/><Setter Property="BorderBrush" Value="__CardStroke__"/>
      <Setter Property="BorderThickness" Value="1"/><Setter Property="CornerRadius" Value="4"/>
      <Setter Property="Padding" Value="20,16"/><Setter Property="Margin" Value="0,0,0,2"/>
    </Style>
    <Style x:Key="Top" TargetType="Border" BasedOn="{StaticResource Card}"><Setter Property="CornerRadius" Value="24,24,4,4"/></Style>
    <Style x:Key="Bottom" TargetType="Border" BasedOn="{StaticResource Card}"><Setter Property="CornerRadius" Value="4,4,24,24"/></Style>
    <Style x:Key="Alone" TargetType="Border" BasedOn="{StaticResource Card}"><Setter Property="CornerRadius" Value="24"/></Style>
    <Style x:Key="Section" TargetType="TextBlock">
      <Setter Property="Foreground" Value="__Accent__"/><Setter Property="FontWeight" Value="Medium"/><Setter Property="Margin" Value="20,16,0,8"/>
    </Style>
    <Style x:Key="Caption" TargetType="TextBlock">
      <Setter Property="Foreground" Value="__Sub__"/><Setter Property="FontSize" Value="13"/><Setter Property="TextWrapping" Value="Wrap"/>
    </Style>
    <Style x:Key="Icon" TargetType="TextBlock">
      <Setter Property="FontFamily" Value="Segoe Fluent Icons, Segoe MDL2 Assets"/><Setter Property="FontSize" Value="20"/>
      <Setter Property="Foreground" Value="__Sub__"/><Setter Property="VerticalAlignment" Value="Center"/><Setter Property="Margin" Value="2,0,18,0"/>
      <Setter Property="DockPanel.Dock" Value="Left"/>
    </Style>
    <!-- buttons: filled (Accent), outlined (Standard), text (Link); pill shaped, a state layer in the text color, squish when pressed -->
    <Style x:Key="Accent" TargetType="Button">
      <Setter Property="Background" Value="__Accent__"/><Setter Property="Foreground" Value="__OnAccent__"/>
      <Setter Property="BorderBrush" Value="Transparent"/><Setter Property="BorderThickness" Value="1"/>
      <Setter Property="FontWeight" Value="Medium"/><Setter Property="Padding" Value="24,9,24,10"/><Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template"><Setter.Value>
        <ControlTemplate TargetType="Button">
          <Grid x:Name="R" RenderTransformOrigin="0.5,0.5">
            <Grid.RenderTransform><ScaleTransform/></Grid.RenderTransform>
            <Border x:Name="B" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="20"/>
            <Border x:Name="S" Background="{TemplateBinding Foreground}" CornerRadius="20" Opacity="0"/>
            <ContentPresenter Margin="{TemplateBinding Padding}" HorizontalAlignment="Center" VerticalAlignment="Center"/>
          </Grid>
          <ControlTemplate.Triggers>
            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="S" Property="Opacity" Value="0.08"/></Trigger>
            <Trigger Property="IsPressed" Value="True"><Setter TargetName="S" Property="Opacity" Value="0.12"/>
              <Trigger.EnterActions><BeginStoryboard><Storyboard><DoubleAnimation Storyboard.TargetName="R" Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleX)" To="0.95" Duration="__Quick__"/><DoubleAnimation Storyboard.TargetName="R" Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleY)" To="0.95" Duration="__Quick__"/></Storyboard></BeginStoryboard></Trigger.EnterActions>
              <Trigger.ExitActions><BeginStoryboard><Storyboard><DoubleAnimation Storyboard.TargetName="R" Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleX)" To="1" Duration="__Motion__" EasingFunction="{StaticResource Spring}"/><DoubleAnimation Storyboard.TargetName="R" Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleY)" To="1" Duration="__Motion__" EasingFunction="{StaticResource Spring}"/></Storyboard></BeginStoryboard></Trigger.ExitActions>
            </Trigger>
            <Trigger Property="IsKeyboardFocused" Value="True">
              <Setter TargetName="B" Property="BorderBrush" Value="__Text__"/><Setter TargetName="B" Property="BorderThickness" Value="2"/>
            </Trigger>
            <Trigger Property="IsEnabled" Value="False"><Setter TargetName="R" Property="Opacity" Value="0.38"/></Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value></Setter>
    </Style>
    <Style x:Key="Standard" TargetType="Button" BasedOn="{StaticResource Accent}">
      <Setter Property="Background" Value="Transparent"/><Setter Property="Foreground" Value="__Accent__"/>
      <Setter Property="BorderBrush" Value="__ControlStroke__"/>
    </Style>
    <Style x:Key="Link" TargetType="Button" BasedOn="{StaticResource Accent}">
      <Setter Property="Background" Value="Transparent"/><Setter Property="Foreground" Value="__Accent__"/><Setter Property="Padding" Value="12,9,12,10"/>
    </Style>
    <!-- choices: filter chips (a check mark on the chosen one) -->
    <Style x:Key="Segment" TargetType="RadioButton">
      <Setter Property="Foreground" Value="__Sub__"/><Setter Property="Cursor" Value="Hand"/><Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Margin" Value="0,0,8,8"/><Setter Property="Padding" Value="16,0"/>
      <Setter Property="Template"><Setter.Value>
        <ControlTemplate TargetType="RadioButton">
          <Border x:Name="B" Background="Transparent" BorderBrush="__ControlStroke__" BorderThickness="1" CornerRadius="8" MinHeight="32"
                  Padding="{TemplateBinding Padding}">
            <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
              <TextBlock x:Name="C" Text="&#xE73E;" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" FontSize="14" Margin="-8,1,8,0"
                         VerticalAlignment="Center" Visibility="Collapsed"/>
              <ContentPresenter VerticalAlignment="Center" Margin="0,0,0,1"/>
            </StackPanel>
          </Border>
          <ControlTemplate.Triggers>
            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="B" Property="Background" Value="__Hover__"/></Trigger>
            <Trigger Property="IsChecked" Value="True">
              <Setter TargetName="B" Property="Background" Value="__Selected__"/><Setter TargetName="B" Property="BorderBrush" Value="__Selected__"/>
              <Setter Property="Foreground" Value="__OnSelected__"/><Setter TargetName="C" Property="Visibility" Value="Visible"/>
            </Trigger>
            <Trigger Property="IsKeyboardFocused" Value="True">
              <Setter TargetName="B" Property="BorderBrush" Value="__Text__"/><Setter TargetName="B" Property="BorderThickness" Value="2"/>
            </Trigger>
            <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.38"/></Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value></Setter>
    </Style>
    <!-- long lists: an outlined dropdown at the tile's right, its menu below it (the chosen item filled, a check mark) -->
    <Style x:Key="Dropdown" TargetType="ComboBox">
      <Setter Property="Foreground" Value="__Text__"/><Setter Property="Cursor" Value="Hand"/><Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="DockPanel.Dock" Value="Right"/><Setter Property="VerticalAlignment" Value="Center"/><Setter Property="Width" Value="210"/>
      <Setter Property="Margin" Value="16,0,0,0"/><Setter Property="MaxDropDownHeight" Value="360"/>
      <Setter Property="Template"><Setter.Value>
        <ControlTemplate TargetType="ComboBox">
          <Grid>
            <ToggleButton Focusable="False" ClickMode="Press" Cursor="Hand"
                          IsChecked="{Binding IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}">
              <ToggleButton.Template><ControlTemplate TargetType="ToggleButton">
                <Border x:Name="O" Background="Transparent" BorderBrush="__ControlStroke__" BorderThickness="1" CornerRadius="8" Height="40"/>
                <ControlTemplate.Triggers>
                  <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="O" Property="Background" Value="__Hover__"/></Trigger>
                </ControlTemplate.Triggers>
              </ControlTemplate></ToggleButton.Template>
            </ToggleButton>
            <Border x:Name="F" BorderBrush="__Accent__" BorderThickness="2" CornerRadius="8" Visibility="Hidden" IsHitTestVisible="False"/>
            <ContentPresenter Content="{TemplateBinding SelectionBoxItem}" IsHitTestVisible="False" Margin="16,0,40,1" VerticalAlignment="Center"/>
            <TextBlock x:Name="A" Text="&#xE70D;" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" FontSize="12" IsHitTestVisible="False"
                       HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0,1,16,0" Foreground="__Sub__"/>
            <Popup x:Name="PART_Popup" IsOpen="{TemplateBinding IsDropDownOpen}" Placement="Bottom" VerticalOffset="4" AllowsTransparency="True"
                   Focusable="False" PopupAnimation="Fade">
              <Border Background="__Card__" BorderBrush="__Stroke__" BorderThickness="1" CornerRadius="8" Padding="0,6" Margin="0,0,10,10"
                      MinWidth="{Binding ActualWidth, RelativeSource={RelativeSource TemplatedParent}}" MaxHeight="{TemplateBinding MaxDropDownHeight}">
                <Border.Effect><DropShadowEffect BlurRadius="10" ShadowDepth="2" Opacity="0.3"/></Border.Effect>
                <ScrollViewer Focusable="False"><ItemsPresenter KeyboardNavigation.DirectionalNavigation="Contained"/></ScrollViewer>
              </Border>
            </Popup>
          </Grid>
          <ControlTemplate.Triggers>
            <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="F" Property="Visibility" Value="Visible"/></Trigger>
            <Trigger Property="IsDropDownOpen" Value="True">
              <Setter TargetName="F" Property="Visibility" Value="Visible"/><Setter TargetName="A" Property="Text" Value="&#xE70E;"/>
            </Trigger>
            <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.38"/></Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value></Setter>
    </Style>
    <Style TargetType="ComboBoxItem">
      <Setter Property="Foreground" Value="__Text__"/><Setter Property="Cursor" Value="Hand"/><Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template"><Setter.Value>
        <ControlTemplate TargetType="ComboBoxItem">
          <Border x:Name="B" Background="Transparent" Padding="16,0,14,0" Height="40">
            <DockPanel VerticalAlignment="Center">
              <TextBlock x:Name="C" DockPanel.Dock="Right" Text="&#xE73E;" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" FontSize="14"
                         Margin="16,1,0,0" VerticalAlignment="Center" Visibility="Hidden"/>
              <ContentPresenter VerticalAlignment="Center" Margin="0,0,0,1"/>
            </DockPanel>
          </Border>
          <ControlTemplate.Triggers>
            <Trigger Property="IsHighlighted" Value="True"><Setter TargetName="B" Property="Background" Value="__Hover__"/></Trigger>
            <Trigger Property="IsSelected" Value="True">
              <Setter TargetName="B" Property="Background" Value="__Selected__"/><Setter Property="Foreground" Value="__OnSelected__"/>
              <Setter TargetName="C" Property="Visibility" Value="Visible"/>
            </Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value></Setter>
    </Style>
    <Style x:Key="Segments" TargetType="Border">
      <Setter Property="HorizontalAlignment" Value="Left"/><Setter Property="Margin" Value="40,12,0,0"/>
    </Style>
    <!-- navigation: a pill-shaped button group, a pill under the chosen page that slides to it (Move-Pill) -->
    <Style x:Key="Tab" TargetType="RadioButton">
      <Setter Property="Foreground" Value="__Sub__"/><Setter Property="FontWeight" Value="Medium"/><Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template"><Setter.Value>
        <ControlTemplate TargetType="RadioButton">
          <Grid>
            <Border x:Name="G" Background="Transparent" CornerRadius="20" Height="40"/>
            <StackPanel Orientation="Horizontal" HorizontalAlignment="Center" VerticalAlignment="Center">
              <TextBlock Text="{TemplateBinding Tag}" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" FontSize="16" FontWeight="Normal"
                         VerticalAlignment="Center" Margin="0,1,8,0"/>
              <ContentPresenter VerticalAlignment="Center" Margin="0,0,0,1"/>
            </StackPanel>
            <Border x:Name="F" BorderBrush="__Text__" BorderThickness="2" CornerRadius="20" Visibility="Hidden"/>
          </Grid>
          <ControlTemplate.Triggers>
            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="G" Property="Background" Value="__Hover__"/></Trigger>
            <Trigger Property="IsChecked" Value="True">
              <Setter Property="Foreground" Value="__OnSelected__"/>
            </Trigger>
            <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="F" Property="Visibility" Value="Visible"/></Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value></Setter>
    </Style>
    <!-- switch: the knob springs across and grows (Material 3) -->
    <Style x:Key="Toggle" TargetType="CheckBox">
      <Setter Property="Cursor" Value="Hand"/><Setter Property="FocusVisualStyle" Value="{x:Null}"/><Setter Property="DockPanel.Dock" Value="Right"/>
      <Setter Property="Template"><Setter.Value>
        <ControlTemplate TargetType="CheckBox">
          <Grid x:Name="R" Background="Transparent">
            <Border x:Name="F" BorderBrush="__Text__" BorderThickness="2" CornerRadius="20" Margin="-4" Visibility="Hidden"/>
            <Border x:Name="T" Width="52" Height="32" CornerRadius="16" BorderThickness="2" BorderBrush="__ControlStroke__" Background="__Track__">
              <Ellipse x:Name="K" Width="24" Height="24" Fill="__ControlStroke__" HorizontalAlignment="Left" Margin="2,0" RenderTransformOrigin="0.5,0.5">
                <Ellipse.RenderTransform><TransformGroup><ScaleTransform ScaleX="0.667" ScaleY="0.667"/><TranslateTransform/></TransformGroup></Ellipse.RenderTransform>
              </Ellipse>
            </Border>
          </Grid>
          <ControlTemplate.Triggers>
            <Trigger Property="IsChecked" Value="True">
              <Setter TargetName="T" Property="Background" Value="__Accent__"/><Setter TargetName="T" Property="BorderBrush" Value="__Accent__"/>
              <Setter TargetName="K" Property="Fill" Value="__OnAccent__"/>
              <Trigger.EnterActions><BeginStoryboard><Storyboard><DoubleAnimation Storyboard.TargetName="K" Storyboard.TargetProperty="(UIElement.RenderTransform).(TransformGroup.Children)[1].(TranslateTransform.X)" To="20" Duration="__Motion__" EasingFunction="{StaticResource Spring}"/><DoubleAnimation Storyboard.TargetName="K" Storyboard.TargetProperty="(UIElement.RenderTransform).(TransformGroup.Children)[0].(ScaleTransform.ScaleX)" To="1" Duration="__Motion__" EasingFunction="{StaticResource Spring}"/><DoubleAnimation Storyboard.TargetName="K" Storyboard.TargetProperty="(UIElement.RenderTransform).(TransformGroup.Children)[0].(ScaleTransform.ScaleY)" To="1" Duration="__Motion__" EasingFunction="{StaticResource Spring}"/></Storyboard></BeginStoryboard></Trigger.EnterActions>
              <Trigger.ExitActions><BeginStoryboard><Storyboard><DoubleAnimation Storyboard.TargetName="K" Storyboard.TargetProperty="(UIElement.RenderTransform).(TransformGroup.Children)[1].(TranslateTransform.X)" To="0" Duration="__Motion__" EasingFunction="{StaticResource Spring}"/><DoubleAnimation Storyboard.TargetName="K" Storyboard.TargetProperty="(UIElement.RenderTransform).(TransformGroup.Children)[0].(ScaleTransform.ScaleX)" To="0.667" Duration="__Motion__" EasingFunction="{StaticResource Spring}"/><DoubleAnimation Storyboard.TargetName="K" Storyboard.TargetProperty="(UIElement.RenderTransform).(TransformGroup.Children)[0].(ScaleTransform.ScaleY)" To="0.667" Duration="__Motion__" EasingFunction="{StaticResource Spring}"/></Storyboard></BeginStoryboard></Trigger.ExitActions>
            </Trigger>
            <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="F" Property="Visibility" Value="Visible"/></Trigger>
            <Trigger Property="IsEnabled" Value="False"><Setter TargetName="R" Property="Opacity" Value="0.38"/></Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value></Setter>
    </Style>
    <Style TargetType="ScrollBar">
      <Setter Property="Width" Value="6"/><Setter Property="MinWidth" Value="6"/><Setter Property="Margin" Value="0,4,3,4"/>
      <Setter Property="Template"><Setter.Value>
        <ControlTemplate TargetType="ScrollBar">
          <Track x:Name="PART_Track" IsDirectionReversed="True">
            <Track.Thumb><Thumb><Thumb.Template><ControlTemplate>
              <Border Background="__Sub__" CornerRadius="3" Opacity="0.6"/>
            </ControlTemplate></Thumb.Template></Thumb></Track.Thumb>
          </Track>
        </ControlTemplate>
      </Setter.Value></Setter>
    </Style>
  </Window.Resources>

  <ScrollViewer VerticalScrollBarVisibility="Auto" Focusable="False">
  <StackPanel x:Name="Page" Width="720" MinWidth="480" MaxWidth="960" Margin="24,12,24,20">
    <DockPanel Margin="4,0,0,20">
      <Image x:Name="Logo" Width="40" Height="40" Margin="0,0,14,0" VerticalAlignment="Center"/>
      <StackPanel VerticalAlignment="Center">
        <TextBlock Text="Hushsub Translate" FontSize="24"/>
        <TextBlock Style="{StaticResource Caption}" Text="Live translated captions, made on this PC."/>
      </StackPanel>
    </DockPanel>

    <Border Style="{StaticResource Alone}" Padding="20,18" Margin="0,0,0,8">
      <StackPanel>
        <StackPanel Orientation="Horizontal">
          <Ellipse x:Name="Dot" Width="10" Height="10" Margin="0,2,10,0" VerticalAlignment="Center"/>
          <TextBlock x:Name="StatusTitle" FontSize="22"/>
        </StackPanel>
        <TextBlock x:Name="StatusText" Style="{StaticResource Caption}" FontSize="14" Margin="20,4,0,0"/>
        <ProgressBar x:Name="Progress" Height="4" Margin="20,12,0,0" Visibility="Collapsed" Foreground="__Accent__" Background="__Selected__">
          <ProgressBar.Template>
            <ControlTemplate TargetType="ProgressBar">
              <Grid>
                <Border x:Name="PART_Track" Background="{TemplateBinding Background}" CornerRadius="2"/>
                <Border x:Name="PART_Indicator" Background="{TemplateBinding Foreground}" CornerRadius="2" HorizontalAlignment="Left"/>
              </Grid>
            </ControlTemplate>
          </ProgressBar.Template>
        </ProgressBar>
        <StackPanel Orientation="Horizontal" Margin="20,18,0,0">
          <Button x:Name="MainButton" Style="{StaticResource Accent}" MinWidth="140" Content="Start"/>
          <Button x:Name="LogButton" Style="{StaticResource Standard}" Margin="8,0,0,0" Content="Show log"/>
          <Button x:Name="DeleteButton" Style="{StaticResource Standard}" Margin="8,0,0,0" Content="Delete download" Visibility="Collapsed"/>
        </StackPanel>
      </StackPanel>
    </Border>
    <Border x:Name="LogCard" Style="{StaticResource Alone}" Padding="20,12,12,16" Margin="0,0,0,8" Visibility="Collapsed">
      <DockPanel>
        <DockPanel DockPanel.Dock="Top" Margin="0,0,0,6">
          <Button x:Name="CopyLog" Style="{StaticResource Link}" DockPanel.Dock="Right" Padding="12,5,12,6" Content="Copy"/>
          <TextBlock Text="Engine log" VerticalAlignment="Center"/>
        </DockPanel>
        <TextBox x:Name="LogBox" IsReadOnly="True" Height="260" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto" BorderThickness="0"
                 FontFamily="Cascadia Mono, Consolas" FontSize="12" Background="__Card__" Foreground="__Sub__" CaretBrush="__Text__"
                 SelectionBrush="__Accent__" AutomationProperties.Name="Engine log"/>
      </DockPanel>
    </Border>

    <Border x:Name="TabBar" Background="__Card__" CornerRadius="24" Padding="4" Margin="0,8,0,0">
      <Grid>
        <Border x:Name="TabPill" Background="__Selected__" CornerRadius="20" HorizontalAlignment="Left">
          <Border.RenderTransform><TranslateTransform/></Border.RenderTransform>
        </Border>
        <UniformGrid x:Name="Tabs" Rows="1" AutomationProperties.Name="Settings">
          <RadioButton x:Name="CaptionTabButton" Style="{StaticResource Tab}" Tag="&#xED1E;" Content="Captions" IsChecked="True"/>
          <RadioButton x:Name="AppTabButton" Style="{StaticResource Tab}" Tag="&#xE713;" Content="App"/>
        </UniformGrid>
      </Grid>
    </Border>
    <StackPanel x:Name="CaptionTab">
    <TextBlock Style="{StaticResource Section}" Text="Languages"/>
    <StackPanel x:Name="Languages">
      <Border Style="{StaticResource Top}">
        <DockPanel>
          <TextBlock Style="{StaticResource Icon}" Text="&#xE767;"/>
          <ComboBox x:Name="Spoken" Style="{StaticResource Dropdown}" AutomationProperties.Name="Spoken"/>
          <StackPanel VerticalAlignment="Center">
            <TextBlock Text="Spoken"/>
            <TextBlock x:Name="LangText" Style="{StaticResource Caption}"/>
          </StackPanel>
        </DockPanel>
      </Border>
      <Border Style="{StaticResource Bottom}">
        <DockPanel>
          <TextBlock Style="{StaticResource Icon}" Text="&#xED1E;"/>
          <ComboBox x:Name="CaptionLang" Style="{StaticResource Dropdown}" AutomationProperties.Name="Captions in"/>
          <StackPanel VerticalAlignment="Center">
            <TextBlock Text="Captions in"/>
            <TextBlock Style="{StaticResource Caption}" Text="Auto: your Windows language."/>
          </StackPanel>
        </DockPanel>
      </Border>
    </StackPanel>
    <TextBlock Style="{StaticResource Section}" Text="Display"/>
    <Border Style="{StaticResource Top}">
      <DockPanel>
        <TextBlock Style="{StaticResource Icon}" Text="&#xE7F0;"/>
        <CheckBox x:Name="Live" Style="{StaticResource Toggle}" AutomationProperties.Name="Live line" VerticalAlignment="Center" Margin="16,0,0,0"/>
        <StackPanel>
          <TextBlock Text="Live line"/>
          <TextBlock Style="{StaticResource Caption}" Text="Words as they're spoken; they may change."/>
        </StackPanel>
      </DockPanel>
    </Border>
    <Border Style="{StaticResource Card}">
      <DockPanel>
        <TextBlock Style="{StaticResource Icon}" Text="&#xE8C1;"/>
        <CheckBox x:Name="ShowOriginal" Style="{StaticResource Toggle}" AutomationProperties.Name="Show original" VerticalAlignment="Center" Margin="16,0,0,0"/>
        <StackPanel>
          <TextBlock Text="Show original"/>
          <TextBlock Style="{StaticResource Caption}" Text="What was said, small, above the translation."/>
        </StackPanel>
      </DockPanel>
    </Border>
    <Border Style="{StaticResource Bottom}">
      <StackPanel>
        <DockPanel>
          <TextBlock Style="{StaticResource Icon}" Text="&#xE8D2;"/>
          <Button x:Name="StyleReset" Style="{StaticResource Standard}" DockPanel.Dock="Right" VerticalAlignment="Top" Padding="16,5,16,6" Margin="16,0,0,0" Content="Reset"/>
          <StackPanel>
            <TextBlock Text="Caption style"/>
            <TextBlock Style="{StaticResource Caption}" Text="To move captions, drag them."/>
          </StackPanel>
        </DockPanel>
        <Border Margin="40,12,0,4" CornerRadius="12" Padding="0,22">
          <Border.Background><LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
            <GradientStop Color="#5B7A99" Offset="0"/><GradientStop Color="#C9B48A" Offset="0.6"/><GradientStop Color="#E8E2D0" Offset="1"/>
          </LinearGradientBrush></Border.Background>
          <Border x:Name="PreviewWindow" HorizontalAlignment="Center" Padding="6,4">
            <Border x:Name="Preview" Padding="8,2,8,3">
              <TextBlock x:Name="PreviewText" Text="Captions look like this"/>
            </Border>
          </Border>
        </Border>
        <Button x:Name="StyleMore" Style="{StaticResource Link}" HorizontalAlignment="Left" Margin="30,4,0,0" Content="Show options"/>
        <StackPanel x:Name="StyleRows" Margin="40,0,0,0" Visibility="Collapsed"/>
      </StackPanel>
    </Border>
    <TextBlock Style="{StaticResource Section}" Text="Personalize"/>
    <Border Style="{StaticResource Alone}">
      <StackPanel>
        <DockPanel>
          <TextBlock Style="{StaticResource Icon}" Text="&#xE8D4;"/>
          <StackPanel>
            <TextBlock Text="Your words"/>
            <TextBlock Style="{StaticResource Caption}" Text="Fix names, one per line: heard = shown (&#x30DE;&#x30EA;&#x30A2; = Maria)."/>
          </StackPanel>
        </DockPanel>
        <Border Margin="40,12,0,0" BorderBrush="__ControlStroke__" BorderThickness="1" CornerRadius="8" Padding="2">
          <TextBox x:Name="Words" AcceptsReturn="True" Height="110" TextWrapping="NoWrap" VerticalScrollBarVisibility="Auto"
                   HorizontalScrollBarVisibility="Auto" FontSize="14" Padding="8,6" Background="__Card__" Foreground="__Text__"
                   BorderThickness="0" CaretBrush="__Text__" SelectionBrush="__Accent__" AutomationProperties.Name="Your words"/>
        </Border>
        <WrapPanel Margin="40,8,0,0">
          <Button x:Name="WordsSave" Style="{StaticResource Standard}" Padding="16,5,16,6" Content="Save"/>
          <Button x:Name="WordsClear" Style="{StaticResource Link}" Margin="8,0,0,0" Content="Delete all"/>
          <TextBlock x:Name="WordsNote" Style="{StaticResource Caption}" VerticalAlignment="Center" Margin="12,0,0,0"/>
        </WrapPanel>
      </StackPanel>
    </Border>
    </StackPanel>
    <StackPanel x:Name="AppTab" Visibility="Collapsed">
    <TextBlock Style="{StaticResource Section}" Text="General"/>
    <Border Style="{StaticResource Top}">
      <StackPanel>
        <DockPanel>
          <TextBlock Style="{StaticResource Icon}" Text="&#xE790;"/>
          <StackPanel>
            <TextBlock Text="Theme"/>
            <TextBlock Style="{StaticResource Caption}" Text="System: matches Windows."/>
          </StackPanel>
        </DockPanel>
        <Border Style="{StaticResource Segments}"><WrapPanel x:Name="Looks" AutomationProperties.Name="Theme"/></Border>
      </StackPanel>
    </Border>
    <Border Style="{StaticResource Card}">
      <DockPanel>
        <TextBlock Style="{StaticResource Icon}" Text="&#xE774;"/>
        <ComboBox x:Name="Browsers" Style="{StaticResource Dropdown}" AutomationProperties.Name="Listen to"/>
        <StackPanel VerticalAlignment="Center">
          <TextBlock Text="Listen to"/>
          <TextBlock Style="{StaticResource Caption}" Text="Auto: the open browser, else your default."/>
        </StackPanel>
      </DockPanel>
    </Border>
    <Border x:Name="ChatboxCard" Style="{StaticResource Card}">
      <DockPanel>
        <TextBlock Style="{StaticResource Icon}" Text="&#xE8BD;"/>
        <CheckBox x:Name="Chatbox" Style="{StaticResource Toggle}" AutomationProperties.Name="VRChat chatbox" VerticalAlignment="Center" Margin="16,0,0,0"/>
        <StackPanel>
          <TextBlock Text="VRChat chatbox"/>
          <TextBlock Style="{StaticResource Caption}" Text="Also shows each translated line in your VRChat chatbox."/>
        </StackPanel>
      </DockPanel>
    </Border>
    <Border Style="{StaticResource Bottom}">
      <StackPanel>
        <DockPanel>
          <TextBlock Style="{StaticResource Icon}" Text="&#xE895;"/>
          <CheckBox x:Name="AutoUpdate" Style="{StaticResource Toggle}" AutomationProperties.Name="Update automatically" VerticalAlignment="Center" Margin="16,0,0,0"/>
          <StackPanel>
            <TextBlock Text="Update automatically"/>
            <TextBlock x:Name="UpdateText" Style="{StaticResource Caption}"/>
          </StackPanel>
        </DockPanel>
        <Button x:Name="UpdateButton" Style="{StaticResource Standard}" HorizontalAlignment="Left" Padding="16,5,16,6" Margin="40,12,0,0" Content="Check for updates"/>
      </StackPanel>
    </Border>
    <TextBlock Style="{StaticResource Section}" Text="Performance"/>
    <Border Style="{StaticResource Top}">
      <StackPanel>
        <DockPanel>
          <TextBlock Style="{StaticResource Icon}" Text="&#xE9D9;"/>
          <StackPanel>
            <TextBlock Text="GPU use"/>
            <TextBlock x:Name="GpuText" Style="{StaticResource Caption}"/>
            <TextBlock x:Name="BudgetText" Style="{StaticResource Caption}"/>
          </StackPanel>
        </DockPanel>
        <Border Style="{StaticResource Segments}"><WrapPanel x:Name="Budgets" AutomationProperties.Name="GPU use"/></Border>
      </StackPanel>
    </Border>
    <Border Style="{StaticResource Bottom}">
      <StackPanel>
        <DockPanel>
          <TextBlock Style="{StaticResource Icon}" Text="&#xE74E;"/>
          <StackPanel>
            <TextBlock Text="Downloaded models"/>
            <TextBlock x:Name="ModelsText" Style="{StaticResource Caption}"/>
          </StackPanel>
        </DockPanel>
        <StackPanel x:Name="Models" Margin="40,4,0,0"/>
      </StackPanel>
    </Border>
    <Button x:Name="Shortcut" Style="{StaticResource Link}" HorizontalAlignment="Left" Margin="8,8,0,0" Content="Add to the desktop and Start menu"/>
    <TextBlock Style="{StaticResource Section}" Text="About"/>
    <Border Style="{StaticResource Top}">
      <DockPanel>
        <TextBlock Style="{StaticResource Icon}" Text="&#xE946;" VerticalAlignment="Top" Margin="2,2,18,0"/>
        <StackPanel>
          <TextBlock x:Name="AboutTitle" Text="Hushsub Translate"/>
          <TextBlock Style="{StaticResource Caption}" Text="Free and open source."/>
        </StackPanel>
      </DockPanel>
    </Border>
    <Border Style="{StaticResource Card}">
      <DockPanel>
        <TextBlock Style="{StaticResource Icon}" Text="&#xEA18;" VerticalAlignment="Top" Margin="2,2,18,0"/>
        <StackPanel>
          <TextBlock Text="Privacy"/>
          <TextBlock Style="{StaticResource Caption}" Text="What happens to what you hear."/>
          <StackPanel x:Name="PrivacyPoints" Margin="0,8,0,0"/>
        </StackPanel>
      </DockPanel>
    </Border>
    <Border Style="{StaticResource Card}">
      <DockPanel>
        <TextBlock Style="{StaticResource Icon}" Text="&#xE8A5;" VerticalAlignment="Top" Margin="2,2,18,0"/>
        <StackPanel>
          <TextBlock Text="Terms"/>
          <TextBlock Style="{StaticResource Caption}" Text="MIT License. Each model has its own license."/>
          <Grid x:Name="LicenseRows" Margin="0,10,0,0"/>
          <TextBlock x:Name="ModeLicense" Style="{StaticResource Caption}" Margin="0,8,0,0" Visibility="Collapsed"/>
          <WrapPanel Margin="-12,8,0,0">
            <Button x:Name="LicenseButton" Style="{StaticResource Link}" Padding="12,5,12,6" Content="Read the MIT License"/>
          </WrapPanel>
        </StackPanel>
      </DockPanel>
    </Border>
    <Border Style="{StaticResource Card}">
      <DockPanel>
        <TextBlock Style="{StaticResource Icon}" Text="&#xE9CE;"/>
        <Button x:Name="HelpButton" Style="{StaticResource Standard}" DockPanel.Dock="Right" Padding="16,5,16,6" Margin="16,0,0,0" VerticalAlignment="Center" Content="Open help"/>
        <StackPanel>
          <TextBlock Text="Help"/>
          <TextBlock Style="{StaticResource Caption}" Text="Setup, modes and fixes."/>
        </StackPanel>
      </DockPanel>
    </Border>
    <Border Style="{StaticResource Bottom}">
      <DockPanel>
        <TextBlock Style="{StaticResource Icon}" Text="&#xED15;" VerticalAlignment="Top" Margin="2,2,18,0"/>
        <StackPanel>
          <TextBlock Text="Send feedback"/>
          <TextBlock Style="{StaticResource Caption}" Text="Opens a GitHub report with your setup filled in. Nothing is sent until you submit."/>
          <WrapPanel Margin="0,12,0,0">
            <Button x:Name="ReportButton" Style="{StaticResource Standard}" Padding="16,5,16,6" Content="Report on GitHub"/>
            <Button x:Name="CopyDetails" Style="{StaticResource Link}" Padding="12,5,12,6" Margin="8,0,0,0" Content="Copy details"/>
          </WrapPanel>
        </StackPanel>
      </DockPanel>
    </Border>
    </StackPanel>
    <StackPanel x:Name="HelpTab" Visibility="Collapsed">
      <DockPanel Margin="0,12,0,0">
        <Button x:Name="HelpBack" Style="{StaticResource Link}" Padding="12,7,16,8" AutomationProperties.Name="Back to settings">
          <StackPanel Orientation="Horizontal">
            <TextBlock Text="&#xE72B;" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" FontSize="16" VerticalAlignment="Center" Margin="0,1,10,0"/>
            <TextBlock Text="Back"/>
          </StackPanel>
        </Button>
        <TextBlock Text="Help" FontSize="22" VerticalAlignment="Center" Margin="12,0,0,2"/>
      </DockPanel>
      <WrapPanel x:Name="HelpJump" Margin="8,12,0,0" AutomationProperties.Name="Help topics"/>
      <StackPanel x:Name="HelpBody"/>
    </StackPanel>
  </StackPanel>
  </ScrollViewer>
</Window>
'@
$motion = if ([Windows.SystemParameters]::ClientAreaAnimation) { 0.25 } else { 0 }  # Windows' "Animation effects"
$xaml = $xaml.Replace("__Motion__", "0:0:$motion").Replace("__Quick__", "0:0:$($motion / 2)")
foreach ($k in $theme.Keys) { $xaml = $xaml.Replace("__$($k)__", "{DynamicResource T_$k}") }  # colors: Set-Theme
$win = [Windows.Markup.XamlReader]::Parse($xaml)
# Google Sans Flex (app\fonts\OFL.txt); Segoe UI draws what it lacks (Japanese, ...) and everything if it is missing
$win.FontFamily = New-Object Windows.Media.FontFamily ([Uri]"$PSScriptRoot\app\fonts\"),"./#Google Sans Flex, Segoe UI Variable Text, Segoe UI"
$dot, $statusTitle, $statusText, $progress, $button, $logButton, $deleteButton, $gpuText, $budgetText, $live, $lnkButton, $modelBox, $modelsText,
$langBox, $langText, $preview, $previewText, $previewWindow, $autoUpdate, $updateText, $updateButton, $captionTab, $appTab, $logCard, $logBox =
    "Dot", "StatusTitle", "StatusText", "Progress", "MainButton", "LogButton", "DeleteButton", "GpuText", "BudgetText", "Live", "Shortcut", "Models", "ModelsText",
    "Languages", "LangText", "Preview", "PreviewText", "PreviewWindow", "AutoUpdate", "UpdateText", "UpdateButton", "CaptionTab", "AppTab", "LogCard", "LogBox" | ForEach-Object { $win.FindName($_) }
$win.MaxHeight = [Windows.SystemParameters]::WorkArea.Height  # scrolls on small screens
if ((Engine-Installed) -and -not (Engine-Running)) {
    # Windows Defender scans each engine DLL the first time it opens after a reboot (or once its scan cache moved on).
    # Reading the 800 DLLs (7 GB, ~13 s, on a background thread) gets that done while the window is open: a first start
    # then takes 44-60 s instead of ~70 s. Reading all engine files took 100 s and was no faster (2026-10-12).
    $warm = [PowerShell]::Create().AddScript({
        param($dir)
        # background mode: low disk priority, and what it reads doesn't push other programs' files out of memory
        [void][W.Win]::SetThreadPriority([W.Win]::GetCurrentThread(), 0x10000)
        $buf = New-Object byte[] (4MB)
        foreach ($f in [IO.Directory]::EnumerateFiles($dir, "*", "AllDirectories")) {
            if ($f -notmatch '\.(dll|pyd|exe)$') { continue }
            try { $s = [IO.File]::OpenRead($f); try { while ($s.Read($buf, 0, $buf.Length)) {} } finally { $s.Dispose() } } catch {}
        }
    }).AddArgument("$PSScriptRoot\audioWhisper")
    $null = $warm.BeginInvoke()
}
$win.Add_Loaded({
    # opens maximized; restored, it has the page's natural size. The page follows the window's width, a short window scrolls.
    # Here, before the first frame: no flash. SizeToContent would keep a maximized window at the page's height.
    $page = $win.FindName("Page")
    $win.MinWidth = $win.ActualWidth - $page.ActualWidth + $page.MinWidth
    $win.MinHeight = 320
    $win.Width, $win.Height = $win.ActualWidth, $win.ActualHeight
    $win.SizeToContent = "Manual"
    $page.Width = [double]::NaN
    $win.WindowState = "Maximized"
})
$win.Add_StateChanged({ $win.MaxHeight = if ($win.WindowState -eq "Maximized") { [double]::PositiveInfinity } else { [Windows.SystemParameters]::WorkArea.Height } })
$win.Add_SourceInitialized({ Set-Theme $script:dark })  # now the title bar exists
# OnLoad reads the file and closes it: an open window used to keep app.ico locked, so every update (run while the
# window is open) failed on it. The new name gets past the locked app.ico of the window an older updater runs beside.
$appIcon = Join-Path $PSScriptRoot "app\icon.ico"
if (Test-Path -LiteralPath $appIcon) {
    $win.Icon = [Windows.Media.Imaging.BitmapFrame]::Create([Uri]$appIcon, "None", "OnLoad")  # title bar and taskbar
    $win.FindName("Logo").Source = ([Windows.Media.Imaging.BitmapDecoder]::Create([Uri]$appIcon, "None", "OnLoad").Frames | Sort-Object PixelWidth)[-1]
}
$brush = @{}
function Set-Theme($dark) {
    # every color in the XAML is a T_ resource: replacing them recolors the open window at once
    $script:dark = $dark
    $t = Get-Theme $dark
    foreach ($k in $t.Keys) { $win.Resources["T_$k"] = [Windows.Media.BrushConverter]::new().ConvertFromString($t[$k]) }
    foreach ($k in "On", "Busy", "Off", "Bad") { $brush[$k] = $win.Resources["T_$k"] }
    $h = (New-Object Windows.Interop.WindowInteropHelper $win).Handle
    if ($h -eq [IntPtr]::Zero) { return }
    $on = [int]$dark
    [void][W.Win]::DwmSetWindowAttribute($h, 20, [ref]$on, 4)  # dark title bar
    if (-not [Windows.SystemParameters]::HighContrast) {
        $bg = $win.Resources["T_Bg"].Color
        $ref = [int]$bg.R -bor ([int]$bg.G -shl 8) -bor ([int]$bg.B -shl 16)
        [void][W.Win]::DwmSetWindowAttribute($h, 35, [ref]$ref, 4)  # title bar in the window color (Windows 11; ignored before)
    }
}
Set-Theme $script:dark

# GPU use (and the graphics card)
$gpu = Get-Gpu
$problem = Gpu-Problem $gpu
$gpuText.Text = if ($problem) { $problem } else { "{0}, {1:0.#} GB, {2:0.#} GB free" -f $gpu.Name, $gpu.Total, $gpu.Free }
if ($problem) { $gpuText.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty, "T_Busy"); $gpu = $null }
$whole = if ($gpu) { @{ Total = $gpu.Total; Free = $gpu.Total } }  # what each budget gives when the GPU is free
$hints = @{}
foreach ($b in $budgets) {
    $m = if ($b -eq "Auto") { Pick-Mode $b $gpu } else { Pick-Mode $b $whole }
    $gives = "$m, $($modes[$m].Text)."
    $hints[$b] = if (-not $gpu) { $gives } elseif ($b -eq "Auto") { "Recommended: $gives" }
                 else { "{0:0.#} GB: {1}" -f ($gpu.Total * [double]$b / 100), $gives }
    $r = New-Object Windows.Controls.RadioButton -Property @{ Content = $(if ($b -eq "Auto") { "Auto" } else { "$b%" }); GroupName = "budget"
                                                              Tag = $b; Style = $win.Resources["Segment"]; IsChecked = ($b -eq $budget) }
    $r.Add_Checked({ param($s)
        $script:budget = $s.Tag
        $budgetText.Text = $hints[$s.Tag]
        $script:ceiling = $null
        $script:note = ""
        Save-Settings
        if ((Ours-Open) -and -not $script:restart -and $script:running -and -not (Test-Path -LiteralPath ".captions-paused")) {  # paused: Start restarts it
            # restart only if the new budget gives another mode (our engine's memory counts as free)
            if ((Pick-Mode $script:budget (Get-Gpu) $modes[$script:running].GB) -ne $script:running) { $script:restart = $true; Stop-Captions }
        }
    })
    [void]$win.FindName("Budgets").Children.Add($r)
}
$budgetText.Text = $hints[$budget]
if (-not $gpu) { $win.FindName("Budgets").Parent.Visibility = "Collapsed" }  # without a usable GPU every % gives CPU mode

function Add-Segments($name, $items, $selected, $onChecked) {
    # one segment per item into the panel $name: Tag = key, label = value
    foreach ($k in $items.Keys) {
        $r = New-Object Windows.Controls.RadioButton -Property @{ Content = $items[$k]; GroupName = $name; Tag = $k
                                                                  Style = $win.Resources["Segment"]; IsChecked = ("$k" -eq "$selected") }
        $r.Add_Checked($onChecked)
        [void]$win.FindName($name).Children.Add($r)
    }
}
$script:choices = @{}
function Add-Choices($name, $items, $selected, $onChosen) {
    # a dropdown $name: one item per entry (Tag = key, label = value); $onChosen gets the chosen item
    $box = $win.FindName($name)
    foreach ($k in $items.Keys) {
        $i = New-Object Windows.Controls.ComboBoxItem -Property @{ Content = $items[$k]; Tag = $k }
        [void]$box.Items.Add($i)
        if ("$k" -eq "$selected") { $box.SelectedItem = $i }
    }
    $script:choices[$name] = $onChosen
    $box.Add_SelectionChanged({ param($s) if ($s.SelectedItem) { & $script:choices[$s.Name] $s.SelectedItem } })
}

# Browser, languages, live line
$browserBox = $win.FindName("Browsers")
$chatbox = $win.FindName("Chatbox")
$chatbox.IsChecked = [bool]($saved -and $saved.vrchatChatbox)  # off unless turned on; the captions apply it at once
$chatbox.Add_Click({ Save-Settings })
function Show-Chatbox {  # VRChat's own sound, or your voice into its chatbox (the captions send only then)
    $win.FindName("ChatboxCard").Visibility = if ($script:browser -in "vrchat", "mic") { "Visible" } else { "Collapsed" }
}
Show-Chatbox
Add-Choices Browsers $browsers $script:browser { param($s) $script:browser = $s.Tag; Show-Chatbox; Save-Settings }
function Show-Languages {
    $cap = Caption-Language
    $pair = @($script:spoken, $cap)
    $langText.Text = if ($script:spoken -eq "Auto") { "Detects each line's language. Picking one is more accurate." }
        elseif ($script:spoken -eq $cap) { "$cap, shown as said: no translation." }
        elseif ($pair -contains "Japanese" -and $pair -contains "English") { "$script:spoken to $cap." }
        else { "$script:spoken to $cap. Fast mode's second pass is for Japanese and English only." }
}
$names = [ordered]@{ Auto = "Auto" }; foreach ($l in $languages.Keys) { $names[$l] = $l }
Add-Choices Spoken $names $script:spoken { param($s) $script:spoken = $s.Tag; Show-Languages; Save-Settings }
Add-Choices CaptionLang $names $script:captionLang { param($s) $script:captionLang = $s.Tag; Show-Languages; Save-Settings }
Show-Languages
$live.IsChecked = [bool]($saved -and $saved.live)  # off unless turned on: only finished lines, never words that then change
$live.Add_Click({ Save-Settings })
$showOriginal = $win.FindName("ShowOriginal")
$showOriginal.IsChecked = [bool]($saved -and $saved.showOriginal)  # off unless turned on; the captions apply it at once
$showOriginal.Add_Click({ Save-Settings })
# Your words = glossary.txt without its # help lines (kept on Save). The plugin re-reads it on the next line.
$wordsBox = $win.FindName("Words"); $wordsNote = $win.FindName("WordsNote")
function Read-Words {
    $t = @(Get-Content -LiteralPath "app\glossary.txt" -Encoding UTF8 -ErrorAction SilentlyContinue)
    # saved by hand as ANSI or Shift-JIS: read in the PC's code page, so the next save (an update saves too) converts
    # it to UTF-8 instead of turning its words into U+FFFD for good
    if (($t -join "").Contains([char]0xFFFD)) { $t = @(Get-Content -LiteralPath "app\glossary.txt" -Encoding Default -ErrorAction SilentlyContinue) }
    $t
}
$wordsBox.Text = @(Read-Words | Where-Object { $_.Trim() -and -not $_.TrimStart().StartsWith("#") }) -join "`r`n"
function Word-Lines([string]$text) { @($text -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
$script:savedWords = (Word-Lines $wordsBox.Text) -join "`n"  # closing the window asks before losing edits to it
function Save-Words([string]$text) {
    $lines = @(Word-Lines $text)
    $bad = @($lines | Where-Object { -not $_.StartsWith("#") -and $_ -notmatch '^[^=]*\S[^=]*=' })
    if ($bad) { $wordsNote.Text = "Needs heard = shown: $($bad[0])"; return }
    $help = @(Read-Words | Where-Object { $_.TrimStart().StartsWith("#") })
    [IO.File]::WriteAllLines("$PSScriptRoot\app\glossary.txt", [string[]]($help + $lines))  # UTF-8 without BOM
    $wordsNote.Text = if ($lines) { "Saved." } else { "All deleted." }
    $script:savedWords = $lines -join "`n"
}
$win.FindName("WordsSave").Add_Click({ Save-Words $wordsBox.Text })
$win.FindName("WordsClear").Add_Click({
    if ($wordsBox.Text.Trim() -and [Windows.MessageBox]::Show($win, "Delete all your words? This can't be undone.", "Hushsub Translate", "YesNo") -ne "Yes") { return }
    $wordsBox.Text = ""; Save-Words ""
})
$wordsBox.Add_TextChanged({ $wordsNote.Text = "" })

# Caption style: the preview here, the captions themselves within a second (the plugin watches app-settings.json)
function Brush($color, $percent) { [Windows.Media.BrushConverter]::new().ConvertFromString(("#{0:X2}" -f [int](2.55 * [int]$percent)) + $colors[$color].Substring(1)) }
function Show-Style {
    $st = $script:style
    $smallCaps = $st.captionFont -eq "Small Capitals"  # all capitals a size smaller (as the captions draw it)
    $previewText.FontFamily = $fonts[$st.captionFont]
    $previewText.Text = if ($smallCaps) { "CAPTIONS LOOK LIKE THIS" } else { "Captions look like this" }
    $previewText.FontSize = 14 * [int]$st.captionSize / 100 * $(if ($smallCaps) { 0.85 } else { 1 })
    $previewText.Foreground = Brush $st.captionColor $st.captionOpacity
    $preview.Background = Brush $st.captionBackgroundColor $st.captionBackground
    $previewWindow.Background = Brush $st.captionWindowColor $st.captionWindow
    $edge = @{ "Drop Shadow" = 2, 315, 2; Raised = 1, 315, 0; Depressed = 1, 135, 0; Outline = 0, 0, 4 }[$st.captionEdge]
    $previewText.Effect = if ($edge) { New-Object Windows.Media.Effects.DropShadowEffect -Property @{
        ShadowDepth = $edge[0]; Direction = $edge[1]; BlurRadius = $edge[2]; Color = "#222222"; Opacity = 1 } }
}
$styleRows = $win.FindName("StyleRows")
foreach ($k in $styleOptions.Keys) {
    [void]$styleRows.Children.Add((New-Object Windows.Controls.TextBlock -Property @{ Text = $styleOptions[$k].Label; Margin = "0,12,0,0" }))
    $panel = New-Object Windows.Controls.WrapPanel -Property @{ Tag = $k }
    [Windows.Automation.AutomationProperties]::SetName($panel, $styleOptions[$k].Label)
    $win.RegisterName($k, $panel)
    [void]$styleRows.Children.Add((New-Object Windows.Controls.Border -Property @{ Style = $win.Resources["Segments"]; Margin = "0,6,0,0"; Child = $panel }))
    Add-Segments $k $styleOptions[$k].Items $script:style[$k] { param($s) $script:style[$s.Parent.Tag] = "$($s.Tag)"; Show-Style; Save-Settings }
    foreach ($r in $panel.Children) { $r.Padding = "12,0" }  # narrower chips: Font size and edge style fit one line
    if ($k -like "*Color") {  # color rows: a swatch per color (fits one line), its name as tooltip and for screen readers
        foreach ($r in $panel.Children) {
            $swatch = New-Object Windows.Controls.Border -Property @{ Width = 18; Height = 18; CornerRadius = 9; BorderThickness = 1; Margin = "0,2,0,0"
                                                                    Background = [Windows.Media.BrushConverter]::new().ConvertFromString($colors[$r.Tag]) }
            $swatch.SetResourceReference([Windows.Controls.Border]::BorderBrushProperty, "T_Sub")
            [Windows.Automation.AutomationProperties]::SetName($r, $r.Tag)
            $r.ToolTip, $r.Content = $r.Tag, $swatch
        }
    }
}
$win.FindName("StyleReset").Add_Click({
    if (@($styleOptions.Keys | Where-Object { $script:style[$_] -ne $styleOptions[$_].Default }) -and
        [Windows.MessageBox]::Show($win, "Reset all caption style options to the default?", "Hushsub Translate", "YesNo") -ne "Yes") { return }
    foreach ($k in $styleOptions.Keys) { foreach ($r in $win.FindName($k).Children) { if ($r.Tag -eq $styleOptions[$k].Default) { $r.IsChecked = $true } } }
})
$win.FindName("StyleMore").Add_Click({ param($s)  # the nine option rows stay folded away until wanted
    $open = $styleRows.Visibility -ne "Visible"
    $styleRows.Visibility = if ($open) { "Visible" } else { "Collapsed" }
    $s.Content = if ($open) { "Hide options" } else { "Show options" }
})
Show-Style
Add-Segments Looks $looks $script:look { param($s) $script:look = $s.Tag; Save-Settings; Set-Theme (Want-Dark) }
$win.FindName("Looks").IsEnabled = -not [Windows.SystemParameters]::HighContrast  # contrast themes set the colors
# tabs: the pill slides to the chosen one, its page fades in and rises (Material's shared axis)
$ease = New-Object Windows.Media.Animation.CubicEase -Property @{ EasingMode = "EaseOut" }
function Animate($target, $property, $from, $to) {
    $a = New-Object Windows.Media.Animation.DoubleAnimation $from, $to, ([TimeSpan]::FromSeconds($motion))
    $a.EasingFunction = $ease
    $target.BeginAnimation($property, $a)
}
$tabs, $tabPill = $win.FindName("Tabs"), $win.FindName("TabPill")
$pillX = [Windows.Media.TranslateTransform]::XProperty
function Pill-X { $tabs.ActualWidth / 2 * ($appTab.Visibility -eq "Visible") }
$tabs.Add_SizeChanged({ $tabPill.Width = $tabs.ActualWidth / 2; $tabPill.RenderTransform.BeginAnimation($pillX, $null); $tabPill.RenderTransform.X = Pill-X })
function Fade-In($el) {
    if (-not $motion) { $tabPill.RenderTransform.X = Pill-X; return }
    Animate $tabPill.RenderTransform $pillX $tabPill.RenderTransform.X (Pill-X)
    Animate $el ([Windows.UIElement]::OpacityProperty) 0 1
    Animate $el.RenderTransform ([Windows.Media.TranslateTransform]::YProperty) 16 0
}
$captionTab.RenderTransform, $appTab.RenderTransform = (New-Object Windows.Media.TranslateTransform), (New-Object Windows.Media.TranslateTransform)
$win.FindName("CaptionTabButton").Add_Checked({ $captionTab.Visibility = "Visible"; $appTab.Visibility = "Collapsed"; Fade-In $captionTab })
$win.FindName("AppTabButton").Add_Checked({ $captionTab.Visibility = "Collapsed"; $appTab.Visibility = "Visible"; Fade-In $appTab; Show-About; Refresh-Models })

# Updates: checked on start only with auto-update on (nothing is contacted otherwise), installed when captions are off
# IT can turn updates off for good (Group Policy / Intune; only administrators can write this key)
$script:managed = @("Hushsub Translate", "Private Captions" | ForEach-Object {  # the policy key's name before 1.5.0 still counts
    (Get-ItemProperty -LiteralPath "HKLM:\SOFTWARE\Policies\$_" -ErrorAction SilentlyContinue).DisableUpdates }) -contains 1
$autoUpdate.IsChecked = -not $script:managed -and -not ($saved -and $saved.autoUpdate -eq $false)
if ($script:managed) { $autoUpdate.IsEnabled = $false; $updateButton.Visibility = "Collapsed" }
$autoUpdate.Add_Click({ Save-Settings; Show-About; if ($autoUpdate.IsChecked) { Start-Update $false } })
$updateButton.Add_Click({ Start-Update ($updateButton.Content -eq "Update now") })
if ($autoUpdate.IsChecked) { Start-Update $false }

# Downloaded models: size, unfinished ones, Remove (while no engine runs: it may be using or downloading them)
$modelRows = @{}
foreach ($n in $models.Keys) {
    $row = New-Object Windows.Controls.DockPanel -Property @{ Margin = "0,10,0,0"; Visibility = "Collapsed" }
    $rm = New-Object Windows.Controls.Button -Property @{ Content = "Remove"; Tag = $n; Style = $win.Resources["Standard"]; Padding = "12,3,12,4"
                                                          Margin = "16,0,0,0"; VerticalAlignment = "Center" }
    [Windows.Controls.DockPanel]::SetDock($rm, "Right")
    $rm.SetValue([Windows.Automation.AutomationProperties]::NameProperty, "Remove $n")
    $rm.Add_Click({ param($s)
        $n = $s.Tag
        if ([Windows.MessageBox]::Show($win, ("Remove {0} ({1:0.0} GB, used by {2})? It downloads again on the next Start that needs it." -f $n, $modelRows[$n].GB, $models[$n].Use),
                "Hushsub Translate", "YesNo") -ne "Yes") { return }
        Model-Items $n | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        Refresh-Models
    })
    $text = New-Object Windows.Controls.StackPanel
    $info = New-Object Windows.Controls.TextBlock -Property @{ Style = $win.Resources["Caption"] }
    [void]$text.Children.Add((New-Object Windows.Controls.TextBlock -Property @{ Text = $n }))
    [void]$text.Children.Add($info)
    [void]$row.Children.Add($rm)
    [void]$row.Children.Add($text)
    [void]$modelBox.Children.Add($row)
    $modelRows[$n] = @{ Row = $row; Info = $info; GB = 0 }
}
function Refresh-Models {
    $total = 0
    foreach ($n in $models.Keys) {
        $bytes = [double](Model-Items $n | ForEach-Object { if ($_.PSIsContainer) { Get-ChildItem -LiteralPath $_.FullName -Recurse -File -Force -ErrorAction SilentlyContinue } else { $_ } } |
                          Measure-Object Length -Sum).Sum
        $r = $modelRows[$n]
        $r.GB = $bytes / 1GB
        $total += $r.GB
        $r.Row.Visibility = if ($bytes) { "Visible" } else { "Collapsed" }
        $done = if (Test-Path -LiteralPath ".cache\$($models[$n].Done)") { "" } else { ", unfinished" }
        $r.Info.Text = "{0:0.0} GB, used by {1}{2}" -f $r.GB, $models[$n].Use, $done
    }
    $modelsText.Text = if ($total) { "{0:0.0} GB. A removed model downloads again when needed." -f $total }
                       else { "None yet." }
}
Refresh-Models

function Start-Install {
    $drive = Get-PSDrive -Name $PSScriptRoot.Substring(0, 1) -ErrorAction SilentlyContinue  # none for a network path
    if ($drive -and $drive.Free -lt 20GB -and [Windows.MessageBox]::Show($win, ("Only {0:0} GB free on {1}: the engine and models need ~20 GB. Install anyway?" -f ($drive.Free / 1GB), $drive.Root),
            "Hushsub Translate", "YesNo") -ne "Yes") { return }
    Remove-Item -LiteralPath ".install-error.txt" -ErrorAction SilentlyContinue
    $script:installer = Start-Process powershell -WindowStyle Hidden -PassThru `
        -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSScriptRoot\app\install.ps1`""
}
# installed from the ZIP a moment ago: that double-click was the Install press, so the download starts without another one
if (Test-Path -LiteralPath ".install-now") {
    Remove-Item -LiteralPath ".install-now" -ErrorAction SilentlyContinue
    if (-not (Engine-Installed) -and -not $script:installer) { Start-Install }
}
$button.Add_Click({
    if ($script:clicked -and ([DateTime]::Now - $script:clicked).TotalMilliseconds -lt 700) { return }  # a double click is one press
    $script:clicked = [DateTime]::Now
    if (-not (Engine-Installed)) {
        if ($script:installer -and -not $script:installer.HasExited) { Stop-Install; return }  # Pause
        Start-Install
    }
    elseif ($script:restart -or ((Ours-Open) -and -not (Test-Path -LiteralPath ".captions-paused"))) { $script:restart = $false
        if (Test-Path -LiteralPath ".captions-download") { Stop-Captions } elseif (Ours-Open) { Pause-Captions }  # Stop: at once (a model download pauses)
    }
    elseif ((Ours-Open) -and -not $script:stopping -and (Start-Key (Resolve-Browser)) -eq $script:startKey) {
        Remove-Item -LiteralPath ".captions-paused" -ErrorAction SilentlyContinue  # Start: the paused engine, at once
    }
    elseif ((Ours-Open) -or $script:stopping) {  # other settings, or the last engine still closing: start once it has exited
        $script:ceiling = $null; $script:note = ""; $script:restart = $true
        if (-not $script:stopping) { Stop-Captions }
    }
    elseif (Engine-Running) { [void][Windows.MessageBox]::Show($win, "Another caption engine (audioWhisper) is already running. Close it first.", "Hushsub Translate") }
    else { $script:ceiling = $null; $script:note = ""; Start-Best }
})
$deleteButton.Add_Click({
    if ([Windows.MessageBox]::Show($win, "Delete the engine download so far? Install then starts it again from the beginning.", "Hushsub Translate", "YesNo") -ne "Yes") { return }
    Remove-Item -LiteralPath "engine-download.zip", ".install-error.txt" -ErrorAction SilentlyContinue
    $script:installer = $null
})
# Log: what the engine's (hidden) console shows, copied to .captions-log by captions.ps1
function Show-Log($show) {
    $logCard.Visibility = if ($show) { "Visible" } else { "Collapsed" }
    $logButton.Content = if ($show) { "Hide log" } else { "Show log" }
    if ($show) { Refresh-Log }
}
function Refresh-Log {
    $t = try { [IO.File]::ReadAllText("$PSScriptRoot\.captions-log") } catch { "" }  # missing, or being written: next second
    if (-not $t -and (Test-Path -LiteralPath ".captions-log")) { return }
    if ($t -eq $logBox.Text) { return }
    $atEnd = $logBox.VerticalOffset + $logBox.ViewportHeight -ge $logBox.ExtentHeight - 4  # follow new lines unless scrolled up
    $logBox.Text = $t
    if ($atEnd) { $logBox.ScrollToEnd() }
}
$logButton.Add_Click({ Show-Log ($logCard.Visibility -ne "Visible") })
function Hide-Personal([string]$t) {
    # the copied log goes into a public bug report: this folder's path becomes <app folder> (it can name the employer,
    # as in "OneDrive - Contoso"), with \, / or \\ between its parts; the Windows user name in other paths becomes <user>
    $t = $t -replace ((($PSScriptRoot -split '[\\/]') | ForEach-Object { [regex]::Escape($_) }) -join '[\\/]+'), "<app folder>"
    foreach ($n in @((Split-Path -Leaf $env:USERPROFILE), $env:USERNAME) | Where-Object { $_ } | Select-Object -Unique) {
        $t = $t -replace "(?<=[\\/])$([regex]::Escape($n))(?=[\\/])", "<user>"
    }
    $t
}
function Copy-Text($button, [string]$text) {  # the button says Copied for 2 s
    try { [Windows.Clipboard]::SetText($text) } catch { return }  # the clipboard is busy (another app has it open)
    if ($button.Content -eq "Copied") { return }
    $was, $button.Content = $button.Content, "Copied"
    $t = New-Object Windows.Threading.DispatcherTimer -Property @{ Interval = [TimeSpan]::FromSeconds(2) }
    $t.Add_Tick({ $t.Stop(); $button.Content = $was }.GetNewClosure())
    $t.Start()
}
$win.FindName("CopyLog").Add_Click({ param($s) Copy-Text $s (Hide-Personal $logBox.Text) })
# Hushsub Translate.exe runs this script inside itself (launcher.cs), so Windows shows a real app: its own name and icon
# in the taskbar and Task Manager, pinnable. Built here with Windows' C# compiler, again when launcher.cs's version
# changes (an update): a running .exe can't be overwritten, but it can be renamed out of the way.
$exePath = Join-Path $PSScriptRoot "Hushsub Translate.exe"
function Build-Exe {
    $src = Join-Path $PSScriptRoot "app\launcher.cs"
    $old = Join-Path $PSScriptRoot "Hushsub Translate.old.exe"
    Remove-Item -LiteralPath $old -ErrorAction SilentlyContinue
    $want = [regex]::Match([IO.File]::ReadAllText($src), 'AssemblyVersion\("([\d.]+)"\)').Groups[1].Value
    $have = try { "$([Reflection.AssemblyName]::GetAssemblyName($exePath).Version)" } catch { "" }
    if ($have -eq $want) { return }
    if (Test-Path -LiteralPath $exePath) { Move-Item -LiteralPath $exePath $old }
    $cp = New-Object CodeDom.Compiler.CompilerParameters
    $cp.GenerateExecutable = $true
    $cp.OutputAssembly = $exePath
    $cp.CompilerOptions = "/target:winexe /optimize /win32icon:`"$appIcon`""
    $cp.ReferencedAssemblies.AddRange([string[]]([psobject].Assembly.Location, "System.dll", "System.Core.dll"))
    $result = (New-Object Microsoft.CSharp.CSharpCodeProvider).CompileAssemblyFromFile($cp, $src)
    if ($result.Errors.HasErrors -and (Test-Path -LiteralPath $old)) { Move-Item -LiteralPath $old $exePath }  # keep the last one
}
try { Build-Exe } catch {}  # without it the shortcuts open the script as before
$desktop = [Environment]::GetFolderPath("Desktop")
$lnkPath = Join-Path $desktop "Hushsub Translate.lnk"
$startPath = Join-Path ([Environment]::GetFolderPath("Programs")) "Hushsub Translate.lnk"  # Start menu: search, pin to Start or taskbar
function Save-Shortcut($s) {
    if (Test-Path -LiteralPath $exePath) { $s.TargetPath = $exePath; $s.Arguments = "" }
    else {
        # conhost --headless: no console window at all (Windows 11 hands a plain powershell.exe to Windows Terminal,
        # which ignores -WindowStyle Hidden and keeps a PowerShell window open next to the app)
        $s.TargetPath = "$env:WINDIR\System32\conhost.exe"
        $s.Arguments = "--headless `"$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe`" -NoProfile -ExecutionPolicy Bypass -File `"$PSScriptRoot\CaptionsApp.ps1`""
    }
    $s.WorkingDirectory = $PSScriptRoot
    # the .exe's own icon (",0": the target's): when the folder is moved or renamed, Windows updates a shortcut's
    # target but not a separate icon path, which then draws a blank white icon
    $s.IconLocation = if (Test-Path -LiteralPath $exePath) { ",0" } else { "$appIcon,0" }
    $s.Save()
}
# this app's shortcut from before 1.3.0 is Live Captions.lnk (before 1.2.3 it also opened a PowerShell window)
$oldLnkPath = Join-Path $desktop "Live Captions.lnk"
if ((Test-Path -LiteralPath $oldLnkPath) -and "$((New-Object -ComObject WScript.Shell).CreateShortcut($oldLnkPath).Arguments)".Contains("$PSScriptRoot\CaptionsApp.ps1")) {
    Save-Shortcut (New-Object -ComObject WScript.Shell).CreateShortcut($lnkPath)
    Remove-Item -LiteralPath $oldLnkPath -ErrorAction SilentlyContinue
}
# shortcuts from before 1.4.6 open the script: now the .exe. Ones from before 1.5.1 point at app.ico, blank once the
# folder moved: now the .exe's icon. One whose app is gone (the folder was moved or renamed) opens this copy.
$pinned = "$env:APPDATA\Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar\Hushsub Translate.lnk"
foreach ($p in $lnkPath, $startPath, $pinned) {
    $s = if (Test-Path -LiteralPath $p) { (New-Object -ComObject WScript.Shell).CreateShortcut($p) }
    if (-not $s -or -not (Test-Path -LiteralPath $exePath)) { continue }
    $gone = -not $s.TargetPath -or -not (Test-Path -LiteralPath $s.TargetPath)
    if ($gone -or "$($s.Arguments)".Contains("$PSScriptRoot\CaptionsApp.ps1") -or ($s.TargetPath -eq $exePath -and $s.IconLocation -ne ",0")) { Save-Shortcut $s }
}
# the app was Private Captions before 1.5.0: its shortcuts become Hushsub Translate.lnk, a taskbar pin opens Hushsub Translate.exe,
# and the old .exe goes (while it still runs, at the next start). Only this folder's: never another copy's.
$oldExe = Join-Path $PSScriptRoot "Private Captions.exe"
$pinPath = "$env:APPDATA\Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar\Private Captions.lnk"
foreach ($p in (Join-Path $desktop "Private Captions.lnk"), (Join-Path (Split-Path $startPath) "Private Captions.lnk"), $pinPath) {
    if (-not (Test-Path -LiteralPath $p)) { continue }
    $s = (New-Object -ComObject WScript.Shell).CreateShortcut($p)
    if ($s.TargetPath -ne $oldExe -and -not "$($s.Arguments)".Contains("$PSScriptRoot\CaptionsApp.ps1")) { continue }
    if ($p -eq $pinPath) { Save-Shortcut $s; continue }  # renaming a pin's file would unpin it
    Save-Shortcut (New-Object -ComObject WScript.Shell).CreateShortcut((Join-Path (Split-Path $p) "Hushsub Translate.lnk"))
    Remove-Item -LiteralPath $p -ErrorAction SilentlyContinue
}
Remove-Item -LiteralPath $oldExe, (Join-Path $PSScriptRoot "Private Captions.old.exe") -ErrorAction SilentlyContinue
# the first start: in Start search like any installed app (the desktop shortcut stays a choice)
if (-not $saved -and -not (Test-Path -LiteralPath $startPath)) { Save-Shortcut (New-Object -ComObject WScript.Shell).CreateShortcut($startPath) }
# About: what the app is built with, privacy and terms (following the settings), help, feedback
$repo = "https://github.com/peng-win0/hushsub-translate"
$iconFont = New-Object Windows.Media.FontFamily "Segoe Fluent Icons, Segoe MDL2 Assets"
$codeFont = New-Object Windows.Media.FontFamily "Cascadia Mono, Consolas"
function Add-Inlines($tb, [string]$text) {
    # README markdown in a line: **bold**, `code`, [link](https://...) or [link](a file in this folder)
    foreach ($part in [regex]::Split($text, '(\*\*.+?\*\*|`[^`]+`|\[[^\]]+\]\([^)\s]+\))')) {
        if (-not $part) { continue }
        if ($part -match '^\*\*(.+)\*\*$') {
            $r = New-Object Windows.Documents.Run ($matches[1] -replace '`', ''); $r.FontWeight = [Windows.FontWeights]::Medium
        } elseif ($part -match '^`(.+)`$') {
            $r = New-Object Windows.Documents.Run ($matches[1].Replace(' ', [char]0xA0).Replace('-', [char]0x2011))  # wraps around a name, never inside it
            $r.FontFamily = $codeFont; $r.FontSize = $tb.FontSize - 2
        } elseif ($part -match '^\[(.+)\]\(([^)]+)\)$') {
            $label, $target = ($matches[1] -replace '`', ''), $matches[2]
            $file = if ($target -notmatch '^https://') { Join-Path $PSScriptRoot $target }
            if ($file -and -not (Test-Path -LiteralPath $file -PathType Leaf)) { $r = New-Object Windows.Documents.Run $label }
            else {
                $r = New-Object Windows.Documents.Hyperlink (New-Object Windows.Documents.Run $label)
                $r.Tag = if ($file) { $file } else { $target }
                $r.SetResourceReference([Windows.Documents.TextElement]::ForegroundProperty, "T_Accent")
                $r.Add_Click({ param($s) if ($s.Tag -like "https://*") { Start-Process $s.Tag } else { Start-Process notepad.exe -ArgumentList "`"$($s.Tag)`"" } })
            }
        } else { $r = New-Object Windows.Documents.Run $part }
        $tb.Inlines.Add($r)
    }
}
function Fill-Table($grid, $rows, [switch]$head) {
    # short columns as wide as their text, long ones share the rest by length and wrap; a header row in the caption color
    $n = ($rows | ForEach-Object { $_.Count } | Measure-Object -Maximum).Maximum
    for ($c = 0; $c -lt $n; $c++) {
        $long = ($rows | ForEach-Object { "$($_[$c])".Length } | Measure-Object -Maximum).Maximum
        $w = if ($long -le 30) { [Windows.GridLength]::Auto } else { New-Object Windows.GridLength ([Math]::Min($long, 60)), ([Windows.GridUnitType]::Star) }
        $grid.ColumnDefinitions.Add((New-Object Windows.Controls.ColumnDefinition -Property @{ Width = $w }))
    }
    for ($i = 0; $i -lt $rows.Count; $i++) {
        $grid.RowDefinitions.Add((New-Object Windows.Controls.RowDefinition))
        for ($c = 0; $c -lt $rows[$i].Count; $c++) {
            $tb = New-Object Windows.Controls.TextBlock -Property @{ TextWrapping = "Wrap"; FontSize = 13; Margin = "0,3,24,3" }
            Add-Inlines $tb $rows[$i][$c]
            $sub = $head -and $i -eq 0
            $tb.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty, $(if ($sub) { "T_Sub" } else { "T_Text" }))
            if ($head -and $i -eq 0) { $tb.FontWeight = [Windows.FontWeights]::Medium }
            [Windows.Controls.Grid]::SetRow($tb, $i); [Windows.Controls.Grid]::SetColumn($tb, $c)
            [void]$grid.Children.Add($tb)
        }
    }
}
function Add-Point($panel, $glyph, $color, $text) {
    $d = New-Object Windows.Controls.DockPanel -Property @{ Margin = "0,4,0,0" }
    $g = New-Object Windows.Controls.TextBlock -Property @{ Text = $glyph; FontFamily = $iconFont; FontSize = 14; Margin = "0,2,10,0"; VerticalAlignment = "Top" }
    $g.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty, "T_$color")
    [Windows.Controls.DockPanel]::SetDock($g, "Left")
    [void]$d.Children.Add($g)
    [void]$d.Children.Add((New-Object Windows.Controls.TextBlock -Property @{ Text = $text; TextWrapping = "Wrap"; FontSize = 13 }))
    [void]$panel.Children.Add($d)
}
$win.FindName("AboutTitle").Text = "Hushsub Translate $version"
Fill-Table $win.FindName("LicenseRows") @(
    , @("Part", "Used by", "License")
    , @("The app, Whispering Tiger", "Everything", "MIT")
    , @("Whisper large-v3-turbo, small", "All modes", "MIT")
    , @("MiLMMT-46", "Balanced, Accurate", "Gemma Terms of Use")
    , @("NLLB-200 600M", "Fast, Lite, CPU", "CC-BY-NC 4.0: non-commercial use only")
    , @("LFM2-350M", "Fast", "LFM Open License 1.0: commercial use for organizations under `$10M yearly revenue")
    , @("Silero VAD (voice detector)", "All modes", "MIT")
    , @("ffmpeg (from the engine)", "All modes", "GPLv3: obligations apply only when redistributing")
    , @("Google Sans Flex", "The app's font", "SIL Open Font License")) -head
function Current-Mode {
    # the mode captions run in, else the one Start would pick
    if ($script:running) { return $script:running }
    if ($script:budget -eq "Auto") { Pick-Mode "Auto" $gpu } else { Pick-Mode $script:budget $whole }
}
function Show-About {
    $p = $win.FindName("PrivacyPoints"); $p.Children.Clear()
    $ok = [string][char]0xE73E
    Add-Point $p $ok On "Audio and captions stay on this PC. Nothing is recorded or sent."
    Add-Point $p $ok On "No account, ads or telemetry. No open ports."
    Add-Point $p $ok On $(if ($autoUpdate.IsChecked) { "Online only for downloads and update checks." }
                         else { "Online only for downloads. No update checks." })
    Add-Point $p $ok On "The log may hold captions until the next Start. Its Copy hides your folder and user name."
    $m = Current-Mode; $note = $win.FindName("ModeLicense")
    $note.Visibility = if ($m) { "Visible" } else { "Collapsed" }
    if ($m -in "Fast", "Lite", "CPU") {
        $note.Text = "$m mode uses NLLB-200: non-commercial use only. For work, " +
                     $(if ($gpu) { "pick a GPU use that gives Balanced or Accurate." } else { "use a PC with an NVIDIA graphics card (Balanced or Accurate)." })
        $note.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty, "T_Busy")
    } else {
        $note.Text = "$m mode allows commercial use. Check each license above."
        $note.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty, "T_Sub")
    }
}
function Feedback-Details {
    # what a problem report needs: no captions, names, paths or window titles
    $os = [Environment]::OSVersion.Version
    $card = if ($gpu) { "{0}, {1:0.#} GB, driver {2}" -f $gpu.Name, $gpu.Total, $gpu.Driver } else { $gpuText.Text }
    $mode = if (-not (Engine-Installed)) { "Not started yet (install problem)" } elseif ($script:running) { $script:running } else { "Auto" }
    [ordered]@{
        version = $version; gpu = $card; mode = $mode
        setup = "Windows $(if ($os.Build -ge 22000) { 11 } else { 10 }) (build $($os.Build))`n" +
                "GPU use: $script:budget`nLanguages: $script:spoken to $(Caption-Language)`nListen to: $($browsers[$script:browser])`n" +
                "Live line: $(if ($live.IsChecked) { 'on' } else { 'off' })`nShow original: $(if ($showOriginal.IsChecked) { 'on' } else { 'off' })" +
                "`nVRChat chatbox: $(if ($chatbox.IsChecked) { 'on' } else { 'off' })"
    }
}
$win.FindName("ReportButton").Add_Click({
    $d = Feedback-Details
    $q = ($d.Keys | ForEach-Object { "&$_=" + [Uri]::EscapeDataString($d[$_]) }) -join ""
    Start-Process "$repo/issues/new?template=bug_report.yml$q"
})
$win.FindName("CopyDetails").Add_Click({ param($s)
    $d = Feedback-Details
    Copy-Text $s "Hushsub Translate $($d.version)`nGraphics card: $($d.gpu)`nMode: $($d.mode)`n$($d.setup)"
})
$win.FindName("LicenseButton").Add_Click({ Start-Process notepad.exe -ArgumentList "`"$PSScriptRoot\LICENSE`"" })
# Help: README.md drawn as a page of the app (offline, in its theme), built the first time it opens
$helpTab, $tabBar, $helpBody, $helpJump = "HelpTab", "TabBar", "HelpBody", "HelpJump" | ForEach-Object { $win.FindName($_) }
function Build-Help {
    $card = $null; $para = $null; $rows = $null; $skip = $false
    foreach ($line in @(Get-Content -LiteralPath "README.md" -Encoding UTF8 -ErrorAction SilentlyContinue) + "") {
        $line = $line.TrimEnd()
        if ($null -ne $rows -and $line -notmatch '^\|') {
            $g = New-Object Windows.Controls.Grid -Property @{ Margin = "0,6,0,4" }; Fill-Table $g $rows -head
            [void]$card.Children.Add($g); $rows = $null
        }
        if ($line -match '^## (.+)') {
            $h = New-Object Windows.Controls.TextBlock -Property @{ Text = $matches[1]; Style = $win.Resources["Section"] }
            $card = New-Object Windows.Controls.StackPanel; $para = $null; $skip = $false
            [void]$helpBody.Children.Add($h)
            [void]$helpBody.Children.Add((New-Object Windows.Controls.Border -Property @{ Style = $win.Resources["Alone"]; Child = $card }))
            $chip = New-Object Windows.Controls.Button -Property @{ Content = $matches[1]; Tag = $h; Style = $win.Resources["Standard"]; Padding = "14,4,14,5"; Margin = "0,0,8,8" }
            $chip.Add_Click({ param($s)
                $sv = $win.Content
                $sv.ScrollToVerticalOffset($sv.VerticalOffset + $s.Tag.TransformToAncestor($sv).Transform([Windows.Point]::new(0, 0)).Y - 8)
            })
            [void]$helpJump.Children.Add($chip)
            continue
        }
        if (-not $card -or $skip) { continue }  # before the first heading: the title, pictures and download badge
        if ($line -match '^\*\*Development\.\*\*') { $skip = $true; continue }  # about the repository, not the app
        if (-not $line) { $para = $null; continue }
        if ($line -match '^\|') {
            $cells = @($line.Trim().Trim('|').Split('|') | ForEach-Object { $_.Trim() })
            if ($cells[0] -notmatch '^-+$') { if ($null -eq $rows) { $rows = @() }; $rows += , $cells }
            continue
        }
        if ($line -match '^(\s*)(?:[-*]|(\d+)\.)\s+(.*)') {  # a list item: 2 spaces per level (3 under a numbered item)
            $d = New-Object Windows.Controls.DockPanel -Property @{ Margin = "$(20 * [int][Math]::Floor($matches[1].Length / 2)),5,0,0" }
            $mark = New-Object Windows.Controls.TextBlock -Property @{ Text = $(if ($matches[2]) { "$($matches[2])." } else { [string][char]0x2022 }); Width = 20 }
            $mark.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty, "T_Sub")
            [Windows.Controls.DockPanel]::SetDock($mark, "Left")
            $para = New-Object Windows.Controls.TextBlock -Property @{ TextWrapping = "Wrap" }
            Add-Inlines $para $matches[3]
            [void]$d.Children.Add($mark); [void]$d.Children.Add($para); [void]$card.Children.Add($d)
            continue
        }
        if ($para) { $para.Inlines.Add((New-Object Windows.Documents.Run " ")); Add-Inlines $para $line.Trim(); continue }  # a wrapped line
        $para = New-Object Windows.Controls.TextBlock -Property @{ TextWrapping = "Wrap"; Margin = $(if ($card.Children.Count) { "0,10,0,0" } else { "0" }) }
        Add-Inlines $para $line.Trim()
        [void]$card.Children.Add($para)
    }
}
function Show-Help($show) {
    if ($show -and -not $helpBody.Children.Count) { Build-Help }
    $helpTab.Visibility = if ($show) { "Visible" } else { "Collapsed" }
    $tabBar.Visibility = if ($show) { "Collapsed" } else { "Visible" }
    $appTab.Visibility = $tabBar.Visibility
    $win.Content.UpdateLayout()
    $(if ($show) { $helpTab } else { $win.FindName("HelpButton") }).BringIntoView()
}
$win.FindName("HelpButton").Add_Click({ Show-Help $true })
$win.FindName("HelpBack").Add_Click({ Show-Help $false })
$win.Add_KeyDown({ param($s, $e) if ($e.Key -eq "Escape" -and $helpTab.Visibility -eq "Visible") { Show-Help $false } })
Show-About
if ((Test-Path -LiteralPath $lnkPath) -and (Test-Path -LiteralPath $startPath)) { $lnkButton.Visibility = "Collapsed" }
$lnkButton.Add_Click({
    foreach ($p in $lnkPath, $startPath) { Save-Shortcut (New-Object -ComObject WScript.Shell).CreateShortcut($p) }
    $lnkButton.Visibility = "Collapsed"
})

$script:ticks = 0
$script:modelTicks = 0
$script:updateTicks = 0
$tick = {
    $installing = $script:installer -and -not $script:installer.HasExited
    $updating = $script:updater -and -not $script:updater.HasExited
    if ($script:updater -and -not $updating -and (Test-Path -LiteralPath ".update-done")) {
        # a new version is installed: reopen this window from the new files (it shows "Updated to ...")
        if (Test-Path -LiteralPath $exePath) { Start-Process -FilePath $exePath }
        else { Start-Process powershell -WindowStyle Hidden -ArgumentList "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSScriptRoot\CaptionsApp.ps1`"" }
        Save-Words $wordsBox.Text; $script:savedWords = (Word-Lines $wordsBox.Text) -join "`n"  # no question: nobody may be there
        $win.Close()
        return
    }
    if ($script:look -eq "System" -and (Want-Dark) -ne $script:dark) { Set-Theme (-not $script:dark) }  # Windows switched
    $open, $engine = (Ours-Open), (Engine-Running)
    if ($script:stopping -eq "asked" -and $open) { Stop-Captions }
    # stopped once the engine has exited (it frees the GPU a few seconds after its console); not ours: give up after 30 s
    if ($script:stopping -and -not $open -and (-not $engine -or ([DateTime]::Now - $script:stopAt).TotalSeconds -gt 30)) { $script:stopping = $null }
    # new budget / step down: start again only after the old engine has released the GPU (then free memory is right)
    if ($script:restart -and -not $open -and -not $engine) { $script:restart = $false; Start-Best; $open = Ours-Open }
    # Install done: on to the first captions (their models download now), no second press and wait
    if ($script:installer -and -not $installing -and (Engine-Installed) -and -not $open -and -not $engine) { $script:installer = $null; Start-Best; $open = Ours-Open }
    $paused = $open -and (Test-Path -LiteralPath ".captions-paused")
    $on = ($open -and -not $paused) -or $script:restart  # captions on, or about to be
    if ($on -and $engine -and ++$script:ticks % 5 -eq 0) { Check-Auto }
    if ($open -and -not $script:restart -and (Test-Path -LiteralPath ".captions-restart")) {
        # All PC sound: Windows switched speakers (captions.ps1 noticed); the engine only picks its device at start
        $script:note = "$(Get-Content -LiteralPath '.captions-restart' -Encoding UTF8)"
        Remove-Item -LiteralPath ".captions-restart" -ErrorAction SilentlyContinue
        $script:restart = -not $paused  # paused: the engine closes, and Start loads it for the new speakers
        Stop-Captions
    }
    $installed = Engine-Installed
    $browserBox.IsEnabled = -not $on
    $langBox.IsEnabled = -not $on
    $live.IsEnabled = -not $on
    $logButton.IsEnabled = $open -or (Test-Path -LiteralPath ".captions-log") -or $logCard.Visibility -eq "Visible"
    if ($logCard.Visibility -eq "Visible") { Refresh-Log }
    $failed = $open -and (Test-Path -LiteralPath ".captions-failed")
    if ($failed -and -not $script:failShown) { Show-Log $true }  # once: it can be hidden again
    $script:failShown = $failed
    $modelBox.IsEnabled = -not ($open -or $engine)
    if ($appTab.Visibility -eq "Visible" -and ++$script:modelTicks % 5 -eq 0) { Refresh-Models }  # growing while a mode downloads them; only shown on App
    $pick = if ($open -and $script:app) { $script:app } else { $script:browser }
    $name = if ($pick -eq "auto") { "your browser" } else { $browsers[$pick] }
    $where = if ($pick -eq "system") { "on this PC" } else { "in $name" }
    $step = "$(Get-Content -LiteralPath '.install-step' -ErrorAction SilentlyContinue)"
    $zip = Get-Item -LiteralPath "engine-download.zip" -ErrorAction SilentlyContinue
    $gb = $zip.Length / 1GB
    # captions.ps1 downloading a model: name, zip, size (name only while it checks and unpacks it)
    $dl = if ($open) { @("$(Get-Content -LiteralPath '.captions-download' -ErrorAction SilentlyContinue)".Split("`t") | Where-Object { $_ }) }
    $have, $total = if ($installing -and -not $step -and $zip) { $zip.Length, 5122715193 }
                    elseif ($dl.Count -eq 3) { [double](Get-Item -LiteralPath $dl[1] -ErrorAction SilentlyContinue).Length, [double]$dl[2] }
    # download speed over the last 10 s, so a slow download doesn't look stuck
    if ($total -and $script:dlMark -and $have -ge $script:dlMark[1]) {
        $now = [DateTime]::Now
        if (($now - $script:dlMark[0]).TotalSeconds -ge 10) { $script:dlRate = ($have - $script:dlMark[1]) / ($now - $script:dlMark[0]).TotalSeconds; $script:dlMark = $now, $have }
    } else { $script:dlMark = if ($total) { [DateTime]::Now, $have }; $script:dlRate = $null }
    $speed = if ($null -eq $script:dlRate) { "" } elseif ($script:dlRate -lt 1KB) { " No data: retrying automatically." }
        else { $min = [Math]::Ceiling(($total - $have) / $script:dlRate / 60)
               " {0:0.0} MB/s, about {1} left." -f ($script:dlRate / 1MB), $(if ($min -ge 60) { "{0} h {1} min" -f [Math]::Floor($min / 60), ($min % 60) } else { "$min min" }) }
    $again = if ($zip) { "Resume" } else { "Install" }
    $button.IsEnabled = -not ($installing -and $step) -and -not ($updating -and $script:updateApply)  # pause while downloading, not while checking/unpacking
    $button.Content = if (-not $installed) { if ($installing) { if ($step) { "Installing..." } else { "Pause" } } else { $again } } elseif ($on) { "Stop" } else { "Start" }
    $deleteButton.Visibility = if ($zip -and -not $installing -and -not $installed) { "Visible" } else { "Collapsed" }
    $progress.Visibility = if ($total) { "Visible" } else { "Collapsed" }
    if ($total) { $progress.Maximum, $progress.Value = ($total / 1GB), ($have / 1GB) }
    $off = if ($pick -eq "mic") { "Press Start, then speak$(if ($script:spoken -ne 'Auto') { " $script:spoken" }) into the microphone." }
           else { "Play $(if ($script:spoken -ne 'Auto') { "$script:spoken " })audio $where and press Start." }
    $state, $title, $text =
        if ($installing) {
            if ($step -eq "verify") { "Busy", "Installing", "Checking the download..." }
            elseif ($step -eq "unpack") { "Busy", "Installing", "Unpacking the engine (a few minutes)..." }
            else { "Busy", "Installing", ("Downloading the engine: {0:0.0} of 4.8 GB.{1}" -f $gb, $speed) } }
        elseif (-not $installed) {
            if ($script:installer) { "Bad", "Install failed", "$(Get-Content -LiteralPath '.install-error.txt' -Raw -ErrorAction SilentlyContinue) Press $again to retry." }
            elseif ($zip) { "Off", "Download paused", ("{0:0.0} of 4.8 GB downloaded." -f $gb) }
            else { "Off", "Not installed yet", "Downloads the engine (5 GB) and its models (3-8 GB), then starts captions." } }
        elseif ($script:restart) { "Busy", "Starting", $(if ($script:note) { $script:note } else { "Loading models: about a minute." }) }
        elseif ($dl.Count -eq 3) { "Busy", "Downloading the $($dl[0])", ("{0:0.0} of {1:0.0} GB.{2}" -f ($have / 1GB), ($total / 1GB), $speed) }
        elseif ($dl) { "Busy", "Preparing the $($dl[0])", "A minute or two..." }
        elseif ($paused -or $script:stopping) { "Off", "Off", $off }  # the engine waits paused, or closes in the background
        elseif ($open -and $engine -and (Test-Path -LiteralPath ".captions-stats")) { "On", "On: $script:running", "Captions appear over the video. $script:note" }
        elseif ($open -and $engine -and -not (Test-Path -LiteralPath ".captions-ready")) { "Busy", "Starting", "Loading models: about a minute, longer the first time." }
        elseif ($open -and $engine) { "On", "On: $script:running", "Captions appear when someone speaks." }
        elseif ($failed) { "Bad", ("$(Get-Content -LiteralPath '.captions-failed' -ErrorAction SilentlyContinue)" -replace '^1?$', "The engine keeps crashing"), "See the log below. Press Stop, then Start." }
        elseif ($open -and $pick -eq "system") { "Busy", "Waiting for speakers", "Captions begin once Windows has speakers or headphones." }
        elseif ($open -and $pick -eq "mic") { "Busy", "Waiting for a microphone", "Captions begin once Windows has a microphone." }
        elseif ($open) { "Busy", "Waiting for $name", "Captions begin once $name is open." }
        elseif ($engine) { "On", "On", "Another caption engine is running: close it to stop." }
        else { "Off", "Off", $off }
    $dot.Fill = $brush[$state]
    if ($state -ne $script:dotState) {  # busy: the dot breathes (30 frames a second: smooth, and light)
        $script:dotState = $state
        $breathe = if ($state -eq "Busy" -and $motion) {
            $a = New-Object Windows.Media.Animation.DoubleAnimation 1, 0.3, ([TimeSpan]::FromSeconds(0.9))
            $a.AutoReverse, $a.RepeatBehavior, $a.EasingFunction = $true, [Windows.Media.Animation.RepeatBehavior]::Forever, (New-Object Windows.Media.Animation.SineEase)
            [Windows.Media.Animation.Timeline]::SetDesiredFrameRate($a, 30); $a }
        $dot.BeginAnimation([Windows.UIElement]::OpacityProperty, $breathe)  # $null: still
    }
    $statusTitle.Text = $title
    $statusText.Text = $text

    # updates: checked daily; with auto-update on, a newer version installs once captions are off
    $latest = "$(Get-Content -LiteralPath '.update-latest' -ErrorAction SilentlyContinue)".Trim()
    $newer = $latest -and $(try { [version]$latest -gt [version]$version } catch { $false })
    # a paused engine keeps the GPU awake (no sleep, battery): it closes after a minute off, or for an update. Not
    # while it still loads: the first start converts its model for minutes, and closing would throw that away
    if ($paused -and -not (Test-Path -LiteralPath ".captions-ready")) { $script:pausedAt = [DateTime]::Now }
    if ($paused -and -not $script:stopping -and ($newer -or ([DateTime]::Now - $script:pausedAt).TotalMinutes -ge 1)) { Stop-Captions }
    $busy = $open -or $engine -or $installing
    if ($autoUpdate.IsChecked -and ++$script:updateTicks % 86400 -eq 0) { Start-Update $false }
    if ($autoUpdate.IsChecked -and $newer -and -not $busy -and -not $updating -and $script:applied -ne $latest) { $script:applied = $latest; Start-Update $true; $updating = $true }
    $err = if ($script:updater -and -not $updating) { "$(Get-Content -LiteralPath '.update-error.txt' -Raw -ErrorAction SilentlyContinue)".Trim() }
    $updateText.Text = if ($script:managed) { "Version $version. Updates are managed by your organization." }
        elseif ($updating) { if ($script:updateApply -and $newer) { "Updating to $latest..." } else { "Checking for updates..." } }
        elseif ($err) { "Version $version. $err" }
        elseif ($newer) { "Version $latest is available" + $(if ($busy) { ": it installs once captions are off." } else { "." }) }
        elseif ($updated) { "Updated to $version." }
        elseif ($latest) { "Version $version is up to date." }
        else { "Version $version." }
    $updateButton.Content = if ($newer) { "Update now" } else { "Check for updates" }
    $updateButton.IsEnabled = -not $updating -and -not ($newer -and $busy)
}
& $tick
# An error in a handler must not close the window (WPF ends the app on one) or stop the timer (WPF schedules the next
# tick only after this one returns): the newest one goes to .app-error.txt instead, and the app carries on.
function Note-Error($err) { Set-Content -LiteralPath ".app-error.txt" -Value "$(Get-Date -Format s) $err" -ErrorAction SilentlyContinue }
$win.Dispatcher.Add_UnhandledException({ param($s, $e) $e.Handled = $true; Note-Error $e.Exception.Message })
$timer = New-Object Windows.Threading.DispatcherTimer -Property @{ Interval = [TimeSpan]::FromSeconds(1) }
$timer.Add_Tick({ try { & $tick } catch { Note-Error $_ } })
$timer.Start()
$button.Add_Click({ & $tick })  # show the new state at once, not up to a second later
$win.Add_Closing({ param($s, $e)
    if (((Word-Lines $wordsBox.Text) -join "`n") -eq $script:savedWords) { return }
    $a = [Windows.MessageBox]::Show($win, "Save your words before closing?", "Hushsub Translate", "YesNoCancel")
    if ($a -eq "Yes") { Save-Words $wordsBox.Text; $a = if (((Word-Lines $wordsBox.Text) -join "`n") -ne $script:savedWords) { "Cancel" } }  # a line to fix
    if ($a -eq "Cancel") { $e.Cancel = $true; $win.FindName("CaptionTabButton").IsChecked = $true; Show-Help $false }
})
[void]$win.ShowDialog()
# The window's X quits everything: the captions vanish at once and their engine closes (in a few seconds), an engine
# download pauses (Install resumes it) and so does an update. The window is gone already; this only waits for a console
# that was just started to show its window (up to 10 s).
$timer.Stop()
$instance.ReleaseMutex()  # reopening the app works at once
if (Ours-Open) { Stop-Captions }
if ($script:installer -and -not $script:installer.HasExited) { Stop-Install }
if ($script:updater -and -not $script:updater.HasExited) {
    # stop its download or unpack: update.ps1 then exits before it changes a file, and the next open tries again.
    # Copying the files in (a second or two, no curl or tar) is never cut short, so no update ends half done.
    Get-CimInstance Win32_Process -Filter "ParentProcessId=$($script:updater.Id) AND (Name='curl.exe' OR Name='tar.exe')" -ErrorAction SilentlyContinue |
        ForEach-Object { Stop-Process -Id $_.ProcessId -ErrorAction SilentlyContinue }
}
for ($i = 0; $i -lt 20 -and $script:stopping -eq "asked" -and (Ours-Open); $i++) { Start-Sleep -Milliseconds 500; Stop-Captions }
