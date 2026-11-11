# Hushsub Translate: details

What the [README](../README.md) leaves out: which graphics cards work, every setting, measurements, using it at work,
and how it works.

## Graphics cards

| Graphics card | Works? |
|---|---|
| RTX 30, 40, 50 series | Yes, in every mode, as measured below. |
| RTX 20, GTX 16 series | Should work, a little slower. |
| GTX 10 series | Should work, slower still. |
| GTX 900 or older, AMD, Intel, or none | CPU mode, on the processor. |

Why: the graphics card modes need an NVIDIA card with CUDA (NVIDIA's way of running programs on the card) and int8
support. RTX 20 and GTX 16 cards have no bfloat16 (a fast number format), so translation uses int8 + float32 instead.
Auto steps down if that is too slow. GTX 10 cards also have no fast float16, so speech recognition uses int8 + float32
too.

Only an RTX 4060 has been measured. Reports from other cards are welcome: open an issue and paste the app's log (Show
log, then Copy).

## Settings

The window has two pages: Captions and App.

### Captions page

- **Spoken and Captions in:** the language people speak, and the language the captions show. The choices: English,
  Chinese (simplified or traditional), Spanish, French, Portuguese, Russian, Indonesian, German, Japanese, Vietnamese,
  Turkish, Korean, Italian, Polish, Dutch, Azerbaijani, Bulgarian, Catalan, Croatian, Danish, Finnish, Hebrew,
  Hungarian, Kazakh, Norwegian, Slovak, Slovenian, Swedish or Tagalog.
  - Pick the same language twice to see what is said, untranslated.
  - Every language here is recognized at least as well as Russian, the weakest of the first fifteen, on the FLEURS
    test speech (a standard set of read-aloud clips).
  - Japanese to English is what the app is tuned and measured for, including its filters and Fast mode's second
    pass.
  - Auto under Spoken detects each line's language, for audio that mixes languages. If you know the language, pick
    it: on Japanese, Auto made about 4 points more recognition errors and was about 0.4 s slower.
  - Auto under Captions in uses your Windows display language, or English if the app doesn't have it.
- **Live line:** off by default. Captions then show finished sentences only, so words never change after they
  appear. Turn it on to see words as they are spoken.
  - It holds back the newest word (in Japanese, Chinese and Korean: the last 3 characters) until two updates in a
    row agree on it. That is the word Whisper, the speech recognizer, most often rewrites as it hears more.
  - On the processor, Japanese, Chinese and Korean show only what two updates agree on.
  - The newest words may still change as the sentence goes on.
- **Show original:** off by default. When on, a small row above the captions shows what was said in the newest
  finished line, in the same font as the scroll hint (just the end, if it is too long). When you scroll back, it shows
  above each line. Like the captions, it is kept in memory only and is gone at Stop.
- **Caption style:** YouTube's options, with the same choices and defaults: font, color, size (50-400%) and
  opacity; background and window color and opacity; and character edge style.
  - Show options opens all nine. Changes show right away, also while captions are on. Reset goes back to YouTube's
    defaults.
  - To move the captions, drag them anywhere. They stay there in every mode and after updates. Clicking them never
    takes the keyboard from the video or game below.
  - To read lines you missed, scroll the mouse wheel over the captions. Scroll down or click them to go back to live
    captions; they also go back by themselves after 15 seconds.
  - The last 1,000 lines are kept in memory only, and are gone when captions stop.
- **Your words:** names and terms the captions get wrong, one per line, as `heard = shown` (`マリア = Maria`). Save
  applies them from the next line, also while captions are on. They are kept in `app/glossary.txt`, on this PC only.
  Delete all removes them.

How well the live line does on the test bench. "Right" is the share of characters that are correct. For English,
the time is how long after a word is said it shows (median). For Japanese, it is the wait added before a sentence's
first words.

| | Graphics card | Processor |
|---|---|---|
| English (computer voices) | 97.5% right, 0.8 s | 98.6% right, 3.5 s |
| Japanese | 86% right, +0.4 s | 77-80% right, +2 s |

