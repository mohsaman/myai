---
name: standards-lookup
description: >
  Answering any question that involves a 3GPP specification, an IETF RFC, a spec
  clause number, a cause code, an AVP, an information element, a protocol message
  or a procedure. Use whenever the user mentions TS/TR numbers, RFC numbers, EMM
  or ESM causes, Diameter result codes, MAP operations, NAS messages, S1AP, GTP,
  SCCP, or asks "what does the spec say". Fetches the real document and quotes it
  rather than answering from memory.
---

# Standards lookup

You have a local corpus of standards documents and a fetcher. **Use them.** Do not
answer a specification question from memory, and never invent a clause number.

A model asked which EMM cause corresponds to `DIAMETER_ERROR_USER_UNKNOWN` answered
"#1, TS 24.301 section 9.9.2.1" with complete confidence. Both halves were wrong.
The real answer is one grep away:

```
$ grep -n "IMSI unknown in HSS" ~/specs/3GPP-24.301.txt
4205:	#2	(IMSI unknown in HSS)
```

That is the difference between sounding expert and being useful.

## Procedure

**1. See what is already local.**

```bash
~/myai-stack/scripts/fetch-specs.sh --have
```

**2. Fetch what you need if it is missing.** Work out the right document yourself
from the question — the fetcher resolves where it lives.

```bash
~/myai-stack/scripts/fetch-specs.sh 24.301        # 3GPP TS
~/myai-stack/scripts/fetch-specs.sh 29.272 23.401 # several at once
~/myai-stack/scripts/fetch-specs.sh RFC6733       # IETF
```

A 3GPP spec is a few MB and takes under a minute. Fetch it rather than guess.

**3. Grep for the answer, then read around the hit for context.**

```bash
grep -n "IMSI unknown" ~/specs/3GPP-24.301.txt
sed -n '4195,4215p' ~/specs/3GPP-24.301.txt      # the surrounding table
grep -n "^9\.9\.3\.9" ~/specs/3GPP-24.301.txt    # a specific clause
```

**4. Quote what you found and cite the line.** If the grep returns nothing, say the
document does not appear to contain it — do not fall back on memory.

## Which document

Derive it from the question; these are the common ones, not a limit:

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

- **Never cite a clause you have not grepped.** A wrong spec reference gets copied
  into a code comment and outlives everyone who saw it.
- **Quote the document's words.** Paraphrase after quoting, not instead of it.
- **Cite the file and line** so the user can check you: `3GPP-24.301.txt:4205`.
- **Version matters.** The fetcher takes the newest published version and the
  filename records it. If the user is working to a specific release, say which
  version you read.
- **If the corpus disagrees with what you remember, the corpus is right.**
- **If the grep finds nothing**, try synonyms — specs use precise wording, so
  "IMSI unknown" hits where "unknown subscriber" may not. Then say what you tried.
