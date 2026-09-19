"""One TTS endpoint that speaks whatever language it is handed.

Open WebUI talks to a single TTS engine, but no single engine covers the
world. Kokoro sounds best and knows eight languages; Piper knows fifty-three
and ships one model file per voice. This sits in front of both, works out what
language it was asked to say, and forwards to whichever engine can say it —
fetching the voice first if this is the first time that language has come up.

Detection is by language, not by script, and the difference matters: Persian,
Arabic and Urdu share a script but not a voice, and French, German and Turkish
are all Latin. A script test gets those wrong in both directions.

    POST /v1/audio/speech      OpenAI shape, same as Kokoro and Piper expose
    GET  /voices               what is installed and how routing would go
    GET  /languages            every language known, and who would speak it
    GET  /health

Environment:
    TTS_FORCE=kokoro|piper     pin an engine while comparing quality
    TTS_LANG=fa                pin a language, skipping detection
    TTS_AUTO_DOWNLOAD=0        never fetch a voice mid-request
"""

from __future__ import annotations

import os
import subprocess
import tempfile
import unicodedata
from pathlib import Path
from typing import Optional

import httpx
from fastapi import FastAPI, HTTPException
from fastapi.responses import Response
from pydantic import BaseModel

import voices as vc

HERE = Path(__file__).parent
PIPER_BIN = Path(os.environ.get("PIPER_BIN", HERE / "venv" / "bin" / "piper"))

KOKORO_URL = os.environ.get("KOKORO_URL", "http://127.0.0.1:8880")
FORCE = os.environ.get("TTS_FORCE", "").strip().lower()
PIN_LANG = os.environ.get("TTS_LANG", "").strip().lower()
AUTO_DOWNLOAD = os.environ.get("TTS_AUTO_DOWNLOAD", "1") != "0"
DEFAULT_LANG = os.environ.get("TTS_DEFAULT_LANG", "en")

# Below this many Latin letters, detection is guesswork. See detect().
MIN_DETECT_CHARS = 12

app = FastAPI(title="myai tts router", version="2.0.0")

_detector = None


def detector():
    """Built once, and only over languages something here can actually speak.

    Constraining the set is both faster and more accurate than detecting over
    all 75 lingua knows — it cannot return an answer we would have to discard.
    """
    global _detector
    if _detector is None:
        from lingua import Language, LanguageDetectorBuilder
        speakable = set(vc.supported())
        langs = [l for l in Language.all()
                 if l.iso_code_639_1.name.lower() in speakable]
        _detector = (LanguageDetectorBuilder.from_languages(*langs)
                     .with_low_accuracy_mode()
                     .build())
    return _detector


def detect(text: str) -> str:
    """ISO-639-1 code for `text`, falling back to the default language."""
    if PIN_LANG:
        return PIN_LANG

    script = dominant_script(text)
    letters = sum(1 for c in text if c.isalpha())

    # The length guard is about Latin only. "OK" and "Ja" are several languages
    # each, so a short Latin string is a coin flip and the default wins. A short
    # non-Latin string is not ambiguous in the same way -- nine Han characters
    # are a whole sentence, and no amount of them is English -- so those go to
    # the detector however short they are.
    if script == "latin" and letters < MIN_DETECT_CHARS:
        return DEFAULT_LANG

    lang = detector().detect_language_of(text)
    if lang:
        return lang.iso_code_639_1.name.lower()
    return SCRIPT_HINT.get(script, DEFAULT_LANG)


# Only used for text too short to detect properly. Each maps a script to its
# most common language, which is a guess — but a better one than the default.
SCRIPT_HINT = {
    "arabic": "fa", "cyrillic": "ru", "greek": "el", "hebrew": "he",
    "devanagari": "hi", "thai": "th", "hangul": "ko", "armenian": "hy",
    "georgian": "ka", "bengali": "bn", "telugu": "te", "malayalam": "ml",
    "cjk": "zh", "hiragana": "ja", "katakana": "ja",
}


def dominant_script(text: str) -> str:
    """The script most of the letters belong to.

    Counts letters only: digits and punctuation are shared between scripts and
    would otherwise drag a Persian sentence containing '5G' towards Latin.
    """
    counts: dict[str, int] = {}
    for ch in text:
        if not ch.isalpha():
            continue
        try:
            name = unicodedata.name(ch).split()[0].lower()
        except ValueError:
            continue
        counts[name] = counts.get(name, 0) + 1
    if not counts:
        return "latin"
    return max(counts, key=counts.get)


