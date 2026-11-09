# The app's files

The scripts and files the app runs by itself. `CaptionsApp.ps1`, one folder up, is the window that starts them. How
they fit together: [How it works](../docs/details.md#how-it-works).

| File | What it is |
|---|---|
| `install.ps1` | Downloads the Whispering Tiger engine on the first start and checks it against its SHA-256 hash. |
| `captions.ps1` | Runs the engine: downloads the mode's models, finds the audio, starts it again after a crash. |
| `update.ps1` | Installs a newer GitHub release, with **Update automatically** on or after **Check for updates**. |
| `launcher.cs` | Source of `Hushsub Translate.exe`, which the app builds with Windows' C# compiler. |
| `Profiles/` | The engine's settings for each mode: Accurate, Balanced, Fast, Lite and CPU. The engine rewrites its profile on start, so close it before editing one. |
| `glossary.txt` | Your words, `term = what to translate instead`. Edited in the app under **Your words**. |
| `fake-lines.txt` | Lines Whisper makes up during silence or music, like "Thanks for watching". A caption that is exactly one of them is dropped. |
| `fonts/` | Google Sans Flex, the app's font, and its license (`OFL.txt`). |
| `icon.ico` | The app's icon. |

An update merges `glossary.txt` and `fake-lines.txt`, so lines the user added stay.

This README is on GitHub only: the download leaves it out (`.gitattributes`).
