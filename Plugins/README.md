# The caption plugin

`subtitle_display_plugin.py` is the part of Hushsub Translate that runs inside the Whispering Tiger engine. The
engine's speech recognizer, Whisper, writes down each line it hears. For each line, the plugin:

- swaps in your words (`app/glossary.txt`) and drops lines Whisper made up (`app/fake-lines.txt`);
- translates the line on the graphics card (CPU mode: the processor) with the mode's model;
- draws it over the screen in the style set in the app.

Captions stay in memory only: the last 1,000 lines, for scrolling back, gone when captions stop.

The engine loads every `.py` file in this folder when it starts, and each mode's profile in `app/Profiles/` turns this
one on (`SubtitleDisplayPlugin: true`). It runs on the engine's own Python 3.11. The engine calls `stt_caption`,
`streaming_caption_text`, `on_enable` and `on_disable` by name.

The tests in `bench/` load it without the engine (`test_captions.py`, `test_overlay.py`, `test_translator.py`). A
benchmark run puts a temporary `zz_*.py` file here; git ignores it.

This README is on GitHub only: the download leaves it out (`.gitattributes`).
