---
name: example-project
description: >
  A template for a per-project skill. Copy this directory, rename it, and replace the
  contents with facts about your own project. The description is what the agent
  matches on, so write it as the words someone would actually use when the skill
  should fire — the project name, the directory, the tools involved — not an abstract
  summary. Delete this skill once you have made your own.
---

# Project skill template

A skill is how you stop re-explaining your project at the start of every session.
Put here what an agent could not work out on its own, and nothing it could.

Copy the directory, rename it, and rewrite the sections below.

## Worth including

**Layout that is not obvious from the tree.** Which crate or package owns what, and
which one to change for a given kind of task.

**The commands that matter.** The exact build, test and lint invocations, including
the flags that are easy to get wrong. An agent that has to guess will guess badly.

```bash
cargo check --workspace          # or whatever is true here
npm run test -- --run
```

**Conventions you actually enforce.** Error handling, logging, how failure paths are
expected to be covered, comment style. Say it once here rather than correcting it
every session.

**Traps that have already cost time.** This is the highest-value section, because it
is the part no amount of reading the code reveals. Examples of the shape:

- A path that does not expand the way you expect when passed to a tool.
- A dependency whose feature flags conflict, and which combination resolves it.
- A file that looks generated but is hand-maintained, or the reverse.
- A test that fails for environmental reasons and is not your change.

## Worth leaving out

- Anything the agent can read from the code, the README or the git history.
- Secrets, hostnames, internal addresses, customer names. A skill is a text file
  that gets copied around; treat it as publishable even when it is not.
- General programming advice. The model already has that; every line here costs
  context in every session.

## Keep it short

The description of every installed skill sits in the system prompt of every
session, relevant or not. `goose skills list` prints the token cost per skill.
A page of genuinely non-obvious facts beats five pages of restated documentation.
