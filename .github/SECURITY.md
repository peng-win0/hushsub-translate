# Security policy

## Supported versions

Only the latest release gets fixes. With **Update automatically** on (the default), the app installs it by itself.

## Reporting a problem

Please report security problems privately: on this repository's **Security** tab, choose **Report a vulnerability**.
Don't open a public issue for them. Include the version (App page, About) and the steps to reproduce.
You can expect a first answer within a week.

## What the app does and doesn't do

These are the design rules a report can be checked against:

- Audio and captions are processed in memory on the PC. Nothing is recorded or sent anywhere.
- Nothing listens on a network port: the engine's websocket server and its OSC link are off.
- The only connections are the downloads and update checks listed under [Privacy](../README.md#privacy) in the README.
- Updates come only from this repository's GitHub releases. `app/update.ps1` checks the release's version and
  scripts before it replaces any file, and keeps the old files in `.update-backup`.
- The app runs without administrator rights and installs nothing system-wide. The engine, the models and the
  settings live in its own folder, plus the desktop and Start menu shortcuts if you add them.
