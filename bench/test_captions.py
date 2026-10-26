# Offline check of the YouTube-style roll-up: lines fill up, scroll off the top, and lines already on screen
# never re-wrap when new text arrives. usage: python bench/test_captions.py
import importlib.util, os, sys, time, types

sys.modules["Plugins"] = types.SimpleNamespace(Base=object)
path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "Plugins", "subtitle_display_plugin.py")
spec = importlib.util.spec_from_file_location("sdp", path)
sdp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sdp)

measure = len  # 1 px per character
roll = lambda finals, live, anchor: sdp.roll_up(finals, live, anchor, 2, 20, measure)

lines, a = roll(["Now"], "come on", None)
assert lines == ["Now come on"], lines                      # short sentences share a line (no line per sentence)
lines, a = roll(["Now", "Come on"], "this is my specialty", a)
assert lines == ["Now Come on this is", "my specialty"], lines
f = ["Now", "Come on", "This is my specialty, the dribbling kick."]
lines, a = roll(f, "", a)
assert lines == ["my specialty, the", "dribbling kick."], lines  # scrolled up; earlier breaks kept
assert a == (f[2], 2), a
lines, a = roll(f[1:], "", a)                               # an old final expiring doesn't move the lines
assert lines == ["my specialty, the", "dribbling kick."], lines
lines, a = roll(f[1:], "Let's go", a)                       # new speech scrolls one line up
assert lines == ["dribbling kick.", "Let's go"], lines
lines, a = roll(f[1:], "A very long live line that keeps going on", a)
assert len(lines) == 2 and lines[-1].endswith("going on"), lines  # live text longer than 2 lines: newest shown
lines, a = roll([], "", None)
assert lines == [] and a is None
print("roll-up ok")

# Whisper's YouTube-outro hallucination is dropped whole, opener included; real speech before it is kept.
for raw, want in {"それでは、ご視聴ありがとうございました。": "", "はい、最後までご視聴ありがとうございました!": "",
                  "今日はゲームをしました。ご視聴ありがとうございました。": "今日はゲームをしました",
                  "この動画は、ご覧いただきありがとうございます。": "", "動画を最後までご覧くださりありがとうございました": "",
                  "ご覧ください": "ご覧ください", "ありがとうございます": "ありがとうございます",
                  "それでは始めます": "それでは始めます"}.items():
    assert sdp.strip_outro(raw) == want, (raw, sdp.strip_outro(raw))
print("outro ok")
for line in ("Thank you for watching this video!", "  THANKS for watching this video", "ご視聴ありがとうございました。", "You."):
    assert sdp.is_fake(line), line                             # fake-lines.txt: any case, spacing or punctuation
for line in ("Subtítulos realizados por la comunidad de Amara.org", "Субтитры сделал DimaTorzok",
             "请不吝点赞 订阅 转发 打赏支持明镜与点点栏目", "시청해주셔서 감사합니다"):
    assert sdp.is_fake(line), line                             # subtitle credits, in a line of any length
for line in ("Thank you for watching, now the agenda.", "ありがとうございました、先生", "", "...", "Thank you for the amazing demo"):
    assert not sdp.is_fake(line), line                         # only whole lines
print("fake lines ok")

# Spoken "Auto": translate from the language Whisper heard; a line already in the captions' language shows as said.
opts = {"current_language": "auto", "src_lang": "jpn_Jpan", "trg_lang": "eng_Latn"}
sys.modules["settings"] = types.SimpleNamespace(GetOption=opts.get)
p = sdp.SubtitleDisplayPlugin()
p.translator = types.SimpleNamespace(spoken=None)
p.translator._languages = lambda: sdp.PluginTranslator._languages(p.translator)
assert p._source_language({"language": "ko"}) == "kor_Hang" == p.translator.spoken
assert p._source_language({"language": "en"}) == "eng_Latn"  # English speech, English captions: shown as said
assert p._source_language({"language": "xx"}) == "eng_Latn"  # unknown: the last language heard
opts["current_language"] = "ja"                               # a picked language: never detected
assert p._source_language({"language": "en"}) == "jpn_Jpan"
print("auto language ok")

# The caption window stays where it was dragged, also on a second monitor; pulled back only when off the desktop.
two = (0, 0, 3840, 1080)                                       # two 1920x1080 monitors side by side
assert sdp.on_screen(2500, 978, 800, 90, two) == (2500, 978)
assert sdp.on_screen(2500, 978, 800, 90, (0, 0, 1920, 1080)) == (1120, 978)  # that monitor unplugged
assert sdp.on_screen(-50, -9, 800, 90, (-1920, 0, 3840, 1080)) == (-50, 0)    # left monitor: negative x is fine
print("position ok")

