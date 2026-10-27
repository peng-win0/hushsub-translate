# ============================================================
# Subtitles Display Plugin for Whispering Tiger
# V1.0.13
# See https://github.com/Sharrnah/whispering-ui
# ============================================================
#
import Plugins
import tkinter as tk
import tkinter.font as tkfont
import json
import os
import re
import shutil
import threading
import queue
import time
import traceback
from collections import deque

# torch.hub asks github.com for the voice detector's default branch on each load, even with the model cached: a
# privacy leak and, offline, a ~2 s stall that drops audio. Use the cached copy when there is one. (The engine's
# loads come after this file is imported: measured, no connection once the model is downloaded.)
try:
    import torch.hub as _hub
    _parse_repo_info = _hub._parse_repo_info

    def _local_first(github):
        if ":" not in github and github.count("/") == 1:
            owner, name = github.split("/")
            for ref in ("main", "master"):
                if os.path.isdir(os.path.join(_hub.get_dir(), f"{owner}_{name}_{ref}")):
                    return owner, name, ref
        return _parse_repo_info(github)
    _hub._parse_repo_info = _local_first
except Exception:
    pass

MAX_SCREEN_LINES = 2  # YouTube-style: never show more than this many wrapped lines
# Scrolling back: the wheel over the captions shows earlier lines. The last HISTORY_LINES finished lines (about an
# hour) are kept in memory only, never on disk, and gone when the captions stop. After HISTORY_IDLE seconds without
# scrolling, the live captions come back by themselves.
HISTORY_LINES = 1000
HISTORY_IDLE = 15
HISTORY_HINT = "Earlier captions: scroll down or click for live"

# Fast translator for the live line (NLLB-600M, CTranslate2 format), used when the engine sends untranslated text.
FAST_MODEL_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".cache", "nllb200_ct2", "small")
_NLLB_CODE = re.compile(r"^[a-z]{3}_[A-Z][a-z]{3}$")
# Second-pass translator for Japanese<->English only (LFM2-350M-ENJP-MT, ~0.7 GB, downloaded on first use).
# Measured 2026-09-28 on stream-style lines: NLLB drops half of many sentences, LFM2 keeps them (MiLMMT is
# better still). Too slow for the live line under load (~0.8 s), so it only re-translates finals.
LFM2_REPO = "LiquidAI/LFM2-350M-ENJP-MT"
LFM2_REVISION = "80367784d525777ad7565b24534ba5810eeac59f"  # the benchmarked commit: a changed repo can't swap the model
LFM2_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".cache", "lfm2_enjp", "LFM2-350M-ENJP-MT")
_LFM2_PROMPTS = {"eng_Latn": "Translate to English.", "jpn_Jpan": "Translate to Japanese."}
# MiLMMT-46-1B (the engine's best translator) converted to CTranslate2: same translations as the engine's
# transformers version, ~0.26 s instead of ~1.3 s per line (2026-09-28), fast enough for the live line.
# Converted once from the engine's download in .cache/milmmt.
MILMMT_HF_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".cache", "milmmt", "MiLMMT-46-1B-v1.0")
MILMMT_CT2_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".cache", "milmmt_ct2", "MiLMMT-46-1B-v1.0")
MILMMT4B_HF_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".cache", "milmmt", "MiLMMT-46-4B-v1.0")
MILMMT4B_CT2_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".cache", "milmmt_ct2", "MiLMMT-46-4B-v1.0")
_MILMMT_FILES = ["tokenizer.json", "tokenizer_config.json", "special_tokens_map.json", "tokenizer.model",
                 "added_tokens.json", "generation_config.json"]
_LANGUAGE_NAMES = {"jpn_Jpan": "Japanese", "eng_Latn": "English", "kor_Hang": "Korean", "zho_Hans": "Chinese (Simplified)",
                   "zho_Hant": "Chinese (Traditional)", "ind_Latn": "Indonesian", "spa_Latn": "Spanish",
                   "por_Latn": "Portuguese", "fra_Latn": "French", "deu_Latn": "German", "rus_Cyrl": "Russian",
                   "vie_Latn": "Vietnamese", "tur_Latn": "Turkish", "ita_Latn": "Italian", "pol_Latn": "Polish",
                   "nld_Latn": "Dutch", "arb_Arab": "Arabic", "azj_Latn": "Azerbaijani", "bul_Cyrl": "Bulgarian",
                   "ben_Beng": "Bengali", "cat_Latn": "Catalan", "ces_Latn": "Czech", "dan_Latn": "Danish",
                   "ell_Grek": "Greek", "pes_Arab": "Persian", "fin_Latn": "Finnish", "heb_Hebr": "Hebrew",
                   "hin_Deva": "Hindi", "hrv_Latn": "Croatian", "hun_Latn": "Hungarian", "kaz_Cyrl": "Kazakh",
                   "khm_Khmr": "Khmer", "lao_Laoo": "Lao", "zsm_Latn": "Malay", "mya_Mymr": "Burmese",
                   "nob_Latn": "Norwegian", "ron_Latn": "Romanian", "slk_Latn": "Slovak", "slv_Latn": "Slovenian",
                   "swe_Latn": "Swedish", "tam_Taml": "Tamil", "tha_Thai": "Thai", "tgl_Latn": "Tagalog",
                   "urd_Arab": "Urdu", "uzn_Latn": "Uzbek", "yue_Hant": "Cantonese"}  # every MiLMMT-46 language, its names
# Spoken "Auto" (profile current_language: auto): Whisper's detected language -> the translator's code
WHISPER_TO_NLLB = {"ja": "jpn_Jpan", "en": "eng_Latn", "ko": "kor_Hang", "zh": "zho_Hans", "id": "ind_Latn",
                   "es": "spa_Latn", "pt": "por_Latn", "fr": "fra_Latn", "de": "deu_Latn", "ru": "rus_Cyrl",
                   "vi": "vie_Latn", "tr": "tur_Latn", "it": "ita_Latn", "pl": "pol_Latn", "nl": "nld_Latn",
                   "ar": "arb_Arab", "az": "azj_Latn", "bg": "bul_Cyrl", "bn": "ben_Beng", "ca": "cat_Latn",
                   "cs": "ces_Latn", "da": "dan_Latn", "el": "ell_Grek", "fa": "pes_Arab", "fi": "fin_Latn",
                   "he": "heb_Hebr", "hi": "hin_Deva", "hr": "hrv_Latn", "hu": "hun_Latn", "kk": "kaz_Cyrl",
                   "km": "khm_Khmr", "lo": "lao_Laoo", "ms": "zsm_Latn", "my": "mya_Mymr", "no": "nob_Latn",
                   "ro": "ron_Latn", "sk": "slk_Latn", "sl": "slv_Latn", "sv": "swe_Latn", "ta": "tam_Taml",
                   "th": "tha_Thai", "tl": "tgl_Latn", "ur": "urd_Arab", "uz": "uzn_Latn", "yue": "yue_Hant"}
# Caption style picked in the app (CaptionsApp.ps1): size %, color, background %. Re-read when the file changes.
APP_SETTINGS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "app-settings.json")
# YouTube's caption options, same names and values as in the app
CAPTION_COLORS = {"White": "#FFFFFF", "Yellow": "#FFFF00", "Green": "#00FF00", "Cyan": "#00FFFF", "Blue": "#0000FF",
                  "Magenta": "#FF00FF", "Red": "#FF0000", "Black": "#080808"}
CAPTION_FONTS = {"Proportional Sans-Serif": ("Roboto", "Arial"), "Monospaced Sans-Serif": ("Lucida Console", "Consolas"),
                 "Proportional Serif": ("Times New Roman",), "Monospaced Serif": ("Courier New",),
                 "Casual": ("Comic Sans MS",), "Cursive": ("Monotype Corsiva", "Segoe Script"), "Small Capitals": ("Arial",)}


def edge_copies(edge, u):
    """(dx, dy, color) copies drawn under the text for YouTube's character edge styles, u = offset in pixels."""
    h = max(1, u // 2)
    dark, light = "#222222", "#CCCCCC"
    return {"Drop Shadow": [(u, u, dark)],
            "Raised": [(-h, -h, light), (h, h, dark)],
            "Depressed": [(h, h, light), (-h, -h, dark)],
            "Outline": [(dx * u, dy * u, dark) for dx in (-1, 0, 1) for dy in (-1, 0, 1) if dx or dy]}.get(edge, [])
# Median translation time of recent lines, read by CaptionsApp.ps1 (Auto steps down a mode if this GPU is too slow).
STATS_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".captions-stats")
# Where the user dragged the captions: one place for every mode, and kept by app updates (which replace the profiles).
POSITION_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".captions-position")
# The app's Stop: while this file exists the captions hide and the engine doesn't listen (its models stay loaded)
PAUSE_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".captions-paused")
# Held by the app window while it's open (CaptionsApp.ps1). A paused engine whose app was killed or crashed closes
# itself: nothing else would, and it holds GBs of GPU memory while nothing shows.
APP_MUTEX = "Local\\PrivateCaptionsApp"
APP_CHECK_TICKS = 125  # every ~2 s while paused


def desktop(root):
    """(left, top, width, height) of the whole desktop, every monitor; Tk only knows the main one."""
    try:
        import ctypes
        metric = ctypes.windll.user32.GetSystemMetrics
        left, top, width, height = (metric(i) for i in (76, 77, 78, 79))  # SM_XVIRTUALSCREEN ... SM_CYVIRTUALSCREEN
        if width > 0 and height > 0:
            return left, top, width, height
    except Exception:
        pass
    return 0, 0, root.winfo_screenwidth(), root.winfo_screenheight()


