# TEMPORARY benchmark harness (copied into Plugins/ only for a benchmark run; active while ../bench.flag exists).
# - Remote-audio results (the silent benchmark feed) also go to the plugins, like the main route does.
# - The remote-audio route uses the profile's phrase_time_limit like live captions (the engine forces 30 s there).
# - The subtitle overlay runs headless and logs every frame / trace event to probe/display.jsonl.
import json
import os
import sys
import threading
import time

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
LOG = os.path.join(ROOT, "probe", "display.jsonl")
_log_lock = threading.Lock()


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
    # Plugins load while audioprocessor is still importing; patch it once it is complete.
    threading.Thread(target=patch_send_message, daemon=True).start()
    threading.Thread(target=patch_remote_phrase_limit, daemon=True).start()


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
        return settings.GetOption(name) if name == "phrase_time_limit" else orig(self, name)

    cls.GetOption = cls.get_option = get_option
    log(ev="phrase_limit_patched", value=settings.GetOption("phrase_time_limit"))


if os.path.exists(os.path.join(ROOT, "bench.flag")):
    os.makedirs(os.path.dirname(LOG), exist_ok=True)
    install()
