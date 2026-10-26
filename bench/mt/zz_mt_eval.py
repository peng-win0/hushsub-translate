# TEMPORARY translation eval (copied into Plugins/ only for a run by bench/mt/mt-run.sh; active while ../mt_eval.flag exists).
# MiLMMT-46-4B (int8 weights, CTranslate2) vs the live MiLMMT-1B CT2. cat_runner: CAT-Translate (rejected 2026-10-03).
# mt_eval.flag holds two lines: the sentences JSON path and the output JSON path.
import json
import os
import sys
import threading
import time
import traceback

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
FLAG = os.path.join(ROOT, "mt_eval.flag")
CACHE = os.path.join(ROOT, ".cache")


def say(msg):
    print(f"MT_EVAL: {msg}", flush=True)


def cat_runner(size):
    import ctranslate2
    from huggingface_hub import snapshot_download
    from transformers import AutoTokenizer
    hf_dir = os.path.join(CACHE, "cat_translate", f"CAT-Translate-{size}")
    ct2_dir = os.path.join(CACHE, "cat_translate_ct2", f"CAT-Translate-{size}")
    if not os.path.exists(os.path.join(hf_dir, "config.json")):
        t = time.time()
        snapshot_download(f"cyberagent/CAT-Translate-{size}", local_dir=hf_dir,
                          allow_patterns=["*.json", "*.safetensors", "*.model", "*.jinja", "*.txt"])
        say(f"{size} downloaded in {time.time() - t:.0f} s")
    if not os.path.exists(os.path.join(ct2_dir, "model.bin")):
        files = [f for f in os.listdir(hf_dir) if f.startswith(("tokenizer", "special_tokens", "generation_config"))]
        ctranslate2.converters.TransformersConverter(hf_dir, copy_files=files).convert(ct2_dir, quantization="bfloat16", force=True)
        say(f"{size} converted")
    tok = AutoTokenizer.from_pretrained(hf_dir)
    ends = [t for t in {tok.eos_token, "<|im_end|>", "<|end|>", "<|eot_id|>", "</s>"}
            if t and tok.convert_tokens_to_ids(t) not in (None, tok.unk_token_id)]
    gen = ctranslate2.Generator(ct2_dir, device="cuda", compute_type="bfloat16")
    say(f"{size} end tokens {ends}, bos {tok.bos_token!r}, chat template sample: "
        f"{tok.apply_chat_template([{'role': 'user', 'content': 'X'}], tokenize=False, add_generation_prompt=True)!r}")

    def run(text):
        msg = [{"role": "user", "content": f"Translate the following Japanese text into English.\n\n{text}"}]
        prompt = tok.apply_chat_template(msg, tokenize=False, add_generation_prompt=True)
        ids = tok(prompt, add_special_tokens=False)["input_ids"]
        if tok.bos_token_id is not None and ids[:1] != [tok.bos_token_id]:
            ids = [tok.bos_token_id] + ids  # Llama-style models degrade without <s>
        res = gen.generate_batch([tok.convert_ids_to_tokens(ids)], max_length=256, sampling_topk=1,
                                 include_prompt_in_result=False, end_token=ends)
        return tok.decode(res[0].sequences_ids[0], skip_special_tokens=True).strip()
    return run


def text_only(hf_dir):
    """MiLMMT 4B/12B ship as Gemma3ForConditionalGeneration (text + vision); CTranslate2 converts only the text
    model, so write its weights (language_model.* -> *) and text_config as a Gemma3ForCausalLM folder."""
    from safetensors import safe_open
    from safetensors.torch import save_file
    out = hf_dir + "-text"
    if os.path.exists(os.path.join(out, "config.json")):
        return out
    os.makedirs(out, exist_ok=True)
    with open(os.path.join(hf_dir, "config.json"), encoding="utf-8") as f:
        cfg = json.load(f)
    text = dict(cfg["text_config"], architectures=["Gemma3ForCausalLM"], model_type="gemma3_text")
    text.setdefault("torch_dtype", cfg.get("torch_dtype", "bfloat16"))
    weight_map = {}
    for shard in sorted(f for f in os.listdir(hf_dir) if f.endswith(".safetensors")):
        tensors = {}
        with safe_open(os.path.join(hf_dir, shard), "pt") as f:
            for k in f.keys():
                if k.startswith("language_model."):
                    tensors[k[len("language_model."):]] = f.get_tensor(k)
        if tensors:
            save_file(tensors, os.path.join(out, shard), metadata={"format": "pt"})
            weight_map.update(dict.fromkeys(tensors, shard))
        del tensors
    with open(os.path.join(out, "model.safetensors.index.json"), "w", encoding="utf-8") as f:
        json.dump({"metadata": {}, "weight_map": weight_map}, f)
    for name in os.listdir(hf_dir):
        if name.startswith(("tokenizer", "special_tokens", "added_tokens", "generation_config")):
            with open(os.path.join(hf_dir, name), "rb") as src, open(os.path.join(out, name), "wb") as dst:
                dst.write(src.read())
    with open(os.path.join(out, "config.json"), "w", encoding="utf-8") as f:  # last: marks the folder complete
        json.dump(text, f, indent=1)
    say(f"text-only weights written ({len(weight_map)} tensors)")
    return out


