# Getting the most out of myai

The README covers installing and configuring the stack. This covers **using** it — what
it can do, how to ask, and where the sharp edges are.

Everything here runs on your machine. The only thing that ever leaves is a web search,
and only when a model decides it needs one — it will tell you when it does.

---

## The first ten minutes

```bash
myai start          # brings up all seven services, opens the browser
myai status         # what is running, and on which ports
```

Then try these, in this order. Each one demonstrates a different capability and takes
under a minute.

| Ask | What it shows |
|---|---|
| "How much disk is free, and what is using it?" *(switch on **Terminal**)* | it runs real commands and reads the output |
| "Plot the last 30 days of anything from this CSV" *(attach a file, switch on **Code Interpreter**)* | a real Python kernel, not a sandbox |
| Paste a screenshot: "what is wrong with this config?" *(pick **Qwen2.5-VL**)* | it reads images |
| "Generate an image of a lighthouse at dusk" *(image icon)* | SDXL on the local GPU |
| "What changed in the latest Ollama release?" | it searches the web and says so |
| "Present that as an infographic" | a rendered HTML page, not ASCII art |

---

## Choosing a model

This matters more than any other setting. The models are not interchangeable.

| Model | Use it for | Avoid it for |
|---|---|---|
| **Qwen3 30B** | general chat, reasoning, tool use — the default | nothing much; it is the all-rounder |
| **Qwen3 Explorer** | when you want a position, not a survey — it challenges the question | quick factual lookups; it is slower and blunter |
| **GPT-OSS 20B** | long-context reading, 128k window | agentic loops — it invents tools that do not exist |
| **Qwen2.5 Coder 14B** | writing and reviewing code | general conversation |
| **Qwen2.5-VL 7B** | anything with an image in it | text-only work; it is small |
| **Qwen2.5 3B** | instant factual answers | anything needing thought |
| **Telecom Expert** | standards questions — it greps the spec corpus | general use |
| **Aya Expanse 32B** | Persian, and other non-English output | domain terminology; verify what it translates |

Two findings worth carrying:

**GPT-OSS is the better talker and the worse agent.** It reasons well in conversation
and repeatedly failed at multi-turn tool use, inventing `container.exec`, `browser.run`
and `cat` as tools. Use it for reading and thinking, not for doing.

**Aya composes in Persian; Qwen3 translates into it.** Asked to write a message to a
colleague, Qwen3 produced correct but robotic text while Aya used natural idiom —
and 25× fewer tokens, because it has no reasoning block.

---

## What it can do

### Ask about your machine

Switch on **Terminal** → *This Mac*. Then ask for the answer, not the command:

```
Which volume is fullest?
Is ComfyUI running, and how long has it been up?
What did the last 50 lines of the mcpo log say?
Summarise the git status of ~/projects/thing.
```

**Read-only by construction.** No shell, so pipes and redirects are rejected rather than
interpreted; an allowlist of inspection tools, so `rm`, `kill`, `sudo` and `curl` cannot
run; confined to `TERMINAL_ROOT`; and credential paths (`~/.ssh`, `*.pem`, `.token`)
refused outright.

It also reaches **remote machines** you have configured:

```bash
myai terminal add nas admin@192.168.1.10
myai terminal test nas          # prove it works as you, before the model tries
```

```
Is the NAS running out of disk?
Compare uptime across nas and edge.
```

The model names a *host* from your list, never an address — nothing it says produces a
connection to a machine you did not configure.

### Write and run code

Switch on **Code Interpreter**. This is a real Jupyter kernel with filesystem, network
and pip — not the browser sandbox Open WebUI ships with.

```
Parse ~/Downloads/usage.csv and plot the weekly totals.
Work out how much KV cache a 48-layer model needs at 128k context.
Convert every .png in ~/Desktop/shots into a single PDF.
```

numpy, pandas, matplotlib, requests and beautifulsoup4 are installed. Unlike the
terminal, this is **not** restricted — Python there can do anything your account can.

### Look at images

Pick **Qwen2.5-VL 7B** and paste or attach. Screenshots, diagrams, tables, scanned
documents, error dialogs. About 8 seconds per image.

### Generate images

Click the **image icon** in the chat input. SDXL runs on the local GPU at 1024×1024, 20
steps, roughly 45 seconds.

It is not in the model dropdown and cannot be — SDXL is a diffusion model in a separate
process from Ollama. The dropdown lists language models only.

### Speak and listen

The speaker icon on any reply reads it aloud through Kokoro — 72 voices, about a second
to start. The microphone dictates, via faster-whisper. Both local.

### Search the web

Enabled by default on every model. The model decides when a question needs it; you do
not have to ask.

It will tell you when it goes online — what it searched for and the URL — and Open WebUI
shows citations under the answer independently.

### Look up a standard, correctly

This is the feature most worth understanding, because it fixes a failure you would
otherwise never catch.

Ask a model for a spec clause and it will produce a confident, plausible, wrong one.
Asked which EMM cause maps to `DIAMETER_ERROR_USER_UNKNOWN`, a 30B model answered
*"#1, TS 24.301 section 9.9.2.1"*. Both halves were wrong.

So the stack keeps the actual documents:

