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
EMBED_MODEL="${EMBED_MODEL:-nomic-embed-text}"
TTS_VOICE="${TTS_VOICE:-af_bella}"

read -rp "Open WebUI admin email: " EMAIL
read -rsp "Open WebUI admin password: " PASSWORD; echo

TOKEN=$(curl -fsS --max-time 20 -X POST "$BASE/api/v1/auths/signin" \
  -H 'Content-Type: application/json' \
  -d "{\"email\":\"$EMAIL\",\"password\":\"$PASSWORD\"}" \
  | python3 -c 'import sys,json; print(json.load(sys.stdin).get("token",""))' 2>/dev/null)

[ -z "$TOKEN" ] && { echo "sign-in failed"; exit 1; }
echo "signed in"

export BASE TOKEN TASK_MODEL CHAT_MODEL VISION_MODEL EMBED_MODEL TTS_VOICE
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

# 6. Per-model function calling.
#    legacy = Open WebUI drives tools itself, instead of offering them to the model.
#    Needed so web search actually runs, and so tool-less vision models stop erroring.
def fc(model_id, vision):
    payload = {
        "id": model_id, "name": model_id, "base_model_id": None,
        "meta": {"capabilities": {"vision": vision, "citations": True}},
        "params": {"function_calling": "legacy"},
    }
    try:
        call("/api/v1/models/create", payload)
    except urllib.error.HTTPError as e:
        if e.code in (400, 409):
            call(f"/api/v1/models/model/update?id={model_id}", payload)
        else:
            raise
for m, v in ((os.environ["CHAT_MODEL"], False), (os.environ["VISION_MODEL"], True)):
    try_(f"function calling: legacy -> {m}", lambda m=m, v=v: fc(m, v))
PY

echo
echo "done — restart with: myai restart"
