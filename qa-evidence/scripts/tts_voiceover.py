#!/usr/bin/env python3
# tts_voiceover.py - synthesize narration lines for make_recording.pl with
# tiny-voca (https://github.com/n4ze3m/tiny-voca), a 4.5M-parameter CPU-only
# English TTS released under Apache-2.0. One wav per job line, cached by the
# exact text+voice+speed, because the model is deterministic: same input,
# same audio.
#
# usage: tts_voiceover.py --job job.json --workdir DIR
#          [--model model.onnx] [--phonemizer DIR] [--voice F2|M2]
#          [--speed 1.0] [--cache DIR]
#
# job.json: [{"id": "01", "text": "..."}, ...]
# writes one WORKDIR/ID.wav (24 kHz mono) per line.
#
# Setup (one time): a tiny-voca weights checkout containing model.onnx (or
# onnx/model.onnx), config.json and phonemizer/, plus a venv with onnxruntime,
# numpy, soundfile and dizione. Paths resolve from flags, then from
# TINY_VOCA_MODEL / TINY_VOCA_PHONEMIZER / TINY_VOCA_CACHE, then from
# ./model.onnx and ./phonemizer next to this script's cwd.

import argparse
import hashlib
import json
import os
import re
import sys
from pathlib import Path

# tiny_voca.infer.sentence-splitting, ported so this driver needs no torch.
SPACE = re.compile("[\\s\uFEFF]+")
SENTENCE_END = re.compile(r'(?:(?<=[.!?…])|(?<=[.!?…]["\')\]]))\s+(?=["\'(\[]?[A-Z0-9])')
NOT_AN_END = re.compile(
    r'(?:\b(?:mr|mrs|ms|dr|prof|sr|jr|st|vs|etc|no|inc|ltd|co|e\.g|i\.e|a\.m|p\.m)|\b[A-Z])\.$',
    re.IGNORECASE | re.ASCII)
CLAUSE_END = re.compile(r'(?<=[,;:—])\s+')
TEXT_END = re.compile("[\\s\uFEFF]+$")
CLOSING = "\"'”’)]»"
MAX_TOKENS = 500          # model cap is 512 including edge tokens


def finished(text):
    body = TEXT_END.sub("", text)
    if not body:
        return text
    last = SPACE.split(body)[-1]
    if any(c.isalnum() for c in last):
        marked = last.rstrip(CLOSING)[-1:] in tuple(".!?…,;:")
    else:
        marked = any(c in ".!?…" for c in last) or last in (",", ";", ":")
    return text if marked else body + "."


def sentences(text):
    parts, current = [], ""
    for piece in SENTENCE_END.split(SPACE.sub(" ", text).strip()):
        current = f"{current} {piece}" if current else piece
        if not NOT_AN_END.search(current):
            parts.append(current)
            current = ""
    if current:
        parts.append(current)
    return [p for p in parts if any(c.isalnum() for c in p)]


def pieces(text):
    """text split into chunks each below MAX_TOKENS phonemes, best effort:
    after clause marks, then halved between words."""
    cut = CLAUSE_END.split(text)
    if len(cut) > 1:
        return cut
    words = text.split(" ")
    if len(words) < 2:
        return []
    half = (len(words) + 1) // 2
    return [" ".join(words[:half]), " ".join(words[half:])]