```bash
fetch-specs 24.301 29.272 23.401     # 3GPP
fetch-specs RFC6733 RFC9260          # IETF
fetch-specs --have                   # what is local
```

They land in `~/specs` as markdown. With **Telecom Expert** and **Terminal** on, the
model greps them before answering and cites the line:

```
#2 (IMSI unknown in HSS) — 3GPP-24.301.txt:4205, clause 9.9.3.9
```

In **goose** it goes further: if the document is missing it fetches it itself, then
greps it.

**Verify anything it expands.** Retrieval fixes invented clause numbers. It does not fix
a model reading a table badly, and acronym expansion is still unreliable.

### Make an infographic

Ask for one and you get a rendered HTML page in Open WebUI's Artifacts panel — not ASCII
art. In goose you get an HTML file plus a PNG.

You can render any HTML yourself the same way:

```bash
render-html page.html              # -> page.png, correctly sized
render-html page.html out.png 1400 # explicit output and width
```

Chrome screenshots whatever window height you give it, so a hand-picked number leaves a
third of the image empty or crops the bottom. `render-html` renders tall and trims the
background afterwards — on a real example it went from 2800px with 40% dead space to
1544px with none.

The HTML can be interactive: hover states, sortable tables, collapsible sections, tabs.
A PNG throws that away, so say which you want. If it is unclear, the interactive version
is safer — it degrades to a screenshot; a screenshot does not upgrade.

Expect to iterate on layout. A 30B model gets the styling right and the structure
approximately right; telling it to restructure works.

### Remember things across chats

Open WebUI's memory is on. Tell it something worth keeping — "I work in Rust, prefer
explicit error handling, and dislike preamble" — and it persists.

In goose, the `memory` MCP extension does the same but ships disabled: with four
extensions loaded a 3B-active model starts calling tools that were never advertised.
Enable it on a larger model.

---

## Working from the terminal

`goose` is the same models as an agent in your shell. It reads files, runs commands,
checks its own output and iterates.

```bash
cd ~/some-project
goose                                    # interactive
goose run -t "summarise the last 5 commits"
goose session --name lab                 # resumable
```

It asks before anything with side effects. `GOOSE_MODE=auto` lets it act unattended —
reasonable in a scratch directory, less so in your home.

**There is no sandbox.** goose reads, writes and runs commands anywhere your account
can, regardless of where you start it.

Two things shape its behaviour, both worth editing:

| File | Effect |
|---|---|
| `~/.config/goose/.goosehints` | loaded into every session — how it works |
| `./.goosehints` | stacks on top, per project — what this project is |
| `~/.agents/skills/*/SKILL.md` | conditional expertise it loads when relevant |

A rule that must **always** hold belongs in the hints file. Skills only load when the
model decides they are relevant, and it does not always decide correctly.

---

## Getting better answers

**Pick the right model.** The single biggest lever. See the table above.

**Say when you want it verified.** "Check it on the machine" or "verify against the
spec" reliably changes behaviour, because the tools are there and the instruction fires.

**Ask for a position.** "Give me three approaches, ranked, including one you think is
wrong" or "what would have to be true for this to be a bad idea" produces far better
output than an open question.

**Critique in a second turn.** Small models are much better at finding flaws in text
than at avoiding them while generating. "Now argue against that" is cheap and effective.

**Name the skill** if you are relying on one. Five words removes the uncertainty about
whether it loaded.

**Watch the context.** `myai stats` shows what each request cost. Long conversations get
slower — generation rate falls as the window fills, because every token attends over
everything before it. Start a fresh chat rather than carrying 20k of history.

---

## What it cannot do

Worth knowing so you do not waste time.

**Match a frontier model on long multi-step reasoning.** Qwen3 activates 3 billion
parameters per token. It is a capable assistant that never tires; it is not GPT-5 or
Claude. For work that needs many constraints held at once, you will feel it.

**Be trusted on specifics it has not checked.** It will invent a filename, a config key,
a version number or a spec clause to sound authoritative. The verification tooling
exists precisely because of this. Treat every unchecked specific as unverified.

**Reliably expand acronyms in a domain.** Told explicitly not to, it still did — and got
it wrong a third of the time.

**Hold a long context usefully.** The window is 32k (64k+ on some models), but quality
degrades well before the limit.

**Ingest documents into knowledge collections.** Open WebUI's RAG pipeline extracts zero
characters in this build. Use the spec corpus and file attachments instead.

---

## When something looks wrong

| Symptom | Likely cause |
|---|---|
| Replies suddenly very slow | memory pressure — `sysctl vm.swapusage`; two models resident at once |
| Empty reply from a thinking model | token budget consumed by reasoning; not a crash |
| "I cannot access X" | the capability exists but the toggle is off — check **+** menu |
| A tool that does not exist was called | the model invented it; switch to Qwen3 |
| Web page fetched but nothing useful | JavaScript-rendered; find a static URL |
| HTTP 200 but no content | check the body, not the status code |

```bash
myai status                 # what is running
myai stats                  # per-request timings
myai logs                   # Open WebUI
myai logs terminal          # the terminal server
ollama ps                   # what is loaded, and whether it is on the GPU
```

The rule that catches most of it: **check what came back, not what the status code
said.** A 200 can be a bot-block page, `exit 0` can hide a silent failure, and a model
saying it lacks access is often wrong.
