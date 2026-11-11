# Runbook

What to do for the jobs that come up while maintaining the app. What the app does is in the [README](../README.md),
and how it is built is in [details.md](details.md).

## Before any change

Run the offline tests and the lint. They are the same ones CI (the GitHub Actions workflow) runs on every push. They
take about 25 s and need no engine, graphics card or network:

```
python bench/test_captions.py
python bench/test_translator.py
python bench/test_overlay.py
powershell -NoProfile -ExecutionPolicy Bypass -File bench/test_log_privacy.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File bench/test_update.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File bench/test_compat.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File bench/test_exe.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File bench/test_app.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File bench/test_zip.ps1
ruff check Plugins bench
```

CI pins ruff 0.17.3. If you don't have it installed, `uvx ruff@0.17.3 check Plugins bench` runs that same version (it
downloads ruff the first time).

Scripts must parse in Windows PowerShell 5.1 and be plain ASCII; CI checks both. The plugin runs on the engine's
Python 3.11.

## Release

1. Raise `version.txt` (`X.Y.Z`) in the commit that finishes the release, with the change in the subject line
   (`1.4.18: Fast mode never shows a line said before Stop`).
2. Push to `main` and wait for the Tests workflow to pass.
3. Tag the commit `vX.Y.Z` and publish a GitHub release for the tag, with short notes. It needs no files: the app's
   updater downloads the tag's source ZIP, which `.gitattributes` keeps free of `bench/`, `docs/` and the dev files.
4. Every copy with Update automatically on installs it the next time the app opens, or within a day if the app stays
   open (once no captions run). Before it replaces a file, the updater checks the version and that every script
   parses.

If `app/launcher.cs` changed, raise its `AssemblyVersion` too: the app rebuilds `Hushsub Translate.exe` only then.

## A bad release

- **For everyone:** publish a new, higher version with the fix or the previous code. The updater never goes back to a
  lower version, so deleting the release doesn't undo it for copies that already updated.
- **For one PC, now:**
  1. Turn off Update automatically and close the app.
  2. Download the previous release's source ZIP from GitHub.
  3. Copy what is inside its top folder over the app's folder, except `app\glossary.txt` and `app\fake-lines.txt`,
     which hold the user's own words. The engine, models and settings aren't in the ZIP, so they stay.

  Files the bad release added stay too; they do nothing unless the old code uses them. A good update keeps no backup:
  `.update-backup\` stays only after a failed one, whose files are already restored.

## A problem report

Report on GitHub (under Send feedback) fills the issue form with the version, graphics card, mode and settings. It
never includes captions, names or paths. Ask for Show log next: `.captions-log` has the engine's status lines, never
what was said. Most reports match one of the README's troubleshooting entries.

## A new engine or model

- **Engine:** change the mirrors and `$sha256` (the SHA-256 of the engine's ZIP) in `app/install.ps1`. Then try each
  mode on a PC with an NVIDIA card and on one without.
  - Check that the plugin's hooks (`stt_caption`, `streaming_caption_text`) still exist, and the profile keys that
    `app/captions.ps1` and `CaptionsApp.ps1` write.
  - Run `node bench/osv.mjs` (it sends only package names and versions to OSV.dev) and update the counts in
    `docs/details.md`, "Known issues in the engine's libraries".
- **A model:** change its entry (`File`, `Size`, `Sha`) at the top of `app/captions.ps1`. First, measure it against
  the current one with the kit in `bench/`.

## CI fails

Run the failing step's command locally (see above). If only CI fails, compare its Python (3.11) and PowerShell (5.1)
with yours. Dependabot opens a pull request each month for the pinned actions: merge it once its checks pass.
