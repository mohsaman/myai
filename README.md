# myai — a local AI stack for macOS and Linux

![The stack at a glance](docs/infographic.png)


A complete, self-hosted AI setup that runs on a single machine. Nothing is sent to a
provider. What it can do:

- **Chat and reasoning** — a 30B mixture-of-experts model at conversational speed
- **Work from the terminal** — `goose`, an agent in your shell driven by the same local models
- **Agentic tool use** — the model decides when to read files, fetch a URL or recall a fact, and chains the calls itself
- **Write and run code** — a real Python kernel with filesystem, shell and network access, not a browser sandbox
- **Inspect machines** — a read-only terminal for this computer and any SSH hosts you add: allowlisted commands, no shell, credential paths blocked
- **Read images** — screenshots, diagrams, tables and scanned documents
- **Generate images** — SDXL on the local GPU
- **Speak and listen** — neural text-to-speech in 72 voices, plus dictation
- **Search the web** — with citations, only when you ask for it
- **Remember** — a persistent knowledge graph that carries across conversations
- **64k context** — long documents and long conversations stay in memory

Runs on **macOS** (launchd, Metal) and **Linux** (systemd, CUDA) — same commands on both.

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
| **Jupyter** | The code interpreter's kernel — real Python, filesystem and network |
| **mcpo** | Bridges MCP tool servers into Open WebUI as callable tools |
| **terminal** | Read-only shell the model can query, locally and over SSH |

Suggested models — swap freely, these are what the defaults assume:

| Model | Size | Role | Measured (Apple M5, 32 GB) |
|---|---|---|---|
| `qwen3:30b-a3b` | 18 GB | Chat, reasoning, web search | 50.9 tok/s |
| `gpt-oss:20b` | 13 GB | Agentic work — native tool calling | 28.8 tok/s |
| `qwen2.5-coder:14b` | 9 GB | Code | 14.1 tok/s |
| `qwen2.5vl:7b` | 6 GB | Vision (reads images) | 7.9 s/image |
| `qwen2.5:3b` | 1.9 GB | Background tasks — titles, tags | — |
| `nomic-embed-text` | 274 MB | Embeddings for document retrieval | — |
| SDXL 1.0 | 6.5 GB | Image generation | 42 s/image |

---

## Requirements

### macOS

- **Apple Silicon Mac.** Tested on M5; any M-series works.
- **32 GB unified memory recommended.** 16 GB works if you drop the 30B model and use a 14B or smaller.
- **~40 GB free disk** for all models above.
- **Homebrew.** <https://brew.sh>

> A fanless Mac (Air) throttles under sustained image generation. Chat is unaffected.

### Linux

- **NVIDIA GPU with CUDA** for usable image generation and faster inference. CPU-only works
  for chat but SDXL becomes impractical.
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

That copies `myai` to `~/.local/bin`, generates the three launch agents from the templates
with your home directory substituted, and loads them. Make sure `~/.local/bin` is on your PATH.

### 7. Configure Open WebUI

```bash
myai start                     # register an admin account in the browser first
./scripts/configure.sh         # then apply the settings below
```