def milmmt_runner(name="MiLMMT-46-1B-v1.0", compute="bfloat16"):
    import ctranslate2
    from huggingface_hub import snapshot_download
    from transformers import AutoTokenizer
    from Models.TextTranslation import texttranslate_milmmt as m
    hf_dir = os.path.join(CACHE, "milmmt", name)
    ct2_dir = os.path.join(CACHE, "milmmt_ct2", name)
    if not os.path.exists(os.path.join(ct2_dir, "model.bin")):
        if not os.path.exists(os.path.join(hf_dir, "config.json")) or not any(f.endswith(".safetensors") for f in os.listdir(hf_dir)):
            t = time.time()
            snapshot_download(f"xiaomi-research/{name}", local_dir=hf_dir,
                              allow_patterns=["*.json", "*.safetensors", "*.model", "*.jinja", "*.txt"])
            say(f"{name} downloaded in {time.time() - t:.0f} s")
        with open(os.path.join(hf_dir, "config.json"), encoding="utf-8") as f:
            src_dir = text_only(hf_dir) if "text_config" in json.load(f) else hf_dir
        files = [f for f in os.listdir(src_dir) if f.startswith(("tokenizer", "special_tokens", "added_tokens", "generation_config"))]
        ctranslate2.converters.TransformersConverter(src_dir, copy_files=files).convert(
            ct2_dir, quantization="int8_bfloat16" if compute.startswith("int8") else "bfloat16", force=True)
        say(f"{name} converted")
    tok = AutoTokenizer.from_pretrained(hf_dir)
    gen = ctranslate2.Generator(ct2_dir, device="cuda", compute_type=compute)
    _, src = m._resolve_language("jpn_Jpan")
    _, trg = m._resolve_language("eng_Latn")

    def run(text):
        ids = tok(m.build_prompt(src, trg, text), add_special_tokens=False)["input_ids"]
        res = gen.generate_batch([tok.convert_ids_to_tokens(ids)], max_length=256, sampling_topk=1,
                                 include_prompt_in_result=False, end_token=["<eos>", "<end_of_turn>"])
        return tok.decode(res[0].sequences_ids[0], skip_special_tokens=True).strip()
    return run


def main():
    try:
        with open(FLAG, encoding="utf-8") as f:
            src_path, out_path = [line.strip() for line in f.read().splitlines()[:2]]
        while not hasattr(sys.modules.get("audioprocessor"), "send_message"):
            time.sleep(0.5)
        time.sleep(5)
        with open(src_path, encoding="utf-8") as f:
            items = json.load(f)
        import torch
        runners = {}
        for name, make in (("milmmt", milmmt_runner), ("milmmt4b", lambda: milmmt_runner("MiLMMT-46-4B-v1.0", "int8_bfloat16"))):
            try:
                before = torch.cuda.mem_get_info()[0]
                runners[name] = make()
                say(f"{name} loaded, ~{(before - torch.cuda.mem_get_info()[0]) / 2**20:.0f} MiB")
            except Exception:
                say(f"{name} FAILED")
                traceback.print_exc()
        for name, run in runners.items():
            run("こんにちは")
            say(f"{name} warm: {run('今日は何をしようかな。')!r}")
        rows = []
        for item in items:
            row = dict(item)
            for name, run in runners.items():
                t = time.perf_counter()
                try:
                    row[name] = run(item["ja"])
                except Exception as e:
                    row[name] = f"<error {e}>"
                row[name + "_ms"] = round(1000 * (time.perf_counter() - t))
            rows.append(row)
        with open(out_path, "w", encoding="utf-8") as f:
            json.dump(rows, f, ensure_ascii=False, indent=1)
        for name in runners:
            ms = sorted(r[name + "_ms"] for r in rows)
            say(f"{name}: median {ms[len(ms) // 2]} ms, p90 {ms[int(len(ms) * 0.9)]} ms")
        say("DONE")
    except Exception:
        traceback.print_exc()
        say("DONE (crashed)")


if os.path.exists(FLAG):
    threading.Thread(target=main, daemon=True).start()
