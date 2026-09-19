"""The voice catalogue: which engine speaks a language, and where to get it.

Kokoro sounds better but knows nine languages. Piper knows fifty-three and has
one model file per voice, so a new language is a download rather than a new
release. This module is what turns a detected language code into something that
can actually be spoken, fetching the model the first time it is needed.

Nothing here is preloaded. 177 voices at ~60 MB each is 10 GB, and almost all of
it would be for languages you will never use.
"""

from __future__ import annotations

import json
import os
import threading
import urllib.request
from pathlib import Path
from typing import Optional

HERE = Path(__file__).parent
VOICES = Path(os.environ.get("PIPER_VOICE_DIR", HERE / "voices"))
CATALOG = VOICES / "catalog.json"

CATALOG_URL = ("https://huggingface.co/rhasspy/piper-voices/"
               "resolve/main/voices.json")
DOWNLOAD_BASE = "https://huggingface.co/rhasspy/piper-voices/resolve/main"

# Kokoro's nine, by the letter its voice names start with. Kokoro wins where it
# competes: it streams mp3, starts in about a second, and sounds markedly better
# than Piper's medium models on the same sentence.
KOKORO_LANGS = {
    "en": "af_bella",   # also 'b' voices for en-GB; 'a' is the default accent
    "es": "ef_dora",
    "fr": "ff_siwis",
    "hi": "hf_alpha",
    "it": "if_sara",
    "ja": "jf_alpha",
    "pt": "pf_dora",
    "zh": "zf_xiaobei",
}

# Piper publishes several qualities per voice. medium is the one to want: low is
# noticeably robotic, high is roughly double the size and slower to synthesise
# for a difference most listeners do not notice through a laptop speaker.
QUALITY_ORDER = ["medium", "high", "low", "x_low"]

# Languages where the catalogue offers more than one locale and the choice is
# not arbitrary. Everything else takes whatever locale exists.
PREFERRED_LOCALE = {
    "en": "en_US",
    "es": "es_ES",
    "pt": "pt_BR",
    "nl": "nl_NL",
}

_lock = threading.Lock()
_catalog: Optional[dict] = None


def _fetch(url: str, dest: Path, timeout: int = 600) -> None:
    """Download to a temporary name and rename, so a killed process never
    leaves a half-written .onnx that looks installed."""
    dest.parent.mkdir(parents=True, exist_ok=True)
    tmp = dest.with_suffix(dest.suffix + ".part")
    req = urllib.request.Request(url, headers={"User-Agent": "myai-tts/1.0"})
    with urllib.request.urlopen(req, timeout=timeout) as r, open(tmp, "wb") as f:
        while True:
            chunk = r.read(1 << 20)
            if not chunk:
                break
            f.write(chunk)
    tmp.rename(dest)


def catalog(refresh: bool = False) -> dict:
    """The Piper voice list, cached on disk after the first call."""
    global _catalog
    with _lock:
        if _catalog is not None and not refresh:
            return _catalog
        if CATALOG.exists() and not refresh:
            _catalog = json.loads(CATALOG.read_text())
            return _catalog
        _fetch(CATALOG_URL, CATALOG, timeout=120)
        _catalog = json.loads(CATALOG.read_text())
        return _catalog


def pick_voice(lang: str) -> Optional[str]:
    """Best Piper voice key for an ISO-639-1 code, or None if unsupported."""
    try:
        cat = catalog()
    except Exception as exc:                      # offline, or HF down
        print(f"[voices] catalogue unavailable: {exc}")
        return None

    candidates = [(k, m) for k, m in cat.items()
                  if m["language"]["code"].split("_")[0] == lang]
    if not candidates:
        return None

    preferred = PREFERRED_LOCALE.get(lang)
    if preferred:
        exact = [c for c in candidates if c[1]["language"]["code"] == preferred]
        if exact:
            candidates = exact

    def rank(item):
        quality = item[1].get("quality", "low")
        return (QUALITY_ORDER.index(quality)
                if quality in QUALITY_ORDER else len(QUALITY_ORDER))

    return sorted(candidates, key=rank)[0][0]


def installed() -> list[str]:
    return sorted(p.stem for p in VOICES.glob("*.onnx"))


def ensure_voice(lang: str, download: bool = True) -> Optional[str]:
    """Return an installed Piper voice for `lang`, fetching it if allowed.

    The first request in a new language pays the download — around 60 MB, ten to
    thirty seconds on a normal connection. Every request after it is local.
    """
    for key in installed():
        if key.split("_")[0] == lang:
            return key

    voice = pick_voice(lang)
    if not voice:
        return None
    if not download:
        print(f"[voices] {lang}: {voice} available but auto-download is off")
        return None

    meta = catalog()[voice]
    onnx = next(p for p in meta["files"] if p.endswith(".onnx"))
    cfg = next(p for p in meta["files"] if p.endswith(".onnx.json"))

    print(f"[voices] fetching {voice} for '{lang}' "
          f"({meta['files'][onnx]['size_bytes'] // (1 << 20)} MB)")
    try:
        _fetch(f"{DOWNLOAD_BASE}/{onnx}", VOICES / f"{voice}.onnx")
        _fetch(f"{DOWNLOAD_BASE}/{cfg}", VOICES / f"{voice}.onnx.json")
    except Exception as exc:
        print(f"[voices] download failed for {voice}: {exc}")
        (VOICES / f"{voice}.onnx").unlink(missing_ok=True)
        (VOICES / f"{voice}.onnx.json").unlink(missing_ok=True)
        return None

    print(f"[voices] installed {voice}")
    return voice


def supported() -> dict[str, str]:
    """Every language the stack can speak, and which engine would speak it."""
    out = {lang: "kokoro" for lang in KOKORO_LANGS}
    try:
        for meta in catalog().values():
            out.setdefault(meta["language"]["code"].split("_")[0], "piper")
    except Exception:
        pass
    return dict(sorted(out.items()))
