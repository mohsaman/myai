# Getting the most out of myai

The README covers installing and configuring the stack. This covers **using** it — what
it can do, how to ask, and where the sharp edges are.

Everything here runs on your machine. The only thing that ever leaves is a web search,
and only when a model decides it needs one — it will tell you when it does.

---

## The first ten minutes

```bash
myai start          # brings up all nine services, opens the browser
myai status         # what is running, and on which ports
```

Then try these, in this order. Each one demonstrates a different capability and takes
under a minute.

| Ask | What it shows |
|---|---|
| "How much disk is free, and what is using it?" *(switch on **Terminal**)* | it runs real commands and reads the output |
| "Plot the last 30 days of anything from this CSV" *(attach a file, switch on **Code Interpreter**)* | a real Python kernel, not a sandbox |
| Paste a screenshot: "what is wrong with this config?" | it reads images — same model, no switching |
| "Generate an image of a lighthouse at dusk" *(image icon)* | Qwen-Image-2.1 on the local GPU |
| "What changed in the latest Ollama release?" | it searches the web and says so |
| "Present that as an infographic" | a rendered HTML page, not ASCII art |

---

## Choosing a model

This matters more than any other setting. The models are not interchangeable.

| Entry | What it is |
|---|---|
| **Qwen3.8 27B** | the model. Chat, images, code, tool use — Apple Silicon build, ~17 tok/s |
| **Telecom Expert** | a *preset*: the same weights with a system prompt that greps the spec corpus |
| **Qwen3 Explorer** | a *preset*: same weights, prompted to take a position rather than survey |

Two models are installed but hidden, because you should never pick them by hand: a 3B
handles chat titling in the background, and an embedding model serves retrieval.

The thing worth knowing:

**Its context caps at 40k**, low for a model advertising 256k. The KV cache measures
98 KiB per token, and weights plus cache have to fit in 24 GB. That figure is measured,
not derived — the architecture implies 34 KiB, and trusting the derivation would set a
window needing 30 GB. For longer documents, split them rather than hoping.

**Turn thinking off for short prompts.** Asked to write one sentence greeting a colleague,
the model spent 33 seconds and 300 tokens reasoning and returned **nothing at all**. The
same prompt with `think: false` answered in 1.7 seconds and 10 tokens. That is not a tuning
preference — with thinking on, short requests can come back empty.

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

Pick **myai** (Qwen3.8 27B) and paste or attach. Screenshots, diagrams, tables, scanned
documents, error dialogs. It is the only model here that does vision *and* tool calling, so
you no longer have to switch model to read an image with an integration toggle on. Being a
Apple Silicon build, so faster than the generic one — around 17 tokens/second warm.

### Generate images

Click the **image icon** in the chat input. Qwen-Image-2.1 runs on the local GPU at
1024×1024, 25 steps. It handles text inside an image far better than the SDXL it replaced —
labels on a diagram come out legible — and supports 2048×2048 natively.

**Asking the chat model for a picture will not work, and that is not a fault.** It will offer
you SVG or say it cannot, because generating pixels is a diffusion model's job. The image
icon is the route; the model dropdown lists language models only.

From a shell, the same model is one command:

```bash
generate-image "an isometric diagram of a mobile core network" core.png
generate-image -s 2048 "a red bicycle against a whitewashed wall"
```

> Qwen-Image-2.1 is licensed for non-commercial use only. See the note in the README.

### Speak and listen, in any of 53 languages

The speaker icon on any reply reads it aloud. The microphone dictates, via faster-whisper.
Both local.

You do not pick a language. A router in front of the two speech engines reads the text,
works out what language it is, and sends it to whichever engine can say it — Kokoro for
the eight it does best, Piper for the other forty-five. Ask a question in Turkish and the
answer comes back spoken in Turkish, with nothing switched by hand.

The first reply in a new language pauses for a few seconds while its voice downloads
(about 60 MB). Every reply after that is local and immediate. To warm one up in advance:

```bash
curl -s localhost:8881/languages | python3 -m json.tool   # what is ready
curl -s -X POST localhost:8881/v1/audio/speech \
     -H 'Content-Type: application/json' \
     -d '{"input":"Merhaba, nasilsiniz?"}' -o /dev/null   # fetches Turkish
```

Detection is by language, not by alphabet, which is what makes it work in practice:
Persian, Arabic and Urdu share a script but need different voices, and French, German
and Turkish are all Latin. It reads a Persian sentence containing `5G` as Persian,
because it counts letters and ignores digits.

Two honest limits. Very short replies ("OK", "Done") default to English, because two
Latin letters are not enough to identify a language. And a reply that genuinely mixes
two languages gets read in whichever one dominates — there is no mid-sentence switching.

**Quality is not uniform across those 53 languages.** Kokoro's eight sound good. Piper's
forty-five range from good to merely intelligible, and Persian has a measured defect:
all five voices mangle **word-initial** ق and غ. قرمز comes out as گرمز, قطار loses its
first consonant entirely, غذا becomes هزا. The same letters at the end of a word are
fine — داغ and باغ both come back correctly — which is why some Persian sounds normal
and some sounds like invented words.

The router picks `fa_IR-ganji-medium`, which measured best of the five (12.3% word error
against 28.8% for the voice the catalogue would otherwise have chosen). It reduces the
problem; it does not remove it.

That was found by synthesising Persian and transcribing it back with Whisper, which is a
reasonable way to check any language you care about before trusting it:

