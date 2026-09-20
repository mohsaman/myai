#!/usr/bin/env bash
# Apply the recommended Open WebUI settings via its admin API.
#
# Run AFTER you have registered an admin account in the browser.
# Everything here can also be set by hand in Admin Settings — see README.md.

set -uo pipefail

BASE="${OPENWEBUI_URL:-http://127.0.0.1:8080}"
TASK_MODEL="${TASK_MODEL:-qwen2.5:3b}"
CHAT_MODEL="${CHAT_MODEL:-qwen3.8:27b-mlx}"
EMBED_MODEL="${EMBED_MODEL:-nomic-embed-text:latest}"
TTS_VOICE="${TTS_VOICE:-af_bella}"
STT_MODEL="${STT_MODEL:-small}"

read -rp "Open WebUI admin email: " EMAIL
read -rsp "Open WebUI admin password: " PASSWORD; echo

TOKEN=$(curl -fsS --max-time 20 -X POST "$BASE/api/v1/auths/signin" \
  -H 'Content-Type: application/json' \
  -d "{\"email\":\"$EMAIL\",\"password\":\"$PASSWORD\"}" \
  | python3 -c 'import sys,json; print(json.load(sys.stdin).get("token",""))' 2>/dev/null)

[ -z "$TOKEN" ] && { echo "sign-in failed"; exit 1; }
echo "signed in"

export BASE TOKEN TASK_MODEL CHAT_MODEL EMBED_MODEL TTS_VOICE STT_MODEL
python3 <<'PY'
import os, json, urllib.request, urllib.error
BASE, TOKEN = os.environ["BASE"], os.environ["TOKEN"]
OLLAMA = os.environ.get("OLLAMA_URL", "http://127.0.0.1:11434")

def call(path, data=None):
    r = urllib.request.Request(BASE + path, method="POST" if data is not None else "GET")
    r.add_header("Authorization", "Bearer " + TOKEN)
    r.add_header("Content-Type", "application/json")
    body = json.dumps(data).encode() if data is not None else None
    with urllib.request.urlopen(r, body, timeout=120) as x:
        return json.load(x)

def try_(label, fn):
    try:
        fn(); print(f"  ok   {label}")
    except urllib.error.HTTPError as e:
        print(f"  FAIL {label}: {e.code} {e.read().decode()[:120]}")
    except Exception as e:
        print(f"  FAIL {label}: {str(e)[:120]}")

# 1. Background tasks on a small model — the single most important setting.
def task_model():
    c = call("/api/v1/tasks/config"); c["TASK_MODEL"] = os.environ["TASK_MODEL"]
    call("/api/v1/tasks/config/update", c)
try_("task model -> " + os.environ["TASK_MODEL"], task_model)

# 2. Text-to-speech via the local router, which picks an engine per language.
#    Pointing straight at Kokoro (8880) also works, but then only its eight
#    languages are speakable and everything else is read with an English accent.
def tts():
    c = call("/api/v1/audio/config")
    c["tts"].update({
        "ENGINE": "openai",
        "OPENAI_API_BASE_URL": "http://127.0.0.1:8881/v1",
        "OPENAI_API_KEY": "local",
        "MODEL": "kokoro",
        "VOICE": os.environ["TTS_VOICE"],
    })
    # "" selects Open WebUI's bundled faster-whisper. small is fast and fine for
    # English; non-Latin languages transcribe noticeably better on medium.
    c["stt"].update({"ENGINE": "", "WHISPER_MODEL": os.environ["STT_MODEL"]})
    call("/api/v1/audio/config/update", c)
try_("tts -> local router (per-language), stt -> local whisper (%s)"
     % os.environ["STT_MODEL"], tts)