For comparison, showing every update with nothing held back scores 96.9% (graphics card) and 98.1% (processor) in
English, and 83% and 73% in Japanese. Japanese finished lines score 79.5% and 64%.

### App page

- **Theme:** Dark (the default), Light, or System to follow Windows. Windows contrast themes always use their own
  colors.
- **Listen to:**
  - Auto listens to the browser that is open when you press Start. If none or several are open, it listens to your
    default browser. Brave, Chrome, Edge, Firefox, Opera (also Opera GX) and Vivaldi are listed. With another default
    browser, Auto listens to all PC sound.
  - Pick a browser if the audio plays in a different one.
  - VRChat, Discord, Zoom, Teams and VLC caption only that app's sound. Captions begin when the app opens. (A YouTube
    app installed from the browser plays in that browser.)
  - All PC sound captions everything the PC plays on its default speakers or headphones, like Windows Live Captions.
    That includes a meeting app, a video player, and notification sounds too. When Windows switches speakers,
    captions restart on the new ones by themselves, in under a minute.
- **VRChat chatbox:** off by default, and shown only when Listen to is VRChat or Microphone. When on, each finished
  line goes to VRChat on this PC, which shows it in your chatbox. Drafts are never sent. If VRChat isn't running, the
  messages go nowhere and the captions carry on. Technically: the engine's own `VRC_OSCLib` sends each line to
  VRChat's OSC input (`127.0.0.1`, the profile's `osc_port` 9000 and `osc_address`), in pieces of `osc_chat_limit`
  (144) characters, `osc_min_time_between_messages` (1.5 s) apart.
