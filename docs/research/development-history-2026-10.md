---
date: 2026-10-26
question: "Where are the planning history and real-guest evidence collected during development?"
feeds: [roadmap 0015, ADR-0059]
---
# Development history and real-guest evidence

The former sibling development board is now tracked in this repository at [history/board/](history/board/). It preserves the planning material, reviews, test reports, fixtures, board viewer and generated layout images together, rather than turning old execution instructions into new architecture decisions.

**This is a historical research archive, not instructions to execute.** Its plans may describe older commits, absolute paths that no longer exist, superseded approaches, and proposed work that never ran. A checked box or an executor's report is not independent verification. Current decisions remain in [the ADRs](../adr/); current work remains in [the roadmap](../roadmap/); session results belong in [the diary](../diary/). Nothing in the archive overrides the repository's safety rules or authorises a guest run.

## Evidence to start with

- [Windows real-guest run and helper crash diagnosis](history/board/realguest-windows-report.md): a start was accepted, then the helper failed; Windows Setup was not observed.
- [PMU crash comparison](windows-pmu-crash-2026-10.md) and the later [boot-display investigation](windows-boot-display-2026-10.md), with [reproducible diagnostic sources and logs](history/windows-boot-probe/README.md). No successful Windows boot is claimed.
- [Linux real-guest run](history/board/realguest-report.md).
- [macOS real-guest run](history/board/realguest-macos-report.md).
- [Provisioning run](history/board/realguest-seed-report.md), [second run](history/board/realguest-seed-report-2.md), and [third run](history/board/realguest-seed-report-3.md).
- [Custom GPU run](history/board/realguest-gpu-report.md) and its [generated scanout](history/board/realguest-gpu-scanout.png).
- [Container run](history/board/realguest-container-report.md).

## Studies and planning

- [SDK survey](history/board/macos27-sdk-survey.md).
- [Graphics assessment](history/board/gpu-linux-windows-assessment.md).
- [Terminal assessment](history/board/terminalkit-assessment.md).
- [TPM feasibility notes](history/board/tpm-feasibility-2026-10-26.md): **paused at the owner's request**. No emulator, firmware, transport or extra private interface was implemented.
- Historical [planning material](history/board/cards/) and [later planning/reviews](history/board/cards2/).
- The [board viewer](history/board/index.html) and its adjacent data/scripts are retained for context. They were not run or regenerated during import. Historical paths in them are not a supported development interface.

## Import verification and limits

The directory was moved into the repository, not independently reconstructed. Finder metadata files were removed; reports, fixtures and visual evidence were retained. Four historical Swift snippets have a `.swift.txt` suffix so they remain evidence rather than compiled or linted source; their contents are unchanged. The initial commit hook correctly rejected treating one scratch snippet as production Swift. No source report was rewritten to turn an unverified claim into a verified one. Relative-link adjustments, if needed for the new location, are housekeeping rather than new evidence.

Not verified: the historical experiments were not repeated by importing their reports; old board tooling and absolute paths were not made portable; TPM feasibility remains a research sketch, not support for an installed guest. The current session's checks and any further crash mitigation are recorded separately in the diary.
