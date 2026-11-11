# TEMPORARY benchmark harness (copied into Plugins/ only for a benchmark run; active while ../bench.flag exists).
# - Remote-audio results (the silent benchmark feed) also go to the plugins, like the main route does.
# - The remote-audio route uses the profile's phrase_time_limit like live captions (the engine forces 30 s there).
# - The subtitle overlay runs headless and logs every frame / trace event to probe/display.jsonl.
import json
import os
import re
import sys
import threading
import time

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
LOG = os.path.join(ROOT, "probe", "display.jsonl")
_log_lock = threading.Lock()
TEXT_PAUSE = {"low": 0.0, "now": None, "used": 0}  # a run named TPAUSEnn: pause nn/100 s after a draft ends a sentence


def log(**kw):
    kw["t"] = round(time.time() * 1000)
    with _log_lock, open(LOG, "a", encoding="utf-8") as f:
        f.write(json.dumps(kw, ensure_ascii=False) + "\n")


def install():
    import Plugins

    cls = next(c for c in Plugins.Base.__subclasses__() if c.__name__ == "SubtitleDisplayPlugin")

    def headless(self):
        last = None
        while True:
            finals, live = self.update_queue.get()
            text = "\n".join(finals + [live] if live else finals)
            if text != last:
                log(ev="frame", text=text)
                last = text

    cls.tkinter_thread_func = headless
    cls._trace = lambda self, ev, **kw: log(ev=ev, **kw)
    run = os.path.basename(next((a for a in sys.argv if a.endswith(".yaml")), ""))
    # a run named GATEnn: no new draft once nn hundredths of a second have passed since the last speech chunk
    gate = re.search(r"GATE(\d\d)", run)
    threading.Thread(target=patch_cut_hook, args=(float(f"0.{gate[1]}") if gate else 0.0,), daemon=True).start()
    # EARLY_FINAL=seconds, or a run named EARLYnn (bench.sh EARLY10A:profile = 0.10 s): the early-final experiment.
    # Both can be on: EARLY10GATE10A.
    early = re.search(r"EARLY(\d\d)", run)
    head = os.environ.get("EARLY_FINAL") or (f"0.{early[1]}" if early else "")
    if head:
        threading.Thread(target=patch_early_final, args=(float(head),), daemon=True).start()
    tp = re.search(r"TPAUSE(\d\d)", run)
    TEXT_PAUSE["low"] = float(f"0.{tp[1]}") if tp else 0.0
    if "NODRTR" in run:  # drafts are not translated (no English live line): does translating them delay finals?
        orig_sub = cls._submit_translation
        cls._submit_translation = lambda self, text, is_final, *a, **k: orig_sub(self, text, is_final, *a, **k) if is_final else None
    if run[:5] == "SHORT":  # a run named SHORTx: Whisper's encoder sees the clip's length, not a padded 30 s window
        threading.Thread(target=patch_short_window, daemon=True).start()
    # Plugins load while audioprocessor is still importing; patch it once it is complete.
    threading.Thread(target=patch_send_message, daemon=True).start()
    threading.Thread(target=patch_remote_phrase_limit, daemon=True).start()