- **Update automatically:** see [Privacy](../README.md#privacy).
- **GPU use:** how much of the graphics card the app may use. Keep it on Auto.
- **Downloaded models:** each model's size and the modes that use it. Remove deletes a model, or the part downloaded
  so far.
- **About:** the version, Privacy, Terms (each part's license), Help (the README) and Send feedback. Send feedback
  opens a GitHub problem report with your version, Windows, graphics card and mode filled in, never captions or file
  paths.

## Measurements

Delays and memory were measured on an RTX 4060 Laptop (8 GB).

- **Graphics card modes:** the Japanese recognition error rate is about 20.5% in each of them.
- **CPU mode,** on a Ryzen 7 7840HS (8 cores): a finished line is ready about 2.8 s after the speech ends, and in
  English about 0.5 s later. Recognition errors are about 36% (Lite: about 25% on the same clips). Processors with
  fewer cores take longer.

Disk space, measured on the bench PC with every mode used once (2026-10-24):

| What | Size |
|---|---|
| The engine (`audioWhisper\`, Whispering Tiger 1.3.20.1), in all | 8.8 GB |
| Of that: PyTorch, including about 3.0 GB of NVIDIA's CUDA libraries (cuDNN, cuBLAS, ...) | 4.6 GB |
| Of that: other CUDA kernels (`flash_attn`, `selective_scan`) | 0.9 GB |
| Of that: OCR, Japanese dictionaries, ONNX Runtime and the rest | 3.3 GB |
| Speech model: Whisper large-v3-turbo | 1.5 GB |
| Speech model: Whisper small | 0.5 GB |
| Translation model: MiLMMT-46-4B | 3.7 GB |
| Translation model: MiLMMT-46-1B | 2.0 GB |
| Translation model: NLLB-600M | 2.4 GB |
| Translation model: LFM2 | 0.7 GB |

A mode downloads only its own models. So the 20 GB in the README is the engine plus the largest mode, with room to
spare. About 3.9 GB of the engine is CUDA. The engine comes as one prebuilt package from Whispering Tiger, so nothing
in it is trimmed.

## Using it at work

- **Data stays on the PC.** Audio is processed in memory. Nothing is uploaded or saved (see
  [Privacy](../README.md#privacy)). The log (`.captions-log`) holds the engine's status lines, never what was said,
  and is replaced each time the engine starts. Once the models are downloaded and Update automatically is off, the
  app works offline.
- **No administrator rights, nothing installed system-wide.** The engine, the models and the settings
  (`app-settings.json`) live in the app's folder: `%LOCALAPPDATA%\Programs\Hushsub Translate`, or wherever you
  extracted the ZIP. To uninstall, delete that folder and the app's shortcuts (Start menu, and the desktop if you
  added one).
- **PCs where IT restricts apps (AppLocker or App Control for Business).** The engine is not code-signed, so IT has to
  allow the app's folder with a path or hash rule. Until then, it can't start. Scripts allowed that way run normally.
  The app writes its settings, log and models into that folder, so users need write access to it.
- **Setting it up on several PCs.** The folder is portable. Install it once, start captions once in each mode you
  want (this downloads its models), then copy the whole folder. To keep every copy on the version you tested, put
  `{"autoUpdate": false}` in `app-settings.json` before copying.
- **Managing updates centrally.** To turn updates off so users can't turn them back on, set the DWORD
  `DisableUpdates` = `1` under `HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Hushsub Translate`, with Group Policy
  Preferences or Intune. (The key's name before 1.5.0, `Private Captions`, still works.) The app then never contacts
  GitHub, and its update switch shows "Updates are managed by your organization."
- **Verified downloads.** Before they are used, the engine and every model are checked against a SHA-256 hash
  (a fingerprint) written into the scripts. LFM2 is also pinned to one Hugging Face commit. So a changed or damaged
  file on a server is rejected. Updates come only from this repository's GitHub releases, over HTTPS.
- **Model licenses.** For business use, pick Balanced or Accurate (a GPU use setting that gives one, on cards with
  6 GB or more). Fast, Lite and CPU use NLLB-200, which is licensed for non-commercial use only. The app itself is
  MIT-licensed. Check each license below with your legal team.

| Model | Used by | License |
|---|---|---|
| Whisper large-v3-turbo, small | All modes (small: CPU) | MIT |
| MiLMMT-46 (1B, 4B) | Balanced, Accurate | Gemma Terms of Use |
| NLLB-200 600M | Fast, Lite, CPU | CC-BY-NC 4.0: non-commercial only |
| LFM2-350M-ENJP-MT | Fast | LFM Open License v1.0: commercial use for organizations under $10M yearly revenue |
| Silero VAD 6 (voice detector) | All modes | MIT |

The engine's download also brings ffmpeg 5.1.2 (a GPLv3 build, `toolchain/ffmpeg/LICENSE`), which decodes the
captured audio. GPL obligations apply only when redistributing it.

### Known issues in the engine's libraries

Security scanners flag some of the libraries inside the engine (v1.3.20.1). In short: none of them can be reached the
way the app uses the engine. The details:

- **CTranslate2 4.7.1** has two model-loading flaws, fixed in 4.8.1:
  [CVE-2026-102566](https://nvd.nist.gov/vuln/detail/CVE-2026-102566) (heap overflow, CVSS 7.8) and
  [CVE-2026-102567](https://nvd.nist.gov/vuln/detail/CVE-2026-102567) (out-of-bounds read, CVSS 6.1). Both need a
  crafted model file. The app loads only the hash-checked models above (MiLMMT is converted on the PC from its
  checked download). So they are out of reach unless someone can already write to the app's folder, and that person
  could replace the engine itself anyway.
- **Updates to these libraries** come with Whispering Tiger's releases. 1.3.20.1 is its latest (checked 2026-11-05).
  The app moves to a new engine release once it has been tested.
- **The full scan:** on 2026-11-05, [OSV.dev](https://osv.dev) listed 183 advisories on 22 of the engine's 132 Python
  packages (`node bench/osv.mjs --list` prints them). Grouped by what each one needs:
  - *A crafted model file in the app's folder*, the same condition as CTranslate2's: PyTorch 2.7.1
    ([CVE-2026-24747](https://github.com/advisories/GHSA-63cw-57p8-fm3p), an untrusted checkpoint), sentencepiece
    0.2.0, and the model loaders of NeMo, Lightning, mamba-ssm, flash-attn, Accelerate and Diffusers.
  - *A request to a server in the engine*: vLLM 0.9.1 (65 of the 183), Starlette, Werkzeug, Lightning's app server,
    protobuf's JSON parser, OpenTelemetry. Nothing listens on a port, so none of them gets a request.
  - *A crafted image, document or data file*: Pillow 11.1.0 (55), pyarrow, datasets, fsspec, NLTK. The app opens
    no such file.
  - *A hostile download server*: urllib3 1.26.18 and requests 2.32.3. They only take part if the engine fetches a
    model itself. The app downloads each model first, with Windows' curl, from fixed model servers over HTTPS, and
    rejects a file that isn't the pinned one. So the worst a server could do is make a download fail or use too much
    memory.
  - *Another account on the same PC*: filelock 3.18.0 (lock files) and a temporary file in requests.
  - PyTorch's other advisories are crafted inputs to a few functions. It only ever sees the PC's audio, its captions
    and the hash-checked models.

## How it works

The [Whispering Tiger](https://github.com/Sharrnah/whispering) engine (v1.3.20.1) captures the audio: the browser's,
the speakers' (loopback), or the microphone's. It decodes it with the ffmpeg that comes with its download, and
transcribes it with Whisper large-v3-turbo (Whisper small in CPU mode). Then `Plugins/subtitle_display_plugin.py`
translates each line on the graphics card (in CPU mode, the processor) and draws the captions over the screen.

| File | Purpose |
|---|---|
| `Hushsub Translate.bat` | Opens the app (the .exe once it exists). |
| `CaptionsApp.ps1` | The app window. |
| `Plugins/` | The plugin above. The engine loads it from here. |
| `app/launcher.cs` | Source of `Hushsub Translate.exe`. The app builds it on its first start, and again when an update changes it. The .exe runs `CaptionsApp.ps1` inside itself, so Windows shows Hushsub Translate, not PowerShell. |
| `app/install.ps1` | Downloads and checks the engine. |
| `app/captions.ps1` | Runs the engine: downloads the mode's models, waits for the browser, speakers or microphone, and restarts the engine after a crash. |
| `app/update.ps1` | Installs a newer GitHub release (`version.txt`) after checking its version and scripts. |
| `app/Profiles/*.yaml` | Engine settings for Accurate, Balanced, Fast, Lite and CPU. The engine rewrites its profile when it starts, so close it before editing one. |
| `app/glossary.txt` | Your words: names and terms the translator or speech recognition gets wrong (for example product or team names). They are swapped in before translation, in every spoken language. Edit them under Your words; they apply from the next line. |
| `app/fake-lines.txt` | Lines Whisper makes up during silence or music, like "Thanks for watching". A caption that is exactly one of them is dropped. Add your own. To turn one off, put `#` before it (an update adds a deleted line back). |
| `app/fonts/` | Google Sans Flex, the app's font. |

**Development.** These are in the repository but not in the download:

- `bench/` has the tests and the benchmark kit. See [its README](../bench/README.md) for what each one does, and the
  runbook's [Before any change](runbook.md#before-any-change) for the commands. None of the tests needs the engine,
  a graphics card or the network.
- GitHub Actions runs the tests on every push, on Python 3.11 like the engine (`.github/workflows/tests.yml`). It also
  checks that every script parses and is plain ASCII, and lints the Python with `ruff check Plugins bench` (see
  `ruff.toml`).
- `docs/` holds the README's pictures, this page and the [runbook](runbook.md) (releases, rollback, reports).
- `.github/` holds the issue form, the [security policy](../.github/SECURITY.md), the tests workflow and Dependabot
  (which keeps the workflow's pinned actions current).