def no_focus(window):
    """Clicking, dragging or scrolling the captions must not take the keyboard from the video or game below them
    (YouTube's keys stopped working, a full-screen game could minimize): Windows' WS_EX_NOACTIVATE."""
    try:
        import ctypes
        user32 = ctypes.WinDLL("user32")
        user32.GetParent.restype = ctypes.c_void_p
        user32.GetParent.argtypes = [ctypes.c_void_p]
        user32.GetWindowLongW.argtypes = [ctypes.c_void_p, ctypes.c_int]
        user32.SetWindowLongW.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_long]
        window.update_idletasks()
        hwnd = user32.GetParent(window.winfo_id()) or window.winfo_id()  # Tk's frame window around the canvas
        user32.SetWindowLongW(hwnd, -20, user32.GetWindowLongW(hwnd, -20) | 0x08000000)  # GWL_EXSTYLE
    except (AttributeError, OSError):
        pass  # not Windows


def app_open():
    """False once the app window's process is gone (closed or crashed): its mutex goes with it."""
    try:
        import ctypes
        kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
        kernel32.OpenMutexW.restype = ctypes.c_void_p
        kernel32.OpenMutexW.argtypes = [ctypes.c_uint32, ctypes.c_int, ctypes.c_wchar_p]
        kernel32.CloseHandle.argtypes = [ctypes.c_void_p]
    except (AttributeError, OSError):
        return True  # not Windows
    handle = kernel32.OpenMutexW(0x00100000, False, APP_MUTEX)  # SYNCHRONIZE
    if handle:
        kernel32.CloseHandle(handle)
        return True
    return ctypes.get_last_error() != 2  # ERROR_FILE_NOT_FOUND: no app; any other error: assume it's there


def close_console():
    """Closes this engine's console as the app's Stop does (its X): captions.ps1 and the engine exit gracefully."""
    import ctypes
    user32, kernel32 = ctypes.WinDLL("user32"), ctypes.WinDLL("kernel32")
    kernel32.GetConsoleWindow.restype = ctypes.c_void_p
    user32.PostMessageW.argtypes = [ctypes.c_void_p, ctypes.c_uint, ctypes.c_void_p, ctypes.c_void_p]
    console = kernel32.GetConsoleWindow()
    if console:
        user32.PostMessageW(console, 0x0010, None, None)  # WM_CLOSE


def show_window(window, show):
    """Hides or shows a window without activating it (Tk's deiconify would take the keyboard from the video)."""
    try:
        import ctypes
        user32 = ctypes.WinDLL("user32")
        user32.GetParent.restype = ctypes.c_void_p
        user32.GetParent.argtypes = [ctypes.c_void_p]
        user32.ShowWindow.argtypes = [ctypes.c_void_p, ctypes.c_int]
        user32.ShowWindow(user32.GetParent(window.winfo_id()) or window.winfo_id(), 8 if show else 0)  # SW_SHOWNA, SW_HIDE
    except (AttributeError, OSError):
        (window.deiconify if show else window.withdraw)()  # not Windows


def on_screen(x, y, width, height, screen):
    """(x, y) pulled back so a width x height window stays on the desktop (a monitor was unplugged, dragged too far).
    Exactly where the user dragged it otherwise, also over the taskbar."""
    # ponytail: the box around all monitors, so a gap between monitors of different sizes counts as on screen
    left, top, w, h = screen
    return max(left, min(x, left + w - width)), max(top, min(y, top + h - height))


def gpu_compute_type(ctranslate2, wanted):
    # CTranslate2 refuses a compute type the GPU can't run instead of falling back: bfloat16 needs an RTX 30+,
    # float16 an RTX 20 / GTX 16+. Older GPUs (GTX 10+) get int8 weights with float32 math.
    return wanted if wanted in ctranslate2.get_supported_compute_types("cuda") else "int8_float32"


def text_only(hf_dir):
    """MiLMMT 4B ships as Gemma3ForConditionalGeneration (text + vision); CTranslate2 converts only the text
    model, so write its weights (language_model.* -> *) and text_config as a Gemma3ForCausalLM folder."""
    from safetensors import safe_open
    from safetensors.torch import save_file
    out = hf_dir + "-text"
    os.makedirs(out, exist_ok=True)
    with open(os.path.join(hf_dir, "config.json"), encoding="utf-8") as f:
        cfg = json.load(f)
    weight_map = {}
    for shard in sorted(f for f in os.listdir(hf_dir) if f.endswith(".safetensors")):
        with safe_open(os.path.join(hf_dir, shard), "pt") as f:
            tensors = {k[len("language_model."):]: f.get_tensor(k) for k in f.keys() if k.startswith("language_model.")}
        if tensors:
            save_file(tensors, os.path.join(out, shard), metadata={"format": "pt"})
            weight_map.update(dict.fromkeys(tensors, shard))
        del tensors
    with open(os.path.join(out, "model.safetensors.index.json"), "w", encoding="utf-8") as f:
        json.dump({"metadata": {}, "weight_map": weight_map}, f)
    for name in os.listdir(hf_dir):
        if name.startswith(("tokenizer", "special_tokens", "added_tokens", "generation_config")):
            shutil.copy(os.path.join(hf_dir, name), out)
    text = dict(cfg["text_config"], architectures=["Gemma3ForCausalLM"], model_type="gemma3_text")
    text.setdefault("torch_dtype", cfg.get("torch_dtype", "bfloat16"))
    with open(os.path.join(out, "config.json"), "w", encoding="utf-8") as f:
        json.dump(text, f)
    return out


def milmmt_prompt(src, trg, text):
    """MiLMMT's prompt, built by the engine's own code when available."""
    try:
        from Models.TextTranslation import texttranslate_milmmt as m
        return m.build_prompt(m._resolve_language(src)[1], m._resolve_language(trg)[1], text)
    except Exception:
        s, t = _LANGUAGE_NAMES.get(src, src), _LANGUAGE_NAMES.get(trg, trg)
        return f"Translate this from {s} to {t}:\n{s}: {text}\n{t}:"


def roll_up(finals, live, anchor, max_lines, width, measure):
    """YouTube live-caption roll-up: all text flows as one stream, lines fill up and scroll off the top.
    Wrapping always restarts at `anchor` (final text, word index) = the first word of the top line, so lines
    already on screen never re-wrap; the anchor only moves to a line start (scroll) or resets when its line
    expires. Returns (lines to show, new anchor)."""
    key, skip = anchor if anchor and anchor[0] in finals else (None, 0)
    start = finals.index(key) if key is not None else 0
    words = [(w, i, j) for i in range(start, len(finals)) for j, w in enumerate(finals[i].split())
             if i > start or j >= skip]
    words += [(w, None, j) for j, w in enumerate((live or "").split())]
    lines = []
    for word in words:
        if lines and measure(" ".join(w for w, _, _ in lines[-1] + [word])) <= width:
            lines[-1].append(word)
        else:
            lines.append([word])
    # scroll finished lines away; a line starting in the live text can't anchor (that text still changes)
    while len(lines) > max_lines and lines[1][0][1] is not None:
        lines.pop(0)
    anchor = (finals[lines[0][0][1]], lines[0][0][2]) if lines and lines[0][0][1] is not None else None
    return [" ".join(w for w, _, _ in line) for line in lines[-max_lines:]], anchor


class Original(str):
    """A row drawn small: the spoken line above its translation (the app's Show original), or the scroll hint."""


def fit_end(text, width, measure):
    """The end of `text` that fits in `width`, after "…" if cut: the newest words of a long spoken line."""
    if measure(text) <= width:
        return text
    lo, hi = 0, len(text)
    while lo < hi:  # the shortest cut that fits
        mid = (lo + hi) // 2
        if measure("…" + text[mid:]) <= width:
            hi = mid
        else:
            lo = mid + 1
    return "…" + text[lo:]


# A whole phrase (1-40 chars) said 3+ times in a row, separated by spaces/punctuation.
# Needs a separator so normal words ("book") are untouched; 2x ("hello hello") is left alone.
# Bounded lengths keep the regex fast on long looping hallucinations.
_REPEAT = re.compile(r"\b(\w.{0,39}?)(?:[\s,.!?、。…]{1,3}\1\b){2,}", re.IGNORECASE)


# Source lines that are only Japanese filler sounds ("うううう", "なんか", "えーっと").
# Translators turn these into junk like "Oh, my God.", so they are not shown at all.
# No word made only of the [...] sounds ("うーん"): two ways to match it backtracks exponentially (CodeQL py/redos).
_FILLER = re.compile(
    r"^(?:[\sあいうえおぁぃぅぇぉんーっ〜~、。!！?？…・]|なんか|えーっと|えっと|えーと|あの|その|まあ|ほら)*$")


# Whole-line sound events Whisper writes in Japanese -> YouTube-style tags (shown instead of a translation).
_SOUND_TAGS = [
    (re.compile(r"^[\s(（【\[]*(?:爆?笑|[あア]?(?:は|ハ){2,}|(?:ふ|フ){2,}|[wｗ]{3,})[\s)）】\]!！?？…。、ー〜]*$"), "[laughs]"),
    (re.compile(r"^[\s(（【\[]*(?:♪|♫|🎵|音楽|BGM|〜|~)+[\s)）】\]]*$"), "[music]"),
    (re.compile(r"^[\s(（【\[]*(?:拍手|8{3,}|８{3,})+[\s)）】\]!！]*$"), "[applause]"),  # 8888 = パチパチ
]
_TAGS = {tag for _, tag in _SOUND_TAGS}


def sound_tag(source_text):
    text = (source_text or "").strip()
    for pattern, tag in _SOUND_TAGS:
        if text and pattern.match(text):
            return tag
    return None


def is_filler(source_text):
    return bool(source_text) and bool(_FILLER.match(source_text.strip()))


