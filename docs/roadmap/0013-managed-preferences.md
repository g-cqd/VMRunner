---
status: in-progress
blocked-by: []
date: 2026-10-21
decision: ADR-0013
---
# 0013 — Let an organisation lock settings through managed preferences

Study: `docs/research/mdm-2026-10.md`. Read forced keys with `objectIsForced` and lock the matching controls.

## Built

`ManagedPreferences` reads the keys forced in the app's own domain, fails closed on a value of the wrong type, and the
library applies it to every machine it loads, adds or changes. Keys: `AllowSharedFolders`, `AllowClipboardSharing`,
`AllowMicrophone`, `AllowSuspend`, `AllowHostInformation`, `RequireDisposableMachines`, `MaxRuntimeMinutes`, and the
app's own settings, which are now one list (`AppSetting`). A restricted control shows a lock (`.managedLock`); the help
topic *Settings your organisation manages* lists the keys.

## Owed

ADR-0013 is still proposed: the owner accepts it with this first set of keys, or changes it. A run with a real
configuration profile installed. Reading the policy again when a profile changes while the app runs (today the library
reads it at launch).
