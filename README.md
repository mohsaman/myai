# myai — a local AI stack for Apple Silicon

A complete, self-hosted AI setup that runs on a single Mac: chat, code, vision, image
generation, speech synthesis and transcription. Nothing is sent to a provider.

One command starts everything and opens the browser. One command stops everything, clears
residual processes and stays stopped across reboots.

```
myai start     myai stop     myai status     myai logs     myai backup
```

---

## What you get

| Component | Role |
|---|---|
| **Ollama** | Runs the language models, serves them on a local API |
| **Open WebUI** | Browser interface — chat, file upload, voice, model switching |
| **ComfyUI + SDXL** | Image generation on the GPU |
| **Kokoro** | Neural text-to-speech, 72 voices, OpenAI-compatible API |
| **faster-whisper** | Speech recognition (built into Open WebUI) |

Suggested models — swap freely, these are what the defaults assume:

| Model | Size | Role | Measured (M5, 32 GB) |
|---|---|---|---|
| `qwen3:30b-a3b` | 18 GB | Chat, reasoning, web search | 50.9 tok/s |
| `qwen2.5-coder:14b` | 9 GB | Code | 14.1 tok/s |
| `qwen2.5vl:7b` | 6 GB | Vision (reads images) | 7.9 s/image |
| `qwen2.5:3b` | 1.9 GB | Background tasks — titles, tags | — |
| `nomic-embed-text` | 274 MB | Embeddings for document retrieval | — |
| SDXL 1.0 | 6.5 GB | Image generation | 42 s/image |

---

## Requirements

- **Apple Silicon Mac.** Tested on M5; any M-series works.
- **32 GB unified memory recommended.** 16 GB works if you drop the 30B model and use a 14B or smaller.
- **~40 GB free disk** for all models above.
- **Homebrew.** <https://brew.sh>

> A fanless Mac (Air) throttles under sustained image generation. Chat is unaffected.

---

## Install

### 1. Ollama and the models

```bash
brew install ollama
brew services start ollama

ollama pull qwen3:30b-a3b        # chat + reasoning
ollama pull qwen2.5-coder:14b    # code
ollama pull qwen2.5vl:7b         # vision
ollama pull qwen2.5:3b           # background tasks — keep this one small
ollama pull nomic-embed-text     # embeddings
```

> **Pulls sometimes hang at 100%** — the transfer finishes but the client never writes the
> manifest. Kill it and re-run the same `ollama pull`; it resumes from the partial blob and
> completes in seconds rather than re-downloading.

### 2. Open WebUI

It needs Python 3.11 specifically. `uv` fetches that without touching system Python:

```bash
brew install uv
uv python install 3.11

mkdir -p ~/.open-webui/logs
uv venv --python 3.11 ~/.open-webui/venv
VIRTUAL_ENV="$HOME/.open-webui/venv" uv pip install open-webui
```

### 3. ComfyUI and SDXL

```bash
git clone https://github.com/comfyanonymous/ComfyUI.git ~/ComfyUI
cd ~/ComfyUI && git checkout v0.36.0        # pin it
mkdir -p logs models/checkpoints

uv venv --python 3.12 venv
VIRTUAL_ENV="$HOME/ComfyUI/venv" uv pip install torch torchvision torchaudio
VIRTUAL_ENV="$HOME/ComfyUI/venv" uv pip install -r requirements.txt

curl -L -o models/checkpoints/sd_xl_base_1.0.safetensors \
  "https://huggingface.co/stabilityai/stable-diffusion-xl-base-1.0/resolve/main/sd_xl_base_1.0.safetensors"
```

Verify Metal is available — this must print `True`:

```bash
~/ComfyUI/venv/bin/python -c "import torch; print(torch.backends.mps.is_available())"
```

> Deliberately **no ComfyUI Manager and no custom nodes**. Custom nodes are arbitrary Python
> executed in-process; skipping them is most of the supply-chain risk avoided. Download
> checkpoints by hand instead.

### 4. Kokoro (text-to-speech)

```bash
brew install espeak-ng
git clone https://github.com/remsky/Kokoro-FastAPI.git ~/kokoro
cd ~/kokoro && git checkout v0.9.0 && mkdir -p logs

uv venv --python 3.12 venv
VIRTUAL_ENV="$HOME/kokoro/venv" uv pip install -e .
./venv/bin/python docker/scripts/download_model.py --output api/src/models/v1_0
```

> The project is Docker-first and hardcodes container paths. Running it natively requires
> `MODEL_DIR` and `VOICES_DIR` as absolute paths — the launch agent below sets them. Without
> those you get `Read-only file system: '/app'`.

### 5. Install myai and the launch agents

```bash
./install.sh
```

That copies `myai` to `~/.local/bin`, generates the three launch agents from the templates
with your home directory substituted, and loads them. Make sure `~/.local/bin` is on your PATH.