# YouTube-outro phrases Whisper tacks onto the end of real speech ("... ご視聴ありがとうございました",
# "この動画は、ご覧いただきありがとうございます").
# Whole-line versions are dropped by fake-lines.txt; this strips them from the end of a longer line,
# together with a sign-off opener when that is all that precedes it ("それでは、ご視聴..." -> "", not "Well then...").
_OUTRO = re.compile(
    r"(?:^\s*(?:それでは|それじゃあ?|では|じゃあ|ということで|さて|はい))?[\s、。,.!！]*(?:(?:(?:この|今回の)?動画(?:を|は)?[\s、,]*)?(?:最後まで)?(?:ご視聴|ご覧)(?:いただき|頂き|頂いて|いただいて|くださり|下さり)?(?:本当に)?ありがとうございま(?:した|す)"
    r"|チャンネル登録(?:を)?(?:よろしく)?お願い(?:します|いたします)|(?:また)?次(?:回)?の動画でお会いしましょう)[\s、。,.!！]*$")


def strip_outro(source_text):
    text = source_text or ""
    while True:
        stripped = _OUTRO.sub("", text)
        if stripped == text:
            return text
        text = stripped


def _line_key(text):
    return re.sub(r"[\W_]+", "", (text or "").casefold())  # case, spaces and punctuation don't matter


def load_fake_lines(*paths):
    """fake-lines.txt (and the engine's own ignorelist.txt): whole lines Whisper makes up during silence."""
    keys = set()
    for path in paths:
        try:
            with open(path, encoding="utf-8-sig") as f:  # Notepad may save it with a BOM
                keys.update(_line_key(line) for line in f if not line.lstrip().startswith("#"))
        except (OSError, UnicodeDecodeError):  # saved as ANSI or Shift-JIS: skipped, not a plugin that fails to load
            pass
    keys.discard("")
    return keys


FAKE_LINES = load_fake_lines(*(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", *name)
                               for name in (("app", "fake-lines.txt"), ("ignorelist.txt",))))


# Subtitle credits Whisper learned from videos and prints during silence, anywhere in a line: "Subtitles by the
# Amara.org community" (in many languages), "Субтитры сделал DimaTorzok", "Редактор субтитров А.Семкин",
# "请不吝点赞 订阅 转发 打赏支持明镜与点点栏目", "优优独播剧场——YoYo Television Series Exclusive".
_FAKE_PARTS = ("amaraorg", "dimatorzok", "редакторсубтитров", "明镜与点点", "明鏡與點點", "yoyotelevisionseries")


def is_fake(source_text):
    key = _line_key(source_text)
    return key in FAKE_LINES or any(part in key for part in _FAKE_PARTS)


def is_char_loop(source_text):
    """Whisper junk like '顔顔顎顔顤顔': a single character makes up most of the line."""
    chars = [c for c in (source_text or "") if not c.isspace()]
    return len(chars) >= 4 and max(map(chars.count, set(chars))) / len(chars) > 0.5


_WORD = "0-9A-Za-zÀ-ɏЀ-ӿ"  # letters of the languages that put spaces between words (Latin, Cyrillic)


def load_glossary(path):
    """glossary.txt: 'term = replacement' lines, swapped in before translation, in any case. Longest first
    (兎田ぺこら before ぺこら). A term that starts or ends with a Latin/Cyrillic letter only matches whole words there
    (AWS, not the "aws" in "laws"); Japanese, Chinese and Korean have no spaces, so they match anywhere."""
    try:
        with open(path, encoding="utf-8-sig") as f:  # Notepad may save it with a BOM
            pairs = dict(line.split("=", 1) for line in f if "=" in line and not line.lstrip().startswith("#"))
    except (OSError, UnicodeDecodeError):  # else it fails again on every line, and nothing is translated
        return None
    pairs = {k.strip().lower(): v.strip() for k, v in pairs.items() if k.strip()}
    if not pairs:
        return None
    word = re.compile(f"[{_WORD}]")
    pattern = re.compile("|".join((f"(?<![{_WORD}])" if word.match(k[0]) else "") + re.escape(k) +
                                  (f"(?![{_WORD}])" if word.match(k[-1]) else "")
                                  for k in sorted(pairs, key=len, reverse=True)), re.IGNORECASE)
    return lambda text: pattern.sub(lambda m: pairs.get(m.group(0).lower(), m.group(0)), text)  # .get: Unicode folds a few letters differently


def tidy_english(text):
    """LFM2 sometimes answers in lowercase or with a subtitle dash ('- i know.'); fix that."""
    text = re.sub(r"^[\s\-–—]+", "", text or "")
    text = re.sub(r"\bi\b", "I", text)
    return text[:1].upper() + text[1:]


# "uh"/"uhm" as a word: a filler in every caption language that writes it (not "um": Portuguese "one")
_UH = re.compile(r"(?:,\s*)?\b[Uu]h+m?\b(?=[\s,.!?]|$)")


def collapse_repeats(text):
    """'first, first, first, first' -> 'first'. Whisper sometimes loops a phrase many times.
    Fillers go too: 'Well, uh, well' -> 'Well, well'. So does a subtitle dash NLLB puts in front: '- The staff' -> 'The staff'."""
    prev = None
    while prev != text:
        prev, text = text, _REPEAT.sub(r"\1", text)
    cut = re.sub(r"^(?:[,.]|[-–—](?=\s))\s*|\s+(?=[,.!?])", "", re.sub(r"\s{2,}", " ", _UH.sub("", text)).strip(" ,、"))
    if not cut.strip(" ,.!?"):
        return text.strip(" ,、")
    return cut[0].upper() + cut[1:] if text[:1].isupper() else cut


def agreed_start(a, b, hold=0):
    """The start of draft b that the draft before it, a, agrees on, ending at a word's end (anywhere in CJK text),
    less its last `hold` words. Case and punctuation don't count: Whisper changes them as it hears more
    ("good evening." -> "Good evening, all")."""
    ka = [(c.casefold(), i) for i, c in enumerate(a) if c.isalnum()]
    kb = [(c.casefold(), i) for i, c in enumerate(b) if c.isalnum()]
    n = 0
    while n < min(len(ka), len(kb)) and ka[n][0] == kb[n][0]:
        n += 1

    def word_end(s, k, n):
        i = k[n - 1][1] + 1
        return i == len(s) or not (s[i].isalnum() or s[i] in "'’-") or ord(s[i - 1]) >= 0x2E80 or ord(s[i]) >= 0x2E80

    def back(n):
        while n and not (word_end(a, ka, n) and word_end(b, kb, n)):
            n -= 1
        return n

    n = back(n)
    for _ in range(hold):
        n = back(n - 1) if n else 0
    return b[:kb[n - 1][1] + 1].strip() if n else ""