```bash
# say something, then have a different model read it back to you
curl -s -X POST localhost:8881/v1/audio/speech -H 'Content-Type: application/json' \
     -d '{"input":"<a sentence you know>"}' -o /tmp/check.wav
```

### Search the web

Enabled by default on every model. The model decides when a question needs it; you do
not have to ask.

It will tell you when it goes online — what it searched for and the URL — and Open WebUI
shows citations under the answer independently.

### Look up a standard, correctly

This is the feature most worth understanding, because it fixes a failure you would
otherwise never catch.

Ask a model for a spec clause and it will produce a confident, plausible, wrong one.
Asked which EMM cause maps to `DIAMETER_ERROR_USER_UNKNOWN`, a local model answered
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

**Verify anything it expands.** Retrieval fixes invented clause numbers. It does not fix
a model reading a table badly, and acronym expansion is still unreliable.

### Make an infographic

Ask for one and you get a rendered HTML page in Open WebUI's Artifacts panel — not ASCII
art.

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

Expect to iterate on layout. A local model of this size gets the styling right and the structure
approximately right; telling it to restructure works.

### Remember things across chats

Open WebUI's memory is on. Tell it something worth keeping — "I work in Rust, prefer
explicit error handling, and dislike preamble" — and it persists.

---

## Working outside the browser

Open WebUI is one way in. **OpenCode** is the other: the same model as an agent that reads
your files, runs commands and iterates — in a terminal, or in a desktop window.

```bash
opencode                                  # a session in the current directory
opencode run "summarise what changed today"
```

It is the right tool when the answer depends on your machine rather than on the model's
knowledge: what is in these files, what is this service doing, what broke. It can run the
stack's own commands — `myai status`, `myai doctor`, `generate-image`, `fetch-specs` — so
"is the stack healthy?" is a question it answers by looking, not by guessing.

**If it claims it cannot run something, PATH is the usual reason** — a desktop app launched
from the Dock starts with four directories and none of them contain these tools. That is what
the `com.myai.guipath` launch agent fixes, and an app that was already open when it was
installed needs restarting before it notices.

**It is the same model, so it has the same failure modes.** A familiar interface does not
make a 27B local model careful: it will still produce a confident clause number it never
checked. The instructions in `AGENTS.md` push against that — verify before asserting, grep
the spec before citing it — but the habit of asking "where did that come from?" matters more
than the file does.

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
parameters per token. It is a capable assistant that never tires; it is not a frontier
hosted model. For work that needs many constraints held at once, you will feel it.

**Be trusted on specifics it has not checked.** It will invent a filename, a config key,
a version number or a spec clause to sound authoritative. The verification tooling
exists precisely because of this. Treat every unchecked specific as unverified.

**Reliably expand acronyms in a domain.** Told explicitly not to, it still did — and got
it wrong a third of the time.

**Hold a long context usefully.** The window is 32k, set by what the KV cache allows
rather than what the model advertises. Quality degrades well before that, so a fresh chat
beats a long one, and a long document wants splitting rather than pasting.

**Ingest documents into knowledge collections.** Open WebUI's RAG pipeline extracts zero
characters in this build. Use the spec corpus and file attachments instead.

**Speak every language equally well.** It will *speak* 53, but see the note above: quality
falls off outside the eight Kokoro handles, and Persian has a measured defect on
word-initial ق and غ. Test a language before you rely on it — the method is three commands
and it takes a couple of minutes.

---

## When something looks wrong

| Symptom | Likely cause |
|---|---|
| Replies suddenly very slow | memory pressure — `sysctl vm.swapusage`; two models resident at once |
| Empty reply from a thinking model | token budget consumed by reasoning; not a crash |
| "I cannot access X" | the capability exists but the toggle is off — check **+** menu |
| Microphone permission denied | you are on an http LAN address; browsers only allow the mic on a secure origin — use `127.0.0.1` or set up HTTPS |
| "I have no network access" | almost always false — see below |
| It refuses, and rephrasing keeps failing | the refusal is in the context now; start a new chat, do not rewrite the prompt |
| It asks for a password you should not need | it did not try; key auth often already works |
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

### When it says it cannot do something

This deserves its own section, because the stated reason is frequently not the real
one, and believing it sends you debugging the wrong layer.

Asked to SSH into a router on the local network, a local model answered *"I cannot access
external network devices — I have no network access."* Every part of that was false: it
had a shell, the machine had a network, and the address was the machine's own default
gateway. The actual trigger was **the password in the prompt**. The capability claim was
invented afterwards to justify a refusal it had already decided on.

Three distinct failures look identical from the chat window:

| What you see | What it is | What to do |
|---|---|---|
| "I have no network access" | a credential in your prompt tripped a refusal | set up key auth, keep secrets out of prompts |
| rephrasing keeps failing | the refusal is in the context and it now defends it | **start a new chat** — do not rewrite the prompt |
| "please provide the password" | it did not try; key auth may already work | tell it to run the command and report the error |

Fixing one reveals the next wearing similar clothes, which is why it can take several
rounds and feel like nothing changed.

**Keep credentials out of prompts entirely.** Set up SSH keys, then phrase the task with
no secrets in it. It avoids the refusal, and it keeps passwords out of your shell history
and the model's context. The `AGENTS.md` shipped here tells the agent to try before
claiming it cannot, to never use `sshpass -p`, and to re-evaluate rather than defend an
earlier refusal — but an instructions file is weaker than the model's training, so the
habit matters more than the instruction.

**Verify anything it reports from a device.** Summaries mix what the config says with
what the model inferred from comments. The facts are usually right; the interpretation
is where it drifts.
