# Security policy

## Supported versions

Only the latest release gets fixes. With **Update automatically** on (the default), the app installs it by itself.

## Reporting a problem

Please report security problems privately: on this repository's **Security** tab, choose **Report a vulnerability**.
Don't open a public issue for them. Include the version (App page, About) and the steps to reproduce.
You can expect a first answer within a week.

## What the app does and doesn't do

These are the design rules a report can be checked against:

- Audio and captions are processed in memory on the PC. Nothing is recorded. Nothing is sent anywhere, except with
  the **VRChat chatbox** switch on: then each translated line goes to VRChat on the same PC (`127.0.0.1:9000`).
- Nothing listens on a network port: the engine's websocket and OSC servers are off. The chatbox only sends.
- The only connections are the downloads and update checks listed under [Privacy](../README.md#privacy) in the README.
- Updates come only from this repository's GitHub releases. `app/update.ps1` checks the release's version and
  scripts before it replaces any file, and puts every old file back if one can't be replaced.
- The app runs without administrator rights and installs nothing system-wide. The engine, the models and the
  settings live in its own folder, plus its Start menu shortcut and, if you add it, a desktop one.