class PluginTranslator:
    """Translates inside the plugin when the engine sends untranslated text (profile `txt_translate: false`).

    The engine runs speech recognition and translation serially on one worker, so a ~1 s translation per
    sentence used to freeze the live line. Here the engine only transcribes, and plugin threads translate:
      - fast: the live-line draft and every final. milmmt4b = MiLMMT-4B via CTranslate2 (~0.6 s, best; live
        profile), milmmt = MiLMMT-1B (~0.25 s), nllb = NLLB-600M (~0.2 s, rougher; light profile). A final whose
        text equals a recent draft reuses that draft's translation.
      - upgrade (optional): re-translates each final before it shows (no quick draft that then changes). lfm2 =
        LFM2-350M-ENJP-MT (JA<->EN, ~0.8 s under load, 0.7 GB; light profile), milmmt4b = MiLMMT-4B int8
        (~0.6 s alone, 3.8 GB)
    """

    def __init__(self, show_live, show_final, upgrade_final, fast_device="cuda", upgrade=False, fast_model="milmmt",
                 upgrade_model="lfm2"):
        self.show_live, self.show_final, self.upgrade_final = show_live, show_final, upgrade_final
        self.fast_device = fast_device
        self.fast_model = fast_model or "milmmt"  # milmmt (bfloat16, 2.3 GB) | milmmt_int8 (0.9 GB, a bit slower) | milmmt4b | nllb
        self.milmmt = None  # MiLMMT CTranslate2 (tokenizer, generator)
        self.upgrade = upgrade
        self.upgrade_model = upgrade_model or "lfm2"  # lfm2 | milmmt4b
        self.cv = threading.Condition()
        # each line carries its source language from submit(): with spoken "Auto" it can change from line to line
        self.draft = None  # newest (seq, text, src) live-line draft; older ones are skipped
        self.finals = deque()  # (seq, text, src) finals waiting for the fast pass
        self.upgrades = deque()  # (seq, fast_text, text, src) finals waiting for the good pass
        self.spoken = None  # spoken "Auto": the language Whisper heard last (else the profile's src_lang)
        self.recent = {}  # source -> translation of the last few drafts; ~half of finals equal the last draft
        self.inflight = None  # source text the draft worker is translating right now
        self.fast = None  # NLLB (tokenizer, translator)
        self.lfm2 = None  # LFM2 (tokenizer, model, end-of-turn token ids)
        self.times = deque(maxlen=12)  # seconds per translated line (fast pass), for STATS_FILE
        # names and jargon in any spoken language: Kronii not "cronyism", スパチャ = Super Chat not "spa treat" (bench/mt, 2026-10-07)
        # (the app's Your words edits it: re-read on the next line after a change, no restart)
        self.glossary_file = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "app", "glossary.txt")
        self.glossary_mtime = None
        self.glossary = None
        threading.Thread(target=self._fast_loop, daemon=True).start()
        if upgrade:
            threading.Thread(target=self._good_loop, daemon=True).start()

    def submit(self, seq, text, final, src):
        try:
            mtime = os.path.getmtime(self.glossary_file)
        except OSError:
            mtime = None
        if mtime != self.glossary_mtime:
            self.glossary_mtime, self.glossary = mtime, load_glossary(self.glossary_file)
        if self.glossary:
            text = self.glossary(text)
        with self.cv:
            if final:
                self.finals.append((seq, text, src))
                self.draft = None
            else:
                self.draft = (seq, text, src)
            self.cv.notify_all()

    def _languages(self):
        import settings
        return self.spoken or settings.GetOption("src_lang"), settings.GetOption("trg_lang")

    def _load_fast(self):
        try:
            import ctranslate2
            from transformers import AutoTokenizer
            if not os.path.exists(os.path.join(FAST_MODEL_DIR, "model.bin")):
                import downloader  # the engine's own downloader and mirrors
                from Models.TextTranslation import texttranslateNLLB200_CTranslate2 as nllb
                print("SubtitleDisplayPlugin: downloading NLLB-200 (~1.3 GB, first start only)")  # captions.ps1 normally did
                link = nllb.MODEL_LINKS["small"]
                downloader.download_extract(link["urls"], os.path.abspath(os.path.dirname(FAST_MODEL_DIR)), link["checksum"],
                                            title="Text Translation (NLLB200CT2)")
            cuda = self.fast_device == "cuda" and ctranslate2.get_cuda_device_count() > 0
            tokenizer = AutoTokenizer.from_pretrained(FAST_MODEL_DIR)
            translator = ctranslate2.Translator(FAST_MODEL_DIR, device="cuda" if cuda else "cpu",
                                                compute_type=gpu_compute_type(ctranslate2, "int8_float16") if cuda else "int8")
            return tokenizer, translator
        except Exception:
            print("SubtitleDisplayPlugin: fast translator unavailable, finals only")
            traceback.print_exc()
            return None

    def _load_milmmt(self, big=False, threads=2):
        try:
            import ctranslate2
            from transformers import AutoTokenizer
            hf_dir, ct2_dir = (MILMMT4B_HF_DIR, MILMMT4B_CT2_DIR) if big else (MILMMT_HF_DIR, MILMMT_CT2_DIR)
            if not os.path.exists(os.path.join(ct2_dir, "model.bin")):
                from Models.TextTranslation import texttranslate_milmmt  # the engine's own downloader and mirrors
                name = os.path.basename(hf_dir)
                # captions.ps1 normally downloaded it: then this only checks the files (once)
                print(f"SubtitleDisplayPlugin: checking {name} (first start only)")
                if not texttranslate_milmmt.download_model(name, force_non_ui_dl=True):
                    raise RuntimeError(f"{name} download failed")
                print(f"SubtitleDisplayPlugin: converting {name} for CTranslate2 (first start only, a few minutes)")
                src_dir = text_only(hf_dir) if big else hf_dir
                files = [f for f in _MILMMT_FILES if os.path.exists(os.path.join(src_dir, f))]
                # into a temp folder renamed when complete: a stop mid-conversion can't leave a half model.bin
                ctranslate2.converters.TransformersConverter(src_dir, copy_files=files).convert(
                    ct2_dir + ".tmp", quantization="int8_bfloat16" if big else "bfloat16", force=True)
                shutil.rmtree(ct2_dir, ignore_errors=True)
                os.replace(ct2_dir + ".tmp", ct2_dir)
                if big:
                    shutil.rmtree(src_dir, ignore_errors=True)  # the text-only copy was only needed to convert
            cuda = self.fast_device == "cuda" and ctranslate2.get_cuda_device_count() > 0
            # Gemma-based: float16 overflows, so bfloat16 (or int8 weights with bfloat16 math) on the GPU,
            # and int8 weights with float32 math on GPUs older than RTX 30 (no bfloat16).
            compute = gpu_compute_type(ctranslate2, "int8_bfloat16" if big or self.fast_model == "milmmt_int8" else "bfloat16") if cuda else "int8"
            # The original folder's config.json tells transformers what the tokenizer is (the CTranslate2 copy's
            # config.json doesn't), so use it while it exists.
            tokenizer = AutoTokenizer.from_pretrained(hf_dir if os.path.isdir(hf_dir) else ct2_dir)
            # Two workers (shared weights): a finished sentence never waits for a live-line translation.
            generator = ctranslate2.Generator(ct2_dir, device="cuda" if cuda else "cpu", compute_type=compute,
                                              inter_threads=threads)
            return tokenizer, generator
        except Exception:
            print(f"SubtitleDisplayPlugin: MiLMMT{'-4B' if big else ''} translator unavailable")
            traceback.print_exc()
            return None

    def _milmmt_translate(self, text, src, trg, model=None):
        tokenizer, generator = model or self.milmmt
        ids = tokenizer(milmmt_prompt(src, trg, text), add_special_tokens=False)["input_ids"]
        result = generator.generate_batch([tokenizer.convert_ids_to_tokens(ids)], max_length=min(256, 2 * len(ids) + 16),
                                          sampling_topk=1, include_prompt_in_result=False,
                                          end_token=["<eos>", "<end_of_turn>"])
        return tokenizer.decode(result[0].sequences_ids[0], skip_special_tokens=True).strip()

    def _load_lfm2(self):
        try:
            import torch
            from transformers import AutoModelForCausalLM, AutoTokenizer
            if not os.path.exists(os.path.join(LFM2_DIR, "model.safetensors")):  # the weights: a stopped download can leave config.json
                from huggingface_hub import snapshot_download
                print("SubtitleDisplayPlugin: downloading LFM2-350M-ENJP-MT (~0.7 GB, first start only)")
                snapshot_download(LFM2_REPO, revision=LFM2_REVISION, local_dir=LFM2_DIR,
                                  allow_patterns=["*.json", "*.safetensors", "*.jinja", "*.txt"])
            cuda = self.fast_device == "cuda" and torch.cuda.is_available()
            tokenizer = AutoTokenizer.from_pretrained(LFM2_DIR)
            bf16 = cuda and torch.cuda.get_device_capability()[0] >= 8  # RTX 30+; older GPUs only emulate bfloat16
            model = AutoModelForCausalLM.from_pretrained(LFM2_DIR, dtype=torch.bfloat16 if bf16 else torch.float32)
            model = model.to("cuda" if cuda else "cpu").eval()
            stop = {tokenizer.eos_token_id, tokenizer.convert_tokens_to_ids("<|im_end|>")}
            return tokenizer, model, stop
        except Exception:
            print("SubtitleDisplayPlugin: LFM2 translator unavailable, keeping the NLLB lines")
            traceback.print_exc()
            return None

    def _lfm2_translate(self, text, trg):
        """Greedy decoding with repetition penalty 1.05, as a plain loop (less overhead than generate())."""
        import torch
        tokenizer, model, stop = self.lfm2
        messages = [{"role": "system", "content": _LFM2_PROMPTS[trg]}, {"role": "user", "content": text}]
        prompt = tokenizer.apply_chat_template(messages, tokenize=False, add_generation_prompt=True)
        ids = tokenizer(prompt, return_tensors="pt", add_special_tokens=False)["input_ids"].to(model.device)
        seen, out_ids = ids[0].clone(), []
        with torch.inference_mode():
            out = model(input_ids=ids, use_cache=True)
            for _ in range(96):
                logits = out.logits[0, -1].float()
                prev = logits[seen]
                logits[seen] = torch.where(prev > 0, prev / 1.05, prev * 1.05)
                token = int(logits.argmax())
                if token in stop:
                    break
                out_ids.append(token)
                step = torch.tensor([[token]], device=model.device)
                seen = torch.cat([seen, step[0]])
                out = model(input_ids=step, past_key_values=out.past_key_values, use_cache=True)
        text = tokenizer.decode(out_ids, skip_special_tokens=True).strip()
        return tidy_english(text) if trg == "eng_Latn" else text

    def _fast_translate(self, text, src):
        trg = self._languages()[1]
        if self.milmmt is not None:
            return self._milmmt_translate(text, src, trg)
        if self.fast is None or not (_NLLB_CODE.match(src or "") and _NLLB_CODE.match(trg or "")):
            return None
        tokenizer, translator = self.fast
        tokenizer.src_lang = src
        tokens = tokenizer.convert_ids_to_tokens(tokenizer.encode(text))
        result = translator.translate_batch([tokens], target_prefix=[[trg]], beam_size=2, no_repeat_ngram_size=3,
                                            repetition_penalty=1.1, max_decoding_length=96)
        out = result[0].hypotheses[0][1:]  # drop the target language token
        return tokenizer.decode(tokenizer.convert_tokens_to_ids(out), skip_special_tokens=True).strip()

    def _fast_loop(self):
        started = time.time()
        if self.fast_model.startswith("milmmt"):
            self.milmmt = self._load_milmmt(big=self.fast_model == "milmmt4b")
            if self.milmmt:
                try:
                    self._milmmt_translate("こんにちは", "jpn_Jpan", "eng_Latn")  # warm up now, not on the first caption
                except Exception:
                    traceback.print_exc()
                    self.milmmt = None
        if self.milmmt is None:
            self.fast = self._load_fast()
        if self.fast or self.milmmt:
            name = "MiLMMT" if self.milmmt else "NLLB"
            print(f"SubtitleDisplayPlugin: live-line translator ({name}) ready ({time.time() - started:.0f} s)")
        if self.milmmt:
            # MiLMMT (~0.3 s) runs two workers: finals get their own, so they never queue behind a draft.
            threading.Thread(target=self._work_loop, args=(True, False), daemon=True).start()
            self._work_loop(False, True)
        else:
            self._work_loop(True, True)

    def _work_loop(self, take_finals, take_drafts):
        while True:
            try:
                self._work_one(take_finals, take_drafts)
            except Exception:  # an error showing one line must not end this thread: captions would stop for good
                traceback.print_exc()

    def _work_one(self, take_finals, take_drafts):
        with self.cv:
            while not (take_finals and self.finals) and not (take_drafts and self.draft is not None):
                self.cv.wait()
            final = take_finals and bool(self.finals)
            seq, text, src = self.finals.popleft() if final else self.draft
            if not final:
                self.draft, self.inflight = None, text
            while final and self.inflight == text:
                self.cv.wait()  # the draft worker is translating this exact text: reuse it, don't run it twice
            out = self.recent.get(text) if final else None
        if out is None:
            try:
                started = time.time()
                out = self._fast_translate(text, src)
                self._record_time(time.time() - started)
            except Exception:
                traceback.print_exc()
        if not final:
            with self.cv:
                if out:
                    self.recent[text] = out
                    if len(self.recent) > 4:
                        del self.recent[next(iter(self.recent))]
                self.inflight = None
                self.cv.notify_all()
        if final:
            late = []
            with self.cv:
                queued = self.upgrade  # read under the lock: the good pass may have just given up
                if queued:  # the good pass shows this line
                    self.upgrades.append((seq, out, text, src))
                    # Falling behind: older finals show their fast text (never skip one that has none).
                    while len(self.upgrades) > 2 and self.upgrades[0][1] is not None:
                        late.append(self.upgrades.popleft()[:2])
                    self.cv.notify_all()
            for late_seq, fast_text in late:
                self.upgrade_final(late_seq, fast_text)
            if not queued:
                self.show_final(seq, out or text)  # no translation: show the source text
        elif out:
            self.show_live(seq, out)

    def _record_time(self, seconds):
        self.times.append(seconds)
        if len(self.times) >= 6:
            try:
                with open(STATS_FILE, "w", encoding="utf-8") as f:
                    f.write(f"{1000 * sorted(self.times)[len(self.times) // 2]:.0f}")
            except OSError:
                pass

    def _give_up(self):
        # The good pass didn't load: stop queueing finals for it. Finals already waiting show their fast text (or
        # their source text, if the fast pass failed on them too) instead of never appearing.
        with self.cv:
            self.upgrade = False
            left = [(seq, fast_text or text) for seq, fast_text, text, _ in self.upgrades]
            self.upgrades.clear()
        for seq, text in left:
            self.upgrade_final(seq, text)

    def _good_loop(self):
        started = time.time()
        if self.upgrade_model == "milmmt4b":
            big = self._load_milmmt(big=True, threads=1)
            if big is None:
                return self._give_up()

            def translate(text, src):
                return self._milmmt_translate(text, src, self._languages()[1], model=big)
        else:
            self.lfm2 = self._load_lfm2()
            if self.lfm2 is None:
                return self._give_up()

            def translate(text, src):  # LFM2 is Japanese<->English only
                trg = self._languages()[1]
                return self._lfm2_translate(text, trg) if {src, trg} == {"jpn_Jpan", "eng_Latn"} else ""
        try:
            translate("こんにちは", "jpn_Jpan")  # load the model now, not on the first caption
            print(f"SubtitleDisplayPlugin: final-line translator ready ({time.time() - started:.0f} s)")
        except Exception:
            traceback.print_exc()
        while True:
            with self.cv:
                while not self.upgrades:
                    self.cv.wait()
                seq, fast_text, text, src = self.upgrades.popleft()
            try:
                good = translate(text, src)
            except Exception:
                traceback.print_exc()
                good = ""
            try:
                self.upgrade_final(seq, good or fast_text or text)  # nothing better: the fast text, else the source
            except Exception:  # keep this thread alive (see _work_loop)
                traceback.print_exc()


