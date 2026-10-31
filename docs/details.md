# Hushsub Translate: details

Everything the [README](../README.md) leaves out: graphics cards, every setting, measurements, using it at work and
how it works.

## Graphics cards

| Graphics card | Works? |
|---|---|
| RTX 30, 40, 50 series | Yes, all modes, as measured below. |
| RTX 20, GTX 16 series | Should work, somewhat slower. These cards have no bfloat16, so translation uses int8 + float32. Auto steps down if it is too slow. |
| GTX 10 series | Should work, slower still: no fast float16 either. |
| GTX 900 or older, AMD, Intel, none | CPU mode on the processor. The graphics card modes need NVIDIA CUDA with int8 support. |

Only an RTX 4060 has been measured. Reports from other cards are welcome: open an issue and paste the app's log
(**Show log**, then **Copy**).

## Settings

The window has two pages.

- **Captions**
  - **Languages:** what is spoken (**Spoken**) and what the captions are in (**Captions in**): English, Chinese (simplified
    or traditional), Spanish, French, Portuguese, Russian, Indonesian, German, Japanese, Vietnamese, Turkish, Korean,
    Italian, Polish, Dutch, Azerbaijani, Bulgarian, Catalan, Croatian, Danish, Finnish, Hebrew, Hungarian, Kazakh,
    Norwegian, Slovak, Slovenian, Swedish or Tagalog. Each has at most the recognition error rate of Russian, the
    weakest of the first fifteen, on FLEURS test speech. Picking the same language twice shows what is said, untranslated. Japanese → English is what everything is tuned and measured for: the filters
    and Fast mode's second pass.
    - **Auto** under Spoken detects each line's language, for audio that mixes languages. Picking the language is
      better when you know it: on Japanese, Auto made ~4 points more recognition errors and was ~0.4 s slower.
    - **Auto** under Captions uses your Windows display language, or English if the app doesn't have it.
  - **Show original:** off by default. On, a small row above the captions shows what was said in the newest finished
    line: one row in the scroll hint's font, its end if it is too long. Scrolling back shows it above each line. Kept in
    memory only, like the lines themselves, and gone at Stop.
  - **VRChat chatbox:** off by default, shown only when **Listen to** is VRChat or Microphone. On, each finished line
    goes to VRChat's OSC input on this PC (`127.0.0.1`, the profile's `osc_port` 9000 and `osc_address`), split into
    `osc_chat_limit` (144) characters, `osc_min_time_between_messages` (1.5 s) apart, by the engine's own
    `VRC_OSCLib`. Drafts are never sent. If VRChat isn't running the messages go nowhere and the captions carry on.
  - **Live line:** off by default: captions show finished sentences only, never words that then change. Turn it on
    to see words as they're spoken. It leaves out the newest word (Japanese, Chinese and Korean: the last 3
    characters), the one Whisper most often rewrites as it hears more, unless two updates in a row agree on it. On
    the processor, Japanese, Chinese and Korean show only what two updates agree on. The newest words may still
    change as the sentence goes on. On the bench (characters right; English: how long after a word is said it
    shows, median; Japanese: the wait added before a sentence's first words):

    | | Graphics card | Processor |
    |---|---|---|
    | English (computer voices) | 97.5%, 0.8 s (every update shown: 96.9%) | 98.6%, 3.5 s (98.1%) |
    | Japanese (finished lines: 79.5% / 64%) | 86%, +0.4 s (83%) | 77-80%, +2 s (73%) |
  - **Caption style:** YouTube's options, with the same choices and defaults: font family, color, size (50–400%) and
    opacity, background and window color and opacity, and character edge style. Its nine options open with **Show options**. Changes show right away, also
    while captions are on. **Reset** goes back to YouTube's defaults. To move the captions, drag them
    anywhere. They stay there in every mode and after updates, and clicking them never takes the keyboard from
    the video or game below. To read lines you missed, scroll the mouse wheel
    over the captions; scroll down or click them to go back to live captions (also after 15 seconds by itself).
    The last 1,000 lines are kept in memory only and are gone when captions stop.
  - **Your words:** names and terms the captions get wrong, one per line as `heard = shown`
    (`マリア = Maria`). **Save** applies them from the next line, also while captions are on. They are kept in
    `app/glossary.txt` on this PC only. **Delete all** removes them.
- **App**
  - **Theme:** Dark (the default), Light, or System to follow Windows. Windows contrast themes always use their own colors.
  - **Listen to:** **Auto** listens to the browser that is open when you press Start, or your default browser if
    none or several are open. Brave, Chrome, Edge, Firefox, Opera (also Opera GX) and Vivaldi are listed; with another default browser, Auto
    listens to all PC sound. Pick one if the audio plays in another browser. **VRChat**, **Discord**, **Zoom**,
    **Teams** and **VLC** caption only that app's sound (a YouTube app installed from the browser plays in its
    browser). Captions begin when the app opens. **All PC sound** captions everything
    the PC plays on its default speakers or headphones (a meeting app, a video player, notification sounds too), like
    Windows Live Captions. When Windows switches speakers, captions restart on the new ones by themselves (under a minute).
  - **Update automatically:** see [Privacy](../README.md#privacy).
  - **GPU use:** keep it on **Auto**.
  - **Downloaded models:** each model's size and the modes that use it. **Remove** deletes a model, or the part downloaded so far.
  - **About:** the version, **Privacy**, **Terms** (each part's license), **Help** (this guide) and **Send feedback**:
    a GitHub problem report with your version, Windows, graphics card and mode filled in, never captions or file paths.

## Measurements

Delays and memory were measured on an RTX 4060 Laptop (8 GB). The Japanese recognition error rate is ~20.5% in every
graphics card mode. CPU was measured on a Ryzen 7 7840HS (8 cores): a finished line is ready ~2.8 s after the speech ends and in
English ~0.5 s later; recognition errors ~36% (Lite ~25% on the same clips). Processors with fewer cores take longer.

Disk, measured on the bench PC with every mode used once (2026-10-24):

| What | Size |
|---|---|
| Engine (`audioWhisper\`, Whispering Tiger 1.3.20.1) | 8.8 GB |
| of which PyTorch | 4.6 GB, ~3.0 GB of it NVIDIA's CUDA libraries (cuDNN, cuBLAS, ...) |
| of which other CUDA kernels (`flash_attn`, `selective_scan`) | 0.9 GB |
| of which OCR, Japanese dictionaries, ONNX Runtime and the rest | 3.3 GB |
| Speech models: Whisper large-v3-turbo / small | 1.5 / 0.5 GB |
| Translation models: MiLMMT-46-4B / 1B, NLLB-600M, LFM2 | 3.7 / 2.0, 2.4, 0.7 GB |

A mode downloads only its own models, so the 20 GB in the README is the engine plus the largest mode, with room to
spare. About 3.9 GB of the engine is CUDA. That is the part a planned new core would replace. The
engine comes as one prebuilt package from Whispering Tiger, so until then nothing in it is trimmed.

## Using it at work

- **Data stays on the PC.** Audio is processed in memory; nothing is uploaded or saved (see [Privacy](../README.md#privacy)). The
  log (`.captions-log`) holds the engine's status lines, never what was said, and is replaced each time the engine starts. Once the models are downloaded and
  **Update automatically** is off, the app works offline.
- **No administrator rights, nothing installed system-wide.** The engine, the models and the settings
  (`app-settings.json`) live in the app's folder: `%LOCALAPPDATA%\Programs\Hushsub Translate`, or where you extracted the ZIP. To
  uninstall, delete that folder and the app's shortcuts (Start menu, and the desktop if you added one).
- **PCs where IT restricts apps (AppLocker or App Control for Business).** The engine is not code-signed, so IT has to
  allow the app's folder (a path or hash rule); until then it can't start. Scripts allowed that way run normally. The
  app writes its settings, log and models into that folder, so users need write access to it.
- **Setting it up on several PCs.** The folder is portable: install it once, start captions once in each mode you
  want (this downloads its models), then copy the whole folder. To keep every copy on the version you tested, put
  `{"autoUpdate": false}` in `app-settings.json` before copying.
- **Managing updates centrally.** To turn updates off so users can't turn them back on, set the DWORD
  `DisableUpdates` = `1` under `HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Hushsub Translate` (Group Policy Preferences or
  Intune; the key's name before 1.5.0, `Private Captions`, still works). The app then never contacts GitHub, and its update switch shows "Updates are managed by your organization."
- **Verified downloads.** The engine and every model are checked against a SHA-256 hash pinned in the scripts
  before they are used, and LFM2 is pinned to one Hugging Face commit, so a changed or damaged file on a server is
  rejected. Updates come only from this repository's GitHub releases, over HTTPS.
- **Known issues in the engine's libraries.** The engine (v1.3.20.1) bundles CTranslate2 4.7.1, which has two
  model-loading flaws fixed in 4.8.1: [CVE-2026-102566](https://nvd.nist.gov/vuln/detail/CVE-2026-102566) (heap
  overflow, CVSS 7.8) and [CVE-2026-102567](https://nvd.nist.gov/vuln/detail/CVE-2026-102567) (out-of-bounds read,
  CVSS 6.1). Both need a crafted model file. The app loads only the hash-checked models above (MiLMMT is converted
  from its checked download on the PC), so they are out of reach unless someone can already write to the app's
  folder, and could then replace the engine itself. The engine's libraries are updated by Whispering Tiger's
  releases; the app moves to a new engine release once it has been tested.
- **Model licenses.** For business use, pick **Balanced** or **Accurate** (a GPU use % that gives one, on cards with
  6 GB or more). Fast, Lite and CPU use NLLB-200, which is licensed for non-commercial use only. The app itself is
  MIT-licensed. Check each license below with your legal team.

| Model | Used by | License |
|---|---|---|
| Whisper large-v3-turbo, small | All modes (small: CPU) | MIT |
| MiLMMT-46 (1B, 4B) | Balanced, Accurate | Gemma Terms of Use |
| NLLB-200 600M | Fast, Lite, CPU | CC-BY-NC 4.0: non-commercial only |
| LFM2-350M-ENJP-MT | Fast | LFM Open License v1.0: commercial use for organizations under $10M yearly revenue |
| Silero VAD 6 (voice detector) | All modes | MIT |

The engine's download also brings ffmpeg 5.1.2 (a GPLv3 build, `toolchain/ffmpeg/LICENSE`), which decodes the captured
audio. GPL obligations apply only when redistributing it.

## How it works

The [Whispering Tiger](https://github.com/Sharrnah/whispering) engine (v1.3.20.1) captures the browser's audio (or the speakers' loopback, or the microphone) and
transcribes it with Whisper large-v3-turbo (small in CPU mode). It decodes the audio with the ffmpeg its download
brings along. `Plugins/subtitle_display_plugin.py` translates each line on the GPU (CPU mode: the processor) and
draws the overlay.

| File | Purpose |
|---|---|
| `Hushsub Translate.bat` | Opens the app (the .exe once it exists). |
| `CaptionsApp.ps1` | The app window. |
| `Plugins/` | The plugin above; the engine loads it from here. |
| `app/launcher.cs` | Source of `Hushsub Translate.exe`, which the app builds on its first start and after an update changes it. The .exe runs `CaptionsApp.ps1` inside itself, so Windows shows Hushsub Translate, not PowerShell. |
| `app/install.ps1` | Downloads and checks the engine. |
| `app/captions.ps1` | Runs the engine: downloads the mode's models, waits for the browser, speakers or microphone, restarts after a crash. |
| `app/update.ps1` | Installs a newer GitHub release (`version.txt`) after checking its version and scripts. |
| `app/Profiles/*.yaml` | Engine settings for Accurate, Balanced, Fast, Lite and CPU. The engine rewrites its profile on start, so close it before editing one. |
| `app/glossary.txt` | Names and terms the translator or speech recognition gets wrong (for example product or team names), swapped in before translation, in every spoken language. Edit it under **Your words**; used from the next line. |
| `app/fake-lines.txt` | Lines Whisper makes up during silence or music, like "Thanks for watching". A caption that is exactly one of them is dropped. Add your own. |
| `app/fonts/` | Google Sans Flex, the app's font. |

**Development.** These are in the repository but not in the download:

- `bench/` has the benchmark kit (`sh bench/bench.sh NAME:profile`) and the tests: `python bench/test_captions.py`,
  `python bench/test_overlay.py`, `python bench/test_translator.py`, `powershell -File bench/test_update.ps1`,
  `powershell -File bench/test_log_privacy.ps1`, `powershell -File bench/test_compat.ps1`,
  `powershell -File bench/test_exe.ps1`, `powershell -File bench/test_app.ps1` (builds the app window offscreen) and
  `powershell -File bench/test_zip.ps1` (installing from the ZIP).
  None needs the engine, a GPU or the network; GitHub Actions runs them on every push, on Python 3.11 like the engine
  (`.github/workflows/tests.yml`, which also checks that every script parses and is plain ASCII, and lints the Python
  with `ruff check Plugins bench`, see `ruff.toml`).
  `python bench/live_accuracy.py bench/out/NAME.jsonl` scores a bench run's live line as the overlay shows it;
  `python bench/english.py` makes English test audio for it with the Windows voices, and with
  `--words bench/out/english.words.json` it also tells how long after each word is said it is on screen.
  `sh bench/langs.sh` measures recognition per language on Google's FLEURS read-speech clips (`bench/fleurs.py`
  fetches 12 per language), ~6 min a language; run it again after a stop and it goes on where it stopped.
- `docs/` holds the README images, this page and the [runbook](runbook.md) (releases, rollback, reports); `.github/` the issue form, the [security policy](../.github/SECURITY.md), the tests
  workflow and Dependabot (keeps the workflow's pinned actions current).
