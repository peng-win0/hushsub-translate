# Offline check: a final equal to a recent or in-flight draft reuses that draft's translation (no second model run),
# and a queued line keeps the language it was spoken in when spoken "Auto" switches.
# usage: python bench/test_translator.py
import importlib.util, os, sys, threading, time, types

sys.modules["Plugins"] = types.SimpleNamespace(Base=object)
path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "Plugins", "subtitle_display_plugin.py")
spec = importlib.util.spec_from_file_location("sdp", path)
sdp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sdp)


class Stub(sdp.PluginTranslator):
    calls = []
    srcs = {}

    def _fast_loop(self):  # two workers like MiLMMT, no model
        threading.Thread(target=self._work_loop, args=(True, False), daemon=True).start()
        self._work_loop(False, True)

    def _fast_translate(self, text, src):
        self.calls.append(text)
        self.srcs[text] = src
        time.sleep(0.2)
        return "T:" + text

    @staticmethod
    def _languages():  # no engine settings offline
        return JA, "eng_Latn"


JA = "jpn_Jpan"


def wait(done, timeout=5.0):
    """Until done() holds: a slow CI runner gets time, a fast run doesn't sit in fixed sleeps."""
    end = time.monotonic() + timeout
    while not done():
        assert time.monotonic() < end, "timed out"
        time.sleep(0.01)


finals, lives = {}, {}
t = Stub(lambda s, x: lives.__setitem__(s, x), lambda s, x: finals.__setitem__(s, x), None, upgrade=False)
t.submit(1, "A", False, JA); time.sleep(0.05); t.submit(2, "A", True, JA)  # final while the draft is in flight
wait(lambda: 2 in finals)
t.submit(3, "B", False, JA); wait(lambda: 3 in lives); t.submit(4, "B", True, JA)   # final after the draft finished
t.submit(5, "C", True, JA)                                              # nothing to reuse
wait(lambda: 4 in finals and 5 in finals)
assert finals == {2: "T:A", 4: "T:B", 5: "T:C"}, finals
assert t.calls == ["A", "B", "C"], t.calls
gpath = os.path.join(os.environ.get("TEMP", "."), "wt-test-glossary.txt")
with open(gpath, "w", encoding="utf-8") as f:
    f.write("# a comment\nクロニー = Kronii\nスパチャ = スーパーチャット\nAWS = Amazon Web Services\ncooper netties = Kubernetes\n")
t.glossary_file = gpath  # the shipped glossary.txt is only a template
assert sdp.load_glossary(gpath)("Laws on aws, AWSの話, Cooper Netties.") == "Laws on Amazon Web Services, Amazon Web Servicesの話, Kubernetes.", \
    sdp.load_glossary(gpath)("Laws on aws, AWSの話, Cooper Netties.")  # whole Latin words in any case; inside Japanese too
assert sdp.load_glossary(os.devnull) is None
t.submit(6, "クロニーとスパチャ", True, JA)                               # glossary.txt applied before translation
wait(lambda: 6 in finals)
assert finals[6] == "T:Kroniiとスーパーチャット", finals[6]
t.submit(10, "we run cooper netties", True, "eng_Latn")                   # and for every spoken language
wait(lambda: 10 in finals)
assert finals[10] == "T:we run Kubernetes", finals[10]
with open(gpath, "a", encoding="utf-8") as f:
    f.write("ぺこら = Pekora\n")                                    # the app's Your words saved a new word...
os.utime(gpath, (time.time() + 5, time.time() + 5))
t.submit(11, "ぺこらとクロニー", True, JA)                                # ...used from the next line, no restart
wait(lambda: 11 in finals)
assert finals[11] == "T:PekoraとKronii", finals[11]
t.submit(7, "D", True, JA); t.submit(8, "E", True, JA)                     # E waits while D translates...
t.submit(9, "F", True, "kor_Hang")                                  # ...then Whisper hears Korean
wait(lambda: 9 in finals)
assert (t.srcs["D"], t.srcs["E"], t.srcs["F"]) == ("jpn_Jpan", "jpn_Jpan", "kor_Hang"), t.srcs


class NoFast(Stub):  # the fast translator failed to load; LFM2 (Japanese<->English only) re-translates finals
    def _fast_translate(self, text, src):
        return None

    def _load_lfm2(self):
        return object()

    def _lfm2_translate(self, text, trg):
        return "L:" + text


ups = []
u = NoFast(None, None, lambda old, x: ups.append((old, x)), upgrade=True)
u.submit(1, "G", True, "kor_Hang"); u.submit(2, "H", True, JA)          # LFM2 can't do Korean: the source text shows
wait(lambda: len(ups) == 2)
assert ups == [(1, "G"), (2, "L:H")], ups


class Both(Stub):  # Fast mode: NLLB, then LFM2 for Japanese<->English; only one version of a line ever shows
    def _load_lfm2(self):
        return object()

    def _lfm2_translate(self, text, trg):
        return "L:" + text


early, ups = {}, []
f = Both(None, lambda s, x: early.__setitem__(s, x), lambda old, x: ups.append((old, x)), upgrade=True)
f.submit(1, "R", True, JA); f.submit(2, "S", True, "kor_Hang")    # Korean: LFM2 can't, the fast text shows
wait(lambda: len(ups) == 2)
assert early == {} and ups == [(1, "L:R"), (2, "T:S")], (early, ups)


class NoneLoads(Stub):  # neither translator works: every final still shows, as its source text
    def _fast_translate(self, text, src):
        return None

    def _load_lfm2(self):
        time.sleep(0.3)  # a final queues for it while it loads
        return None


shown, gave_up = {}, []
n = NoneLoads(None, lambda s, x: shown.__setitem__(s, x), lambda old, x: gave_up.append((old, x)), upgrade=True)
n.submit(1, "K", True, JA)                          # queued for the good pass, which then fails to load
wait(lambda: gave_up)
n.submit(2, "M", True, JA)                          # after it gave up: shown right away
wait(lambda: shown)
assert gave_up == [(1, "K")] and shown == {2: "M"}, (gave_up, shown)

bad = {}


def show_once_bad(s, x):  # the display fails on one line: the next lines must still show
    if x == "T:P":
        raise RuntimeError("display failed")
    bad[s] = x


b = Stub(None, show_once_bad, None, upgrade=False)
b.submit(1, "P", True, JA); b.submit(2, "Q", True, JA)
wait(lambda: bad)
assert bad == {2: "T:Q"}, bad
print("OK")