# Fillers: "uh" goes, real words stay (Portuguese "um" = "one", "Uhura"), a line that is only "uh" stays as said.
for said, shown in [("For some reason, there was something at the left-hand corner too, uh, I think it was from NMI.",
                     "For some reason, there was something at the left-hand corner too, I think it was from NMI."),
                    ("Well, uh, well, it's NMI.", "Well, well, it's NMI."),
                    ("There was something on the left-hand side too, uh uh", "There was something on the left-hand side too"),
                    ("Uh, what?", "What?"), ("Uhm. Okay.", "Okay."), ("Eu tenho um carro.", "Eu tenho um carro."),
                    ("Uhura is here.", "Uhura is here."), ("Uh...", "Uh..."), ("Hmm, what kind?", "Hmm, what kind?"),
                    ("- The staff...", "The staff..."), ("-5 degrees.", "-5 degrees.")]:  # NLLB's subtitle dash goes
    assert sdp.collapse_repeats(said) == shown, (said, sdp.collapse_repeats(said))
for said, filler in [("うーん", True), ("えーっと、あの…", True), ("まあ、うーん。", True), ("なんか", True),
                     ("うーん、そうですね", False), ("", False)]:
    assert sdp.is_filler(said) == filler, said
t = time.perf_counter()
assert not sdp.is_filler("うーん" * 2000 + "X")  # a looping hallucination: linear, not exponential
assert time.perf_counter() - t < 0.5
print("fillers ok")

# Every language the app lists has a Whisper code the plugin maps (spoken Auto) and a name MiLMMT knows.
import re
app = open(os.path.join(os.path.dirname(path), "..", "CaptionsApp.ps1"), encoding="ascii").read()
listed = re.findall(r'= "([a-z]{2})", "([a-z]{3}_[A-Z][a-z]{3})"', app.split("$languages = [ordered]@{", 1)[1].split("}", 1)[0])
assert len(listed) == 16, listed
for whisper, nllb in listed:
    assert whisper in sdp.WHISPER_TO_NLLB and nllb in sdp._LANGUAGE_NAMES, (whisper, nllb)
print("languages ok")

# A finished sentence stays on screen while its final translates: the live line's draft text becomes the finished
# line at once, the next sentence's live line goes below it, and the final's translation replaces it in place.
import threading
from collections import deque
p = sdp.SubtitleDisplayPlugin()
p.transcriptions, p.transcription_times, p._pending, p._display_lock = deque(maxlen=3), {}, {}, threading.RLock()
p._sources, p.originals = {}, {}
p.update_intermediate_label_text = lambda: None
sent = []
p.translator = types.SimpleNamespace(submit=lambda seq, text, final, src: sent.append(seq))
p._submit_translation("draft", False, "jpn_Jpan"); p._show_live(sent[-1], "The works of Kato")
p._submit_translation("final", True, "jpn_Jpan"); fin = sent[-1]
assert list(p.transcriptions) == ["The works of Kato"] and p.current_intermediate_transcription is None
p._submit_translation("next", False, "jpn_Jpan"); p._show_live(sent[-1], "It became")
p._show_final(fin, "The works of store manager Kato.")
assert list(p.transcriptions) == ["The works of store manager Kato."], p.transcriptions
assert p.current_intermediate_transcription == "It became" and not p._pending  # the next sentence's live line stays
p._submit_translation("short", True, "jpn_Jpan"); p._show_final(sent[-1], "Now.")  # replaces its draft "It became"
p._submit_translation("d", False, "jpn_Jpan"); p._show_live(sent[-1], "Come on")
p._submit_translation("f", True, "jpn_Jpan")
p._show_final(sent[-1], "Come on!")                                # from the good pass (Fast mode): in place too
assert list(p.transcriptions) == ["The works of store manager Kato.", "Now.", "Come on!"], p.transcriptions
shown = {t: p.originals.get(t) for t in p.transcriptions}  # Show original: each line's spoken text
assert shown == {"The works of store manager Kato.": "final", "Now.": "short", "Come on!": "f"}, shown
p._append_final("Four.")  # pushes the first line off the screen; scrolling back still has it, translated
assert list(p.history) == ["The works of store manager Kato.", "Now.", "Come on!", "Four."], p.history
p._submit_translation("g", True, "jpn_Jpan"); late = sent[-1]      # still translating when Stop is pressed
p._final_cut = p._drop_seq = p._seq; p._pending.clear(); p.originals.clear()  # what Stop does (set_paused)
p._submit_translation("h", False, "jpn_Jpan"); p._show_live(sent[-1], "After")
p._submit_translation("i", True, "jpn_Jpan"); new = sent[-1]
p._show_final(late, "Said before Stop.")                         # finishes after Start: never shown
p._show_final(new, "After Start.")                               # and doesn't take the new line's place
assert list(p.transcriptions)[-1] == "After Start." and "Said before Stop." not in p.history, p.history
assert "Said before Stop." not in p.originals and not p._sources, "a dropped line leaves nothing behind"
print("pending final ok")

