# ARC10 — KnownGaps 5-8

Model: haiku · Effort: low · Worktree: no (work in `WT` directly) · `WT = ~/Developer/g-cqd/arcleak-lane` (branch `lane/rules`) · Lane ARC, card 10 of 10 (after ARC09; last card)

Item 8. Executable false-negative ledger entries listed by the research (paraphrased shapes, no private code): gap 5 closure handed to a child method that stores it in another file; gap 6 back-reference typed as `UIViewController` or a class-bound protocol; gap 7 timer invalidated only in a teardown `stop()`; gap 8 AsyncStream continuation stored on self whose `onTermination` captures self (a strong-self `for await` consumer Task is already caught, so the entry uses `[weak self]` for the consumer and says so). Gap 9 (SwiftSignalKit disposable) is NOT added: ARC03 closes it. The file is a `Clean/` fixture: every entry must stay silent. The file ends with `}` and no final newline before and after the edit; that is expected (fixtures are not format-linted).

- **Model:** haiku, low. **Size:** about 85 lines (fixture only). Anchors are text, never line numbers: find each one with `grep -n` on a short piece of it if you need to look.
- **Files:**
  - `Tests/ArcLeakCoreTests/Fixtures/Clean/KnownGaps.swift`: append after the last class (`RouterOwner`)

## Change

### Edit 1: `Tests/ArcLeakCoreTests/Fixtures/Clean/KnownGaps.swift` (near `final class RouterOwner {`)

Find this exact text (it occurs once in the file):

````swift
    }

    func handle(_ value: Int) {}
}
````

Replace it with:

````swift
    }

    func handle(_ value: Int) {}
}

// Gap 5: a closure handed to a method of a child that stores it in a file
// arcleak does not connect to this call (`list.configure(onSelect:)` keeping
// `onSelect` in a property). self → list → stored parameter → self is a real
// cycle, but proving it needs parameter-to-property flow across files.
final class ListScreen {
    let list = ListController()

    func setUp() {
        list.configure(onSelect: { self.open() })
    }

    func open() {}
}

// Gap 6: a back-reference typed as a supertype or a protocol. The child keeps
// its parent as `UIViewController` (or `any ChildOwner`), so the type-level
// ownership graph has no edge back to `ParentScreen` and finds no cycle.
protocol ChildOwner: AnyObject {}

final class ChildPanel {
    var host: UIViewController?
    var owner: (any ChildOwner)?
}

final class ParentScreen: UIViewController, ChildOwner {
    let panel = ChildPanel()

    func attach() {
        panel.host = self
        panel.owner = self
    }
}

// Gap 7: a repeating timer invalidated only in a teardown method that nothing
// may call. A reachable `invalidate()` silences timer-retains-self, so a
// `stop()` that is never called leaves run loop → timer → self in place.
final class Heartbeat {
    var timer: Timer?

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            self.beat()
        }
    }

    func stop() {
        timer?.invalidate()
    }

    func beat() {}
}

// Gap 8: an AsyncStream continuation stored on self, finished only in deinit,
// whose termination handler captures self: self → continuation → onTermination
// → self. The handler is set on the build closure's parameter, not on a member
// of self, so no stored-closure fact exists. (A consumer Task that captures
// self strongly in `for await` IS caught, by task-nonterminating-self.)
final class EventFeed {
    var continuation: AsyncStream<Int>.Continuation?
    var consumer: Task<Void, Never>?

    func start() {
        let stream = AsyncStream<Int> { c in
            c.onTermination = { _ in self.reset() }
            self.continuation = c
        }
        consumer = Task { [weak self] in
            for await value in stream {
                self?.handle(value)
            }
        }
    }

    func handle(_ value: Int) {}
    func reset() {}

    deinit {
        continuation?.finish()
        consumer?.cancel()
    }
}
````

## Commands (in order; all verified on a copy of the clone at the previous card's commit)

1. Build (background): `/bin/bash --noprofile --norc -c 'cd ~/Developer/g-cqd/arcleak-lane && swift build --build-tests > /tmp/arc-lane-build.log 2>&1; echo EXIT=$? >> /tmp/arc-lane-build.log'`. Expected: the log contains `Build complete!` and ends with `EXIT=0`; no `warning:` or `error:` line (`/bin/bash --noprofile --norc -c 'grep -cE "warning:|error:" /tmp/arc-lane-build.log'` prints `0`).
2. Tests (background): `/bin/bash --noprofile --norc -c 'cd ~/Developer/g-cqd/arcleak-lane && swift test --no-parallel > /tmp/arc-lane-test.log 2>&1; echo EXIT=$? >> /tmp/arc-lane-test.log'`. Expected: `EXIT=0` and a line containing `Test run with 197 tests in 41 suites passed`.
3. Self-dogfood: `/bin/bash --noprofile --norc -c 'cd ~/Developer/g-cqd/arcleak-lane && swift run -q arcleak analyze Sources --strict --no-cache; echo EXIT=$?'`. Expected: `arcleak: 0 finding(s) (0 error(s), 0 warning(s)) in 82 file(s); 9 suppressed` then `EXIT=0`.
4. Format lint: `/bin/bash --noprofile --norc -c 'cd ~/Developer/g-cqd/arcleak-lane && Scripts/lint-format.sh; echo EXIT=$?'`. Expected: only `EXIT=0`.
5. GCD policy: `/bin/bash --noprofile --norc -c 'cd ~/Developer/g-cqd/arcleak-lane && Scripts/no-gcd.sh'`. Expected: `no-gcd: implementation is GCD-free`.
6. `/bin/bash --noprofile --norc -c 'cd ~/Developer/g-cqd/arcleak-lane && swift run -q arcleak analyze Tests/ArcLeakCoreTests/Fixtures/Clean/KnownGaps.swift --no-cache'` prints the summary line `arcleak: 0 finding(s) (0 error(s), 0 warning(s)) in 1 file(s)`.
7. Whole gate (background): `/bin/bash --noprofile --norc -c 'cd ~/Developer/g-cqd/arcleak-lane && Scripts/ci-local.sh > /tmp/arc-lane-ci.log 2>&1; echo EXIT=$? >> /tmp/arc-lane-ci.log'`. Expected: the log's last two lines are `== all gates green` and `EXIT=0` (about 40 s after the build above).

