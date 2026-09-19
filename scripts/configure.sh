#!/usr/bin/env bash
# Apply the recommended Open WebUI settings via its admin API.
#
# Run AFTER you have registered an admin account in the browser.
# Everything here can also be set by hand in Admin Settings — see README.md.

set -uo pipefail

BASE="${OPENWEBUI_URL:-http://127.0.0.1:8080}"
TASK_MODEL="${TASK_MODEL:-qwen2.5:3b}"
CHAT_MODEL="${CHAT_MODEL:-qwen3:30b-a3b}"
VISION_MODEL="${VISION_MODEL:-qwen2.5vl:7b}"
EMBED_MODEL="${EMBED_MODEL:-nomic-embed-text:latest}"
CODE_MODEL="${CODE_MODEL:-qwen2.5-coder:14b}"
TTS_VOICE="${TTS_VOICE:-af_bella}"

read -rp "Open WebUI admin email: " EMAIL
read -rsp "Open WebUI admin password: " PASSWORD; echo

TOKEN=$(curl -fsS --max-time 20 -X POST "$BASE/api/v1/auths/signin" \
  -H 'Content-Type: application/json' \
  -d "{\"email\":\"$EMAIL\",\"password\":\"$PASSWORD\"}" \
  | python3 -c 'import sys,json; print(json.load(sys.stdin).get("token",""))' 2>/dev/null)

[ -z "$TOKEN" ] && { echo "sign-in failed"; exit 1; }
echo "signed in"

export BASE TOKEN TASK_MODEL CHAT_MODEL VISION_MODEL EMBED_MODEL CODE_MODEL TTS_VOICE
python3 <<'PY'
import os, json, urllib.request, urllib.error
BASE, TOKEN = os.environ["BASE"], os.environ["TOKEN"]

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

# 2. Text-to-speech via local Kokoro (speaks the OpenAI protocol).
def tts():
    c = call("/api/v1/audio/config")
    c["tts"].update({
        "ENGINE": "openai",
        "OPENAI_API_BASE_URL": "http://127.0.0.1:8880/v1",
        "OPENAI_API_KEY": "local",
        "MODEL": "kokoro",
        "VOICE": os.environ["TTS_VOICE"],
    })
    c["stt"].update({"ENGINE": "", "WHISPER_MODEL": "small"})  # "" = local faster-whisper
    call("/api/v1/audio/config/update", c)
try_("tts -> local kokoro, stt -> local whisper (small)", tts)

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
#    The dropdown otherwise shows raw ids like "qwen2.5vl:7b", which say nothing
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
MODELS = [
    (os.environ["CHAT_MODEL"],   "Qwen3 30B",        "general chat + web search",                 False, True,  False),
    (os.environ["VISION_MODEL"], "Qwen2.5-VL 7B",    "vision \u2014 reads images",                  True,  True,  False),
    (os.environ["CODE_MODEL"],   "Qwen2.5 Coder 14B","writing & reviewing code",                  False, False, False),
    (os.environ["TASK_MODEL"],   "Qwen2.5 3B",       "fast \u2014 titles, tags, background tasks",  False, False, False),
    (os.environ["EMBED_MODEL"],  "Nomic Embed",      "embeddings \u2014 not for chat",              False, False, True),
]

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
PY

echo
echo "done — restart with: myai restart"