# VRChat chatbox: each finished line goes to VRChat on this PC, never a draft, only with the switch on. In the app the
# engine's VRC_OSCLib sends it; here a stand-in puts each call on a local UDP socket.
import json, socket
rx = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
rx.bind(("127.0.0.1", 0))
rx.settimeout(2)
gaps = []
def chunks(data, chunk_size, delay, initial_delay, address, ip, port, **kw):
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as tx:
        tx.sendto(json.dumps([data, chunk_size, delay, address]).encode(), (ip, port))
sys.modules["VRC_OSCLib"] = types.SimpleNamespace(Chat_chunks=chunks, set_min_time_between_messages=gaps.append)
osc = {"osc_ip": "0", "osc_port": rx.getsockname()[1], "osc_address": "/chatbox/input", "osc_chat_limit": 144,
       "osc_min_time_between_messages": 1.5,  # the profiles' values; osc_ip 0 = the engine's own sending is off
       "audio_input_process": "VRChat.exe", "audio_input_device": ""}  # as captions.ps1 writes them for VRChat
sys.modules["settings"] = types.SimpleNamespace(GetOption=osc.get)
def final(text):
    p._submit_translation(text, True, "jpn_Jpan")
    p._show_final(sent[-1], text)
final("Switch off.")
p.chatbox = True
p._submit_translation("b", False, "jpn_Jpan"); p._show_live(sent[-1], "Hello th")  # a draft
final("Hello there.")
final("Hello there.")  # a looping segment: shown once, sent once
p._submit_translation("older", True, "jpn_Jpan"); older = sent[-1]
final("Newer.")
p._show_final(older, "Older.")  # finished after a newer line: the chatbox keeps the newest
osc["audio_input_process"] = "chrome.exe"; final("From a video.")  # Listen to changed, the engine not restarted yet
osc["audio_input_process"], osc["audio_input_device"] = "", "Speakers (Realtek) [Loopback]"; final("All PC sound.")
osc["audio_input_device"] = "Microphone (USB)"; final("Into the mic.")
p._chat("[music]")  # a sound tag: shown in the captions, never sent
got = []
rx.settimeout(0.3)
try:
    while True:
        got.append(json.loads(rx.recv(4096)))
except socket.timeout:
    pass
assert [g[0] for g in got] == ["Hello there.", "Newer.", "Into the mic."], got
assert got[0][1:] == [144, 1.5, "/chatbox/input"] and set(gaps) == {1.5}, (got, gaps)
p.chatbox = False
rx.close()
print("chatbox ok")

# The live line shows only what two drafts in a row agree on, cut at a word's end (anywhere in CJK text).
assert sdp.agreed_start("I want to go", "I want to gather") == "I want to"
assert sdp.agreed_start("I want", "I wanted it") == "I"
assert sdp.agreed_start("今日は天気", "今日は電気") == "今日は"
assert sdp.agreed_start("", "first draft") == ""
assert sdp.agreed_start("good evening.", "Good evening, everyone.") == "Good evening"  # case, punctuation: the newest
assert sdp.agreed_start("I'm gonna...", "I'm gonna die.") == "I'm gonna"
assert sdp.agreed_start("I'm", "I am") == ""                                          # "I" of "I'm" isn't a word
assert sdp.agreed_start("12 people", "120 people") == ""
assert sdp.agreed_start("今日は、天気", "今日は天気が") == "今日は天気"
assert sdp.agreed_start("Let's look at it.", "Let's look at it.", 1) == "Let's look at"
assert sdp.agreed_start("Hi", "Hi", 1) == "" and sdp.agreed_start("I'm", "I'm", 2) == ""
p = sdp.SubtitleDisplayPlugin()
p.is_enabled = lambda default: True
shown = []
p.update_label = lambda text, result, is_final: shown.append((text, result["text"], is_final))
for draft in ("Look at", "Let's look at the", "Let's look at the cat", "Let's look at the cat", "Let's look at the cat"):
    p.stt_intermediate(draft, {"text": draft})
assert [t for t, _, _ in shown] == ["Look", "Let's look at", "Let's look at the", "Let's look at the cat"], shown
p.stt("Let's look at the cats.", {"text": "Let's look at the cats."})
p.stt_intermediate("Next", {"text": "Next"})  # a new sentence's first word waits for the next draft
for draft in ("今日はいい天気", "今日はいい天気です"):  # CJK on GPU: one draft less 3 characters
    p.stt_intermediate(draft, {"text": draft})
assert [t for t, _, _ in shown[-2:]] == ["今日はい", "今日はいい天気"], shown  # then two agree
p.stt("", {})
sys.modules["settings"] = types.SimpleNamespace(GetOption=lambda name: "cpu" if name == "ai_device" else None)
for draft in ("今日は", "今日は天気", "今日は天気です"):  # CJK on CPU: only what two drafts agree on
    p.stt_intermediate(draft, {"text": draft})
assert [t for t, _, _ in shown[-2:]] == ["今日は", "今日は天気"], shown
del sys.modules["settings"]
p.stt("Let's look at the cats.", {"text": "Let's look at the cats."})
assert shown[-1] == ("Let's look at the cats.", "Let's look at the cats.", True), shown
print("live line agreement ok")
