# Test audio in each language: the first clips of Google's FLEURS test sets (people reading Wikipedia sentences,
# CC BY 4.0), to measure recognition per language. Reads each language's archive only up to its last needed clip
# (~5 MB, not the whole 0.4 GB). Read speech is easier than the TV clips in bench/clips: compare languages with it.
# usage: python -I bench/fleurs.py [clips per language, 12] [FLEURS config ...]   (skips languages it already has)
#   -> bench/out/fleurs/<code>.raw (16 kHz mono PCM16), .refs.json, .ends.json, and lang_<code>.yaml (a copy of the
#   balanced profile in that language, captions in English; English's in Japanese). Then, for each language:
#   RAW=bench/out/fleurs/<code>.raw REFS=bench/out/fleurs/<code>.refs.json ENDS=bench/out/fleurs/<code>.ends.json \
#     sh bench/bench.sh lang_<code>:bench/out/fleurs/lang_<code>.yaml
import json
import os
import re
import subprocess
import sys
import tarfile
import urllib.request

B = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(B, "out", "fleurs")
FFMPEG = os.path.join(B, "..", "toolchain", "ffmpeg", "bin", "ffmpeg.exe")
URL = "https://huggingface.co/datasets/google/fleurs/resolve/70bb2e84b976b7e960aa89f1c648e09c59f894dd/data/{}/"  # pinned: the same clips on every run, even if the tar.gz files are dropped from main
# FLEURS config: Whisper code, NLLB code. The app's languages first (FLEURS has Mandarin in simplified only), then the
# other languages MiLMMT-46 translates.
LANGS = {
    "en_us": ("en", "eng_Latn"), "cmn_hans_cn": ("zh", "zho_Hans"), "es_419": ("es", "spa_Latn"), "fr_fr": ("fr", "fra_Latn"),
    "pt_br": ("pt", "por_Latn"), "ru_ru": ("ru", "rus_Cyrl"), "id_id": ("id", "ind_Latn"), "de_de": ("de", "deu_Latn"),
    "ja_jp": ("ja", "jpn_Jpan"), "vi_vn": ("vi", "vie_Latn"), "tr_tr": ("tr", "tur_Latn"), "ko_kr": ("ko", "kor_Hang"),
    "it_it": ("it", "ita_Latn"), "pl_pl": ("pl", "pol_Latn"), "nl_nl": ("nl", "nld_Latn"),
    "ar_eg": ("ar", "arb_Arab"), "az_az": ("az", "azj_Latn"), "bg_bg": ("bg", "bul_Cyrl"), "bn_in": ("bn", "ben_Beng"),
    "ca_es": ("ca", "cat_Latn"), "cs_cz": ("cs", "ces_Latn"), "da_dk": ("da", "dan_Latn"), "el_gr": ("el", "ell_Grek"),
    "fa_ir": ("fa", "pes_Arab"), "fi_fi": ("fi", "fin_Latn"), "he_il": ("he", "heb_Hebr"), "hi_in": ("hi", "hin_Deva"),
    "hr_hr": ("hr", "hrv_Latn"), "hu_hu": ("hu", "hun_Latn"), "kk_kz": ("kk", "kaz_Cyrl"), "km_kh": ("km", "khm_Khmr"),
    "lo_la": ("lo", "lao_Laoo"), "ms_my": ("ms", "zsm_Latn"), "my_mm": ("my", "mya_Mymr"), "nb_no": ("no", "nob_Latn"),
    "ro_ro": ("ro", "ron_Latn"), "sk_sk": ("sk", "slk_Latn"), "sl_si": ("sl", "slv_Latn"), "sv_se": ("sv", "swe_Latn"),
    "ta_in": ("ta", "tam_Taml"), "th_th": ("th", "tha_Thai"), "fil_ph": ("tl", "tgl_Latn"), "ur_pk": ("ur", "urd_Arab"),
    "uz_uz": ("uz", "uzn_Latn"), "yue_hant_hk": ("yue", "yue_Hant"),
}
LEAD, GAP = 1.0, 4.5  # s of silence before the first clip and after each (score.mjs waits 4.5 s for a clip's final)


def fetch(cfg, n):
    with urllib.request.urlopen(URL.format(cfg) + "test.tsv", timeout=60) as r:
        rows = {c[1]: (c[0], c[2]) for c in (line.split("\t") for line in r.read().decode("utf-8").splitlines()) if len(c) > 2}
    pcm, refs, ends, seen = bytearray(int(LEAD * 32000)), [], [], set()
    with urllib.request.urlopen(URL.format(cfg) + "audio/test.tar.gz", timeout=60) as r, tarfile.open(fileobj=r, mode="r|gz") as tar:
        for m in tar:  # stream order; stops reading the download once n clips are in
            sid, text = rows.get(os.path.basename(m.name), (None, None))
            if not m.isfile() or sid is None or sid in seen:
                continue  # the same sentence read again by someone else
            seen.add(sid)
            wav = tar.extractfile(m).read()
            pcm += subprocess.run([FFMPEG, "-v", "error", "-i", "pipe:0", "-f", "s16le", "-ac", "1", "-ar", "16000", "pipe:1"],
                                  input=wav, capture_output=True, check=True).stdout
            refs.append({"file": os.path.basename(m.name), "text": text})
            ends.append(round(len(pcm) / 32))
            pcm += bytes(int(GAP * 32000))
            if len(refs) == n:
                break
    return pcm, refs, ends


def main():
    n = int(sys.argv[1]) if len(sys.argv) > 1 else 12
    cfgs = sys.argv[2:] or list(LANGS)
    os.makedirs(OUT, exist_ok=True)
    with open(os.path.join(B, "..", "app", "Profiles", "balanced.yaml"), encoding="utf-8") as f:
        profile = f.read()
    for cfg in cfgs:
        code, nllb = LANGS[cfg]
        if os.path.exists(os.path.join(OUT, f"lang_{code}.yaml")):  # written last: this language is complete
            continue
        for attempt in range(3):  # a stalled download ends on urlopen's timeout and starts over
            try:
                pcm, refs, ends = fetch(cfg, n)
                break
            except Exception as e:
                print(f"{cfg}: try {attempt + 1} failed: {e}")
        else:
            continue  # one missing language doesn't stop the rest; the next run tries it again
        base = os.path.join(OUT, code)
        with open(base + ".raw", "wb") as f:
            f.write(pcm)
        with open(base + ".refs.json", "w", encoding="utf-8") as f:
            json.dump(refs, f, ensure_ascii=False, indent=1)
        with open(base + ".ends.json", "w") as f:
            json.dump(ends, f)
        trg = "jpn_Jpan" if nllb == "eng_Latn" else "eng_Latn"
        p = re.sub(r"(?m)^current_language: .*$", f"current_language: '{code}'", profile)
        p = re.sub(r"(?m)^src_lang: .*$", f"src_lang: {nllb}", p)
        p = re.sub(r"(?m)^trg_lang: .*$", f"trg_lang: {trg}", p)
        with open(os.path.join(OUT, f"lang_{code}.yaml"), "w", encoding="utf-8") as f:
            f.write(p)
        print(f"{cfg}: {len(refs)} clips, {len(pcm) / 32000:.0f} s")


if __name__ == "__main__":
    main()