def patch_early_final(head):
    """Experiment (EARLY_FINAL=seconds): start Whisper's final pass after `head` s of silence, not after the
    full pause. When the pause ends with the same audio, the worker's own final pass gets that result."""
    import hashlib

    import numpy as np

    def ready():
        rec, fw, ap = (sys.modules.get(n) for n in ("audio_processing_recording", "Models.STT.faster_whisper", "audioprocessor"))
        return hasattr(rec, "AudioProcessor") and hasattr(fw, "FasterWhisper") and hasattr(ap, "convert_audio") and hasattr(ap, "whisper_ai_thread")

    while not ready():
        time.sleep(0.2)
    import audio_tools

    rec_cls = sys.modules["audio_processing_recording"].AudioProcessor
    fw_cls = sys.modules["Models.STT.faster_whisper"].FasterWhisper
    ap = sys.modules["audioprocessor"]
    memo, memo_lock, tl = {}, threading.Lock(), threading.local()
    state = {"model": None, "kw": None}
    orig_tr, orig_cb, orig_thread = fw_cls.transcribe, rec_cls._callback_locked, ap.whisper_ai_thread

    def key_of(audio, kw):
        return hashlib.blake2b(np.ascontiguousarray(audio).tobytes(), digest_size=16).hexdigest() + repr(sorted(kw.items()))

    def transcribe(self, audio_sample, *a, **kw):
        if a:
            return orig_tr(self, audio_sample, *a, **kw)
        state["model"], state["kw"] = self, dict(kw)
        final, t0 = getattr(tl, "final", False), time.time()
        with memo_lock:
            slot = memo.get(key_of(audio_sample, kw))
        if slot is not None and slot[0].wait(10) and slot[1] is not None:
            if final:
                log(ev="early_hit", wait=round((time.time() - t0) * 1000))
            return slot[1]
        if final:
            log(ev="early_miss", spec=slot is not None)
        return orig_tr(self, audio_sample, **kw)

    def whisper_ai_thread(*a, **k):
        tl.final = a[5] if len(a) > 5 else k.get("final_audio", False)
        try:
            return orig_thread(*a, **k)
        finally:
            tl.final = False

    def speculate(rec, frames):
        """The recorder's flush steps (normalize, silence cut, WAV) and the worker's WAV-to-array step, early."""
        t0, g = time.time(), rec.settings.GetOption
        if g("denoise_audio") or g("vad_on_full_clip"):
            return  # those change the final audio after the flush
        data = b"".join(frames)
        if rec.needs_sample_rate_conversion:
            data = audio_tools.resample_audio(data, rec.recorded_sample_rate, rec.default_sample_rate, target_channels=1,
                                              input_channels=rec.input_channel_num).tobytes()
        if g("normalize_enabled") and len(data) >= rec.block_size_samples:
            data = audio_tools.convert_audio_datatype_to_float(np.frombuffer(data, np.int16))
            data, _ = audio_tools.normalize_audio_lufs(data, rec.default_sample_rate, g("normalize_lower_threshold"),
                                                       g("normalize_upper_threshold"), g("normalize_gain_factor"), verbose=False)
            data = audio_tools.convert_audio_datatype_to_integer(data, np.int16)
        if g("silence_cutting_enabled"):
            arr = np.frombuffer(data, np.int16) if isinstance(data, bytes) else data
            if len(arr) >= rec.block_size_samples:
                data = audio_tools.remove_silence_parts(arr, rec.default_sample_rate, silence_offset=g("silence_offset"),
                                                        max_silence_length=g("max_silence_length"),
                                                        keep_silence_length=g("keep_silence_length"), verbose=False)
        if isinstance(data, np.ndarray):
            data = data.tobytes()
        if not data:
            return
        # = ap.convert_audio(wav of data) for 16 kHz mono int16, without its pydub/ffprobe call: running that next to
        # the worker's own one broke the worker's (JSONDecodeError in mediainfo_json, run EARLY10A)
        audio = np.frombuffer(data, np.int16).flatten().astype(np.float32) / 32768.0
        kw = state["kw"]
        k, slot = key_of(audio, kw), [threading.Event(), None]
        with memo_lock:
            if k in memo:
                return
            memo[k] = slot
            while len(memo) > 8:
                memo.pop(next(iter(memo)))
        try:
            slot[1] = orig_tr(state["model"], audio, **kw)
        except Exception as e:  # noqa: BLE001 - an experiment must never stop captions
            log(ev="early_error", err=repr(e))
        finally:
            slot[0].set()
        log(ev="early_done", ms=round((time.time() - t0) * 1000))

    def callback_locked(self, *a, **k):
        r = orig_cb(self, *a, **k)
        try:  # runs under the recorder's lock, so frames and start_time agree
            if self.frames and state["model"] is not None and time.time() - self.start_time >= head \
                    and getattr(self, "_early_tag", None) != self.start_time:
                self._early_tag = self.start_time
                threading.Thread(target=speculate, args=(self, list(self.frames)), daemon=True).start()
        except Exception as e:  # noqa: BLE001
            log(ev="early_error", err=repr(e))
        return r

    fw_cls.transcribe, rec_cls._callback_locked, ap.whisper_ai_thread = transcribe, callback_locked, whisper_ai_thread
    log(ev="early_final_ready", head=head)


