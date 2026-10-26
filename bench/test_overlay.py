# Check of the caption window: draws a caption with the app's caption style, changes the style live and checks what
# the canvases hold (no screenshot; the window opens off-screen, never visible). usage: python bench/test_overlay.py
import ctypes, importlib.util, json, os, queue, sys, tempfile, threading, time, types

sys.modules["Plugins"] = types.SimpleNamespace(Base=object)
path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "Plugins", "subtitle_display_plugin.py")
spec = importlib.util.spec_from_file_location("sdp", path)
sdp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sdp)
tmp = tempfile.mkdtemp()  # never the real app-settings.json / .captions-position
sdp.APP_SETTINGS = os.path.join(tmp, "app-settings.json")
sdp.POSITION_FILE = os.path.join(tmp, ".captions-position")
sdp.PAUSE_FILE = os.path.join(tmp, ".captions-paused")
sdp.APP_MUTEX = "Local\\PrivateCaptionsTest%d" % os.getpid()  # never the real app's
opts = {"stt_enabled": True}  # the engine's settings
sys.modules["settings"] = types.SimpleNamespace(GetOption=opts.get, SetOption=opts.__setitem__)
sdp.desktop = lambda root: (-40000, -40000, 35000, 35000)  # a pretend monitor far off the real ones: nothing shows


def write_style(style, n):
    with open(sdp.APP_SETTINGS, "w", encoding="utf-8") as f:
        json.dump(style, f)
    os.utime(sdp.APP_SETTINGS, (n, n))  # a new mtime, as the app's next save gives


class Stub(sdp.SubtitleDisplayPlugin):
    settings = {"top": 0, "bottom": 80, "window_width": 900, "window_height": 120, "transparency_color": "#FF00FF",
                "opacity": -0.01, "font_size": 20, "font_color": "white", "font_background_color": "black",
                "x_position": 0, "y_position": 0}

    def get_plugin_setting(self, name, default=None):
        return self.settings.get(name, default)

    def set_plugin_setting(self, name, value):
        self.settings[name] = value

    def is_enabled(self, default=True):
        return False


def pump(root, seconds):
    end = time.time() + seconds
    while time.time() < end:
        root.update()
        time.sleep(0.02)


def pump_until(root, done, timeout=3.0):  # the style is re-read every second
    end = time.time() + timeout
    while not done():
        assert time.time() < end, "timed out"
        pump(root, 0.05)


def no_focus_set(window):  # WS_EX_NOACTIVATE on Tk's frame window
    import ctypes
    u = ctypes.WinDLL("user32")
    u.GetParent.restype, u.GetParent.argtypes = ctypes.c_void_p, [ctypes.c_void_p]
    u.GetWindowLongW.argtypes = [ctypes.c_void_p, ctypes.c_int]
    return bool(u.GetWindowLongW(u.GetParent(window.winfo_id()), -20) & 0x08000000)


def visible(window):
    import ctypes
    u = ctypes.WinDLL("user32")
    u.GetParent.restype, u.GetParent.argtypes = ctypes.c_void_p, [ctypes.c_void_p]
    u.IsWindowVisible.argtypes = [ctypes.c_void_p]
    return bool(u.IsWindowVisible(u.GetParent(window.winfo_id())))


def items(canvas):
    return [canvas.type(i) for i in canvas.find_withtag("cc")]


