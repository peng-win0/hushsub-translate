# Starts the caption engine for one browser, for all PC sound (-App system: the default speakers' loopback) or for
# the default microphone (-App mic), run by CaptionsApp.ps1 in a console window that stays hidden.
# - Waits for the browser first: if it isn't running at engine start, per-app capture fails and the engine
#   sits "ready" with no audio. (Once running, the engine reconnects by itself when the browser restarts.)
# - Downloads the mode's models first (resumable; the engine's own downloader often fails, see below).
# - Starts the engine again if it crashes (gives up after 3 quick crashes in a row).
# - Copies this console's text to .captions-log every second: the app's Log panel shows it. Not by piping the
#   engine's output: the engine (PyInstaller, ignores PYTHON* variables) then buffers it and fails on Japanese text.
# It never kills the engine: force-killing an engine that holds CUDA models can leave a stuck process
# that keeps its GPU memory until reboot.
param([string]$ProfilePath, [string]$App, [string]$Title)
Set-Location -LiteralPath $PSScriptRoot
# the engine decodes audio with ffmpeg, which its zip brings in toolchain\ (Whispering Tiger's own app puts it on PATH;
# without it every line fails with "[WinError 2] The system cannot find the file specified")
$env:PATH = "$PSScriptRoot\toolchain\ffmpeg\bin;$env:PATH"
$Host.UI.RawUI.WindowTitle = $Title
# wide enough that the engine's lines don't wrap: the Log panel wraps them to its own width
try { $Host.UI.RawUI.BufferSize = New-Object Management.Automation.Host.Size 500, $Host.UI.RawUI.BufferSize.Height } catch {}
# CaptionsApp.ps1 finds this console window here, to close it (= stop, like its X).
Add-Type -Name Con -Namespace W -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
[DllImport("kernel32.dll")] static extern IntPtr GetStdHandle(int n);
[DllImport("kernel32.dll")] static extern bool GetConsoleScreenBufferInfo(IntPtr h, out Info i);
[DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern bool ReadConsoleOutputCharacter(IntPtr h, System.Text.StringBuilder s, int n, int xy, out int read);
struct Info { public short W, H, X, Y, Attr, L, T, R, B, MaxW, MaxH; }
static string text, seen;
static int same;
// The console's last 1000 rows up to the cursor; null without a console. Row by row: a wide (CJK) character
// fills two cells but reads as one character. A row that ends in text was wrapped by the console: joined to the next.
// Reading every row takes ~35 ms, so while the cursor and the last two rows are unchanged the last text is reused
// (read again every 5th time anyway: once the console is full, an exact repeat of the last line changes neither).
public static string Text() {
    IntPtr h = GetStdHandle(-11); Info i;
    if (!GetConsoleScreenBufferInfo(h, out i)) return null;
    var s = new System.Text.StringBuilder(i.W);
    string now = i.X + "," + i.Y + "\n" + Row(h, s, i.W, i.Y - 1) + "\n" + Row(h, s, i.W, i.Y);
    if (text != null && now == seen && ++same < 5) return text;
    seen = now; same = 0;
    var t = new System.Text.StringBuilder();
    for (int y = System.Math.Max(0, i.Y - 999); y <= i.Y; y++) {
        string row = Row(h, s, i.W, y);
        if (row == null) continue;
        t.Append(row.TrimEnd());
        if (row.Length == 0 || row[row.Length - 1] == ' ' || y == i.Y) t.Append("\r\n");
    }
    return text = t.ToString().TrimEnd();
}
static string Row(IntPtr h, System.Text.StringBuilder s, int w, int y) {
    int read; s.Length = 0;
    return y >= 0 && ReadConsoleOutputCharacter(h, s, w, y << 16, out read) ? s.ToString(0, read) : null;
}
'@
# The default speakers' (flow 0) or microphone's (flow 1) name, as WASAPI (and so the engine: speakers as its
# "<name> [Loopback]" device) lists it; null without one.
Add-Type -Name Speakers -Namespace W -MemberDefinition @'
[ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IEnumerator { void EnumAudioEndpoints(); void GetDefaultAudioEndpoint(int flow, int role, out IDevice device); }
[ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IDevice { void Activate(); void OpenPropertyStore(int access, out IStore store); }
[ComImport, Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IStore { void GetCount(); void GetAt(); void GetValue(ref Key key, out Value value); }
struct Key { public Guid Fmt; public int Id; }
struct Value { public short Type, R1, R2, R3; public IntPtr Data, Data2; }
[DllImport("ole32.dll")] static extern int PropVariantClear(ref Value v);
static Value Get(int flow, string fmt, int id) {
    var e = (IEnumerator)Activator.CreateInstance(Type.GetTypeFromCLSID(new Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")));
    IDevice d; IStore s; Value v;
    e.GetDefaultAudioEndpoint(flow, 1, out d);  // render/capture, multimedia (what PortAudio calls the default); fails without one
    d.OpenPropertyStore(0, out s);
    var k = new Key { Fmt = new Guid(fmt), Id = id };
    s.GetValue(ref k, out v);
    return v;
}
public static string Name(int flow) {
    try { var v = Get(flow, "A45C254E-DF1C-4EFD-8020-67D146A850E0", 14); string n = v.Type == 31 ? Marshal.PtrToStringUni(v.Data) : null; PropVariantClear(ref v); return n; }  // PKEY_Device_FriendlyName, VT_LPWSTR
    catch { return null; }
}
// sample rate Windows mixes at (nSamplesPerSec of the WAVEFORMATEX blob in PKEY_AudioEngine_DeviceFormat); 0 if unknown
public static int Rate(int flow) {
    try { var v = Get(flow, "F19F064D-082C-4E27-BC73-6882A1BB8E4C", 0); int r = v.Type == 65 ? Marshal.ReadInt32(v.Data2, 4) : 0; PropVariantClear(ref v); return r; }  // VT_BLOB
    catch { return 0; }
}
'@
# Startup lines of the engine (v1.3.20.1) that look like errors but are not: CUDA works without Triton and the toolkit.
$noise = '^(triton\\windows_utils\.py:\d+: UserWarning: Failed to find CUDA\.|\s+warnings\.warn\("Failed to find CUDA\."\)|' +
         'Triton is not available or CUDA toolkit is not properly installed on Windows\. Triton-based backbones are disabled\.|' +
         '\[NeMo W [^\]]+\] Megatron num_microbatches_calculator not found, using Apex version\.|' +
         'W\d{4} .*redirects\.py:\d+\] NOTE: Redirects are currently not supported in Windows or MacOs\.|' +
         'OneLogger: Setting error_handling_strategy to .*|No exporters were provided\. This means that no telemetry data will be collected\.|' +
         '\{"type": "loading_state", .*\}|' +
         # Stop closes this console, and the Intel Fortran runtime in the engine (from SciPy) reports that as an error
         'forrtl: error \(200\): program aborting due to window-CLOSE event|Image\s+PC\s+Routine\s+Line\s+Source|\S+\s+[0-9A-F]{16}\s+Unknown\s+Unknown\s+Unknown)$'
# What was said stays in memory: the engine prints each line it hears, and the log (a file, and Show log's Copy) keeps
# only that a line was heard
function Hide-Said($t) { $t -replace '(?m)^(Transcribe(?: \(OSC\))?|skipping\.\.\. result):[^\r\n]*', '$1: (text hidden)' }
$script:logText = $null
$script:readyLines = $null  # "now ready" lines in the console when the engine (re)started; $null: ready, or no engine yet
function Save-Log {
    $t = [W.Con]::Text()
    if ($null -eq $t -or $t -eq $script:logText) { return }
    $script:logText = $t
    if ($null -ne $script:readyLines -and ([regex]::Matches($t, "Whispering Tiger is now ready!")).Count -gt $script:readyLines) {
        $script:readyLines = $null
        Set-Content -LiteralPath ".captions-ready" -Value ""  # the app: "On" (until then "Starting": the engine loads for ~1 min)
    }
    $t = Hide-Said ((@($t -split "`r`n") -notmatch $noise) -join "`r`n")
    try { [IO.File]::WriteAllText("$PSScriptRoot\.captions-log", $t) } catch {}  # UTF-8; the app may be reading it: next second
}
$h = [W.Con]::GetConsoleWindow()
[void][W.Con]::ShowWindow($h, 0)
Set-Content -LiteralPath ".captions-window" -Value $h.ToInt64()

# The models this mode needs, fetched before the engine starts. The engine fetches them itself, but from a random one of
# its 3 mirrors and resuming only on the first: since Oct 2026 eu2 answers 403 for some files and DNS filters (Cloudflare
# WARP) block usc1, so on a slow connection a cut download starts over or fails. A failed voice detector isn't even
# reported (then "'NoneType' object is not callable" on every audio chunk). Same zips, hashes and folders as the engine
# (v1.3.20.1); curl resumes across mirrors, also the engine's own unfinished zip. The app shows .captions-download.
$mirrors = "https://eu2.contabostorage.com/bf1a89517e2643359087e5d8219c0c67:ai-models/",
           "https://s3.libs.space:9000/ai-models/",  # port 9000: blocked on some networks
           "https://usc1.contabostorage.com/8fcf133c506f4e688c7ab9ad537b5c18:ai-models/"
$vad = @{ Label = "voice detector"; File = "silero/silero-vad-v5.zip"; Size = 4005175; Into = "silero-vad-v5"
          Sha = "3A24B1E4A2D3075C6FF467D05CDA35705E490EE7E0088ACBEB436FB456C4F7DF"; Done = "silero-vad-v5\snakers4_silero-vad_master\hubconf.py" }
$whisper = @{ Label = "speech recognition"; File = "Whisper-CT2/large-v3-turbo-ct2-fp16.zip"; Size = 1486720716; Into = "whisper"
              Sha = "D16072C18D63C7B070D9F44F1A5C0D6A6FD36F13FAA0C3BF41CE34FDC90CF9B8"; Done = "whisper\large-v3-turbo-ct2-fp16\model.bin" }
$whisperSmall = @{ Label = "speech recognition (small)"; File = "Whisper-CT2/new1/small-ct2-fp16.zip"; Size = 445195615; Into = "whisper"  # CPU
                   Sha = "58021A0635469D240B9AFCE7360A191F401BF6151BDE527301500083A007EBE3"; Done = "whisper\small-ct2-fp16\model.bin" }
# MiLMMT: the plugin converts the download for CTranslate2 (milmmt_ct2) on its first start
$translator = @{
    balanced = @{ Label = "translator (MiLMMT-1B)"; File = "MiLMMT-46/MiLMMT-46-1B-v1.0.zip"; Size = 1578663629; Into = "milmmt\MiLMMT-46-1B-v1.0"
                  Sha = "CE9F7FC1782D075D0234363217B7BADB2CC385667FC6FE11F24704E81CAFF760"
                  Done = "milmmt_ct2\MiLMMT-46-1B-v1.0\model.bin", "milmmt\MiLMMT-46-1B-v1.0\model.safetensors" }
    accurate = @{ Label = "translator (MiLMMT-4B)"; File = "MiLMMT-46/MiLMMT-46-4B-v1.0.zip"; Size = 6761091060; Into = "milmmt\MiLMMT-46-4B-v1.0"
                  Sha = "13CFB1DB5585C77CF0220D6BE6B51EEC084D296B3E4C851F7D8E9D3FE026CA7C"
                  Done = "milmmt_ct2\MiLMMT-46-4B-v1.0\model.bin", "milmmt\MiLMMT-46-4B-v1.0\model-00002-of-00002.safetensors" }
    lite     = @{ Label = "translator (NLLB-600M)"; File = "NLLB-200/CT2/small.zip"; Size = 1379215064; Into = "nllb200_ct2"
                  Sha = "54188E59E5267329996F93A559BEFC0C14C09EF6A4F5F4E9645B0DA94E380D47"; Done = "nllb200_ct2\small\model.bin" }
}
$translator.fast = $translator.lite  # + LFM2, which the plugin fetches from Hugging Face
$translator.cpu = $translator.lite
function Get-Model($m) {
    # $null when the model is there, else why not (the app's status title)
    if ($m.Done | Where-Object { Test-Path -LiteralPath ".cache\$_" }) { return }
    $dir = ".cache\$($m.Into)"
    $zip = "$dir\$(Split-Path $m.File -Leaf)"  # the engine's name for it
    $null = New-Item -ItemType Directory $dir -Force
    $size = { [long](Get-Item -LiteralPath $zip -ErrorAction SilentlyContinue).Length }
    if ((& $size) -gt $m.Size) { Remove-Item -LiteralPath $zip }
    # room for the zip and what it unpacks to (MiLMMT's conversion comes after the zip is deleted, and is smaller)
    $drive = try { [IO.DriveInfo](Resolve-Path -LiteralPath $dir).ProviderPath } catch { $null }  # none for a network (UNC) path: no check
    $need = 2 * $m.Size + 1GB - (& $size)
    if ($drive -and $drive.AvailableFreeSpace -lt $need) {
        Write-Host ("Not enough disk space: the {0} needs about {1:0} GB free on {2}" -f $m.Label, [Math]::Ceiling($need / 1GB), $drive.Name)
        return "Not enough disk space"
    }
    Write-Host ("Downloading the {0} ({1}, only the first time)..." -f $m.Label, $(if ($m.Size -lt 1GB) { "{0:0} MB" -f ($m.Size / 1MB) } else { "{0:0.0} GB" -f ($m.Size / 1GB) }))
    Set-Content -LiteralPath ".captions-download" -Value "$($m.Label)`t$zip`t$($m.Size)"
    foreach ($url in $mirrors) {
        # retry here, not with curl's --retry: that throws away what the run downloaded, a re-run resumes it (-C -)
        for ($try = 1; $try -le 5 -and (& $size) -lt $m.Size; $try++) {
            $curl = Start-Process "$env:SystemRoot\System32\curl.exe" -NoNewWindow -PassThru `
                -ArgumentList "-L --fail --connect-timeout 30 --speed-limit 1024 --speed-time 60 -C - -s -o `"$zip`" `"$url$($m.File)`""
            $null = $curl.Handle  # keep the handle so ExitCode is available later
            while (-not $curl.WaitForExit(1000)) { Save-Log }
            if ($curl.ExitCode -notin 18, 28, 56) { break }  # partial file, stalled, connection reset: again; else next mirror
            Start-Sleep -Seconds 5
        }
        if ((& $size) -eq $m.Size) { break }
    }
    Set-Content -LiteralPath ".captions-download" -Value $m.Label  # the app: checking and unpacking
    Save-Log
    $ok = (& $size) -eq $m.Size -and (Get-FileHash -LiteralPath $zip).Hash -eq $m.Sha
    if ($ok) { & "$env:SystemRoot\System32\tar.exe" -xf $zip -C $dir; $ok = [bool]($m.Done | Where-Object { Test-Path -LiteralPath ".cache\$_" }) }
    if ($ok -or (& $size) -ge $m.Size) { Remove-Item -LiteralPath $zip -ErrorAction SilentlyContinue }  # done, or damaged
    Remove-Item -LiteralPath ".captions-download" -ErrorAction SilentlyContinue
    if (-not $ok) { Write-Host "Could not download the $($m.Label). Check your internet connection, then press Start to continue."; "Download failed" }
}
$downloadFailed = $false
$profileName = [IO.Path]::GetFileNameWithoutExtension($ProfilePath)
foreach ($m in $vad, $(if ($profileName -eq "cpu") { $whisperSmall } else { $whisper }), $translator[$profileName]) {
    $why = Get-Model $m
    if ($why) { Save-Log; Set-Content -LiteralPath ".captions-failed" -Value $why; $downloadFailed = $true; break }
}
# Language detection (1.1 GB): the engine downloads it on every start until the file exists, but uses it only to
# guess a text's language for its own translation (src_lang auto), which this app never sets: spoken Auto is Whisper's
# own detection. An empty file stands in for it.
if (-not (Test-Path -LiteralPath ".cache\lid\lid218e.bin")) {
    $null = New-Item -ItemType File ".cache\lid\lid218e.bin" -Force
    Remove-Item -LiteralPath ".cache\lid\LID_lid218e.zip" -ErrorAction SilentlyContinue  # an unfinished download of it
}

# fake-lines.txt was ignorelist.custom.txt before 1.3.3. The engine still reads that name (and creates it if missing),
# so lines added to it move to fake-lines.txt, which the plugin reads; then it stays empty and hidden.
$old = "ignorelist.custom.txt"
if (Test-Path -LiteralPath $old) {
    $key = { param($l) ($l.ToLowerInvariant() -replace '[\W_]+', '') }
    $have = @{}; foreach ($l in @(Get-Content -LiteralPath "fake-lines.txt" -Encoding UTF8 -ErrorAction SilentlyContinue)) { $have[(& $key $l)] = 1 }
    $new = @(Get-Content -LiteralPath $old -Encoding UTF8 | Where-Object { $_.Trim() -and -not $_.TrimStart().StartsWith("#") -and -not $have.ContainsKey((& $key $_)) })
    if ($new) { [IO.File]::AppendAllText("$PSScriptRoot\fake-lines.txt", "`n" + ($new -join "`n") + "`n") }  # UTF-8 without BOM
    if ((Get-Item -LiteralPath $old -Force).Length) { Clear-Content -LiteralPath $old -Force }
} else {
    $null = New-Item -ItemType File $old
}
(Get-Item -LiteralPath $old -Force).Attributes = "Hidden"

# CPU mode: Whisper on every physical core, up to 8 (its default is 4; on 8 cores lines came 0.8 s sooner, same words)
$cpuThreads = 0
if ($profileName -eq "cpu") {
    try { $cpuThreads = [Math]::Min(8, [int](Get-CimInstance Win32_Processor | Measure-Object NumberOfCores -Sum).Sum) } catch {}
}

# Points the profile at the audio to capture: one app's process, or a device by name (the engine only reads the
# profile at start, and isn't running here). Names are YAML single-quoted, so a ' or : in a device name stays text.
function Write-Profile($path, $process, $device, $limit, $threads) {
    $q = { param($s) "'" + "$s".Replace("'", "''") + "'" }
    $yaml = Get-Content -LiteralPath $path -Encoding UTF8 | ForEach-Object {
        if ($_ -like "audio_input_process: *") { "audio_input_process: $(& $q $process)" }
        elseif ($_ -like "audio_input_device: *") { "audio_input_device: $(& $q $device)" }
        elseif ($_ -like "phrase_time_limit: *") { "phrase_time_limit: $limit" }
        elseif ($_ -like "whisper_cpu_threads: *") { "whisper_cpu_threads: $threads" } else { $_ } }
    [IO.File]::WriteAllLines($path, [string[]]$yaml)  # UTF-8 without BOM
}

$quickCrashes = 0
while (-not $downloadFailed) {
    if ($App -in "system", "mic") {
        $flow = [int]($App -eq "mic")
        if (-not ($speakers = [W.Speakers]::Name($flow))) {
            Write-Host "Waiting for $(('speakers or headphones', 'a microphone')[$flow]) (captions begin automatically)..."
            while (-not ($speakers = [W.Speakers]::Name($flow))) { Save-Log; Start-Sleep -Seconds 2 }
        }
        Write-Host "Listening to $(('all sound on', 'the microphone')[$flow]): $speakers"
        $process, $device = "", "$speakers$((' [Loopback]', '')[$flow])"
        # The engine (v1.3.20.1) counts phrase_time_limit in blocks of the device's rate: 30 is 9.6 s at 16 kHz (the
        # browser capture) but 28.8 s from 48 kHz speakers, which made long lines arrive late. Scale it to the same 9.6 s.
        $rate = [W.Speakers]::Rate($flow)
        $limit = if ($rate -gt 0) { [Math]::Round(30 * 16000 / $rate) } else { 10 }
    } else {
        if (-not (Get-Process $App -ErrorAction SilentlyContinue)) {
            Write-Host "Waiting for $App to start (captions begin automatically)..."
            while (-not (Get-Process $App -ErrorAction SilentlyContinue)) { Save-Log; Start-Sleep -Seconds 2 }
            Start-Sleep -Seconds 3  # let the browser finish starting its audio processes
        }
        $process, $device = "$App.exe", ""
        $limit = 30  # the profiles' value (the engine rewrites the profile, so a scaled value must not stay behind)
    }

    Write-Profile (Resolve-Path -LiteralPath $ProfilePath).Path $process $device $limit $cpuThreads

    $started = Get-Date
    Remove-Item -LiteralPath ".captions-ready" -ErrorAction SilentlyContinue
    $script:readyLines = ([regex]::Matches("$([W.Con]::Text())", "Whispering Tiger is now ready!")).Count
    $engine = Start-Process -FilePath "audioWhisper\audioWhisper.exe" -ArgumentList "--config", "`"$ProfilePath`"" -NoNewWindow -PassThru
    $null = $engine.Handle  # keep the handle so ExitCode is available later
    $polls = 0
    while (-not $engine.WaitForExit(1000)) {
        Save-Log
        # Windows switched speakers or microphone (headset plugged in): the engine keeps the old device, so ask the app to restart it
        if (($App -in "system", "mic") -and ++$polls % 5 -eq 0 -and ($now = [W.Speakers]::Name($flow)) -and $now -ne $speakers) {
            Set-Content -LiteralPath ".captions-restart" -Value "Switched to $now." -Encoding UTF8
            $speakers = $now  # once per switch
        }
    }

    if (((Get-Date) - $started).TotalSeconds -lt 60) { $quickCrashes++ } else { $quickCrashes = 0 }
    if ($quickCrashes -ge 3) {
        Write-Host "`nThe caption engine stopped 3 times right after starting. See the messages above."
        Save-Log; Set-Content -LiteralPath ".captions-failed" -Value "The engine keeps crashing"  # the app shows this and its Log panel
        break
    }
    Write-Host "`nThe caption engine stopped (exit code $($engine.ExitCode)). Restarting in 5 seconds..."
    Save-Log
    Start-Sleep -Seconds 5
}
