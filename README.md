# myai — a local AI stack for macOS and Linux

![The stack at a glance](docs/infographic.png)


A complete, self-hosted AI setup that runs on a single machine. Nothing is sent to a
provider. What it can do:

- **Chat and reasoning** — one dense 27B model at conversational speed
- **Agentic tool use** — the model decides when to read files, fetch a URL or recall a fact, and chains the calls itself
- **Write and run code** — a real Python kernel with filesystem, shell and network access, not a browser sandbox
- **Inspect machines** — a read-only terminal for this computer and any SSH hosts you add: allowlisted commands, no shell, credential paths blocked
- **Read images** — screenshots, diagrams, tables and scanned documents
- **Generate images** — Qwen-Image-2.1 on the local GPU, native 2K with legible text
- **Speak and listen** — neural text-to-speech in 53 languages, plus dictation
- **Search the web** — with citations, only when you ask for it
- **Remember** — a persistent knowledge graph that carries across conversations
- **48k context** — long documents and long conversations stay in memory

Runs on **macOS** (launchd, Metal) and **Linux** (systemd, CUDA) — same commands on both.

One command starts everything and opens the browser. One command stops everything, clears
residual processes and stays stopped across reboots.

```
myai start     myai stop     myai status     myai doctor     myai unload     myai logs     myai backup
```

**New here? Read [GUIDE.md](GUIDE.md).** This file covers installing and configuring the
stack; the guide covers using it — what each capability is for, which model to pick, how
to phrase things, and where the sharp edges are.

---

## What you get

| Component | Role |
|---|---|
| **Ollama** | Runs the language models, serves them on a local API |
| **Open WebUI** | Browser interface — chat, file upload, voice, model switching |
| **ComfyUI + Qwen-Image-2.1** | Image generation on the GPU |
| **Kokoro** | Neural text-to-speech, 72 voices, 8 languages, best quality |
| **Piper** | Text-to-speech for the other 45 languages, one model per voice |
| **TTS router** | Detects the language of a reply and picks the engine that can say it |
| **faster-whisper** | Speech recognition (built into Open WebUI) |
| **Jupyter** | The code interpreter's kernel — real Python, filesystem and network |
| **mcpo** | Bridges MCP tool servers into Open WebUI as callable tools |
| **terminal** | Read-only shell the model can query, locally and over SSH |
| **caddy** | TLS in front of Open WebUI, so browsers will grant a microphone off-machine |

[![Architecture](docs/architecture.png)](docs/architecture.html)

The diagram above is the same information in one page: which services are reachable from
where, what each model is for, and — the part worth reading twice — the five paths that
actually cross the machine boundary.

Suggested models — swap freely, these are what the defaults assume:

| Model | Size | Role | Measured (Apple M5, 32 GB) |
|---|---|---|---|
| `qwen3.8:27b-mlx` | 18 GB | Everything — chat, images, code, tool use, and background titling. Dense, 27.8B parameters, nvfp4, 40k context | 17 tok/s |
| `nomic-embed-text` | 274 MB | Embeddings for document retrieval | — |
| Qwen-Image-2.1 | 16.1 GB | Image generation — 3 files, research licence | — |

---

## Requirements

### macOS

- **Apple Silicon Mac.** Tested on M5; any M-series works.
- **32 GB unified memory recommended.** 16 GB works if you drop the 27B and use a 14B or smaller.
- **~30 GB free disk** for all models above.
- **Homebrew.** <https://brew.sh>
- **Node.js** (`brew install node`) — the MCP tool servers are fetched with `npx` on first
  run. Without it the filesystem, fetch, memory and time tools fail silently at startup.

> A fanless Mac (Air) throttles under sustained load — image generation, and also long
> agent sessions. Occasional chat is unaffected, but an OpenCode session sending requests
> back to back for 40 minutes measured prompt processing falling from 193 to ~20 tok/s and
> generation from 13–15 to 3.4 tok/s. A cool, idle machine recovered the full rate.

### Linux

- **NVIDIA GPU with CUDA** for usable image generation and faster inference. CPU-only works
  for chat but image generation becomes impractical.
- **32 GB RAM recommended** (or 16 GB VRAM + 16 GB system).
- **systemd** with user units — every mainstream distro.
- Python 3.11 is fetched by `uv`; no system Python is touched.

---

---

## Install — macOS

### 1. Ollama and the models

```bash
brew install ollama
brew services start ollama

> This model needs **ollama 0.34 or newer** — older versions reject the manifest with
> *"requires a newer version of Ollama"* and a 412, before downloading anything. The
> `-mlx` build is compiled for Apple Silicon and is roughly twice the speed of the generic
> one on an M-series Mac; on any other platform use `qwen3.8:27b`.
> The tag says 27b; `ollama show` reports 27.8B parameters. Same model — pull by the tag.

ollama pull qwen3.8:27b-mlx      # 27.8B parameters, nvfp4, 18 GB — chat, images, code, tools, titling
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

### 3. ComfyUI and Qwen-Image-2.1

```bash
git clone https://github.com/comfyanonymous/ComfyUI.git ~/ComfyUI
cd ~/ComfyUI && git checkout v0.37.0        # pin it — 0.37 is the first with the Qwen 2.1 nodes
mkdir -p logs models/diffusion_models models/text_encoders models/vae

uv venv --python 3.12 venv
VIRTUAL_ENV="$HOME/ComfyUI/venv" uv pip install torch torchvision torchaudio
VIRTUAL_ENV="$HOME/ComfyUI/venv" uv pip install -r requirements.txt

# Three files, not one: the diffusion model, the text encoder and the VAE load
# separately. 16.1 GB in total.
B=https://huggingface.co/Comfy-Org/Qwen-Image-2.1/resolve/main
curl -L -o models/diffusion_models/qwen_image_2.1_int8_convrot.safetensors \
  "$B/diffusion_models/qwen_image_2.1_int8_convrot.safetensors"     # 6.76 GB
curl -L -o models/text_encoders/qwen3vl_8b_int8_convrot.safetensors \
  "$B/text_encoders/qwen3vl_8b_int8_convrot.safetensors"            # 8.71 GB
curl -L -o models/vae/qwen_image_2.1_vae_bf16.safetensors \
  "$B/vae/qwen_image_2.1_vae_bf16.safetensors"                      # 0.63 GB
```

> **Licence.** Qwen-Image-2.1 ships under the Qwen Research License, not Apache — it grants
> rights *"FOR NON-COMMERCIAL PURPOSES ONLY"*, defined as research or evaluation. Earlier
> Qwen-Image releases were Apache 2.0; this one is not. Commercial use needs a separate
> agreement from Qwen. SDXL, which this replaced, was commercially usable under
> CreativeML OpenRAIL++-M — so this is a real trade, made deliberately for the quality.

> The `int8_convrot` builds are the ones that fit: bf16 is roughly double and will not sit
> inside a 24 GB budget. Verified working on Apple Silicon via MPS.

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

Kokoro covers eight languages well. Piper covers fifty-three, so the two together are what
let the stack speak anything, and a small router in front picks between them:

```bash
brew install ffmpeg                      # see the note below — not optional
python3 -m venv ~/piper/venv
~/piper/venv/bin/pip install piper-tts fastapi uvicorn httpx \
                             lingua-language-detector