Or set them by hand in the UI — the script just automates what's described in
[Configuration](#configuration).

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
ollama pull qwen3:30b-a3b
ollama pull qwen2.5-coder:14b
ollama pull qwen2.5vl:7b
ollama pull qwen2.5:3b
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

### 3. ComfyUI and SDXL

```bash
git clone https://github.com/comfyanonymous/ComfyUI.git ~/ComfyUI
cd ~/ComfyUI && git checkout v0.36.0
mkdir -p logs models/checkpoints

uv venv --python 3.12 venv
# CUDA build — check https://pytorch.org for the index matching your driver
VIRTUAL_ENV="$HOME/ComfyUI/venv" uv pip install torch torchvision torchaudio \
  --index-url https://download.pytorch.org/whl/cu124
VIRTUAL_ENV="$HOME/ComfyUI/venv" uv pip install -r requirements.txt

curl -L -o models/checkpoints/sd_xl_base_1.0.safetensors \
  "https://huggingface.co/stabilityai/stable-diffusion-xl-base-1.0/resolve/main/sd_xl_base_1.0.safetensors"
```

Verify CUDA is visible — must print `True`:

```bash
~/ComfyUI/venv/bin/python -c "import torch; print(torch.cuda.is_available())"
```

> On macOS the equivalent check is `torch.backends.mps.is_available()`. The service file
> passes `--highvram` on both platforms.

### 4. Kokoro (text-to-speech)

```bash
sudo apt install espeak-ng          # or: dnf install espeak-ng / pacman -S espeak-ng

git clone https://github.com/remsky/Kokoro-FastAPI.git ~/kokoro
cd ~/kokoro && git checkout v0.9.0 && mkdir -p logs

uv venv --python 3.12 venv
VIRTUAL_ENV="$HOME/kokoro/venv" uv pip install -e .
./venv/bin/python docker/scripts/download_model.py --output api/src/models/v1_0
```

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

### Task model — the most important one

Admin → Settings → Interface → **Task Model** → `qwen2.5:3b`

Open WebUI generates chat titles, tags and follow-up suggestions using your *selected chat
model* by default. That means every message silently fires extra inferences on the 18 GB
model. On a 32 GB machine this forces everything else into swap.

*Measured impact: image generation went from 251s to 84s after this change alone.*

### Model unload timeout

Models sit in RAM for **5 minutes** after use by default. On a memory-constrained machine
that is most of your RAM, held for nothing.

**macOS** — `myai start` sets this for you:
```bash
launchctl setenv OLLAMA_KEEP_ALIVE 60s
brew services restart ollama
```

> Don't put it in Homebrew's plist — `brew services` regenerates that file from its formula
> on every start and silently drops hand-added keys.

**Linux** — already set in `myai-ollama.service` as `Environment="OLLAMA_KEEP_ALIVE=60s"`.
Change it there and `systemctl --user daemon-reload`.

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
| `fetch` | 1 | Retrieve a URL and read the page |
| `memory` | 9 | Store and recall facts in a knowledge graph that survives between chats |
| `time` | 2 | Current time, timezone conversion |

Edit `~/mcpo/config.json` to add more. Anything in the MCP ecosystem works — git,
databases, ticketing systems, your own scripts.

> The filesystem server is deliberately scoped to a single directory. Widening it to
> `$HOME` gives any prompt — including text pulled in by a web search — the ability to
> read every file you own. Scope it narrowly and on purpose.

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
sets it explicitly in the service definition:

```
OLLAMA_CONTEXT_LENGTH=65536
```

Bigger is not automatically better — the KV cache has to fit in GPU memory alongside
the weights, or inference silently spills to the CPU and slows to a crawl. Work out
your own ceiling before raising it:

```
KV bytes/token ≈ 2 × layers × kv_heads × head_dim     (1 byte/element at q8_0)
```

For a 30B MoE with 48 layers, 4 KV heads and head_dim 128, that is 48 KiB per token —
so 64k costs 3 GB of cache on top of ~20 GB of weights. On a 32 GB Mac the GPU limit
is roughly 24 GB, which 64k fits and 128k does not. Check with `ollama ps`: the
`PROCESSOR` column must read `100% GPU`.

---

## Using the tools

Everything below is off by default in a new chat. Open the **+** menu in the message
box and switch on what you need — nothing attaches automatically, and a model with no
tools will happily invent output rather than admit it cannot act.

Use **GPT-OSS 20B** for anything involving tools. It is the model configured for native
function calling, so it chooses tools itself instead of waiting to be told.

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

### Remote machines over SSH

The terminal reaches other machines too — a NAS, a lab box, a server — using the same
allowlist. Add targets from the command line:

```bash
myai terminal add nas  admin@192.168.20.10
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

## goose — the same stack from your terminal

Open WebUI is a browser. `goose` is an agent in your shell: it reads files, runs
commands, checks its own output and iterates, driven by the local model. Nothing
leaves the machine.

```bash
brew install block-goose-cli        # macOS
# Linux: curl -fsSL https://github.com/block/goose/releases/download/stable/download_cli.sh | bash
./install.sh                        # writes ~/.config/goose/config.yaml
```

```bash
cd ~/some-project
goose                               # interactive session in this directory
goose run -t "summarise the last 5 commits"     # one shot
goose session --name lab            # a session you can return to
goose session --resume              # pick the last one up
```

It asks before anything with side effects. `GOOSE_MODE=auto goose` lets it act
unattended; `chat` turns tools off entirely.

### Why it is worth having alongside the web UI

| | Open WebUI | goose |
|---|---|---|
| Where | browser | your terminal, in the project directory |
| Files | via MCP, scoped to `~/ai-workspace` | wherever you run it |
| Shell | read-only, allowlisted | full, with confirmation |
| Loop | answers, then stops | runs, reads the result, tries again |

The terminal server in this repo is the safe surface the *model* is given inside
the browser. goose is the one *you* drive, so it is allowed to be sharper.

### Model choice matters more here than in chat

Agentic work needs well-formed tool calls, turn after turn. Measured on this stack,
asking each model to find the CPU core count:

| Model | Result |
|---|---|
| `qwen3:30b-a3b` | ran `sysctl -n hw.ncpu`, answered correctly, first try |
| `gpt-oss:20b` | emitted `raw='{"}'` — malformed tool call — and assumed Linux, reading `/proc/cpuinfo` on a Mac |

The config ships with `gpt-oss:20b` as the stack's agentic default, but switch if it
misbehaves:

```bash
sed -i '' 's/^GOOSE_MODEL:.*/GOOSE_MODEL: qwen3:30b-a3b/' ~/.config/goose/config.yaml
# or per run:
GOOSE_MODEL=qwen3:30b-a3b goose
```

Honest expectation: a 3B-active model is a capable assistant for "run this, read that,
summarise", and will struggle on long tasks that need many constraints held at once.
`GOOSE_MAX_TURNS: 30` is set so a stuck loop stops rather than grinding.

### Extensions

goose speaks MCP over stdio, so it uses the same servers as the browser stack directly —
`mcpo` is only the HTTP bridge Open WebUI needs.

| Extension | What it adds |
|---|---|
| `developer` | shell, file editing, search — goose's built-in |
| `filesystem` | MCP filesystem, scoped to `~/ai-workspace` |
| `fetch` | retrieve a URL |
| `memory` | knowledge graph — **shipped disabled** |

`memory` is off because with four extensions loaded, a 3B-active model began calling
tools that had not been advertised and returned empty turns. Enable it in
`~/.config/goose/config.yaml` once you are on something larger.

---

## Security notes

- **Ollama, ComfyUI and Kokoro bind to loopback only.** Only Open WebUI is exposed, and it
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

The image above is rendered from [`docs/infographic.html`](docs/infographic.html).
Open it in a browser to view or edit, then re-render with:

```bash
chrome --headless --disable-gpu --hide-scrollbars --force-device-scale-factor=2 \\
  --window-size=1200,1520 --screenshot=docs/infographic.png docs/infographic.html
```

---

## Licence

MIT for the scripts in this repo. The components it installs carry their own licences —
Ollama, Open WebUI, ComfyUI, Kokoro and the model weights each have separate terms. SDXL
ships under CreativeML Open RAIL++-M, which has use restrictions worth reading.