def patch_short_window():
    """Experiment: pad each window to the clip's length plus 1 s, not to 30 s. If CTranslate2 refuses the shorter
    input, log it once and go back to 30 s, so the run still scores."""
    while not hasattr(sys.modules.get("faster_whisper.transcribe"), "WhisperModel"):
        time.sleep(0.2)
    fwt = sys.modules["faster_whisper.transcribe"]
    orig_pad, orig_enc, on, seen = fwt.pad_or_trim, fwt.WhisperModel.encode, [True], [0]

    def pad(array, length=3000, **k):
        n = array.shape[k.get("axis", -1)]
        return orig_pad(array, min(length, n + 100 + n % 2) if on[0] else length, **k)

    def encode(self, features):
        if seen[0] < 5:  # proves the window really shrank (an older faster-whisper pads 30 s before this point)
            seen[0] += 1
            log(ev="short_shape", shape=list(getattr(features, "shape", ())))
        try:
            return orig_enc(self, features)
        except Exception as e:  # noqa: BLE001
            if on[0]:
                on[0] = False
                log(ev="short_error", err=repr(e))
            return orig_enc(self, orig_pad(features, 3000))

    fwt.pad_or_trim, fwt.WhisperModel.encode = pad, encode
    log(ev="short_window_ready")


def patch_cut_hook(gate=0.0):
    """Log when the recorder queues a final clip for Whisper, and its last speech-chunk time (start_time).
    gate > 0: drop drafts queued after `gate` s of silence, so the final pass doesn't wait behind one."""
    while not hasattr(sys.modules.get("audio_processing_recording"), "AudioProcessor"):
        time.sleep(0.2)
    rec_cls = sys.modules["audio_processing_recording"].AudioProcessor
    orig = rec_cls._queue_audio

    def queue_audio(self, audio_data, final, *a, **k):
        if final:
            log(ev="cut", last=round(self.start_time * 1000))
        elif gate and time.time() - self.start_time > gate:
            log(ev="draft_gated")
            return None
        return orig(self, audio_data, final, *a, **k)

    rec_cls._queue_audio = queue_audio
    log(ev="cut_hook_ready")


def patch_send_message():
    import Plugins
    while not hasattr(sys.modules.get("audioprocessor"), "send_message"):
        time.sleep(0.2)
    audioprocessor = sys.modules["audioprocessor"]
    orig_send = audioprocessor.send_message

    def send_message(predicted_text, result_obj, final_audio, settings, plugins):
        if getattr(settings, "remote_result", None) is not None:
            obj = dict(result_obj, audio_source_id="main")
            log(ev="final_in" if final_audio else "draft_in", text=obj.get("text"),
                tr=obj.get("txt_translation"))
            if TEXT_PAUSE["low"]:  # the engine re-reads pause every 32 ms tick
                ends = (obj.get("text") or "").strip().endswith(("。", "？", "！", "?", "!", "."))
                TEXT_PAUSE["now"] = TEXT_PAUSE["low"] if ends and not final_audio else None
            if final_audio or settings.GetOption("realtime"):
                threading.Thread(target=audioprocessor.plugin_process,
                                 args=(plugins or Plugins.plugins, predicted_text, obj, final_audio, settings)).start()
        return orig_send(predicted_text, result_obj, final_audio, settings, plugins)

    audioprocessor.send_message = send_message
    log(ev="harness_ready")


def patch_remote_phrase_limit():
    while not hasattr(sys.modules.get("remote_audio"), "RemoteSettings"):
        time.sleep(0.2)
    import settings
    cls = sys.modules["remote_audio"].RemoteSettings
    orig = cls.GetOption

    def get_option(self, name):
        if name == "pause" and TEXT_PAUSE["now"] is not None:
            TEXT_PAUSE["used"] += 1
            if TEXT_PAUSE["used"] % 50 == 1:  # proves the recorder reads it (a tick at a time, so sampled)
                log(ev="tpause_used", n=TEXT_PAUSE["used"])
            return TEXT_PAUSE["now"]
        return settings.GetOption(name) if name == "phrase_time_limit" else orig(self, name)

    cls.GetOption = cls.get_option = get_option
    log(ev="phrase_limit_patched", value=settings.GetOption("phrase_time_limit"))


if os.path.exists(os.path.join(ROOT, "bench.flag")):
    os.makedirs(os.path.dirname(LOG), exist_ok=True)
    install()
