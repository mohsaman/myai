---
name: mme-workspace
description: >
  Working on the local Rust MME workspace at ~/myaimme — the mme, nas, rrc and s1ap
  crates. Use whenever the user mentions the MME workspace, myaimme, or asks to build,
  check, test or extend those crates. Covers the crate layout, the build commands that
  matter, and the mistakes that have already cost time here.
---

# MME workspace

A Cargo workspace at `~/myaimme` with four members: `mme`, `nas`, `rrc`, `s1ap`.

## Before changing anything

Run `cargo check --workspace` first and read the output. The workspace has been
edited by an agent that wrote empty files, so do not assume a crate compiles just
because it exists.

## Conventions

- Cite the 3GPP clause in a comment for anything implementing a procedure, but only
  a clause you have confirmed. A wrong reference outlives the person who wrote it.
- Handle the failure path. Telecom code without timeout, retry and failover paths is
  not finished.
- Prefer explicit over clever. Ops teams read this.

## Known traps here

- `~` does not expand in tool arguments. Writing to `~/myaimme/...` from a tool has
  previously created a literal `~` directory instead. Use absolute paths.
- `rasn` has a feature conflict in this tree; the `macros` feature is the one that
  resolves.