## Stop conditions

- A Find text is not found exactly once, or a new file already exists.
- Any expected line above differs (test count, finding count, line numbers, dogfood summary, `EXIT=`), or the build log has a `warning:`.
- `git status --short` lists any file not named in this card.

## Must not touch

`Benchmarks/` (the benchmarks package), `Package.swift`, `Package.resolved`, `Sources/ArcLeakCore/Diagnostics/ToolInfo.swift` and every version string (no version bump: that is a release step), `.github/`, `Scripts/`, `Docs/`, and every file this card does not name.

## Commit

Run `/bin/bash --noprofile --norc -c 'git -C ~/Developer/g-cqd/arcleak-lane status --short'` first: it must list exactly the files of this card (`M` or `??`), nothing else. Then:

```bash
/bin/bash --noprofile --norc -c 'git -C ~/Developer/g-cqd/arcleak-lane add Tests/ArcLeakCoreTests/Fixtures/Clean/KnownGaps.swift && git -C ~/Developer/g-cqd/arcleak-lane -c user.name=Gigi -c user.email=42325924+g-cqd@users.noreply.github.com commit -m "test: record four more known false negatives

Clean/KnownGaps gains executable entries for real leaks arcleak does not
see yet: a closure handed to a child method that stores it in another file
(gap 5), a back-reference typed as UIViewController or a class-bound
protocol (gap 6), a repeating timer invalidated only in a stop() nothing
may call (gap 7), and an AsyncStream whose continuation is stored on self
with a termination handler capturing self (gap 8). They are asserted
silent, so a detector that lands moves them to Leaks/. A SwiftSignalKit
disposable kept on self is not listed: combine-sink-self-cycle reports it
now. 197 tests pass."'
```

Then `/bin/bash --noprofile --norc -c 'git -C ~/Developer/g-cqd/arcleak-lane log --oneline -1'` shows the subject line, and `git status --short` is empty.

## Rules for this lane (apply to every ARC card)

- `WT=~/Developer/g-cqd/arcleak-lane`, branch `lane/rules`. Check first: `/bin/bash --noprofile --norc -c 'git -C ~/Developer/g-cqd/arcleak-lane branch --show-current'` prints `lane/rules`, and `/bin/bash --noprofile --norc -c 'git -C ~/Developer/g-cqd/arcleak-lane status --short'` prints nothing. If the branch does not exist yet (first card only), create it with `/bin/bash --noprofile --norc -c 'git -C ~/Developer/g-cqd/arcleak-lane checkout -b lane/rules'` from `main` at `5c234f3`.
- The login shell is fish: run every command as `/bin/bash --noprofile --norc -c '...'`, with absolute paths. Never use `~/.agent-harness/bin/work`.
- Edits: use the Edit tool with the "Find" text as `old_string` and the "Replace it with" text as `new_string`, exactly as printed (the four-backtick fences are not part of the text). Every Find text occurs exactly once; if it does not, stop. New files: use the Write tool with the content exactly as printed, plus one final newline. Apply the edits in the order given.
- Gate. `Scripts/ci-local.sh` runs completely in this environment (verified: build, `swift test`, self-dogfood, runtime oracle, LSP smoke, no-gcd, format lint; 36 s incremental on the orchestrator's copy). The card's commands run its sub-commands first (`swift build --build-tests`, `swift test --no-parallel`, `swift run arcleak analyze Sources --strict --no-cache`, `Scripts/lint-format.sh`, `Scripts/no-gcd.sh`), then the whole script. Long commands go to a log in the background (`run_in_background`); wait for the completion notification, then read the `EXIT=` line. One build at a time in WT.
- Commit only with the exact command in the card: unsigned, identity `Gigi <42325924+g-cqd@users.noreply.github.com>`, message in double quotes. A global pre-commit hook runs swift-format checks and prints `[OK] pre-commit checks completed successfully.`; if it reports a problem, stop. No push, no amend, no rebase, no other git history operation.
- Stop and report (paste the output) on any unexpected result: a Find text not found exactly once, a compiler error or warning, a test count or summary line that differs from the card, a finding in the self-dogfood run, any output from `Scripts/lint-format.sh`, `git status` listing a file the card does not name, or a hook failure. Do not improvise a fix.
- Export: none. The integrator exports the branch with `git format-patch`; no script, no shell step, no file outside WT is needed.
