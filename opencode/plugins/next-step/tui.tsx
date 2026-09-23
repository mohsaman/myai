// next-step: after each reply, suggest the most useful next message.
//
// An OpenCode 2.x TUI plugin, built on the plugin API in the OpenCode source
// (packages/plugin/src/tui) and patterned on two built-in feature plugins:
// prompt/btw for the one-shot generation and system/notifications for the
// session lifecycle events.
//
// When a root session's run succeeds, it asks the session's own model for one
// short next message with session.generate -- the call /btw uses, which answers
// from the session's context WITHOUT adding anything to the conversation. The
// suggestion is drawn in muted text in the session.composer.top slot, just above
// the input. alt+n (or /next, or the command palette) sends it as your message.
// Anything that starts a new run in the session clears it.
//
// Why send rather than fill the input: the 2.x TUI plugin API has no way to read
// or set the composer text, so "accept" can only mean "send". A key that sends
// must not be one pressed while typing, hence alt+n rather than Tab.
//
// Disable: MYAI_NEXT_STEP=0 in the environment the TUI starts from.
// Diagnose: MYAI_NEXT_STEP_DEBUG=1 writes each decision to
// ~/.local/state/opencode/next-step.log.

import { Plugin } from "@opencode/plugin/tui"
import { createSignal, Show } from "solid-js"
import { appendFileSync, mkdirSync } from "node:fs"
import { homedir } from "node:os"
import path from "node:path"

const DEBUG = process.env.MYAI_NEXT_STEP_DEBUG === "1"
const DEBUG_FILE = path.join(homedir(), ".local", "state", "opencode", "next-step.log")
function debug(message: string) {
  if (!DEBUG) return
  try {
    mkdirSync(path.dirname(DEBUG_FILE), { recursive: true })
    appendFileSync(DEBUG_FILE, `${new Date().toISOString()} ${message}\n`)
  } catch {}
}

const KEY = "alt+n"
const MAX_CHARS = 160

// session.generate exposes the session's tools but runs no tool loop (see
// prompt/btw), so the instructions rule tool calls out.
// Always propose one: an opt-out like "reply NONE if nothing follows" is taken
// by a small model even when a useful follow-up exists (measured: a one-line
// factual answer came back NONE). NONE is still honoured if it appears.
const INSTRUCTIONS = [
  "Propose the user's single most useful NEXT message in this conversation --",
  "a follow-up question, a check, or the obvious next task. Always propose one.",
  "Reply with ONLY that message, exactly as the user would type it: specific to",
  "what just happened, under 15 words. No quotes, no preamble, no explanation.",
  "Do not call any tools and do not take any actions.",
].join(" ")

function clean(raw: string | undefined) {
  const line = (raw ?? "")
    .replace(/<think>[\s\S]*?<\/think>/g, "")
    .split("\n")
    .map((item) => item.trim())
    .find(Boolean)
    ?.replace(/^["'`“”]+|["'`“”]+$/g, "")
    .trim()
  if (!line || /^none\.?$/i.test(line) || line.length > MAX_CHARS) return undefined
  return line
}

export default Plugin.define({
  id: "myai.next-step",
  setup(context) {
    if (process.env.MYAI_NEXT_STEP === "0") return

    const [suggestion, setSuggestion] = createSignal<{ sessionID: string; text: string }>()
    // Bumped by every run start and every new request; a generation that
    // returns under a stale epoch is dropped, never shown late.
    const epoch = new Map<string, number>()

    const bump = (sessionID: string) => {
      const next = (epoch.get(sessionID) ?? 0) + 1
      epoch.set(sessionID, next)
      if (suggestion()?.sessionID === sessionID) setSuggestion(undefined)
      return next
    }

    const suggest = async (sessionID: string) => {
      const session = context.data.session.get(sessionID)
      if (!session) return debug(`${sessionID} skipped: session not in client data`)
      if (session.parentID !== undefined) return debug(`${sessionID} skipped: subagent`)
      const mine = bump(sessionID)
      const started = Date.now()
      const result = await context.client.session
        .generate({ sessionID, prompt: INSTRUCTIONS })
        .catch((cause: unknown) => {
          debug(`${sessionID} generate failed: ${String(cause)}`)
          return undefined
        })
      if (!result) return
      if (epoch.get(sessionID) !== mine) return debug(`${sessionID} dropped: superseded after ${Date.now() - started} ms`)
      const text = clean(result.text)
      debug(`${sessionID} generated in ${Date.now() - started} ms: ${JSON.stringify(result.text)} -> ${JSON.stringify(text)}`)
      if (text) setSuggestion({ sessionID, text })
    }

    const send = async () => {
      const current = suggestion()
      if (!current) return
      const route = context.ui.router.current()
      if (route.type !== "session" || route.sessionID !== current.sessionID) return
      setSuggestion(undefined)
      await context.client.session
        .prompt({ sessionID: current.sessionID, text: current.text })
        .catch((cause: unknown) =>
          context.ui.toast.show({ message: `next-step: ${String(cause)}`, variant: "error" }),
        )
    }

    const dispose = [
      context.data.on("session.execution.started", (event) => {
        debug(`${event.data.sessionID} execution started`)
        bump(event.data.sessionID)
      }),
      context.data.on("session.execution.succeeded", (event) => {
        debug(`${event.data.sessionID} execution succeeded`)
        void suggest(event.data.sessionID)
      }),
      context.ui.slot({
        prepend: "session.composer.top",
        render: (input) => (
          <Show when={suggestion()?.sessionID === input.sessionID}>
            <box flexDirection="row" gap={2} paddingLeft={2} paddingRight={2}>
              <text fg={context.theme.text.muted} wrapMode="word" flexGrow={1}>
                {"› " + (suggestion()?.text ?? "")}
              </text>
              <text fg={context.theme.text.muted} flexShrink={0}>
                {KEY + " send"}
              </text>
            </box>
          </Show>
        ),
      }),
      // A keymap layer is owned by the component that creates it, so it lives
      // in an app-level slot that renders nothing (as prompt/btw does).
      context.ui.slot({
        append: "app",
        render() {
          context.keymap.layer(() => ({
            commands: [
              {
                id: "myai.next-step.send",
                title: "Send suggested next step",
                description: "Send the suggested next message shown above the prompt",
                group: "Session",
                bind: KEY,
                palette: true,
                slash: { name: "next" },
                enabled: () => suggestion() !== undefined,
                run: send,
              },
            ],
          }))
          return null
        },
      }),
    ]

    return () => dispose.reverse().forEach((cleanup) => cleanup())
  },
})