# 3. Image generation via local ComfyUI.
def images():
    c = call("/api/v1/images/config")
    c.update({
        "ENABLE_IMAGE_GENERATION": True,
        "IMAGE_GENERATION_ENGINE": "comfyui",
        "COMFYUI_BASE_URL": "http://127.0.0.1:8188",
        "IMAGE_GENERATION_MODEL": "sd_xl_base_1.0.safetensors",
        "IMAGE_SIZE": "1024x1024",
        "IMAGE_STEPS": 20,
    })
    wf = json.loads(c["COMFYUI_WORKFLOW"])
    wf["4"]["inputs"]["ckpt_name"] = "sd_xl_base_1.0.safetensors"
    wf["5"]["inputs"].update({"width": 1024, "height": 1024})
    wf["3"]["inputs"].update({"steps": 20, "sampler_name": "dpmpp_2m", "scheduler": "karras"})
    c["COMFYUI_WORKFLOW"] = json.dumps(wf, indent=2)
    c["COMFYUI_WORKFLOW_NODES"] = [
        {"type": "model",           "key": "ckpt_name", "node_ids": ["4"]},
        {"type": "prompt",          "key": "text",      "node_ids": ["6"]},
        {"type": "negative_prompt", "key": "text",      "node_ids": ["7"]},
        {"type": "width",           "key": "width",     "node_ids": ["5"]},
        {"type": "height",          "key": "height",    "node_ids": ["5"]},
        {"type": "steps",           "key": "steps",     "node_ids": ["3"]},
        {"type": "seed",            "key": "seed",      "node_ids": ["3"]},
    ]
    call("/api/v1/images/config/update", c)
try_("image generation -> local comfyui + sdxl", images)

# 4. Web search. Bypass embedding: results go straight into the prompt.
def web():
    c = call("/api/v1/retrieval/config")
    c["web"].update({
        "ENABLE_WEB_SEARCH": True,
        "WEB_SEARCH_ENGINE": "duckduckgo",
        "WEB_SEARCH_RESULT_COUNT": 5,
        "BYPASS_WEB_SEARCH_EMBEDDING_AND_RETRIEVAL": True,
    })
    c["ENABLE_MARKDOWN_HEADER_TEXT_SPLITTER"] = False  # breaks PDF ingestion
    call("/api/v1/retrieval/config/update", c)
try_("web search -> duckduckgo", web)

# 5. Embeddings for document retrieval (separate endpoint).
def embed():
    call("/api/v1/retrieval/embedding/update", {
        "RAG_EMBEDDING_ENGINE": "ollama",
        "RAG_EMBEDDING_MODEL": os.environ["EMBED_MODEL"],
        "ollama_config": {"url": "http://127.0.0.1:11434", "key": ""},
        "RAG_EMBEDDING_BATCH_SIZE": 8,
    })
try_("embeddings -> " + os.environ["EMBED_MODEL"], embed)

# 6. Per-model display names, capabilities and function calling.
#    The dropdown otherwise shows raw ids like "qwen3.8:27b-mlx", which say nothing
#    about what each model is for — so each gets its use in parentheses.
#
#    legacy function calling = Open WebUI drives tools itself, instead of offering
#    them to the model. Needed so web search actually runs, and so tool-less vision
#    models stop erroring. Only the chat and vision models need it.
import urllib.parse

# id, display name, use shown in parentheses, vision, legacy function calling, hidden
# hidden=True keeps a model out of the chat dropdown. The embedding model is only
# ever called by the retrieval pipeline (which resolves it against Ollama by name,
# independently of this list), so it is noise in a chat model picker.
# One model does chat, images, code and tools, so the picker shows one entry.
# The other two are never chosen by hand -- the task model runs titling in the
# background, the embedding model is called by the retrieval pipeline -- so both
# are hidden rather than offered as choices nobody should make. De-duplicated by
# id, because several role variables can legitimately name the same model.
seen = set()
MODELS = []
for _row in [
    (os.environ["CHAT_MODEL"],  "Qwen3.8 27B", "chat, images, code, tools",     True,  False, False),
    (os.environ["TASK_MODEL"],  "Qwen2.5 3B",  "background tasks",              False, False, True),
    (os.environ["EMBED_MODEL"], "Nomic Embed", "embeddings \u2014 not for chat", False, False, True),
]:
    if _row[0] and _row[0] not in seen:
        seen.add(_row[0])
        MODELS.append(_row)