mkdir -p ~/piper/logs ~/piper/voices
```

`install.sh` copies `tts/router.py` and `tts/voices.py` into `~/piper` and registers the
service. No voices are downloaded up front — 177 voices at ~60 MB each is 10 GB, almost
all of it for languages you will never use — so the router fetches one the first time a
language comes up and reuses it from then on.

> **ffmpeg is required, and its absence is silent.** Kokoro returns mp3, which Open WebUI
> plays directly; Piper returns WAV, which Open WebUI transcodes. Without ffmpeg every
> non-Kokoro language fails with a bare `[Errno 2] No such file or directory: 'ffprobe'`
> and nothing in the interface says why.

### 5. Code interpreter and agentic tools

A Python kernel for the code interpreter, and the MCP tool servers the model calls.

```bash
# Jupyter — the code interpreter's kernel
python3 -m venv ~/jupyter/venv
~/jupyter/venv/bin/pip install jupyter_server ipykernel numpy pandas matplotlib requests beautifulsoup4

# mcpo — bridges MCP servers to Open WebUI
python3 -m venv ~/mcpo/venv
~/mcpo/venv/bin/pip install mcpo 'mcp<2'      # mcpo 0.0.x needs the mcp 1.x client API

# terminal — the read-only shell the model queries
python3 -m venv ~/terminal/venv
~/terminal/venv/bin/pip install fastapi 'uvicorn[standard]'
```

The MCP servers themselves need `node`/`npx` and `uv`/`uvx` on PATH — they are fetched
on first run. `install.sh` writes `~/mcpo/config.json` and generates both auth tokens.

### 6. Install myai and the launch agents

```bash
./install.sh
```

That copies `myai` to `~/.local/bin`, generates the eight launch agents from the templates
with your home directory substituted, and loads them. Ollama is the ninth service and is
managed through `brew services`, not a launch agent. Make sure `~/.local/bin` is on your PATH.

Anything you skipped is skipped here too, with a line saying so — `install.sh` only installs
agents whose program actually exists. Run `myai doctor` afterwards to see what landed.

### 7. Configure Open WebUI

```bash
myai start                     # register an admin account in the browser first
./scripts/configure.sh         # then apply the settings below
```

Or set them by hand in the UI — the script just automates what's described in
[Configuration](#configuration).

The chat model ends up with web search, image generation and the code interpreter on by
default, and the MCP tools attached. None of that forces anything: under native function
calling an enabled feature is *offered* to the model, which decides per message whether to
use it — the way a desktop agent works, with no toggle to remember.

That makes the row of tool controls in the message box redundant, so `ui/custom.css` hides
it: the Integrations menu, the feature chips, the tool counter and the terminal picker. The
+ menu (files, images, screen capture), paste, the microphone and voice mode stay. Hiding
changes nothing functional, because each chat's features are set from the model's defaults,
not from the controls. The cost is the per-chat override: to keep a chat offline, say so in
the message. `install.sh` puts the file in `~/.config/myai/`, and `myai start` copies it into
Open WebUI's `frontend/static/` — not `static/`, which Open WebUI empties and recopies on
every start — so it also survives a pip upgrade. It also stops the new-chat description from
popping up a tooltip that only repeats the same text. Per-machine rules go in `~/.config/myai/local.css`,
which `myai start` appends and the repo never contains. Open WebUI's own branding belongs
there if you change it at all: its licence permits that only for deployments of at most 50
end users in a rolling 30 days, or with the copyright holder's permission. To bring the controls back, delete
`~/.config/myai/custom.css` and empty the copy in the package.

### 8. Size the context window, then check the install

```bash
./scripts/set-context.sh       # measure each model's KV cost, bake in a window
myai doctor                    # verify the whole stack before you rely on it
```

`set-context` is not optional on a memory-constrained machine and it is not a setting you can
reason out. It loads each model twice, once with a trivial prompt and once with a large one,
and divides the change in allocation by the change in tokens. The derived figure is wrong here
by a factor of three — see [Context length](#context-length) — and a window sized from it asks
for 30 GB on a 24 GB machine, which fails by getting slow rather than by erroring.

`myai doctor` is the step people skip and then regret: it names anything missing, anything
running that shouldn't be, and anything installed but never configured.

---

## Install — Linux

The same five components. Only the packaging and service manager differ.

### 1. Ollama and the models

```bash
curl -fsSL https://ollama.com/install.sh | sh
```

The installer creates a **system-wide** `ollama.service`. myai runs its own user unit instead,
so disable that one or it will hold the port:

```bash
sudo systemctl disable --now ollama
```

Then pull the models — identical to macOS:

```bash
ollama pull qwen3.8:27b        # -mlx is Apple Silicon only; this is the portable build
ollama pull nomic-embed-text
```

### 2. Open WebUI

```bash
curl -LsSf https://astral.sh/uv/install.sh | sh     # if you do not have uv
uv python install 3.11

mkdir -p ~/.open-webui/logs
uv venv --python 3.11 ~/.open-webui/venv
VIRTUAL_ENV="$HOME/.open-webui/venv" uv pip install open-webui
```

### 3. ComfyUI and Qwen-Image-2.1

```bash
git clone https://github.com/comfyanonymous/ComfyUI.git ~/ComfyUI
cd ~/ComfyUI && git checkout v0.36.0
mkdir -p logs models/checkpoints

uv venv --python 3.12 venv
# CUDA build — check https://pytorch.org for the index matching your driver
VIRTUAL_ENV="$HOME/ComfyUI/venv" uv pip install torch torchvision torchaudio \
  --index-url https://download.pytorch.org/whl/cu124
VIRTUAL_ENV="$HOME/ComfyUI/venv" uv pip install -r requirements.txt

B=https://huggingface.co/Comfy-Org/Qwen-Image-2.1/resolve/main
curl -L -o models/diffusion_models/qwen_image_2.1_int8_convrot.safetensors \
  "$B/diffusion_models/qwen_image_2.1_int8_convrot.safetensors"
curl -L -o models/text_encoders/qwen3vl_8b_int8_convrot.safetensors \
  "$B/text_encoders/qwen3vl_8b_int8_convrot.safetensors"
curl -L -o models/vae/qwen_image_2.1_vae_bf16.safetensors \
  "$B/vae/qwen_image_2.1_vae_bf16.safetensors"
```

Verify CUDA is visible — must print `True`:

```bash
~/ComfyUI/venv/bin/python -c "import torch; print(torch.cuda.is_available())"
```

> On macOS the equivalent check is `torch.backends.mps.is_available()`.

### 4. Kokoro (text-to-speech)

```bash
sudo apt install espeak-ng          # or: dnf install espeak-ng / pacman -S espeak-ng