def checks(_root=None, n=0):
    p, root = plugin, plugin.root
    root.update()
    s = p.cc_scale  # the display's scale (2.0 at 200%): saved positions and the profile's sizes are at 100%
    assert (root.winfo_x(), root.winfo_y()) == (round(-10000 * s),) * 2, "the saved position wins over the profile's"
    assert root.winfo_width() == round(900 * s), "the profile's width, scaled"
    p.update_queue.put((["first caption line here"], "and the live line"))
    pump(root, 0.3)
    texts = items(p.text_canvas)
    assert texts == ["text"], texts  # defaults: no edge copies
    assert items(p.canvas) == ["rectangle"] and items(p.box_canvas) == [], "bar, no window box"
    assert abs(float(root.attributes("-alpha")) - 0.75) < 0.01
    text_win = p.text_canvas.winfo_toplevel()
    assert str(text_win.wm_attributes("-transparentcolor")) == p.text_canvas.cget("bg") == "#090909", "letter edges blend into the bar"
    x0, y0 = root.winfo_x(), root.winfo_y()  # dragging the captions (here their bar) moves all three windows
    p.canvas.event_generate("<Button-1>", x=5, y=5, rootx=x0 + 5, rooty=y0 + 5)
    p.canvas.event_generate("<B1-Motion>", x=5, y=5, rootx=x0 + 105, rooty=y0 + 55)
    p.canvas.event_generate("<ButtonRelease-1>", x=5, y=5, rootx=x0 + 105, rooty=y0 + 55)
    root.update()
    assert (root.winfo_x(), root.winfo_y()) == (text_win.winfo_x(), text_win.winfo_y()) == (x0 + 100, y0 + 50)
    with open(sdp.POSITION_FILE) as f:
        assert json.load(f) == {"x": round((x0 + 100) / s), "y": round((y0 + 50) / s)}, "the new spot is kept"

    # scrolling back: the wheel shows earlier lines with a hint above them, a click or 15 s idle returns to live
    from collections import deque
    p.history = deque(f"Line {i}." for i in range(6))
    x0, y0, h0 = root.winfo_x(), root.winfo_y(), root.winfo_height()
    shown = lambda: [p.text_canvas.itemcget(i, "text") for i in p.text_canvas.find_withtag("cc")]
    p.text_canvas.event_generate("<MouseWheel>", delta=120)
    root.update()
    assert shown() == ["Line 4.", "Line 3.", sdp.HISTORY_HINT], shown()
    assert (root.winfo_y(), root.winfo_height()) == (y0 - p.cc_hint_h, h0 + p.cc_hint_h), "the hint grows the top, not the bottom"
    assert p.text_canvas.bbox(p.text_canvas.find_withtag("cc")[-1])[1] >= 0, "the hint fits in the window"
    p.update_queue.put((["a new line"], ""))
    pump(root, 0.1)
    assert "a new line" not in shown(), "new lines wait while scrolled back"
    p.text_canvas.event_generate("<MouseWheel>", delta=1200)
    root.update()
    assert shown() == ["Line 1.", "Line 0.", sdp.HISTORY_HINT], "no further back than the oldest line"
    p.text_canvas.event_generate("<MouseWheel>", delta=-60)
    p.text_canvas.event_generate("<MouseWheel>", delta=-60)  # a touchpad's half notches
    root.update()
    assert shown()[0] == "Line 2.", shown()
    p.canvas.event_generate("<Button-1>", x=5, y=5, rootx=x0 + 5, rooty=y0 + 5)
    p.canvas.event_generate("<ButtonRelease-1>", x=5, y=5, rootx=x0 + 5, rooty=y0 + 5)
    root.update()
    assert shown() == ["a new line"] and (root.winfo_x(), root.winfo_y(), root.winfo_height()) == (x0, y0, h0), "a click: live"
    p.text_canvas.event_generate("<MouseWheel>", delta=120)
    p.cc_back_at -= sdp.HISTORY_IDLE + 1
    pump(root, 0.1)
    assert shown() == ["a new line"] and root.winfo_height() == h0, "idle: live again"
    p.text_canvas.event_generate("<MouseWheel>", delta=120)
    p.text_canvas.event_generate("<MouseWheel>", delta=-240)
    root.update()
    assert shown() == ["a new line"] and root.winfo_height() == h0, "scrolled down past the newest: live"

    # Show original: the spoken line, small, above the captions; scrolling back shows it above each line
    y0 = root.winfo_y()
    write_style({"showOriginal": True}, 1_500_000_000)
    pump_until(root, lambda: p.cc_original)
    assert (root.winfo_y(), root.winfo_height()) == (y0 - p.cc_hint_h, h0 + p.cc_hint_h), "a small row more, the bottom stays"
    p.originals.update({"a new line": "新しい行", "Line 4.": "四", "Line 3.": "三"})
    p.update_queue.put((["a new line"], "and live"))
    pump(root, 0.1)
    t = p.text_canvas.find_withtag("cc")
    assert shown() == ["a new line and live", "新しい行"], shown()
    assert p.text_canvas.itemcget(t[1], "font") == str(p.cc_hint_font), "smaller"
    p.originals["a new line"] = "長" * 400
    p.update_queue.put((["a new line"], ""))
    pump(root, 0.1)
    x1, _, x2, _ = p.text_canvas.bbox(p.text_canvas.find_withtag("cc")[1])
    assert shown()[1].startswith("…長") and x1 >= 0 and x2 <= root.winfo_width(), "a long one: its end, on one row"
    p.text_canvas.event_generate("<MouseWheel>", delta=120)
    root.update()
    assert shown() == ["Line 4.", "四", "Line 3.", sdp.HISTORY_HINT], shown()
    assert p.text_canvas.bbox(p.text_canvas.find_withtag("cc")[-1])[1] >= 0, "two lines, an original and the hint fit"
    p.text_canvas.event_generate("<MouseWheel>", delta=120)
    root.update()
    assert shown() == ["Line 3.", "三", sdp.HISTORY_HINT], "never an original whose line scrolled off below"
    p.text_canvas.event_generate("<MouseWheel>", delta=-240)
    write_style({"vrchatChatbox": True}, 1_560_000_000)
    pump_until(root, lambda: p.chatbox and not p.cc_original)
    write_style({}, 1_600_000_000)
    pump_until(root, lambda: not p.cc_original and not p.chatbox)
    assert (root.winfo_y(), root.winfo_height()) == (y0, h0), "off: as before"

    # Stop in the app: the captions hide at once and the engine stops listening; Start shows them again, emptied
    wins = (root, p.box_canvas.winfo_toplevel(), p.text_canvas.winfo_toplevel())
    assert all(map(visible, wins))
    p.transcriptions.append("said before Stop")
    open(sdp.PAUSE_FILE, "w").close()
    pump(root, 0.1)
    assert not any(map(visible, wins)) and opts["stt_enabled"] is False and shown() == [], "paused"
    assert list(p.transcriptions) == [] and p.history is None, "what was said before Stop is gone"
    opts["stt_enabled"] = True  # the engine starting turns listening on: still paused
    p.update_queue.put((["said while paused"], ""))
    pump(root, 0.1)
    assert opts["stt_enabled"] is False and shown() == [] and not any(map(visible, wins))
    # the app was killed while paused: the engine closes its own console (it would hold the GPU, unseen, forever)
    closed = []
    sdp.close_console, sdp.APP_CHECK_TICKS = (lambda: closed.append(1)), 3
    k32 = ctypes.WinDLL("kernel32")
    k32.CreateMutexW.restype = ctypes.c_void_p
    held = k32.CreateMutexW(None, False, sdp.APP_MUTEX)
    assert sdp.app_open()
    pump(root, 0.2)
    assert closed == [], "the app is open: stays loaded"
    k32.CloseHandle(ctypes.c_void_p(held))
    assert not sdp.app_open()
    pump(root, 0.2)
    assert closed, "the app is gone: closes"
    os.remove(sdp.PAUSE_FILE)
    pump(root, 0.1)
    assert all(map(visible, wins)) and opts["stt_enabled"] is True and shown() == [], "Start: shown again, nothing old"
    p.update_queue.put((["a new line"], ""))
    pump(root, 0.1)
    assert shown() == ["a new line"]

    write_style({"captionColor": "Magenta", "captionSize": "200", "captionEdge": "Outline", "captionWindow": "50",
                 "captionWindowColor": "Blue", "captionBackground": "0", "captionOpacity": "50"}, 2_000_000_000)
    pump_until(root, lambda: p.cc_font.cget("size") == 40)
    pump(root, 0.1)
    assert all(no_focus_set(w) for w in (root, p.box_canvas.winfo_toplevel(), p.text_canvas.winfo_toplevel())), \
        "clicking the captions never takes the keyboard from the video"
    t = p.text_canvas.find_withtag("cc")
    assert len(t) in (9, 18), len(t)  # per line 8 outline copies + the text, redrawn without a new caption
    assert p.text_canvas.itemcget(t[-1], "fill") == "#FE00FE", "magenta must not be the see-through color"
    assert p.cc_font.cget("size") == 40
    assert items(p.canvas) == [] and items(p.box_canvas) == ["rectangle"], "no bar, a window box"
    assert p.box_canvas.itemcget(p.box_canvas.find_withtag("cc")[0], "fill") == "#0000FF"
    assert p.text_canvas.cget("bg") == "#090909", "no bar color picked: still YouTube's black"
    assert abs(float(p.text_canvas.winfo_toplevel().attributes("-alpha")) - 0.5) < 0.01
    assert root.winfo_height() == p.box_canvas.winfo_toplevel().winfo_height(), "the three windows stay together"

    write_style({"captionFont": "Small Capitals", "captionSize": "oops"}, 2_000_000_100)
    pump_until(root, lambda: p.cc_font.cget("size") == 17)
    pump(root, 0.1)
    t = p.text_canvas.find_withtag("cc")
    assert p.text_canvas.itemcget(t[-1], "text").isupper() and p.cc_font.cget("size") == 17, "small capitals, size 100%"

    with open(sdp.APP_SETTINGS, "w") as f:
        f.write('{"captionSize": "1')  # half-written by the app: keep the last style, try again
    os.utime(sdp.APP_SETTINGS, (2_000_000_200, 2_000_000_200))
    pump(root, 1.3)
    assert p.cc_font.cget("size") == 17
    with open(sdp.POSITION_FILE) as f:  # a style change moved the top edge: saved for every mode
        assert json.load(f) == {"x": round(root.winfo_x() / s), "y": round(root.winfo_y() / s)}
    root.destroy()
    print("overlay ok")


write_style({}, 1_000_000_000)
with open(sdp.POSITION_FILE, "w") as f:
    json.dump({"x": -10000, "y": -10000}, f)  # off-screen; dragged there earlier, maybe in another mode
plugin = Stub()
plugin.update_queue = queue.Queue()
plugin._display_lock = threading.RLock()  # as init() makes it
plugin.transcriptions, plugin.transcription_times, plugin._pending = [], {}, {}
plugin._sources, plugin.originals = {}, {}
sdp.tk.Tk.mainloop = checks  # run the checks in place of the window's main loop
plugin.tkinter_thread_func()