# Entries are created but never removed, so deleting a model from Ollama used to
# leave it selectable in the picker -- and picking it fails at request time with
# nothing explaining why. Anything whose backing model is gone gets dropped, and
# a preset whose base is gone is repointed at the chat model rather than deleted,
# because the prompt is the valuable part and the weights are interchangeable.
def prune():
    try:
        tags = json.loads(urllib.request.urlopen(
            OLLAMA + "/api/tags", timeout=15).read())
    except Exception as e:
        print("  skipped prune: ollama unreachable (%s)" % e); return
    have = {m["name"] for m in tags.get("models", [])}
    for m in call("/api/v1/models/") or []:
        mid, base = m.get("id"), m.get("base_model_id")
        target = base or mid
        if target in have:
            continue
        enc = urllib.parse.quote(mid, safe="")
        if base:
            m["base_model_id"] = os.environ["CHAT_MODEL"]
            call("/api/v1/models/model/update?id=" + enc, m)
            print("  repointed %s -> %s" % (mid, os.environ["CHAT_MODEL"]))
        else:
            call("/api/v1/models/model/delete?id=" + enc, {})
            print("  dropped %s (no longer in ollama)" % mid)

def setup(model_id, label, suffix, vision, legacy, hidden):
    payload = {
        "id": model_id,
        "name": f"{label} ({suffix})",
        "base_model_id": None,
        "meta": {"capabilities": {"vision": vision, "citations": True}},
        "params": {"function_calling": "legacy"} if legacy else {},
    }
    try:
        call("/api/v1/models/create", payload)
    except urllib.error.HTTPError as e:
        if e.code in (400, 409, 401):
            # already exists -> update in place (id must be URL-encoded: it has a colon)
            call("/api/v1/models/model/update?id=" + urllib.parse.quote(model_id, safe=""), payload)
        else:
            raise
    # create/update always leaves the model active, so toggle runs after it and
    # the result is the same whether this script runs once or many times.
    if hidden:
        enc = urllib.parse.quote(model_id, safe="")
        if call(f"/api/v1/models/model?id={enc}").get("is_active"):
            call(f"/api/v1/models/model/toggle?id={enc}", {})

for mid, label, suffix, vis, leg, hid in MODELS:
    try_(f"{mid} -> {label} ({suffix})" + ("  [hidden]" if hid else ""),
         lambda a=mid, b=label, c=suffix, d=vis, e=leg, f=hid: setup(a, b, c, d, e, f))

# 7. Behaviour the models do not have by default.
#
#    Both of these are things the interface already supports and the model has no
#    way to discover. Without them it will tell you it cannot reach the internet
#    while holding a search tool, and draw an "infographic" out of box-drawing
#    characters in a chat interface that renders HTML.
PREAMBLE = """Reaching the internet:
- You may search the web or fetch a URL whenever it would make your answer better. Use that judgement freely; do not ask permission first.
- But always say so in the answer. State that you went online, what you searched for or fetched, and give the URL.
- Mark clearly which parts came from the web and which from your own knowledge.
- If a search returns nothing useful, say so rather than quietly falling back on memory.

Infographics, diagrams and anything visual:
- When asked for an infographic, diagram, chart, dashboard, poster or "make this visual", output a COMPLETE HTML DOCUMENT in a ```html code block. This interface renders it as a real page. Never draw ASCII boxes with box-drawing characters — that is a picture of a picture.
- Self-contained: <!DOCTYPE html>, one <style> block, no external CSS, no CDN scripts, no web fonts. It must render with no network.
- Design it rather than dumping text into boxes: readable width, real hierarchy, CSS grid or flex, dark background with light text, colours as variables on :root.
- Put the actual content in it. Numbers and specifics are what make an infographic worth looking at.
- Do not explain the HTML afterwards."""