git clone https://github.com/remsky/Kokoro-FastAPI.git ~/kokoro
cd ~/kokoro && git checkout v0.9.0 && mkdir -p logs

uv venv --python 3.12 venv
VIRTUAL_ENV="$HOME/kokoro/venv" uv pip install -e .
./venv/bin/python docker/scripts/download_model.py --output api/src/models/v1_0
```

### 4b. Piper and the TTS router

```bash
sudo apt install -y ffmpeg               # required to play Piper's WAV output
python3 -m venv ~/piper/venv
~/piper/venv/bin/pip install piper-tts fastapi uvicorn httpx \
                             lingua-language-detector
mkdir -p ~/piper/logs ~/piper/voices
```

Voices are fetched on first use rather than up front. See the macOS section above for why,
and for what happens when ffmpeg is missing.

### 5. Code interpreter and agentic tools

A Python kernel for the code interpreter, and the MCP tool servers the model calls.

```bash
# Jupyter — the code interpreter's kernel
python3 -m venv ~/jupyter/venv
~/jupyter/venv/bin/pip install jupyter_server ipykernel numpy pandas matplotlib requests beautifulsoup4

# mcpo — bridges MCP servers to Open WebUI
python3 -m venv ~/mcpo/venv
~/mcpo/venv/bin/pip install mcpo 'mcp<2'      # mcpo 0.0.x needs the mcp 1.x client API

# terminal — the read-only shell the model queries
python3 -m venv ~/terminal/venv
~/terminal/venv/bin/pip install fastapi 'uvicorn[standard]'
```

The MCP servers themselves need `node`/`npx` and `uv`/`uvx` on PATH — they are fetched
on first run. `install.sh` writes `~/mcpo/config.json` and generates both auth tokens.

### 6. Install myai and the service units

```bash
./install.sh                         # detects Linux, writes systemd user units
sudo loginctl enable-linger $USER    # so services survive logout and start at boot
```

Without lingering, systemd user units stop when your last session ends and do not start at
boot. This is the Linux equivalent of launchd agents loading at login.

### 7. Configure Open WebUI

```bash
myai start
./scripts/configure.sh
```

### 8. Size the context window, then check the install

```bash
./scripts/set-context.sh       # measure each model's KV cost, bake in a window
myai doctor                    # verify the whole stack before you rely on it
```

`set-context` is not optional on a memory-constrained machine and it is not a setting you can
reason out. It loads each model twice, once with a trivial prompt and once with a large one,
and divides the change in allocation by the change in tokens. The derived figure is wrong here
by a factor of three — see [Context length](#context-length) — and a window sized from it asks
for 30 GB on a 24 GB machine, which fails by getting slow rather than by erroring.

`myai doctor` is the step people skip and then regret: it names anything missing, anything
running that shouldn't be, and anything installed but never configured.

---

## Platform differences at a glance

| | macOS | Linux |
|---|---|---|
| Service manager | launchd agents | systemd user units |
| Ollama supervised by | `brew services` | `myai-ollama.service` |
| GPU backend | Metal (MPS) | CUDA |
| Persist across reboot | `launchctl enable/disable` | `systemctl --user enable/disable` + linger |
| Logs | files under each component | `journalctl --user -u myai-*` |
| Browser open | `open` | `xdg-open` |

`myai` detects the platform and uses the right mechanism; the commands are identical on both.

---

## Configuration

These are the settings that matter. The defaults are wrong for a memory-constrained machine.

### Task model

Admin → Settings → Interface → **Task Model** → `qwen3.8:27b-mlx`

Open WebUI generates chat titles, tags and follow-up suggestions in the background. Which
model does that work is a memory decision, not a quality one, and the right answer depends
on what is left after the chat model is loaded.

This stack used to point it at a 1.9 GB `qwen2.5:3b`, so that background work never touched
the main model. That was right when the main model left room for it. It no longer does. At a
40k window the 27B needs 16.9 GB of weights plus 3.8 GB of KV cache — 20.8 GB of a ~24 GB
budget. A second resident model would leave under 1.5 GB for macOS, a browser and the eight
other services, which is how a machine ends up in swap.

So background work runs on the model that is already loaded. It is slower per title — a 27B
writing four words takes a second or two — but it happens in the background, and it costs no
memory at all, because there is nothing to hold resident beside the model you are talking to.

> If you run a smaller chat model and have several spare GB, the old advice is still the
> better one: a 3B task model keeps background work off the model you are waiting on.

### Model unload timeout

Ollama unloads a model **5 minutes** after use by default. `myai` sets **60s**.

The reason is that two tenants want the same memory and only one can be pinned. The chat
model holds ~22 GB — 16.9 GB of weights plus 3.8 GB of KV cache at a 40k window — and
Qwen-Image-2.1 loads 16.1 GB across its diffusion model, text encoder and VAE. That is 38 GB
against a ~24 GB budget. They cannot both be resident, and **ollama has no idea ComfyUI
exists**, so it will never yield on its own.

A 60s timeout makes the machine arbitrate instead of you. Ask for an image after a pause and
the chat model has already gone; come back to chat and it reloads in about 20 seconds, which
is the cost of a pause you were taking anyway.

To pin it instead:

```bash
MYAI_KEEP_ALIVE=-1 myai restart
```

That is defensible when you chat far more than you generate — but then **every** image needs
`myai unload` first, remembered every time. `myai doctor` will flag the combination.

> **Why `MYAI_` and not `OLLAMA_`.** These are published with `launchctl setenv`, which puts
> them in the environment of *every* process in the GUI session — including the next run of
> `myai`. Defaulting them from their own names made the script read back whatever the last
> run exported, so editing a default in the script did nothing at all: the old value outlived
> it silently. Overrides therefore use `MYAI_*` names, which nothing exports.

> Don't put it in Homebrew's plist either — `brew services` regenerates that file from its
> formula on every start and silently drops hand-added keys.

**Linux** — set in `myai-ollama.service` as `Environment="OLLAMA_KEEP_ALIVE=60s"`.
Change it there and `systemctl --user daemon-reload`.

### ComfyUI and the memory budget

This is the central constraint of the stack, so it is worth stating plainly:

```
chat model  qwen3.8:27b-mlx     16.9 GB weights + 3.8 GB KV  =  22.0 GB
image model Qwen-Image-2.1      6.8 + 8.7 + 0.6              =  16.1 GB
                                                      total  =  38.1 GB