### 6. Configure Open WebUI

```bash
myai start                     # register an admin account in the browser first
./scripts/configure.sh         # then apply the settings below
```

Or set them by hand in the UI — the script just automates what's described in
[Configuration](#configuration).

---

## Configuration

These are the settings that matter. The defaults are wrong for a memory-constrained machine.

### Task model — the most important one

Admin → Settings → Interface → **Task Model** → `qwen2.5:3b`

Open WebUI generates chat titles, tags and follow-up suggestions using your *selected chat
model* by default. That means every message silently fires extra inferences on the 18 GB
model. On a 32 GB machine this forces everything else into swap.

*Measured impact: image generation went from 251s to 84s after this change alone.*

### Model unload timeout

```bash
launchctl setenv OLLAMA_KEEP_ALIVE 60s
brew services restart ollama
```

Models sit in RAM for **5 minutes** after use by default. `myai start` sets this for you.

> Don't put it in Homebrew's plist — `brew services` regenerates that file from its formula
> on every start and silently drops hand-added keys.

### ComfyUI: keep the model resident

The launch agent passes `--highvram`. Without it ComfyUI reloads 6.5 GB of weights from disk
on *every* render.

*Measured impact: 116s → 42s per image.*

### Text-to-speech

Admin → Settings → Audio → TTS:
- Engine: **OpenAI**
- Base URL: `http://127.0.0.1:8880/v1`
- API key: any non-empty string
- Model: `kokoro`, Voice: `af_bella`

Kokoro speaks the OpenAI protocol, so no special support is needed.

### Speech-to-text

Engine: leave **empty** (local faster-whisper). Set Whisper Model to `small` — the `base`
default is noticeably weaker.

### Web search

Admin → Settings → Web Search:
- Enable, Engine: **duckduckgo** (no API key needed)
- **Bypass Embedding and Retrieval: ON**

Then, per model, set **Function Calling: Legacy**. With native function calling the model is
merely *offered* a search tool and often declines; with legacy, Open WebUI runs the search and
injects the results.

> Web search is the one feature that sends data off the machine — the query goes to
> DuckDuckGo. Everything else is local.

### Vision models and tools

A vision model without tool support (like `qwen2.5vl`) will reject any request carrying tool
definitions. Set that model's **Function Calling: Legacy** too, or it fails with
*"does not support tools"* whenever an integration toggle is on.

No single model here does both vision and native tool calling — pick per task.

---

## Usage

```bash
myai start          # start everything, wait until healthy, open the browser
myai stop           # stop everything, sweep residual processes, stay stopped after reboot
myai restart
myai status         # health of each service, LAN URL, installed models
myai logs           # tail Open WebUI logs
myai logs comfy     # tail ComfyUI logs
myai logs kokoro    # tail Kokoro logs
myai backup [dir]   # archive chats, users, config and the launch agents
```

**Reboot behaviour** is the point of `stop`: it runs `launchctl disable`, which persists. A
plain `launchctl unload` does not — launchd rescans `~/Library/LaunchAgents` at login and
brings the service back. `myai start` re-enables them.

**Residual processes** are swept on stop. Ollama forks a separate model runner per loaded
model — an 18 GB model leaves a 19 GB process behind that `brew services stop` does not always
reap. `myai stop` finds and clears it, then verifies the ports are released.

---

## Security notes

- **Ollama, ComfyUI and Kokoro bind to loopback only.** Only Open WebUI is exposed, and it
  requires a login. Don't expose the others — none of them has authentication.
- **Register the admin account immediately** after first start. Until one exists, signup is
  open to anyone who can reach the port.
- **For access away from home, use a VPN** (Tailscale or similar) rather than port
  forwarding. A laptop's address changes; a tunnel doesn't, and nothing needs to be opened
  on your router.

---

## Troubleshooting

| Symptom | Cause |
|---|---|
| `Multimodal data provided, but model does not support multimodal requests` | Image sent to a text-only model. Use the vision model. |
| `does not support tools` | Tool definitions sent to a model without tool support. Set Function Calling: Legacy for it. |
| Model answers from training data instead of searching | Native function calling — the model declined the tool. Set Function Calling: Legacy. |
| Image generation slow and getting slower | Models thrashing memory. Check the Task Model setting and `OLLAMA_KEEP_ALIVE`. |
| Ollama pull stuck at 100% | Kill and re-run the same pull; it resumes and finalises. |
| Document upload: *"The content provided is empty"* | Text extraction returned nothing. Check the file has selectable text; scanned PDFs need OCR. |

---

## Licence

MIT for the scripts in this repo. The components it installs carry their own licences —
Ollama, Open WebUI, ComfyUI, Kokoro and the model weights each have separate terms. SDXL
ships under CreativeML Open RAIL++-M, which has use restrictions worth reading.