def behaviour(model_id):
    enc = urllib.parse.quote(model_id, safe="")
    cur = call(f"/api/v1/models/model?id={enc}")
    params = dict(cur.get("params") or {})
    if "Infographics, diagrams" in params.get("system", ""):
        return
    params["system"] = (params.get("system", "") + "\n\n" + PREAMBLE).strip()
    meta = dict(cur.get("meta") or {})
    # Pre-enable web search for new chats with this model.
    meta["defaultFeatureIds"] = sorted(set((meta.get("defaultFeatureIds") or []) + ["web_search"]))
    caps = dict(meta.get("capabilities") or {}); caps["web_search"] = True
    meta["capabilities"] = caps
    call(f"/api/v1/models/model/update?id={enc}",
         {"id": model_id, "name": cur["name"], "base_model_id": cur.get("base_model_id"),
          "params": params, "meta": meta})

try_(f"web + visual behaviour -> {os.environ['CHAT_MODEL']}",
     lambda: behaviour(os.environ["CHAT_MODEL"]))
try_("prune entries whose model is gone", prune)

# 6. A slash command for spec work, instead of a whole model entry.
#    The domain guidance does not need its own model in the picker -- it is a
#    prompt, and Open WebUI can inject one on demand. /telecom keeps the dropdown
#    to a single entry while leaving the behaviour a keystroke away.
TELECOM_PROMPT = r"""Answer as a wireless software engineer building production systems for tier-1
operators: 3GPP Rel-8 to Rel-18 (EPC, 5GC, IMS, SMS, roaming), core network functions
(MME, HSS, UDM, AMF, SMF, UPF, PCF, PCRF, SMSF, SMSC), and the protocols between them --
Diameter (S6a, Gx, Gy, Rx, Sh), SS7/SIGTRAN (M3UA, SCCP, TCAP, MAP), GTP, PFCP, SCTP,
NGAP, NAS, SIP/IMS. Also eSIM (SGP.02/.22/.32) and roaming (TAP3, NRTRDE, IR.21).

THE SPECIFICATIONS ARE ON DISK. Use them, with the Terminal tool:

  ls ~/specs                                       # what is available
  grep -n "IMSI unknown in HSS" ~/specs/3GPP-24.301.txt
  grep -n "^9\.9\.3\.9" ~/specs/3GPP-24.301.txt   # a specific clause
  sed -n '4195,4215p' ~/specs/3GPP-24.301.txt      # read around a hit

Rules:
- Never cite a clause you have not grepped. Asked which EMM cause maps to
  DIAMETER_ERROR_USER_UNKNOWN, a model answered "#1, section 9.9.2.1" with complete
  confidence. The real answer, one grep away, is "#2 (IMSI unknown in HSS)". A wrong
  reference gets copied into a code comment and outlives everyone who saw it.
- Quote the document's words, then paraphrase. Cite file and line: 3GPP-24.301.txt:4205.
- If the document is not in ~/specs, say so and tell me to run: fetch-specs 24.301
- If the corpus contradicts what you remember, the corpus is right.
- Separate what you verified from what you are inferring.

If the Terminal tool is not switched on in this conversation, say so plainly and ask me
to enable it rather than answering from memory.

Production-grade, not prototypes. Explicit over clever -- ops teams maintain this. Handle
the failure paths: retries, timeouts, failover, graceful degradation. Flag any deviation
from the standard explicitly.

My question:
"""

def telecom_prompt():
    payload = {"command": "/telecom", "title": "Telecom Expert",
               "content": TELECOM_PROMPT}
    try:
        call("/api/v1/prompts/create", payload)
    except urllib.error.HTTPError as e:
        if e.code in (400, 409):
            call("/api/v1/prompts/command/telecom/update", payload)
        else:
            raise
try_("slash command /telecom", telecom_prompt)
PY

echo
echo "done — restart with: myai restart"