GPU budget on a 32 GB Mac                                    =  ~24 GB
```

Nothing errors when you exceed it. Inference spills to the CPU and `ollama ps` goes on
reporting `100% GPU` while throughput collapses.

Two consequences:

- **`OLLAMA_KEEP_ALIVE` is 60s, not `-1`.** Ollama has to be willing to let go, because
  ComfyUI cannot ask it to.
- **ComfyUI does not get `--highvram`.** That flag pins the checkpoint between renders, worth
  *116s → 42s* back when the image model was SDXL's 6.5 GB. At 16.1 GB it is not affordable,
  and pinning both tenants is not a thing that fits.

If you need to free the memory immediately rather than waiting out the timeout:

```bash
myai unload        # releases the model, leaves all nine services up
```

### Image generation speed

Qwen-Image-2.1 is slow on Apple Silicon, and the cause is worth stating so nobody
spends an afternoon tuning the wrong thing. Measured at 1024×1024 on a 32 GB M-series:

| Change | Time | Verdict |
|---|---|---|
| 25 steps, cold | 430 s | baseline |
| 25 steps, warm | 643 s | **slower warm than cold** — it is not load-bound |
| `--gpu-only` (text encoder on GPU, not CPU) | 463 s | no help; reverted |
| 10 steps | 204 s | near-linear in steps |

Sampling dominates. ComfyUI parks the 8.9 GB text encoder on the CPU by default under
its `SHARED` vram state, which looks like the culprit and is not — forcing it onto the
GPU changed nothing measurable.

So steps are the only real control, and they trade directly against quality: at 10 the
fine detail flattens. The default is **15**, which still looks finished; use 25 for
anything going in front of someone.

```bash
generate-image -t 25 "..."      # final
generate-image -t 10 "..."      # draft
```

**The default is 12 steps (~234 s), chosen against the clock rather than the curve.** A
300-second tool timeout is a common default for agents that shell out, and 15 steps lands at
~279 s — inside it, with no margin for a cold model load. 12 has room.

A render is not lost when the caller gives up, because ComfyUI owns the job, not the client.
So the tool prints its job id before it starts waiting:

```
queued 3bace56a-… — if this is interrupted: generate-image -r 3bace56a-… out.png
```

```bash
generate-image -b "..." out.png    # queue and exit immediately, print the id
generate-image -r <id> out.png     # collect a finished job, whenever
```

Use `-b` for anything above about 15 steps from inside an agent: the render happens either
way, and `-r` picks it up afterwards.

### Text-to-speech

Admin → Settings → Audio → TTS:
- Engine: **OpenAI**
- Base URL: `http://127.0.0.1:8881/v1`  ← the router, not Kokoro directly
- API key: any non-empty string
- Model: `kokoro`, Voice: `af_bella`

Point it at `8880` instead and you get Kokoro alone: excellent English, and every other
language read with an English accent. The router speaks the same OpenAI protocol, so
nothing else in the configuration changes.

### Voice and dictation need HTTPS off-machine

Voice mode and dictation work at `http://127.0.0.1:8080` and fail everywhere else,
including your own LAN address. The cause is a browser rule, not this stack: the
microphone is only available in a **secure context**, and browsers implement that by
making `navigator.mediaDevices` *undefined* on an insecure origin rather than by denying
permission. So the controls render, then fail with nothing informative.

`localhost` counts as secure. `http://192.168.1.x:8080` does not.

```bash
brew install mkcert caddy
mkcert -install                 # once, asks for your password
./scripts/setup-tls.sh          # certificate + reverse proxy config
caddy run --config ~/.open-webui/tls/Caddyfile
```

Then use `https://<hostname>.local:8443`, or any of the machine's addresses on port 8443.
The certificate covers every address the machine has when the script runs, plus its
`.local` name, which stays the same when the address changes. To cover a network the
machine is not on right now (home while at the office), name that address too:
`./scripts/setup-tls.sh 192.168.1.20`. After joining a network whose address is not
covered, run the script again and restart Caddy. Open WebUI keeps its plain listener on 8080 for
loopback, so nothing that already worked stops working.

Chrome's `unsafely-treat-insecure-origin-as-secure` flag is supposed to solve this without
a certificate. It did not work here, and it would not help Safari or a phone, neither of
which can set Chrome flags — so it is worth knowing about and not worth relying on.

Other devices must trust the CA at `~/Library/Application Support/mkcert/rootCA.pem`
before the microphone works there. On iOS that means installing it as a profile and then
enabling it under **General → About → Certificate Trust Settings**.

On Linux, Chrome and Chromium do not read the system trust store; they read the per-user NSS
database, so `update-ca-certificates` alone changes nothing for them. mkcert itself is not
needed on the client — only the CA's public certificate is:

```bash
scp ~/Library/Application\ Support/mkcert/rootCA.pem user@linux-host:/tmp/   # never rootCA-key.pem
sudo apt install libnss3-tools                                               # provides certutil
certutil -d sql:$HOME/.pki/nssdb -A -t "C,," -n "myai local CA" -i /tmp/rootCA.pem
```

Then restart Chrome. Check with a load against an empty store as a control: without the CA
the page is Chrome's *Privacy error*, with it the page loads. A snap-packaged Chromium keeps
its own database under `~/snap/chromium/current/.pki/nssdb` instead.

### Speech-to-text

Engine: leave **empty** (local faster-whisper). Set Whisper Model to `small` — the `base`
default is noticeably weaker.

`small` is fine for English. For dictation in other languages it is the weak link, and
`medium` is a marked improvement for about 1.5 GB and a little latency.

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

A vision model without tool support will reject any request carrying tool definitions,
failing with *"does not support tools"* whenever an integration toggle is on. If you run
one, set that model's **Function Calling: Legacy**.

This used to force a choice — read the image *or* use tools. It no longer does:
`qwen3.8:27b-mlx` reports `vision` and `tools` together, so one model covers both. Check with
`ollama show <model>` before assuming; the capability list is authoritative and the model's
own description is not.

---

## Using it from other machines

Everything runs on one machine — call it the host. Other machines can use it two ways, and
neither exposes the model server itself: Ollama stays bound to the host's loopback.

| From another machine | What travels | What runs where | Set up with |
|---|---|---|---|
| **Open WebUI in a browser** | HTTPS to the host's Open WebUI | everything on the host — model, tools, code, files | `scripts/setup-tls.sh` on the host; trust its CA on the client |
| **OpenCode (or any OpenAI-compatible client)** | model requests only, over SSH | model on the host; the agent's shell and file edits on the *client* | `myai share add` on the host; a config on the client |

### Open WebUI from a browser elsewhere