class Vocoder:
    def __init__(self, model, phonemizer, voice, speed, cache):
        os.environ["DIZIONE_DATA"] = str(phonemizer)
        import numpy as np
        import onnxruntime as ort
        import dizione
        self.np = np
        self.dizione = dizione
        self.speed = float(speed)
        self.cache = Path(cache)
        self.cache.mkdir(parents=True, exist_ok=True)
        self.sample_rate = 24000
        cfg = model.parent / "config.json"
        if cfg.exists():
            try:
                meta = json.loads(cfg.read_text())
                self.sample_rate = int(meta.get("sample_rate", 24000))
                voices = meta.get("voices", ["F2", "M2"])
            except Exception:
                voices = ["F2", "M2"]
        else:
            voices = ["F2", "M2"]
        if voice not in voices:
            raise SystemExit(f"unknown voice {voice!r}; this model has {voices}")
        self.voice_index = voices.index(voice)
        self.session = ort.InferenceSession(str(model), providers=["CPUExecutionProvider"])
        self.model_tag = hashlib.sha256(Path(model).read_bytes()).hexdigest()[:16]
        self.voice = voice

    def synth_chunk(self, text):
        phones = self.dizione.phonemize(text)
        n = len(phones.ids)
        if n > MAX_TOKENS + 12:
            raise ValueError(f"one chunk is still too long ({n} tokens): {text[:50]!r}")
        np = self.np
        audio, _ = self.session.run(None, {
            "tokens": np.array([phones.ids], dtype=np.int64),
            "stress": np.array([phones.stress], dtype=np.int64),
            "voice": np.array([self.voice_index], dtype=np.int64),
            "speed": np.array([self.speed], dtype=np.float32),
            "pitch_shift": np.array([0.0], dtype=np.float32),
            "pitch_range": np.array([1.0], dtype=np.float32),
        })
        return audio[0]

    def speak(self, text):
        waves = []

        def read(piece):
            try:
                phones = self.dizione.phonemize(piece)
            except Exception:
                return
            if 0 < len(phones) <= MAX_TOKENS:
                waves.append(self.synth_chunk(piece))
                return
            for part in pieces(piece):
                read(part)

        for s in sentences(finished(text)):
            read(s)
        if not waves:
            raise ValueError("nothing in this line could be pronounced")
        audio = self.np.concatenate(waves)
        peak = float(self.np.abs(audio).max()) if audio.size else 0.0
        if peak > 0.99:
            audio = audio * (0.99 / peak)
        return audio

    def wav_for(self, text, dest):
        key = hashlib.sha1(
            f"{self.model_tag}|{self.voice}|{self.speed}|{text}".encode()).hexdigest()
        cached = self.cache / f"{key}.wav"
        if not cached.exists():
            import soundfile as sf
            audio = self.speak(text)
            sf.write(str(cached), audio, self.sample_rate, subtype="PCM_16")
            tmp = dest.with_suffix(".tmp.wav")
            import shutil
            shutil.copyfile(cached, tmp)
            tmp.rename(dest)
            return len(audio) / self.sample_rate, True
        import shutil
        shutil.copyfile(cached, dest)
        import soundfile as sf
        return sf.info(str(dest)).duration, False


def main():
    p = argparse.ArgumentParser(description="synthesize narration wavs with tiny-voca")
    p.add_argument("--job", required=True, help="json list of {id, text}")
    p.add_argument("--workdir", required=True, help="where ID.wav files are written")
    p.add_argument("--model", default=os.environ.get("TINY_VOCA_MODEL", "model.onnx"))
    p.add_argument("--phonemizer", default=os.environ.get("TINY_VOCA_PHONEMIZER", "phonemizer"))
    p.add_argument("--voice", default=os.environ.get("TINY_VOCA_VOICE", "F2"))
    p.add_argument("--speed", default=os.environ.get("TINY_VOCA_SPEED", "1.0"))
    p.add_argument("--cache", default=os.environ.get(
        "TINY_VOCA_CACHE", os.path.expanduser("~/.cache/openbot-evidence/tts")))
    a = p.parse_args()

    model = Path(a.model)
    if not model.exists() and (Path(a.phonemizer).parent / "onnx" / "model.onnx").exists():
        model = Path(a.phonemizer).parent / "onnx" / "model.onnx"
    if not model.exists():
        raise SystemExit(
            f"no tiny-voca model at {a.model}; get one with:\n"
            "  curl -L -o model.onnx https://huggingface.co/n4ze3m/tiny-voca/resolve/main/onnx/model.onnx\n"
            "  curl -L https://huggingface.co/n4ze3m/tiny-voca/resolve/main/phonemizer/g2p.npz ... (phonemizer/)\n"
            "or pass --model / --phonemizer / set TINY_VOCA_MODEL / TINY_VOCA_PHONEMIZER")

    job = json.loads(Path(a.job).read_text())
    workdir = Path(a.workdir)
    workdir.mkdir(parents=True, exist_ok=True)
    voc = Vocoder(model, a.phonemizer, a.voice, a.speed, a.cache)

    manifest = []
    for item in job:
        dest = workdir / f"{item['id']}.wav"
        dur, fresh = voc.wav_for(item["text"], dest)
        manifest.append({"id": item["id"], "text": item["text"],
                         "dur": round(dur, 3), "path": str(dest)})
        print(f"[tts] {item['id']}: {dur:.2f}s {'synthesized' if fresh else 'cached'}: "
              f"{item['text'][:60]}", file=sys.stderr)
    print(json.dumps({"lines": manifest, "sample_rate": voc.sample_rate}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