def route(text: str) -> tuple[str, str, Optional[str]]:
    """Return (language, backend, piper_voice)."""
    lang = detect(text)

    if FORCE == "kokoro":
        return lang, "kokoro", None
    if FORCE != "piper" and lang in vc.KOKORO_LANGS:
        return lang, "kokoro", None

    voice = vc.ensure_voice(lang, download=AUTO_DOWNLOAD)
    if voice:
        return lang, "piper", voice

    # Nothing can say this properly. Kokoro's default voice will read it with
    # an English accent, which is wrong but audible; silence would just look
    # like the feature is broken.
    print(f"[router] no voice for '{lang}' — falling back to Kokoro")
    return lang, "kokoro", None


class SpeechRequest(BaseModel):
    input: str
    model: Optional[str] = None
    voice: Optional[str] = None
    response_format: Optional[str] = "mp3"
    speed: Optional[float] = 1.0


@app.post("/v1/audio/speech")
async def speech(req: SpeechRequest) -> Response:
    text = (req.input or "").strip()
    if not text:
        raise HTTPException(status_code=400, detail="input is empty")

    lang, backend, piper_voice = route(text)
    print(f"[router] {len(text):>5} chars  lang={lang:<3} -> {backend}"
          + (f" ({piper_voice})" if piper_voice else ""))

    if backend == "kokoro":
        # Kokoro's voice names encode their language, so a voice chosen for
        # English cannot read the Spanish text we just routed here.
        voice = vc.KOKORO_LANGS.get(lang) or req.voice or vc.KOKORO_LANGS["en"]
        async with httpx.AsyncClient(timeout=120) as client:
            try:
                r = await client.post(f"{KOKORO_URL}/v1/audio/speech", json={
                    "input": text,
                    "model": req.model or "kokoro",
                    "voice": voice,
                    "response_format": req.response_format or "mp3",
                    "speed": req.speed or 1.0,
                })
            except httpx.HTTPError as exc:
                raise HTTPException(status_code=502,
                                    detail=f"kokoro unreachable: {exc}") from exc
        if r.status_code != 200:
            raise HTTPException(status_code=r.status_code, detail=r.text[:200])
        return Response(content=r.content,
                        media_type=r.headers.get("content-type", "audio/mpeg"))

    model_path = vc.VOICES / f"{piper_voice}.onnx"
    with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as tmp:
        out = Path(tmp.name)
    try:
        proc = subprocess.run(
            [str(PIPER_BIN), "-m", str(model_path), "-f", str(out)],
            input=text.encode(), capture_output=True, timeout=180,
        )
        if proc.returncode != 0 or not out.exists() or out.stat().st_size == 0:
            raise HTTPException(status_code=500,
                                detail=f"piper failed: {proc.stderr.decode()[:200]}")
        data = out.read_bytes()
    finally:
        out.unlink(missing_ok=True)

    # Piper emits WAV. Open WebUI transcodes it with ffmpeg, which must be
    # installed — without it the request fails with a bare ENOENT for ffprobe.
    return Response(content=data, media_type="audio/wav")


@app.get("/voices")
@app.get("/v1/audio/voices")
async def voices_endpoint() -> dict:
    kokoro: list = []
    async with httpx.AsyncClient(timeout=10) as client:
        try:
            r = await client.get(f"{KOKORO_URL}/v1/audio/voices")
            if r.status_code == 200:
                body = r.json()
                raw = body.get("voices", body)
                kokoro = [v["id"] if isinstance(v, dict) else v for v in raw]
        except httpx.HTTPError:
            pass
    return {
        "voices": kokoro or vc.installed(),   # Open WebUI populates its picker
        "piper_installed": vc.installed(),
        "auto_download": AUTO_DOWNLOAD,
        "forced": FORCE or None,
    }


@app.get("/languages")
async def languages() -> dict:
    sup = vc.supported()
    installed = {v.split("_")[0] for v in vc.installed()}
    return {
        "count": len(sup),
        "languages": [
            {"lang": k, "engine": v,
             "ready": v == "kokoro" or k in installed}
            for k, v in sup.items()
        ],
    }


@app.get("/health")
async def health() -> dict:
    async with httpx.AsyncClient(timeout=5) as client:
        try:
            kokoro_up = (await client.get(
                f"{KOKORO_URL}/v1/audio/voices")).status_code == 200
        except httpx.HTTPError:
            kokoro_up = False
    return {
        "ok": True,
        "kokoro": kokoro_up,
        "piper": PIPER_BIN.exists(),
        "languages": len(vc.supported()),
        "installed_voices": vc.installed(),
    }