class SubtitleDisplayPlugin(Plugins.Base):
    supports_stable_streaming = True
    root = None
    label = None
    tkinter_thread = None
    update_queue = None
    close_requested = None

    current_intermediate_transcription = None

    transcription_keep_last = True
    transcription_limit = 3
    transcription_display_time = 15
    transcriptions = []
    transcription_times = None
    history = None  # the last HISTORY_LINES finished lines, for scrolling back (memory only)

    translator = None  # PluginTranslator, only when the engine itself doesn't translate
    _display_lock = None
    _seq = 0  # numbers every source text handed to the translator
    _final_cut = 0  # drafts at or below this seq belong to a sentence that already has a final
    _live_seq = 0  # seq of the draft on the live line
    _drop_seq = 0  # finals at or below this seq were said before a pause: never shown

    style_mtime = None

    def _read_style(self):
        """The app's settings if app-settings.json changed since the last call, else None (also while unreadable:
        the app may be writing it; tried again next second)."""
        try:
            mtime = os.path.getmtime(APP_SETTINGS)
            if mtime == self.style_mtime:
                return None
            with open(APP_SETTINGS, encoding="utf-8-sig") as f:
                style = json.load(f)
        except (OSError, ValueError):
            return None
        self.style_mtime = mtime
        return style if isinstance(style, dict) else {}

    def tkinter_thread_func(self):
        def apply_style(style):
            # YouTube's caption options (the app's Caption style), missing or odd values -> YouTube's defaults
            def percent(key, default, low=0, high=100):
                try:
                    return min(max(float(style.get(key, default)), low), high) / 100
                except (TypeError, ValueError):
                    return default / 100

            def color(key, default):  # the see-through color itself would be invisible: shift it a hair
                c = CAPTION_COLORS.get(style.get(key), default)
                return "#FE00FE" if c.upper() == transparency_color.upper() else c

            self.cc_small_caps = style.get("captionFont") == "Small Capitals"  # ponytail: all capitals a size smaller
            family = next((f for f in CAPTION_FONTS.get(style.get("captionFont"), CAPTION_FONTS["Proportional Sans-Serif"])
                           if f in families), "Arial")
            self.cc_font.configure(family=family, size=round(font_size * percent("captionSize", 100, 50, 400)
                                                             * (0.85 if self.cc_small_caps else 1)))
            self.cc_color = color("captionColor", font_color)
            self.cc_bar = color("captionBackgroundColor", default_bar)
            self.cc_box = color("captionWindowColor", "#080808")
            # Windows smooths the letters' edges against the see-through color: a hair off the bar color, so the
            # edges blend into the bar as on YouTube (with the profile's magenta, the text got a pink fringe)
            key = "#" + "".join(f"{v + (1 if v < 128 else -1):02X}" for v in (x >> 8 for x in self.root.winfo_rgb(self.cc_bar)))
            text_win.configure(bg=key)
            self.text_canvas.configure(bg=key)
            text_win.wm_attributes("-transparentcolor", key)
            self.cc_edge = style.get("captionEdge")
            text_win.attributes('-alpha', percent("captionOpacity", 100, 25))
            self.cc_box_alpha = percent("captionWindow", 0)
            self.cc_hint_font.configure(family=family, size=max(9, round(self.cc_font.cget("size") * 0.6)))
            self.cc_hint_h = self.cc_hint_font.metrics("linespace") + px(8)
            box_win.attributes('-alpha', self.cc_box_alpha)
            if opacity < 0.0:  # the default look (a custom opacity setting keeps its own)
                self.cc_alpha = percent("captionBackground", 75)
                self.root.attributes('-alpha', self.cc_alpha)
            self.cc_original = style.get("showOriginal") is True  # a small row above for the spoken line
            self.chatbox = style.get("vrchatChatbox") is True  # sent only while the engine hears VRChat or the mic
            self.cc_height = (MAX_SCREEN_LINES * (self.cc_font.metrics("linespace") + px(5)) + px(10)  # fixed: the bottom edge never jumps
                              + (self.cc_hint_h if self.cc_original else 0))
            return self.cc_height

        def place(height, x, y):
            # the window box, the bars and the text are three windows stacked exactly on top of each other
            x, y = on_screen(x, y, window_width, height, desktop(self.root))
            for w in (box_win, self.root, text_win):
                w.geometry(f"{window_width}x{height}+{x}+{y}")
            return x, y

        def save_position(x, y):  # kept in 100%-scale pixels: the same spot after the display scale changes
            x, y = round(x / scale), round(y / scale)
            self.set_plugin_setting("x_position", x)
            self.set_plugin_setting("y_position", y)
            try:
                with open(POSITION_FILE, "w", encoding="utf-8") as f:
                    json.dump({"x": x, "y": y}, f)
            except OSError:
                pass

        def update_transcription_text():
            self.root.after(1000, update_transcription_text)  # first: an error below must not end this timer
            style = self._read_style()
            if style is not None:  # changed in the app: apply now, keeping the captions' bottom edge in place
                x, y = self.cc_home if self.cc_back is not None else (self.root.winfo_x(), self.root.winfo_y())
                old, self.cc_back = self.cc_height, None  # back to the live captions
                height = apply_style(style)
                save_position(*place(height, x, y + old - height))
                for w in (box_win, self.root, text_win):
                    no_focus(w)  # again, in case Tk rebuilt a window's style
                redraw()  # now, not at the next caption
            if self.root is not None and self.is_enabled(False):
                self.update_intermediate_label_text()

        def listen(on):  # the engine's own switch: off, it drops the sound instead of transcribing it
            import settings
            if bool(settings.GetOption("stt_enabled")) != on:
                settings.SetOption("stt_enabled", on)

        def set_paused(paused):
            # Stop in the app pauses: the captions hide and the engine stops listening but keeps its models loaded,
            # so Start shows captions again at once instead of after a minute. What was said before never shows.
            self.cc_paused = paused
            listen(not paused)
            to_live()
            with self._display_lock:
                self.transcriptions.clear()
                self.transcription_times.clear()
                self._pending.clear()
                self._sources.clear()
                self.originals.clear()
                self.current_intermediate_transcription = None
                for d in (getattr(self, "_stream_intermediates", None), getattr(self, "_stable_captions", None)):
                    if d:
                        d.clear()
                self.history = None
                self._final_cut = self._drop_seq = self._seq  # lines still being translated are dropped
            self.cc_frame = self.cc_anchor = None
            draw_lines([])
            for w in (box_win, self.root, text_win):
                show_window(w, not paused)

        def check_queue():
            if self.close_requested.get():
                self.root.quit()
                return
            self.root.after(16, check_queue)  # 60 times a second; first: one frame that fails to draw must not freeze the captions
            frame = None
            try:
                while True:
                    frame = self.update_queue.get_nowait()  # skip stale frames, only the newest matters
            except queue.Empty:
                pass
            paused = os.path.exists(PAUSE_FILE)
            if paused != self.cc_paused:
                set_paused(paused)
            if paused:
                listen(False)  # again: the engine turns listening on as it starts
                self.cc_ticks = (self.cc_ticks + 1) % APP_CHECK_TICKS
                if not self.cc_ticks and not app_open():
                    close_console()
                return
            if self.cc_back is not None and time.time() - self.cc_back_at > HISTORY_IDLE:
                to_live()
            if frame is not None and frame != self.cc_frame:  # the 1 s refresh mostly repeats the last frame
                self.cc_frame = frame
                if self.cc_back is None:  # scrolled back: shown on return
                    draw_youtube_style(*frame)

        def measure():
            caps = self.cc_small_caps
            return (lambda t: self.cc_font.measure(t.upper())) if caps else self.cc_font.measure

        def draw_youtube_style(finals, live):
            lines, self.cc_anchor = roll_up(finals, live, self.cc_anchor, MAX_SCREEN_LINES, window_width - px(60), measure())
            original = self.cc_original and finals and self.originals.get(finals[-1])  # the newest finished line's
            draw_lines([Original(original)] * bool(original) + lines)

        def redraw():  # the live captions, or earlier lines while scrolled back
            if self.cc_back is not None:
                rows = self.cc_rows[self.cc_back:self.cc_back + MAX_SCREEN_LINES + self.cc_original]  # newest first
                if rows and isinstance(rows[0], Original):
                    rows.pop(0)  # its line is below, scrolled off
                while sum(not isinstance(r, Original) for r in rows) > MAX_SCREEN_LINES:
                    rows.pop()  # fits: at most MAX_SCREEN_LINES caption rows, and one small row more than that
                draw_lines(rows[::-1], HISTORY_HINT)
            elif self.cc_frame:
                draw_youtube_style(*self.cc_frame)

        def earlier_rows(n):
            """At least n wrapped rows of the lines kept when scrolling began (or all), newest first. Each line
            starts its own row; lines are wrapped only as far back as scrolled."""
            width = window_width - px(60)
            while len(self.cc_rows) < n and self.cc_used < len(self.cc_snap):
                self.cc_used += 1
                line = self.cc_snap[-self.cc_used]
                self.cc_rows += reversed(roll_up([line], "", None, len(line), width, measure())[0])
                original = self.cc_original and self.originals.get(line)
                if original:
                    self.cc_rows.append(Original(original))  # above its line
            return self.cc_rows

        def on_wheel(e):  # the wheel scrolls back through earlier lines; down past the newest: live again
            self.cc_wheel += e.delta
            steps = int(self.cc_wheel / 120)  # a notch is 120; touchpads send smaller steps
            if not steps:
                return
            self.cc_wheel -= steps * 120
            back = (self.cc_back or 0) + steps
            if back <= 0:
                to_live()
                return
            if self.cc_back is None:
                with self._display_lock:  # translator threads add lines
                    self.cc_snap = list(self.history or ())  # what was said so far: new lines show on return
                if not self.cc_snap:
                    return
                self.cc_rows, self.cc_used = [], 0
                self.cc_home = (self.root.winfo_x(), self.root.winfo_y())
                place(self.cc_height + self.cc_hint_h, self.cc_home[0], self.cc_home[1] - self.cc_hint_h)  # the hint above
            screen = MAX_SCREEN_LINES + self.cc_original
            self.cc_back = min(back, max(len(earlier_rows(back + screen)) - screen, 0))
            self.cc_back_at = time.time()
            redraw()

        def to_live():
            if self.cc_back is not None:
                self.cc_back, self.cc_snap, self.cc_rows = None, [], []
                place(self.cc_height, *self.cc_home)
                redraw()

        def draw_lines(lines, hint=None):
            # YouTube CC look: each line centered on its own bar, newest line at the bottom, all lines in one window
            # box. Box, bars and text are separate windows, each with its own opacity (Tk has one per window).
            width = window_width
            height = self.cc_height + (self.cc_hint_h if hint else 0)  # winfo_height lags a resize until it is drawn
            caps = self.cc_small_caps
            for c in (self.box_canvas, self.canvas, self.text_canvas):
                c.delete("cc")
            u = max(1, round(abs(self.cc_font.cget("size")) / 10 * scale))
            edges = edge_copies(self.cc_edge, u)
            y, left, right, pad = height - px(4), width, 0, px(8)
            for line in reversed([Original(hint)] * bool(hint) + lines):
                small = isinstance(line, Original)  # the spoken line or the hint: one row, the hint font, as written
                font = self.cc_hint_font if small else self.cc_font
                line = fit_end(line, width - px(60), font.measure) if small else line.upper() if caps else line
                for dx, dy, c in () if small else edges:
                    self.text_canvas.create_text(width // 2 + dx, y + dy, text=line, fill=c, font=font,
                                                 anchor="s", tags="cc")
                t = self.text_canvas.create_text(width // 2, y, text=line, fill=self.cc_color, font=font,
                                                 anchor="s", tags="cc")
                x1, y1, x2, y2 = self.text_canvas.bbox(t)
                if self.cc_alpha > 0:
                    self.canvas.create_rectangle(x1 - pad, y1, x2 + pad, y2, fill=self.cc_bar, outline="", tags="cc")
                left, right, y = min(left, x1), max(right, x2), y1  # bars touch, like YouTube's stacked line boxes
            if lines and self.cc_box_alpha > 0:
                self.box_canvas.create_rectangle(left - pad - 2 * u, y - 2 * u, right + pad + 2 * u, height, fill=self.cc_box,
                                                 outline="", tags="cc")

        scale = 1.0
        try:  # sharp captions on a scaled display (125%, 150%, 200%): Windows otherwise draws them small and stretches
            # them, blurry. Only this thread's windows; sizes below are given at 100% and scaled here.
            import ctypes
            user32 = ctypes.WinDLL("user32")
            user32.SetThreadDpiAwarenessContext.restype = ctypes.c_void_p
            if user32.SetThreadDpiAwarenessContext(ctypes.c_void_p(-2)):  # DPI_AWARENESS_CONTEXT_SYSTEM_AWARE
                scale = user32.GetDpiForSystem() / 96 or 1.0
        except (AttributeError, OSError):
            pass  # not Windows, or older than Windows 10 1607: as before
        self.cc_scale = scale

        def px(n):
            return round(n * scale)

        top_position = px(int(self.get_plugin_setting("top")))
        bottom_position = px(int(self.get_plugin_setting("bottom")))

        window_width = px(int(self.get_plugin_setting("window_width")))
        window_height = px(int(self.get_plugin_setting("window_height")))

        transparency_color = self.get_plugin_setting("transparency_color")
        opacity = float(self.get_plugin_setting("opacity"))

        font_size = int(self.get_plugin_setting("font_size"))
        font_color = self.get_plugin_setting("font_color")
        font_background_color = self.get_plugin_setting("font_background_color")
        if font_background_color == "transparent":
            font_background_color = transparency_color

        self.root = tk.Tk()
        self.close_requested = tk.BooleanVar(self.root, False)

        screen_width = self.root.winfo_screenwidth()
        screen_height = self.root.winfo_screenheight()
        position = top_position if top_position != 0 else screen_height - window_height - bottom_position

        if self.get_plugin_setting("x_position", None) == -1:
            self.set_plugin_setting("x_position", round((screen_width - window_width) / 2 / scale))
        if self.get_plugin_setting("y_position", None) == -1:
            self.set_plugin_setting("y_position", round(position / scale))
        x_pos = px(int(self.get_plugin_setting("x_position", (screen_width - window_width) / 2 / scale)))
        y_pos = px(int(self.get_plugin_setting("y_position", position / scale)))
        try:
            with open(POSITION_FILE, encoding="utf-8") as f:
                saved = json.load(f)
            x_pos, y_pos = px(int(saved["x"])), px(int(saved["y"]))
        except (OSError, ValueError, TypeError, KeyError):
            pass  # none yet: the profile's

        self.root.geometry(f"{window_width}x{window_height}+{x_pos}+{y_pos}")
        self.root.configure(bg=transparency_color)
        self.root.overrideredirect(True)
        self.root.attributes('-alpha', opacity)
        self.root.attributes('-topmost', True)
        self.root.lift()
        if opacity < 0.0:
            self.root.attributes('-alpha', 0.8)
            self.root.wm_attributes("-transparentcolor", transparency_color)

        families = set(tkfont.families(self.root))
        self.cc_font = tkfont.Font(self.root, family="Arial", size=font_size, weight="normal")
        self.cc_hint_font = tkfont.Font(self.root, family="Arial", size=12, weight="normal")
        self.cc_back = None  # wrapped rows scrolled back from the newest; None: the live captions
        self.cc_back_at, self.cc_wheel, self.cc_home = 0, 0, (0, 0)
        self.cc_snap, self.cc_rows, self.cc_used = [], [], 0
        default_bar = "#080808" if font_background_color in ("black", transparency_color) else font_background_color
        self.cc_anchor = None
        self.cc_frame = None
        self.cc_alpha = 1.0
        self.cc_original = False
        self.style_mtime = None

        self.canvas = tk.Canvas(self.root, bg=transparency_color, highlightthickness=0)  # the bars
        self.canvas.pack(fill=tk.BOTH, expand=True)
        self.label = None

        def overlay():  # a see-through window over the video: only what is drawn on its canvas shows
            w = tk.Toplevel(self.root, bg=transparency_color)
            w.overrideredirect(True)
            w.attributes('-topmost', True)
            w.wm_attributes("-transparentcolor", transparency_color)
            c = tk.Canvas(w, bg=transparency_color, highlightthickness=0)
            c.pack(fill=tk.BOTH, expand=True)
            return w, c

        box_win, self.box_canvas = overlay()  # YouTube's caption "window", one box behind all lines
        text_win, self.text_canvas = overlay()  # the text on top, with its own opacity
        self.root.lift()
        text_win.lift()

        def on_press(e):  # the captions move by dragging them: their text, bars or box (the rest is see-through)
            self.root.lift()  # and clicking a lower window must not cover the ones above it
            text_win.lift()
            if self.cc_back is not None:  # scrolled back: a click returns to the live captions
                to_live()
                return
            self.drag = (e.x_root - self.root.winfo_x(), e.y_root - self.root.winfo_y(), None)

        def on_motion(e):
            if self.drag:
                x, y = e.x_root - self.drag[0], e.y_root - self.drag[1]
                for w in (box_win, self.root, text_win):
                    w.geometry(f"+{x}+{y}")
                self.drag = (*self.drag[:2], (x, y))  # winfo_x lags until the move is drawn

        def on_release(e):
            if self.drag and self.drag[2]:
                save_position(*self.drag[2])
            self.drag = None

        self.drag = None
        for c in (self.box_canvas, self.canvas, self.text_canvas):
            c.configure(cursor="fleur")
            c.bind("<Button-1>", on_press)
            c.bind("<B1-Motion>", on_motion)
            c.bind("<ButtonRelease-1>", on_release)
            c.bind("<MouseWheel>", on_wheel)
        window_height = apply_style(self._read_style() or {})  # YouTube's defaults: white text on #080808 at 75%
        place(window_height, x_pos, y_pos)
        for w in (box_win, self.root, text_win):
            no_focus(w)
        self.cc_paused, self.cc_ticks = False, 0
        if os.path.exists(PAUSE_FILE):  # loaded ahead by the app, paused until Start
            set_paused(True)

        self.root.after(100, check_queue)
        self.root.after(1000, update_transcription_text)
        self.root.mainloop()

    def stop(self):
        if self.root is not None:
            self.close_requested.set(True)
            if self.tkinter_thread is not None:
                self.tkinter_thread.join()
                self.tkinter_thread = None
            self.root = None
            self.label = None
            self.update_queue = None
            self.history = None

    def init(self):

        # prepare all possible settings
        self.init_plugin_settings(
            {
                # General
                "transcription_keep_last": True,
                "transcription_limit": {"type": "slider", "min": 1, "max": 10, "step": 1, "value": 3},
                "transcription_display_time": {"type": "slider", "min": 0, "max": 90, "step": 1, "value": 15},
                "transcription_display_source_transcript": False,
                "reverse_order_transcriptions": True,
                "extra_intermediate_line": True,
                "streaming_max_characters": {"type": "slider", "min": 100, "max": 2000, "step": 50, "value": 500},
                # With txt_translate off in the profile, the plugin translates (see PluginTranslator).
                "plugin_translation": True,
                "plugin_translation_fast_device": {"type": "select", "value": "cuda", "values": ["cuda", "cpu"]},
                # milmmt = 1B (2.3 GB), milmmt_int8 = same model in 0.9 GB, milmmt4b = 4B int8 (3.8 GB, better, ~2.6x
                # slower), nllb = fastest and lightest, rougher.
                "plugin_translation_fast_model": {"type": "select", "value": "milmmt", "values": ["milmmt", "milmmt_int8", "milmmt4b", "nllb"]},
                # A second model re-translates finals and swaps them in: lfm2 = LFM2-350M-ENJP-MT (0.7 GB, light
                # profile), milmmt4b = MiLMMT-4B int8 (3.8 GB, ~0.6 s, clearly better than the 1B).
                "plugin_translation_upgrade": False,
                "plugin_translation_upgrade_model": {"type": "select", "value": "lfm2", "values": ["lfm2", "milmmt4b"]},

                # Position
                "top": 30,
                "bottom": 0,
                "window_width": 800,
                "window_height": 400,
                "x_position": -1,
                "y_position": -1,

                # Styling
                "font_size": 20,
                "font_color": "white",
                "transparency_color": "black",
                "font_background_color": "transparent",
                "opacity": {"type": "slider", "min": -0.01, "max": 1.0, "step": 0.01, "value": -0.01},
            },
            settings_groups={
                "General": ["transcription_keep_last", "transcription_limit", "transcription_display_time", "transcription_display_source_transcript", "reverse_order_transcriptions", "extra_intermediate_line", "streaming_max_characters", "plugin_translation", "plugin_translation_fast_device", "plugin_translation_fast_model", "plugin_translation_upgrade", "plugin_translation_upgrade_model"],
                "Position": ["top", "bottom", "window_width", "window_height", "x_position", "y_position"],
                "Styling": ["font_size", "font_color", "transparency_color", "font_background_color", "opacity"],
            }
        )

        self.transcription_keep_last = self.get_plugin_setting("transcription_keep_last")
        self.transcription_limit = int(self.get_plugin_setting("transcription_limit"))
        self.transcription_display_time = int(self.get_plugin_setting("transcription_display_time"))
        self.transcriptions = deque(maxlen=self.transcription_limit)
        self.transcription_times = {}
        self._pending = {}  # seq of a final still being translated -> the live-line text shown for it meanwhile
        self._sources = {}  # seq of a final still being translated -> what was said
        self.originals = {}  # shown line -> what was said, for Show original (memory only, like the history)
        if self._display_lock is None:
            self._display_lock = threading.RLock()

        if self.translator is None and self.is_enabled(False) and self.get_plugin_setting("plugin_translation"):
            import settings
            # same language spoken and wanted: show what is said, no translation model
            if not settings.GetOption("txt_translate") and settings.GetOption("src_lang") != settings.GetOption("trg_lang"):
                self.translator = PluginTranslator(self._show_live, self._show_final, self._show_final,
                                                   self.get_plugin_setting("plugin_translation_fast_device"),
                                                   bool(self.get_plugin_setting("plugin_translation_upgrade")),
                                                   self.get_plugin_setting("plugin_translation_fast_model"),
                                                   self.get_plugin_setting("plugin_translation_upgrade_model"))

        if self.root is None and self.is_enabled(False):
            self.update_queue = queue.Queue()
            self.tkinter_thread = threading.Thread(target=self.tkinter_thread_func, daemon=True)
            self.tkinter_thread.start()
        else:
            self.stop()

    # Add a new method for intermediate text handling
    def update_intermediate_label_text(self):
        # Translator threads swap lines in place; don't expire lines halfway through a swap.
        with self._display_lock:
            self._update_intermediate_label_text()

    def _update_intermediate_label_text(self):
        # Remove expired transcriptions from the queue and the timestamp dict
        current_time = time.time()
        self.transcription_keep_last = self.get_plugin_setting("transcription_keep_last")
        self.transcription_display_time = int(self.get_plugin_setting("transcription_display_time"))

        if not self.transcription_keep_last or len(self.transcriptions) > 1:
            # Timestamps are keyed by text, so a line shown twice has one timestamp; once the first copy
            # expires the second has none and counts as expired too (it used to stay up until pushed out).
            while self.transcriptions and (current_time - self.transcription_times.get(self.transcriptions[0], 0)) > self.transcription_display_time:
                self.transcription_times.pop(self.transcriptions.popleft(), None)
        # Lines pushed out by the deque's maxlen leave their timestamps behind; drop those.
        if len(self.transcription_times) > len(self.transcriptions):
            shown = set(self.transcriptions)
            for text in [t for t in self.transcription_times if t not in shown]:
                del self.transcription_times[text]

        # Finished lines + the still-changing live text; the overlay rolls them up like YouTube live captions.
        live = [self.current_intermediate_transcription or ""]
        live.extend(getattr(self, "_stream_intermediates", {}).values())
        live.extend(getattr(self, "_stable_captions", {}).values())
        if self.update_queue is None:  # the overlay was closed; a translator thread may still finish a line
            return
        self.update_queue.put((list(self.transcriptions), " ".join(t for t in live if t)))

    def _select_display_text(self, pipeline_text, result_obj):
        original_text = str(result_obj.get("text") or "")
        translated_text = str(result_obj.get("txt_translation") or "").strip()
        source_id = str(result_obj.get("audio_source_id") or "main")

        # Additional audio routes explicitly choose whether their result goes
        # through text translation. Honor the text passed through that route's
        # output pipeline. The legacy plugin preference continues to control
        # the main microphone so existing profiles keep their old behavior.
        if source_id != "main":
            route_text = str(pipeline_text or "").strip()
            return route_text or translated_text or original_text

        if not self.get_plugin_setting("transcription_display_source_transcript") and translated_text:
            return translated_text
        return original_text

    def streaming_caption_text(self, text, result_obj):
        return self._select_display_text(text, result_obj)

    def stt_caption(self, text, result_obj):
        if not self.is_enabled(False):
            return
        if not hasattr(self, "_stable_captions"):
            self._stable_captions = {}
        source = str(result_obj.get("audio_source_id") or "main")
        getattr(self, "_stream_intermediates", {}).pop(source, None)
        if result_obj.get("display_done"):
            self._stable_captions.pop(source, None)
        else:
            self._stable_captions[source] = text
        self.update_intermediate_label_text()

    def _trace(self, ev, **kw):
        """Benchmark hook (replaced by the bench harness); does nothing normally."""

    def _plugin_translates(self, result_obj):
        return (self.translator is not None and not result_obj.get("txt_translation")
                and not result_obj.get("streaming")
                and str(result_obj.get("audio_source_id") or "main") == "main"
                and not self.get_plugin_setting("transcription_display_source_transcript"))

    def _source_language(self, result_obj):
        """The language this line is translated from: the profile's, or with spoken "Auto" the one Whisper heard
        in it (a language the app doesn't list: the last one heard). It travels with the line through the queues."""
        import settings
        if str(settings.GetOption("current_language") or "").casefold() not in ("auto", "", "none", "null"):
            return settings.GetOption("src_lang")
        spoken = WHISPER_TO_NLLB.get(str(result_obj.get("language") or ""))
        if spoken:
            self.translator.spoken = spoken
        return spoken or self.translator._languages()[0]

    def _submit_translation(self, text, is_final, src):
        with self._display_lock:
            self._seq += 1
            seq = self._seq
            if is_final:
                # The live line already shows this sentence (translated from a draft): keep it on screen as a
                # finished line until the final's translation replaces it, instead of the next sentence's first
                # words wiping it out for the ~0.2-2 s the translation takes.
                live = self.current_intermediate_transcription
                if live and self._live_seq > self._final_cut and live not in self.transcriptions:
                    self._pending[seq] = live
                    self.current_intermediate_transcription = None
                    self._append_final(live)
                    self._keep_original(live, text)
                self._sources[seq] = text
                self._final_cut = seq
        self.translator.submit(seq, text, is_final, src)
        if is_final:
            self.update_intermediate_label_text()

    def _show_live(self, seq, text):
        text = collapse_repeats(text)
        with self._display_lock:
            if seq <= self._final_cut or seq <= self._live_seq:
                return  # a final or a newer draft already took over the live line
            self._live_seq = seq
            self.current_intermediate_transcription = text
            self._trace("live_shown", text=text)
        self.update_intermediate_label_text()

    def _add_line(self, text):  # a finished line: shown, and kept for scrolling back
        self.transcriptions.append(text)
        self.transcription_times[text] = time.time()
        if self.history is None:
            self.history = deque(maxlen=HISTORY_LINES)
        self.history.append(text)

    def _replace_in_history(self, old, text):
        h = self.history or ()
        for i in range(len(h) - 1, max(len(h) - 50, 0) - 1, -1):  # it is one of the newest
            if h[i] == old:
                h[i] = text
                return

    def _append_final(self, text):
        """Shows a finished line; False if it is empty or the one just shown (a looping segment)."""
        if text and not (self.transcriptions and self.transcriptions[-1] == text):
            self._add_line(text)
            self._trace("final_shown", text=text)
            return True
        return False

    def _replace_final(self, old, text):
        """Swaps the shown line `old` for `text` in place, keeping its expiry. False if `old` is no longer shown."""
        if old not in self.transcriptions:
            return False
        if old != text:
            i = len(self.transcriptions) - 1 - list(reversed(self.transcriptions)).index(old)
            self.transcriptions[i] = text
            self._replace_in_history(old, text)
            shown = self.transcription_times.pop(old, time.time())
            self.transcription_times[text] = shown
            self._trace("final_upgraded", old=old, text=text, after_ms=round(1000 * (time.time() - shown)))
        return True

    def _keep_original(self, text, original):
        if original and original != text:
            self.originals[text] = original
            while len(self.originals) > HISTORY_LINES:
                del self.originals[next(iter(self.originals))]  # the oldest

    def _show_final(self, seq, text):
        text = collapse_repeats(text)
        with self._display_lock:
            original = self._sources.pop(seq, None)
            if seq <= self._drop_seq:
                return
            if self._live_seq <= seq:
                self.current_intermediate_transcription = None  # the live line was this sentence
            old = self._pending.pop(seq, None)
            new = (old is not None and self._replace_final(old, text)) or self._append_final(text)
            self._keep_original(text, original)
        self.update_intermediate_label_text()
        if new:
            self._chat(text, seq)

    chatbox = False  # the app's VRChat chatbox switch
    _chat_seq = 0  # the newest line sent to the chatbox

    def _chat(self, text, seq=None):
        """Sends a finished line to VRChat's chatbox on this PC: the engine's own OSC sender, which splits it into
        the chatbox's 144 characters and keeps messages 1.5 s apart. Send-only, nothing listens."""
        if not self.chatbox or not text or text in _TAGS:  # a sound ([music] in the world) isn't something said
            return
        if seq is not None:
            if seq < self._chat_seq:  # ponytail: a line that finished after a newer one is skipped, not reordered
                return  # (the chatbox shows one message: an older one last would hide the newest)
            self._chat_seq = seq
        try:
            import settings
            # what the engine listens to, not the window's choice: Listen to only changes at the next Start
            process = str(settings.GetOption("audio_input_process") or "").lower()
            device = str(settings.GetOption("audio_input_device") or "")
            if process != "vrchat.exe" and not (not process and device and not device.endswith("[Loopback]")):
                return
            import VRC_OSCLib
            gap = float(settings.GetOption("osc_min_time_between_messages") or 1.5)
            VRC_OSCLib.set_min_time_between_messages(gap)
            VRC_OSCLib.Chat_chunks(text, chunk_size=int(settings.GetOption("osc_chat_limit") or 144), delay=gap,
                                   initial_delay=gap, address=settings.GetOption("osc_address") or "/chatbox/input",
                                   ip="127.0.0.1", port=int(settings.GetOption("osc_port") or 9000))  # never another PC
        except Exception as e:  # a bad setting: the captions go on (only the error's kind: the log never gets words)
            print("VRChat chatbox failed:", type(e).__name__)

    def update_label(self, pipeline_text, result_obj, is_final=False):
        raw_source = str(result_obj.get("text") or "")
        source_text = strip_outro(raw_source)
        tag = sound_tag(source_text)
        if (raw_source.strip() and not source_text.strip()) or (
                tag is None and (is_filler(source_text) or is_char_loop(source_text) or is_fake(source_text))):
            if is_final and self._display_lock is not None:
                # Nothing worth showing; the live line belonged to this sentence, so clear it.
                with self._display_lock:
                    self._final_cut = self._seq
                    self.current_intermediate_transcription = None
                self.update_intermediate_label_text()
            return
        if tag is None and self._plugin_translates(result_obj):
            import settings
            src = self._source_language(result_obj)
            if src != settings.GetOption("trg_lang"):  # else already in the captions' language: shown as said
                self._submit_translation(source_text, is_final, src)
                return
        if is_final and self._display_lock is not None:
            with self._display_lock:
                self._final_cut = self._seq  # drafts still being translated are outdated now
        translated_text = tag or collapse_repeats(self._select_display_text(pipeline_text, result_obj))
        if is_final and self.transcriptions and self.transcriptions[-1] == translated_text:
            # Same line again (e.g. a looping segment): just clear the live line, don't stack a duplicate.
            self.current_intermediate_transcription = None
            self.update_intermediate_label_text()
            return

        if result_obj.get("streaming") and result_obj.get("display_mode") == "blocks":
            return
        if result_obj.get("streaming"):
            from streaming_text import StreamRevisionTracker, rolling_text
            if not hasattr(self, "_stream_revisions"):
                self._stream_revisions = StreamRevisionTracker()
                self._stream_intermediates = {}
            if not self._stream_revisions.accept(result_obj):
                return
            source_id = str(result_obj.get("audio_source_id") or "main")
            getattr(self, "_stable_captions", {}).pop(source_id, None)
            translated_text = rolling_text(translated_text, self.get_plugin_setting("streaming_max_characters", 500))
            if is_final:
                self._stream_intermediates.pop(source_id, None)
                if translated_text:
                    self._add_line(translated_text)
                    self._chat(translated_text)
            else:
                self._stream_intermediates[source_id] = translated_text
            self.update_intermediate_label_text()
            return

        # If this is a final transcription, add to transcriptions and reset intermediate text
        if is_final or (not is_final and not self.get_plugin_setting("extra_intermediate_line")):
            with self._display_lock:  # a translator thread may be swapping a line in place
                self._add_line(translated_text)
                self._keep_original(translated_text, source_text)
                self.current_intermediate_transcription = None
                self._trace("final_shown", text=translated_text)
            if is_final:
                self._chat(translated_text)
        else:
            # Otherwise, update the intermediate text
            if translated_text != self.current_intermediate_transcription:
                self._trace("live_shown", text=translated_text)
            self.current_intermediate_transcription = translated_text

        self.update_intermediate_label_text()

    def stt(self, text, result_obj):
        getattr(self, "_drafts", {}).pop(str(result_obj.get("audio_source_id") or "main"), None)
        if self.is_enabled(False) and (text.strip() != "" or result_obj.get("streaming")):
            self.update_label(text, result_obj, is_final=True)

    @staticmethod
    def _whisper_on_gpu():
        try:
            import settings
        except ImportError:
            return True
        return str(settings.GetOption("ai_device") or "").casefold() != "cpu"

    def stt_intermediate(self, text, result_obj):
        if self.is_enabled(False) and text.strip() != "":
            if not result_obj.get("streaming") and text.strip() == str(result_obj.get("text") or "").strip():
                # Whisper rewrites a sentence's newest words as it hears more, so a lone draft is often wrong. The
                # live line shows the newest draft less its last word (CJK: 3 characters), or what two drafts in a
                # row agree on if that's longer, so it needn't wait for the next draft (~0.5 s on GPU, ~2 s on CPU).
                # Bench: English 96% -> 97.5% accurate on GPU, 98% on CPU; Japanese 83% -> 86% on GPU, all +0-0.4 s.
                # Japanese on CPU waits for two drafts to agree: 73% -> 77-80%, +2 s (one draft: 73.5%).
                drafts = self.__dict__.setdefault("_drafts", {})
                source = str(result_obj.get("audio_source_id") or "main")
                prev, shown = drafts.get(source, ("", ""))
                agreed = agreed_start(prev, text)
                cjk = ord(text.rstrip()[-1]) >= 0x2E80
                if not cjk or self._whisper_on_gpu():
                    agreed = max(agreed, agreed_start(text, text, 3 if cjk else 1), key=len)
                drafts[source] = (text, agreed or shown)
                if not agreed or agreed == shown:
                    return
                text, result_obj = agreed, dict(result_obj, text=agreed)
            self.update_label(text, result_obj, is_final=False)

    def on_enable(self):
        self.init()

    def on_disable(self):
        self.stop()