1. **On the host:** `./scripts/setup-tls.sh` issues a certificate for every current address
   plus `<hostname>.local`; add addresses of networks the host is not on right now as
   arguments. Caddy serves it on `:8443`. Plain `http://<host>:8080` also works for chat,
   but browsers withhold the microphone from it — see
   [Voice and dictation need HTTPS off-machine](#voice-and-dictation-need-https-off-machine).
2. **On each client:** trust the host's CA — macOS keychain, Windows `certutil`, iOS
   profile, and on Linux the per-user NSS database, which Chrome reads instead of the
   system store. The steps are in the same section. mkcert is only needed on the host.
3. **Use** `https://<hostname>.local:8443`, which survives the host changing address, or
   any address the certificate covers.

Tools, code and files all act on the **host**, because that is where Open WebUI runs.

### OpenCode on another machine

1. **On the host:** `myai share add <name> <user@client>` — a reverse SSH tunnel that puts
   the host's Ollama on the client's `127.0.0.1:11434`. The host dials out, so nothing new
   listens on the host. Needs key auth from host to client without a passphrase prompt.
2. **On the client, once:** `ClientAliveInterval 15` in its sshd, or the tunnel cannot come
   back for hours after the host sleeps. `myai share add` / `test` check for it and print
   the two commands.
3. **On the client:** the OpenCode config from
   [Pointing it at the local model](#pointing-it-at-the-local-model), unchanged — including
   the `limit` block, without which long sessions never compact.
4. **Run** `opencode --standalone` / `opencode run --standalone`, or OpenCode 2.x leaves a
   shared background server running after you exit.

The model answers from the host; **the agent's shell commands and file edits happen on the
client**, where OpenCode runs. Details, measurements and failure modes:
[From another machine — model here, shell there](#from-another-machine--model-here-shell-there).

Either way, the host serves **one request at a time**: a remote agent and a local chat
queue behind each other, and a fanless host slows under a long agent session.

## Usage

```bash
myai start          # start everything, wait until healthy, open the browser
myai stop           # stop everything, sweep residual processes, stay stopped after reboot
myai restart
myai status         # health of each service, LAN URL, installed models
myai doctor         # check the install and say what to fix
myai unload         # release the model's memory, leave the services running
```

`start` and `stop` append a line to `~/.myai-history.log` with the time and the parent
process. Stop disables the launch agents, so its effect outlives the shell that ran it and
survives a reboot — and when the stack is unexpectedly down, "who stopped it, and when" is
otherwise unanswerable.

```bash
myai logs           # tail Open WebUI logs
myai logs comfy     # tail ComfyUI logs
myai logs kokoro    # tail Kokoro logs
myai logs tts       # tail TTS router logs
myai backup [dir]   # archive chats, users, config and the launch agents
```

**Reboot behaviour** is the point of `stop`: it runs `launchctl disable`, which persists. A
plain `launchctl unload` does not — launchd rescans `~/Library/LaunchAgents` at login and
brings the service back. `myai start` re-enables them.

**Residual processes** are swept on stop. Ollama forks a separate model runner per loaded
model — an 18 GB model leaves a 19 GB process behind that `brew services stop` does not always
reap. `myai stop` finds and clears it, then verifies the ports are released.

---

## Agentic tools

Out of the box a local model can only talk. These two services let it *act* — which is
the difference between a chatbot and an assistant.

### MCP tool servers

[MCP](https://modelcontextprotocol.io) servers expose capabilities as callable tools.
`mcpo` translates them into the OpenAPI that Open WebUI speaks, so the model can call
them directly and chain several calls in one answer.

| Server | Tools | What the model can do |
|---|---|---|
| `filesystem` | 14 | Read, write, move and search files under `~/ai-workspace` |
| `fetch` | 1 | Retrieve a URL and read the page (sends a browser User-Agent) |
| `memory` | 9 | Store and recall facts in a knowledge graph that survives between chats |
| `time` | 2 | Current time, timezone conversion |

Edit `~/mcpo/config.json` to add more. Anything in the MCP ecosystem works — git,
databases, ticketing systems, your own scripts.

> The filesystem server is deliberately scoped to a single directory. Widening it to
> `$HOME` gives any prompt — including text pulled in by a web search — the ability to
> read every file you own. Scope it narrowly and on purpose.


#### Fetching sites that block bots

`mcp-server-fetch` identifies itself as a Python HTTP client by default, and a
number of sites refuse that outright. Both fetch servers here are configured with
a browser User-Agent, which is usually the whole fix:

```
"args": ["mcp-server-fetch", "--user-agent", "Mozilla/5.0 (…) Chrome/140.0.0.0 Safari/537.36"]
```

Worth knowing before you go further:

- **Check `robots.txt` before reaching for `--ignore-robots-txt`.** It is a separate
  gate from the User-Agent and usually is not the thing blocking you. 3gpp.org, for
  instance, ships the stock Joomla file: it disallows `/administrator/` and `/cache/`
  but not the spec archive, so a User-Agent alone is enough and the flag stays off.
- **Getting a 200 does not mean you got the content.** Plenty of directory listings
  are rendered by JavaScript, which this fetcher does not execute. 3gpp.org's
  `/ftp/Specs/archive/24_series/` returns `209 items.` and nothing else. The
  static equivalent, `/DynaReport/24-series.htm`, returns all 222 spec numbers.
  When a page comes back suspiciously short, look for a static version of it.
- **Mind the size.** A full series listing is ~160 KB, roughly 40k tokens. Against a
  64k context that is two or three pages per session, not ten. Raise `max_length`
  deliberately rather than by default.

### Code interpreter

Open WebUI's default Python sandbox (Pyodide) runs in the browser: no filesystem, no
network, no package installs. The Jupyter service replaces it with a real kernel, so
generated code can read your data files, call local APIs, and use pandas, numpy and
matplotlib.

`myai status` reports both. Tokens live in `~/jupyter/.token` and `~/mcpo/.apikey`,
mode `0600`, generated at install and never committed.

---

## Context length

Ollama's default context is smaller than what modern models are trained for. `myai`
sets it when it starts the service:

```
OLLAMA_CONTEXT_LENGTH=32768     # override in the environment to change it
```

On macOS this is applied with `launchctl setenv`, not by editing the launch agent.
`brew services start` regenerates its plist from the formula's template on every
start, so anything added to `~/Library/LaunchAgents/sh.brew.ollama.plist` is
discarded — and edits to the template in the Cellar are lost on `brew upgrade`.
`launchctl setenv` survives both.

Bigger is not automatically better — the KV cache has to fit in GPU memory alongside
the weights, or inference silently spills to the CPU and slows to a crawl. Work out
your own ceiling before raising it:

```
KV bytes/token ≈ 2 × layers × kv_heads × head_dim     (1 byte/element at q8_0)
```

**Do not trust that formula.** It is the textbook one and it is wrong here by a factor of
three. For `qwen3.8:27b-mlx` it predicts 34 KiB per token; the measured cost is 98. Two
things it cannot see: the model reports 65 layers but caches only every fourth one, and the
runtime allocates compute buffers that themselves scale with context. Sized from the derived
figure, a 112k window looks affordable — it would have needed 30 GB on a 24 GB machine.

So measure instead of deriving. `scripts/set-context.sh` loads the model twice, once with a
trivial prompt and once with a large one, and divides the change in allocation by the change
in prompt tokens. That captures whatever the runtime actually does without needing a model of
it:

```bash
./scripts/set-context.sh --dry-run          # measure every model, change nothing
./scripts/set-context.sh qwen3.8:27b-mlx    # measure one and bake in the window
```

`100% GPU` in `ollama ps` is necessary but not sufficient. Exceed the budget and inference
spills to the CPU while still reporting `100% GPU`; nothing reports an error and throughput
collapses — measured here from 18 tok/s to 7, with prompt evaluation going from 23 s to 160 s
for the same 6,300-token prompt.

The tell is `sysctl vm.swapusage`. If swap is filling, the window is too large for the
machine regardless of what fits in the GPU. At 98 KiB/token, 40k is the sustainable setting
for this model on 32 GB: 16.9 GB of weights plus 3.8 GB of cache, inside a ~24 GB ceiling.

---

## Using the tools

Everything below is off by default in a new chat. Open the **+** menu in the message
box and switch on what you need — nothing attaches automatically, and a model with no
tools will happily invent output rather than admit it cannot act.

**Qwen3.8 27B** reports `tools` alongside `vision`, so it chooses tools itself rather than
waiting to be told, and does not have to be swapped out to read an image. Verify with
`ollama show <model>` before assuming a model can do both — the capability list is
authoritative where a model card's prose is not.

### Terminal — ask about the machine

Switch on **Terminal** and pick your machine. Then ask for the answer, not the command:

```
How much memory does this device have?
Which volume is fullest?
Is ComfyUI running, and how long has it been up?
What did the last 50 lines of the mcpo log say?
Which Ollama models are installed and how much disk do they use?
Summarise the git status of ~/myai-stack.
```

**Read-only by design.** The server takes one command, runs it as an argv list with no
shell, and only from an allowlist of inspection tools. So:

| Asked for | What happens |
|---|---|
| `df -h`, `ps`, `launchctl list`, `git status` | runs |
| `ls \| wc -l`, `cmd > file`, `a; b`, `$(cmd)` | refused — there is no shell to interpret them |
| `rm`, `kill`, `sudo`, `curl`, `bash` | refused — not on the allowlist |
| `git push`, `launchctl bootout`, `ollama rm` | refused — state-changing subcommand |
| anything outside `TERMINAL_ROOT` | refused |
| `~/.ssh`, `*.pem`, `.token`, `.apikey`, `.netrc` | refused — credential paths |

One command per call. Ask for raw output and let the model interpret it, rather than
trying to pipe.

The Terminal panel's file browser is read-only and hides credential directories, so
`~/.ssh` and friends do not appear in it at all. The panel's **interactive shell pane is
not implemented**: Open WebUI expects a PTY over websocket for that, which is an
unrestricted login shell and deliberately out of scope here. The panel therefore shows
the file browser but no prompt to type at. What this server provides is the model-facing
`run_command` tool — the model runs commands and reports back, rather than you driving a
shell through a web page.

To widen or narrow the blast radius, edit `TERMINAL_ROOT` in the service definition
(`~/Library/LaunchAgents/com.terminal.server.plist`, or the systemd unit) — pointing it
at a single project directory is a reasonable default if you would rather not expose
your whole home. The allowlist itself is the `ALLOWED` set at the top of
`terminal/server.py`.

### Turning it into a domain expert

A system prompt makes a model *sound* expert. It does not make it correct. Asked
which EMM cause an MME returns when the HSS answers `DIAMETER_ERROR_USER_UNKNOWN`,
a 30B MoE this stack used previously, with a 3GPP expert skill loaded and a hints file forbidding unverified
citations answered **"#1, TS 24.301 section 9.9.2.1"**. Both halves were wrong, and
it said so with complete confidence.

The fix is not a better prompt. It is giving the model the document.

```bash
./scripts/fetch-specs.sh 24.301 29.272 23.401   # 3GPP
./scripts/fetch-specs.sh RFC6733 RFC9260        # IETF
./scripts/fetch-specs.sh --have                 # what is local
```

Documents land in `~/specs` as markdown, one file each — a 3GPP TS is a few MB and
tens of thousands of lines.

**Conversion matters more than it looks.** A specification's real content is in its
tables, and `textutil` flattens a table to one cell per line: the row
`| 0 | 1 | 1 | IMEISV |` becomes four separate lines, so a grep for `IMEISV` returns a
bare word with its bit values nowhere in sight. A model reading that reported the
IMEISV identity type as **444** — the page number from the contents page. `pandoc`
keeps the row intact, the same grep returns the whole row, and the answer is **3
(011)**. The fetcher prefers pandoc for that reason and falls back to textutil with a
warning. The answer the model invented is one grep away:

```
$ grep -n "IMSI unknown in HSS" ~/specs/3GPP-24.301.txt
4205:	#2	(IMSI unknown in HSS)
```

The discipline that makes this work: work out which document the question needs, fetch it
if it is not local, grep it, quote it, and cite the line — and never cite a clause you have
not grepped.

**Grep beats embeddings for this.** Spec lookup is exact — you want clause 9.9.3.9,
not something semantically adjacent. A vector search over chunked specifications
returns passages that *feel* relevant; grep returns the line, and the line is the
answer.

Everything here is openly published: 3GPP specifications are free from 3gpp.org
without registration, RFCs are public domain. The corpus is fetched at runtime into
`~/specs`, outside the repository — no standards text is redistributed here.

### Asking for a chart or an infographic

Open WebUI renders an `html` code block in its Artifacts panel, as a real page beside
the chat. The model has no way to discover that, so without being told it produces an
"infographic" out of box-drawing characters — a picture of a picture.

`configure.sh` adds an instruction covering it: on any request for an infographic,
diagram, chart or dashboard, emit a complete self-contained HTML document, never ASCII
boxes. The page must render with no network — no CDN, no web fonts — so charts have to
be inline SVG.

The same pass tells the model to say when it goes online: search or fetch freely, but
state what was searched for, give the URL, and mark which parts of the answer came from
the web. Web search is pre-enabled per model through `meta.defaultFeatureIds`.

Expect to iterate on layout. Asked for a two-vendor comparison, a local model of this size produced a
properly styled dark-theme page and then put both vendors in one column as two rows
labelled "Cost". Telling it to restructure works; getting it right unprompted is where
a larger model still shows.

### Measuring response time

```
myai stats        # last 12 generations
myai stats 30     # last 30
```

Ollama logs per-request timings; `myai stats` turns them into a table. Reading it:

| Column | Meaning |
|---|---|
| `in` | prompt tokens — the conversation plus any tool output fed in |
| `out` | tokens generated |
| `wait` | prompt evaluation, i.e. time before the first token appears |
| `generate` | time spent producing the answer |
| `tok/s` | generation rate |

Two things the table makes visible that are otherwise invisible:

- **Long outputs run slower per token.** Each new token attends over everything before
  it, so a 1,800-token answer generates at a lower rate than a 20-token one — measured
  here at 27 tok/s versus 31 on the same model.
- **Judge a slow run against its prompt size, not against your peak.** A long-context
  request is *supposed* to be slower. `myai stats` only warns when a run with a SHORT
  prompt comes in under half peak, which is the case that actually indicates a model
  reload or two models competing for GPU memory — and it prints what is loaded
  underneath the table so the two can be read together.

### Remote machines over SSH

The terminal reaches other machines too — a NAS, a lab box, a server — using the same
allowlist. Add targets from the command line:

```bash
myai terminal add nas  admin@192.168.1.10
myai terminal add edge ops@10.0.0.5 --port 2222 --jump ops@bastion.example.net
myai terminal add pi   pi@raspberrypi.local --key ~/.ssh/id_pi
myai terminal list
myai terminal test nas          # check it is reachable, as you, before the model tries
```

Then just name the machine:

```
Is the NAS running out of disk?
Compare uptime across nas and edge.
What version of Linux is edge on?
```

Two properties make this safe enough to hand to a model:

- **The model names a host, never an address.** It picks from the targets you added, so
  nothing it says can produce a connection to a machine you did not configure. Asking it
  to reach `192.168.1.50` returns *unknown host*, not a connection.
- **The allowlist is applied before connecting.** A refused command never leaves your
  machine — measurably: a rejected command returns in ~30 ms, while an accepted one takes
  as long as SSH needs to dial.

Keys must be in `ssh-agent` or passphrase-free: connections use `BatchMode=yes` and fail
rather than hang on a prompt. `hosts.json` is `0600` and gitignored.

### Code Interpreter — compute, plot, transform

Switch on **Code Interpreter**. This is a real Jupyter kernel, so unlike the browser
sandbox it ships with, generated code can read your files, install nothing it does not
already have, and reach local services.

```
Parse ~/Downloads/usage.csv and plot the weekly totals.
Work out how much KV cache a 48-layer model needs at 128k context.
Convert every .png in ~/Desktop/shots to a single PDF.
```

It has numpy, pandas, matplotlib, requests and beautifulsoup4. Unlike the terminal, it is
**not** restricted — Python there can do anything your user account can.

### Tools — files, web, memory

Switch on **Tools** and tick the servers you want:

| Tool | Ask it |
|---|---|
| `filesystem` | "Write a summary of this conversation to notes.md" — scoped to `~/ai-workspace` |
| `fetch` | "Read <url> and tell me what changed in this release" |
| `memory` | "Remember that I prefer answers without preamble" — persists across chats |
| `time` | "What time is it in Tokyo?" |

### Choosing between them

Terminal and Code Interpreter overlap. The rule of thumb:

- **Terminal** for questions *about* the machine — safe, constrained, no side effects.
- **Code Interpreter** for *work on data* — unrestricted, so reserve it for when you
  actually need to compute or write something.

### A word on mixing web and execution

`fetch` pulls text written by someone else into the conversation, and a model acts on
text. With Code Interpreter also on, a fetched page can influence code that runs on your
machine. The terminal is far more resistant — an injected instruction still cannot get
past the allowlist — but the safe habit is to keep browsing and execution in separate
chats.

---

## OpenCode — the same stack outside the browser

Open WebUI is a browser tab. OpenCode is an agent that reads files, runs commands, edits code
and iterates, driven by the same local model. It comes two ways, and they share one config.

```bash
npm install -g opencode-ai        # the CLI
```

> Homebrew also carries it, but the formula lags: at the time of writing brew had 1.18.30
> against npm's 1.18.32. Pick one — they both install to `/opt/homebrew/bin/opencode` and
> npm refuses to overwrite brew's copy. If you switch from brew to npm, `brew uninstall
> opencode` first, and watch what goes with it: it took `ripgrep` out as an unused
> dependency here.

The **desktop app** is a separate download from opencode.ai and bundles its own copy of the
same binary. Not sandboxed, same tools — `bash`, `read`, `write`, `edit`, `glob`, `grep`,
`patch`, `task`, `webfetch` — so it drives the stack exactly as the CLI does. The one
difference found: the bundled build has no `todowrite`, which changes how it tracks a long
job, not what it can run.

### The desktop app cannot see your tools until you fix PATH

This is the part that costs an afternoon. A GUI app is launched by launchd, not by your
shell, so it inherits:

```
PATH=/usr/bin:/bin:/usr/sbin:/sbin
```

Nothing else. It can reach the model over HTTP and happily answer questions, while being
unable to run `myai`, `generate-image`, `render-html` or even `ollama` — every one of which
lives in `~/.local/bin` or `/opt/homebrew/bin`. It does not fail loudly; it just behaves as
though the tools do not exist.

`install.sh` fixes this on macOS with the `com.myai.guipath` launch agent, which publishes a
full PATH into the GUI session at login. `launchctl setenv PATH …` does the same for the
current session but does not survive a reboot.

**Restart the app after installing it** — a running app keeps the PATH it started with.

### Pointing it at the local model

Neither form discovers Ollama on its own. `install.sh` writes this to
`~/.config/opencode/opencode.json` if you have none, and the app reads the same file:

```json
{
  "$schema": "https://opencode.ai/config.json",
  "provider": {
    "ollama": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "Ollama (local)",
      "options": { "baseURL": "http://127.0.0.1:11434/v1" },
      "models": {
        "qwen3.8:27b-mlx": {
          "name": "Qwen3.8 27B (local)",
          "tools": true,
          "limit": { "context": 40960, "output": 8192 }
        }
      }
    }
  },
  "model": "ollama/qwen3.8:27b-mlx",
  "instructions": ["~/.config/opencode/AGENTS.md", "AGENTS.md"]
}
```

The `limit.context` must match the window the model actually carries, or OpenCode will send
prompts the server truncates without telling either of you. `set-context` is what decides
that number — see [Context length](#context-length).

```bash
opencode                       # the TUI, in whatever directory you are in
opencode run "what does this repo do"    # one-shot, no TUI — this is what scripts use
opencode models                # confirm the local model is registered
```

The app is a window; the CLI is a pipe. `opencode run` composes into scripts and cron, which
is the practical reason to keep both.

### From another machine — model here, shell there

OpenCode on another host can use this machine's model while its tools — shell commands,
file edits — run on *that* host. Its bash tool executes wherever OpenCode runs; only the
model calls cross the network. So the whole job is making Ollama reachable there:

```bash
myai share add devbox dev@10.0.0.7     # reverse SSH tunnel, as a LaunchAgent / systemd unit
myai share test devbox                 # does the model answer on the far side?
myai share list
myai share remove devbox
```

On the other host, use the config above unchanged — `http://127.0.0.1:11434/v1` — because
the tunnel puts Ollama on *that* host's loopback.

The tunnel is dialled from this machine, which is the point of doing it this way round:

- **Nothing listens here.** Ollama keeps its loopback bind and Remote Login can stay off.
  Setting `OLLAMA_HOST=0.0.0.0` would reach the same goal by handing an unauthenticated
  model server — pull, delete, run — to everyone on the LAN.
- **Nothing listens there either**, beyond that host's `127.0.0.1`.
- **It needs a key with no passphrase prompt.** launchd and systemd run ssh with no agent
  and no terminal, so `add` checks `ssh -o BatchMode=yes` first rather than installing a
  service that fails in a restart loop. It also refuses when port 11434 there is taken.
- **It comes back on its own** — if the far side lets it. The service restarts ssh on exit
  and keepalives detect a dead link within ~45 s; killing the ssh process measured a 3 s
  recovery. Sleep is different: this machine vanishes without closing, and the far sshd
  keeps the dead session *and the forwarded port* until TCP gives up, hours later. Every
  reconnect meanwhile fails `remote port forwarding failed` (2,889 of them, one night). The
  fix is on the far host, once:

  ```bash
  printf 'ClientAliveInterval 15\nClientAliveCountMax 3\n' | sudo tee /etc/ssh/sshd_config.d/10-client-alive.conf
  sudo sshd -t && sudo systemctl reload ssh
  ```

  With it, a frozen client's port came free in 63 s and the tunnel was back at 64 s.
  `myai share add` and `test` check for this setting and print the fix when it is missing.

Expect it to be slower than local use, not because of the tunnel but because OpenCode's
system prompt is 3–6k tokens a turn; see [Context length](#context-length). Two more
things decide how it feels:

- **Ollama answers one request at a time** (`OLLAMA_NUM_PARALLEL=1`). A remote session and
  a local one queue behind each other — a one-line request measured a 160 s wait while
  another host's agent loop held the model. Run one agent at a time.
- **Give the remote config the `limit` block.** Without it OpenCode does not know the window
  is 40,960 tokens, so it lets the conversation grow instead of compacting it, and every
  turn gets longer to read and hotter to run.

OpenCode 2.x also starts a shared background server (`opencode serve --service`) on first
use, which keeps running after the TUI closes. `opencode service stop` ends it;
`opencode --standalone` and `opencode run --standalone` use a private server that exits
with the session instead. On a machine that only borrows the model, a shell function that
adds `--standalone` to the TUI and `run` keeps it from coming back.

### A suggested next step after every reply

`opencode/plugins/next-step/` is an OpenCode **2.x TUI plugin** (installed to
`~/.config/opencode/plugins/next-step/`). When a run finishes, it asks the session's own model
for one next message and shows it in muted text just above the prompt:

```
  › What do the common ls flags like -a, -l, and -t do?                 alt+n send
```

**alt+n** sends it (so do `/next` and the command palette); starting anything else clears it.

It is built only on the documented plugin API in the OpenCode source (`packages/plugin/src/tui`)
and follows two built-in plugins: `/btw` for the generation, `notifications` for the events.

- **It does not touch the conversation.** The suggestion comes from `session.generate`, the
  same one-shot call `/btw` uses: it reads the session's context and adds nothing to it.
  Measured: context tokens were identical before and after a suggestion.
- **Accepting sends; it cannot fill the box.** The 2.x TUI plugin API has no way to read or
  set the composer text. A key that sends must not be one pressed while typing, so it is
  alt+n, not Tab — unbound in OpenCode's defaults and not a text-editing key.
- **It always proposes something.** An opt-out ("reply NONE if nothing follows") was taken
  by the model even after a one-line answer, so the instructions ask for one every time.
- **Cost:** one extra request after each reply — ~15 s on this machine, and on a server
  that answers one request at a time it queues ahead of your next message.
- **Where it runs:** the OpenCode 2.x terminal UI, including on a remote machine using the
  host's model through `myai share`. Not the desktop app, which is not the TUI, and not
  OpenCode 1.x, whose plugin format differs.
- **Off:** `MYAI_NEXT_STEP=0`. **Diagnose:** `MYAI_NEXT_STEP_DEBUG=1` logs each decision to
  `~/.local/state/opencode/next-step.log`.

Open WebUI has the equivalent built in: follow-up generation shows the first suggested
follow-up as grey text in the empty message box, and Tab accepts it.

### AGENTS.md — what the agent knows before you say anything

`instructions` points at two files: a global one and a per-project one, stacked. The global
file is where behaviour lives — verify before asserting, quote a spec rather than recalling
it, produce a real image rather than describing one. `install.sh` seeds it from
`opencode/AGENTS.md.example`.

That example is deliberately generic. **Put your own role, stack and domain at the top of the
installed copy** — that part is what makes the agent useful, and it is also the part nobody
else can write for you.

> **The interface is not the model.** OpenCode's TUI, slash commands and permission prompts
> are close to what hosted agents offer. What it copies is the harness, not the reasoning: a
> 27B local model still invents clause numbers and still needs the evidence discipline in
> AGENTS.md. Expect the ergonomics, not the instruction-following.

---

## Security notes

- **Ollama, ComfyUI, Kokoro and the TTS router bind to loopback only.** Only Open WebUI is exposed, and it
  requires a login. Don't expose the others — none of them has authentication.
- **Register the admin account immediately** after first start. Until one exists, signup is
  open to anyone who can reach the port.
- **For access away from home, use a VPN** (Tailscale or similar) rather than port
  forwarding. A laptop's address changes; a tunnel doesn't, and nothing needs to be opened
  on your router.
- **Jupyter and mcpo bind to loopback and require their own tokens**, generated at install
  into `~/jupyter/.token` and `~/mcpo/.apikey` (mode `0600`). Neither is in this repo.
- **The terminal is read-only on purpose.** No shell, an allowlist of inspection
  commands, confined to `TERMINAL_ROOT`, and credential paths (`~/.ssh`, `*.pem`,
  `.token`, `.netrc`) refused outright. Widening `ALLOWED` in `terminal/server.py`
  turns it into a general shell — do that knowingly, not by accident.
- **Giving a model tools changes the threat model.** It can now write files and run code,
  and it acts on text it did not get from you — a web page it fetched, a document you
  uploaded. Treat anything it ingests as untrusted input. Keep the filesystem server scoped
  to a working directory, and don't point it at `$HOME`, your keys or a source tree you
  care about.

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

## Diagram source

Both images are rendered from HTML you can open and edit in a browser:

| Image | Source |
|---|---|
| the banner | [`docs/infographic.html`](docs/infographic.html) |
| the architecture page | [`docs/architecture.html`](docs/architecture.html) |

Re-render either with the `render-html` this repo installs:

```bash
render-html docs/architecture.html docs/architecture.png 1400
```

It renders tall and trims the uniform background afterwards, so you do not have to know the
content height in advance — passing a guessed `--window-size` to headless Chrome leaves a
third of the image empty or crops the bottom, and neither is obvious until you look.

---

## Licence

MIT for the scripts in this repo. The components it installs carry their own licences —
Ollama, Open WebUI, ComfyUI, Kokoro and the model weights each have separate terms.
**Qwen-Image-2.1 ships under the Qwen Research License — non-commercial use only.** That is
stricter than everything else here and stricter than the SDXL it replaced, so read it before
putting a generated image anywhere commercial.
