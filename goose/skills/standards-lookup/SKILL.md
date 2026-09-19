---
name: standards-lookup
description: >
  Answering any question involving a 3GPP specification, an IETF RFC, a spec clause
  number, a cause code, an AVP, an information element, a protocol message or a
  procedure. Use whenever the user mentions TS/TR numbers, RFC numbers, EMM or ESM
  causes, Diameter result codes, MAP operations, NAS messages, S1AP, GTP or SCCP,
  or asks what the spec says. Reads the real document and quotes it instead of
  answering from memory.
---

# Standards lookup

Answer specification questions from the document, never from memory. You have a
local corpus and a command that fills it.

## Use the shell. Do not use a web or fetch tool for this.

The command is **`fetch-specs`** and it is on your PATH. Run it with the shell tool.

```bash
fetch-specs --have          # what is already local
fetch-specs 24.301          # fetch a 3GPP TS
fetch-specs 29.272 23.401   # several at once
fetch-specs RFC6733         # fetch an IETF RFC
```

**Do not download standards documents with a fetch, browser or HTTP tool.** That
path is wrong in three ways and has already produced a wrong answer here:

- A 3GPP specification is published as a `.zip` containing a Word file. A fetch tool
  returns bytes you cannot read.
- The directory holds every version ever published. Picking a URL by hand gets an
  old one — a previous attempt pulled `24301-900.zip`, a Release 9 document from
  2009, when the current release is many years newer. `fetch-specs` always takes the
  newest.
- The result would not be saved, so the next question re-downloads it.

`fetch-specs` handles the archive, the conversion to text, the version selection and
the caching. Call it and then read the file it wrote.

## Procedure

1. **`fetch-specs --have`** — see what is already local.
2. **`fetch-specs <id>`** — fetch anything missing. Work out which document the
   question needs; the command resolves where it lives. A 3GPP TS takes under a
   minute. Fetch it rather than guess.
3. **Grep the file, then read around the hit** for context.
4. **Quote what you found and cite the line.**

```bash
grep -n "IMSI unknown" ~/specs/3GPP-24.301.txt
sed -n '4195,4215p' ~/specs/3GPP-24.301.txt     # the surrounding table
grep -n "^9\.9\.3\.9" ~/specs/3GPP-24.301.txt   # a specific clause
```

## Why this exists

Asked which EMM cause an MME returns when the HSS answers
`DIAMETER_ERROR_USER_UNKNOWN`, a model answered **"#1, TS 24.301 section 9.9.2.1"**
with complete confidence. Both halves were wrong. The truth is one line:

```
$ grep -n "IMSI unknown in HSS" ~/specs/3GPP-24.301.txt
4205:	#2	(IMSI unknown in HSS)
```

A wrong clause reference gets copied into a code comment and outlives everyone who
saw it. That is the failure this skill exists to prevent.

## Which document

Derive it from the question; these are common ones, not a limit:

| Topic | Document |
|---|---|
| NAS, EMM/ESM causes, Attach, TAU | TS 24.301 |
| EPS architecture, bearers, procedures | TS 23.401 |
| S6a/S6d Diameter, HSS interface | TS 29.272 |
| S1AP | TS 36.413 |
| GTPv2-C | TS 29.274 |
| SMS transport and encoding | TS 23.040, TS 23.038 |
| SGd / SMS over Diameter | TS 29.338 |
| MAP | TS 29.002 |
| Numbering, addressing, identities | TS 23.003 |
| Security architecture | TS 33.401 |
| IMS | TS 23.228, TS 24.229 |
| Diameter base protocol | RFC 6733 (obsoletes RFC 3588) |
| SCTP | RFC 9260 |

## Rules

- **Never cite a clause you have not grepped.**
- **Quote the document's words.** Paraphrase after quoting, not instead of it.
- **Cite file and line** so the user can check you: `3GPP-24.301.txt:4205`.
- **Say which version you read.** The filename records it; releases differ.
- **If the corpus disagrees with what you remember, the corpus is right.**
- **If grep finds nothing**, try the spec's own wording — "IMSI unknown" hits where
  "unknown subscriber" may not — then say what you tried rather than guessing.
