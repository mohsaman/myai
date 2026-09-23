// next-step: after each reply, put the most useful next message in the prompt.
//
// When a top-level session goes idle, this asks the session's own model for one
// short next message, and places it in the input box. Enter sends it; clear the
// box to ignore it. Nothing leaves the machine that the session was not already
// sending to the same model.
//
// It is prefilled text, not grey "ghost" text: a server plugin can only append
// to the prompt (tui.appendPrompt), and it cannot see whether the box already
// holds something. Three guards keep it from landing on top of real work:
//   - a newer user message or reply in the session cancels a pending suggestion
//     (and aborts its request, which frees the model);
//   - a suggestion older than MAX_AGE_MS is dropped rather than shown late;
//   - subagent sessions (those with a parentID) are never suggested for.
// The one case left: typing into the box in the seconds before a suggestion
// arrives, which appends to what was typed. Keep the model fast or disable it.
//
// Disable: MYAI_NEXT_STEP=0 in the environment opencode starts from.
//
// Only providers with a baseURL (OpenAI-compatible: Ollama, llama.cpp, vLLM,
// LM Studio, a tunnel to any of them) are used; hosted providers are skipped,
// because re-sending context to a paid API for a hint is not a silent default.

const MAX_TOKENS = 48
const REQUEST_TIMEOUT_MS = 60_000
const MAX_AGE_MS = 90_000
const CONTEXT_CHARS = 1_500

const SYSTEM = [
  "You suggest the user's single most useful NEXT message to a coding agent,",
  "given the last exchange. Reply with ONLY that message, as the user would type it:",
  "imperative, specific to what just happened, under 15 words. No quotes, no preamble,",
  "no explanation. If nothing obvious follows, reply with exactly: NONE",
].join(" ")

export const NextStep = async ({ client }) => {
  if (process.env.MYAI_NEXT_STEP === "0") return {}

  // per session: a counter bumped by any newer activity, and the in-flight request
  const epoch = new Map()
  const inflight = new Map()

  const log = (level, message) =>
    client.app.log({ body: { service: "next-step", level, message } }).catch(() => {})

  const bump = (sessionID) => {
    epoch.set(sessionID, (epoch.get(sessionID) ?? 0) + 1)
    inflight.get(sessionID)?.abort()
    inflight.delete(sessionID)
  }

  const textOf = (entry) =>
    (entry?.parts ?? [])
      .filter((p) => p.type === "text" && !p.synthetic && !p.ignored && p.text)
      .map((p) => p.text)
      .join("\n")
      .trim()

  const clip = (s) => (s.length > CONTEXT_CHARS ? "…" + s.slice(-CONTEXT_CHARS) : s)

  async function suggest(sessionID) {
    const mine = (epoch.get(sessionID) ?? 0) + 1
    epoch.set(sessionID, mine)
    const started = Date.now()

    const session = (await client.session.get({ path: { id: sessionID } })).data
    if (!session || session.parentID) return

    const entries = (await client.session.messages({ path: { id: sessionID }, query: { limit: 8 } })).data ?? []
    const lastAssistant = [...entries].reverse().find((e) => e.info?.role === "assistant")
    const lastUser = [...entries].reverse().find((e) => e.info?.role === "user")
    if (!lastAssistant || !lastUser || lastAssistant.info.error) return
    const reply = textOf(lastAssistant)
    const asked = textOf(lastUser)
    if (!reply || !asked) return

    const { providerID, modelID } = lastAssistant.info
    const config = (await client.config.get()).data ?? {}
    const options = config.provider?.[providerID]?.options ?? {}
    const baseURL = options.baseURL
    if (!baseURL) return // hosted provider: see header

    const controller = new AbortController()
    inflight.set(sessionID, controller)
    const timer = setTimeout(() => controller.abort(), REQUEST_TIMEOUT_MS)
    let text
    try {
      const res = await fetch(baseURL.replace(/\/+$/, "") + "/chat/completions", {
        method: "POST",
        signal: controller.signal,
        headers: {
          "content-type": "application/json",
          ...(options.apiKey ? { authorization: `Bearer ${options.apiKey}` } : {}),
        },
        body: JSON.stringify({
          model: modelID,
          max_tokens: MAX_TOKENS,
          temperature: 0.3,
          // a hint is not worth a reasoning pass; servers that do not know the
          // field ignore it
          reasoning_effort: "none",
          messages: [
            { role: "system", content: SYSTEM },
            { role: "user", content: `Last user message:\n${clip(asked)}\n\nLast agent reply:\n${clip(reply)}` },
          ],
        }),
      })
      if (!res.ok) return log("warn", `model returned HTTP ${res.status}`)
      text = (await res.json())?.choices?.[0]?.message?.content ?? ""
    } catch (e) {
      if (e?.name !== "AbortError") log("warn", `suggestion failed: ${e?.message ?? e}`)
      return
    } finally {
      clearTimeout(timer)
      if (inflight.get(sessionID) === controller) inflight.delete(sessionID)
    }

    // superseded, or too late to be useful
    if (epoch.get(sessionID) !== mine || Date.now() - started > MAX_AGE_MS) return

    const line = text
      .replace(/<think>[\s\S]*?<\/think>/g, "")
      .split("\n")
      .map((l) => l.trim())
      .find(Boolean)
      ?.replace(/^["'`“”]+|["'`“”]+$/g, "")
      .trim()
    if (!line || /^none\.?$/i.test(line) || line.length > 200) return

    await client.tui.appendPrompt({ body: { text: line } })
    log("info", `suggested after ${Date.now() - started} ms`)
  }

  return {
    event: async ({ event }) => {
      const sid = event?.properties?.sessionID ?? event?.properties?.info?.sessionID
      if (!sid) return
      if (event.type === "session.idle") {
        suggest(sid).catch((e) => log("warn", `next-step: ${e?.message ?? e}`))
      } else if (event.type === "message.updated" && event.properties.info?.role === "user") {
        bump(sid) // the user moved on: drop anything pending for this session
      }
    },
  }
}
