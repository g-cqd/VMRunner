---
date: 2026-10-22
question: "Do the owner's libraries offer techniques or code that improve this app's performance and memory, and what here belongs in the shared library?"
feeds: [roadmap 0033, roadmap 0035, ADR-0001]
---
# Reusable code: what to take, what to give back

Study, not a decision record. No benchmark was run; numbers are the libraries' own claims or this repository's baselines
(`.vmr-bench.json`). Two of the libraries (an HTTP stack and a CSV coder) are not on this machine and were read through summaries
of their public sources; treat those findings as leads.

## Short answer

- Little speed is left to gain: the per-packet paths allocate nothing and SHA-256 runs near 2 GiB/s.
- No library fits as a dependency of the app: the shared utility library declares a macro-compiler dependency at package level,
  and the JSON library pins a collections range that cannot resolve with this repository's exact pin. Copying small, reviewed
  files with their licence header is the only fit with ADR-0001.
- The larger value is the reverse direction: the per-thread allocation window, the benchmark recorder, strict Base64 and the
  packet parsers belong in the shared library.

## Findings

- The shared library's Base64 is lenient: it accepts non-canonical trailing bits and padding runs of any length (`"Zg==="`,
  `"===="`). This app's decoder must stay strict (armor ambiguity is a signature-confusion vector). Hence roadmap 0035 makes
  the shared decoder configurable, with a strict preset.
- Its percent decoding returns nil on a bad escape; this app's deliberately keeps it and decodes to a fixed point. Not
  substitutable.
- Its allocation counter is process-wide; parallel suites inflate it (ADR-0008 measured 5 of 5 failures before the
  per-thread fix). Our version is ahead.
- Its HTTP date parser is loose (signs, day 31 in any month, a fixed two-digit pivot); the SWAR helpers are exact only for the
  first matching lane, so counting set lanes is wrong.
- No library has big-integer, RSA or DER encoding code; this app builds only a PKCS#1 header and lets `SecKey` do the
  arithmetic. The byte-reader of the HTTP stack is a `~Escapable` view over `RawSpan`: a compile-time-checked shape for the
  byte views here, but it needs an experimental compiler feature (ADR-0011's posture).

## Mapping

| Hot spot here | Candidate | Verdict |
|---|---|---|
| Checksum hashing reads | One reusable read buffer | Do (roadmap 0033): at most ~25% of instructions, inferred |
| Two hex encoders | One table-driven helper | Do: deduplication |
| CRC-24 bitwise loop | Table-driven | Optional, microseconds |
| Strict Base64 | Library decoder | No: lenient |
| Byte views, rings, pools | Library pools, `~Escapable` reader | No: ours allocate nothing; revisit when lifetimes are stable |
| `config.json` decode | JSON library | No: small file read once; breaks ADR-0001 |
| UTF-8/ASCII SIMD kernels | C kernels | No: kilobyte inputs, would weaken strict memory safety |
| Regex listing parsers | Byte scanners | Profile first |

## To give back (roadmap 0035), ranked

Per-thread allocation window and malloc shim; strict canonical Base64 and CRC-24 as options of one decoder; the benchmark
recorder that gates on retired instructions (wall-clock rates spread 63% to 78% across ten runs, instructions 0.2% to 0.8%);
packet parsers and checksum arithmetic; the fixed-slot rings; the debounce and poll helpers; the test-support improvements of
roadmap 0031. Not worth sharing: the network policy engine (Apple-framework specific), the DNS wire code, the runtime limit.

## Not verified

Any benchmark of the libraries; whether the lifetime feature is still experimental in the current compiler (inferred from a
manifest); the two unavailable libraries' details; the shared library's Linux CI.
