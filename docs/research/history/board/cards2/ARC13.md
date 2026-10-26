# ARC13 — stored-closure-strong-self: a struct child is owned too

Model: haiku · Effort: low · Worktree: no (work in `WT` directly) · `WT = ~/Developer/g-cqd/arcleak-lane` (branch `lane/rules`) · Lane ARC (review fixes), card 3 of 8 (after ARC12; next ARC14)

Review fix (D, and finding 3). The owned-child path of `stored-closure-strong-self` (ARC01) exempted children typed as a struct or enum of the same file. A struct stored in `self` holds the closure inline, so `style.onTap = { self… }` is a real cycle. The extraction now keeps an owned-child closure whenever the child is a strong stored property of `self`, whatever its type; the struct case moves from the Clean fixture to the Leaks fixture.

- **Model:** haiku, low. Anchors are text, never line numbers: find each one with `grep -n` on a short piece of it if you need to look.
- **Files:**
  - `Sources/ArcLeakCore/Extraction/FactsExtraction.swift`: `func finish()` (the owned-child filter) and the helper before `resolveUpstreams` (`isOwnedReferenceChild` becomes `static func isOwnedChild`)
  - `Sources/ArcLeakCore/Rules/StoredClosureStrongSelfRule.swift`: doc comment of the rule
  - `Sources/ArcLeakCore/Diagnostics/RuleID.swift`: `explanation` of `.storedClosureStrongSelf`
  - `README.md`: the `stored-closure-strong-self` row of the Rules table
  - `Tests/ArcLeakCoreTests/Fixtures/Leaks/OwnedChildClosure.swift`: new struct `ToolbarStyle`, new property and finding
  - `Tests/ArcLeakCoreTests/Fixtures/Clean/OwnedChildClosureWeak.swift`: struct case removed

## Change

### Edit 1: `Sources/ArcLeakCore/Extraction/FactsExtraction.swift`

Find this exact text (it occurs once in the file):

````swift
                return isOwnedReferenceChild(child, properties: collectedFacts.storedProperties)
````

Replace it with:

````swift
                return Self.isOwnedChild(child, properties: collectedFacts.storedProperties)
````

### Edit 2: `Sources/ArcLeakCore/Extraction/FactsExtraction.swift`

Find this exact text (it occurs once in the file):

````swift
    /// A closure stored through `self.<child>.<member>` closes a cycle only
    /// when `self` owns the child: a strong stored property of this type. A
    /// child whose declared type is a struct or enum of this file is exempt;
    /// a child of unknown type (declared in another file or the SDK) counts.
    private func isOwnedReferenceChild(_ child: String, properties: [StoredPropertyFact]) -> Bool {
        guard let property = properties.first(where: { $0.name == child }),
            property.strength == .strong
        else { return false }
        guard let typeName = property.referencedTypeNames.first else { return true }
        return memberTable[typeName]?.isReferenceType != false
    }
````

Replace it with:

````swift
    /// A closure stored through `self.<child>.<member>` closes a cycle only
    /// when `self` owns the child: a strong stored property of this type. The
    /// child's type does not matter: a class child is kept by reference, and
    /// a struct child is stored inline in `self`, closure included.
    private static func isOwnedChild(_ child: String, properties: [StoredPropertyFact]) -> Bool {
        properties.contains { $0.name == child && $0.strength == .strong }
    }
````

### Edit 3: `Sources/ArcLeakCore/Rules/StoredClosureStrongSelfRule.swift`

Find this exact text (it occurs once in the file):

````swift
/// child must be a strong stored property of this type (extraction drops weak
/// or unowned children, locals, and children typed as a struct or enum of the
/// same file). Warning, not error: a child may clear its callback after
/// firing, which the source of `self` cannot show.
````

Replace it with:

````swift
/// child must be a strong stored property of this type, of any type: a struct
/// child is stored inline in `self` (extraction drops weak or unowned
/// children, locals and computed properties). Warning, not error: a child may
/// clear its callback after firing, which the source of `self` cannot show.
````

### Edit 4: `Sources/ArcLeakCore/Diagnostics/RuleID.swift`

Find this exact text (it occurs once in the file):

````swift
            clear its callback after firing. Weak or unowned children, children held
            in a local, and children typed as a struct or enum of the same file are
            not reported.
````

Replace it with:

````swift
            clear its callback after firing. A struct child counts: `self` stores it
            inline, closure included. Weak or unowned children, children held in a
            local, and computed properties are not reported.
````

### Edit 5: `README.md`

Find this exact text (it occurs once in the file):

````markdown
also one level down, on a child `self` owns through a strong stored property (`self.toolbar.onTap = { self… }`, `.append`) |
````

Replace it with:

````markdown
also one level down, on a child `self` owns through a strong stored property, class or struct (`self.toolbar.onTap = { self… }`, `.append`) |
````

### Edit 6: `Tests/ArcLeakCoreTests/Fixtures/Leaks/OwnedChildClosure.swift`

Find this exact text (it occurs once in the file):

````swift
final class Toolbar {
    var onTap: (() -> Void)?
    var actions: [() -> Void] = []
}

final class Screen {
    let toolbar = Toolbar()
    var footer: Toolbar?
    var count = 0

    func setUp() {
        toolbar.onTap = { // #al:expect stored-closure-strong-self
            self.reload()
        }
        self.footer?.onTap = { self.reload() } // #al:expect stored-closure-strong-self
        self.toolbar.actions.append { // #al:expect stored-closure-strong-self
            self.count += 1
        }
        toolbar.onTap = reload // #al:expect stored-closure-strong-self
    }
````

Replace it with:

````swift
final class Toolbar {
    var onTap: (() -> Void)?
    var actions: [() -> Void] = []
}

// A struct child is stored inline in self, closure included: self → style →
// onTap → self.
struct ToolbarStyle {
    var onTap: (() -> Void)?
}

final class Screen {
    let toolbar = Toolbar()
    var footer: Toolbar?
    var style = ToolbarStyle()
    var count = 0

    func setUp() {
        toolbar.onTap = { // #al:expect stored-closure-strong-self
            self.reload()
        }
        self.footer?.onTap = { self.reload() } // #al:expect stored-closure-strong-self
        self.toolbar.actions.append { // #al:expect stored-closure-strong-self
            self.count += 1
        }
        toolbar.onTap = reload // #al:expect stored-closure-strong-self
        style.onTap = { self.reload() } // #al:expect stored-closure-strong-self
    }
````

### Edit 7: `Tests/ArcLeakCoreTests/Fixtures/Clean/OwnedChildClosureWeak.swift`

Find this exact text (it occurs once in the file):

````swift
// The owned-child shapes that do not close a cycle: [weak self], a child held
// only in a local, a weak child, a child typed as a struct of this file, and
// a member that is not a stored property of self.
final class Panel {
    var onTap: (() -> Void)?
}

struct PanelStyle {
    var onTap: (() -> Void)?
}

final class Host {
    let panel = Panel()
    weak var parentPanel: Panel?
    var style = PanelStyle()
    var computedPanel: Panel { Panel() }

    func setUp() {
        panel.onTap = { [weak self] in
            self?.refresh()
        }
        let local = Panel()
        local.onTap = { self.refresh() }
        parentPanel?.onTap = { self.refresh() }
        style.onTap = { self.refresh() }
        computedPanel.onTap = { self.refresh() }
    }
````

Replace it with:

````swift
// The owned-child shapes that do not close a cycle: [weak self], a child held
// only in a local, a weak child, and a member that is not a stored property
// of self.
final class Panel {
    var onTap: (() -> Void)?
}

final class Host {
    let panel = Panel()
    weak var parentPanel: Panel?
    var computedPanel: Panel { Panel() }

    func setUp() {
        panel.onTap = { [weak self] in
            self?.refresh()
        }
        let local = Panel()
        local.onTap = { self.refresh() }
        parentPanel?.onTap = { self.refresh() }
        computedPanel.onTap = { self.refresh() }
    }
````

## Commands (in order; all verified on a copy of the clone at the previous card's commit)

1. Build (background): `/bin/bash --noprofile --norc -c 'cd ~/Developer/g-cqd/arcleak-lane && swift build --build-tests > /tmp/arc-lane-build.log 2>&1; echo EXIT=$? >> /tmp/arc-lane-build.log'`. Expected: the log contains `Build complete!` and ends with `EXIT=0`; no `warning:` or `error:` line (`/bin/bash --noprofile --norc -c 'grep -cE "warning:|error:" /tmp/arc-lane-build.log'` prints `0`).
2. Tests (background): `/bin/bash --noprofile --norc -c 'cd ~/Developer/g-cqd/arcleak-lane && swift test --no-parallel > /tmp/arc-lane-test.log 2>&1; echo EXIT=$? >> /tmp/arc-lane-test.log'`. Expected: `EXIT=0` and a line containing `Test run with 198 tests in 41 suites passed`.
3. Self-dogfood: `/bin/bash --noprofile --norc -c 'cd ~/Developer/g-cqd/arcleak-lane && swift run -q arcleak analyze Sources --strict --no-cache; echo EXIT=$?'`. Expected: `arcleak: 0 finding(s) (0 error(s), 0 warning(s)) in 82 file(s); 9 suppressed` then `EXIT=0`.
4. Format lint: `/bin/bash --noprofile --norc -c 'cd ~/Developer/g-cqd/arcleak-lane && Scripts/lint-format.sh; echo EXIT=$?'`. Expected: only `EXIT=0`.
5. GCD policy: `/bin/bash --noprofile --norc -c 'cd ~/Developer/g-cqd/arcleak-lane && Scripts/no-gcd.sh'`. Expected: `no-gcd: implementation is GCD-free`.
6. Probe: `/bin/bash --noprofile --norc -c 'cd ~/Developer/g-cqd/arcleak-lane && swift run -q arcleak analyze Tests/ArcLeakCoreTests/Fixtures/Leaks/OwnedChildClosure.swift Tests/ArcLeakCoreTests/Fixtures/Clean/OwnedChildClosureWeak.swift --no-cache; echo EXIT=$?'`. Expected: the summary line `arcleak: 5 finding(s) (0 error(s), 5 warning(s)) in 2 file(s)`, then 5 `warning: [stored-closure-strong-self]` lines at `OwnedChildClosure.swift` lines 24, 27, 28, 31 and 32; nothing in `OwnedChildClosureWeak.swift`; then `EXIT=0`.
7. Whole gate (background): `/bin/bash --noprofile --norc -c 'cd ~/Developer/g-cqd/arcleak-lane && Scripts/ci-local.sh > /tmp/arc-lane-ci.log 2>&1; echo EXIT=$? >> /tmp/arc-lane-ci.log'`. Expected: the log's last two lines are `== all gates green` and `EXIT=0` (about 55 s after the build above).

## Stop conditions

- A Find text is not found exactly once, or a new file already exists.
- Any expected line above differs (test count, finding count, line numbers, dogfood summary, `EXIT=`), or the build log has a `warning:`.
- `git status --short` lists any file not named in this card.

## Must not touch

`Benchmarks/` (the benchmarks package), `Package.swift`, `Package.resolved`, `Sources/ArcLeakCore/Diagnostics/ToolInfo.swift` and every version string (no version bump), `.github/`, `Scripts/`, `Docs/`, and every file this card does not name.

## Commit

Run `/bin/bash --noprofile --norc -c 'git -C ~/Developer/g-cqd/arcleak-lane status --short'` first: it must list exactly the files of this card (`M`, `D` or `??`), nothing else. Then:

```bash
/bin/bash --noprofile --norc -c 'git -C ~/Developer/g-cqd/arcleak-lane add README.md Sources/ArcLeakCore/Diagnostics/RuleID.swift Sources/ArcLeakCore/Extraction/FactsExtraction.swift Sources/ArcLeakCore/Rules/StoredClosureStrongSelfRule.swift Tests/ArcLeakCoreTests/Fixtures/Clean/OwnedChildClosureWeak.swift Tests/ArcLeakCoreTests/Fixtures/Leaks/OwnedChildClosure.swift && git -C ~/Developer/g-cqd/arcleak-lane -c user.name=Gigi -c user.email=42325924+g-cqd@users.noreply.github.com commit --no-gpg-sign -m "fix: flag closures stored on a struct child of self

The owned-child path exempted children typed as a struct declared in the
same file. A struct stored in self holds its members inline, so a closure
assigned to self.style.onTap that captures self strongly is the cycle
self -> style -> closure -> self, and the Clean twin asserted it as clean.
The exemption is gone: any strong stored property of self counts as an owned
child, whatever its type. Weak and unowned children, locals and computed
properties still stay silent.

The struct case moves from Clean/OwnedChildClosureWeak to
Leaks/OwnedChildClosure (5 findings). 198 tests pass."'
```

Then `/bin/bash --noprofile --norc -c 'git -C ~/Developer/g-cqd/arcleak-lane log --oneline -1'` shows the subject line `fix: flag closures stored on a struct child of self`, and `git status --short` is empty.

## Rules for this lane (apply to every ARC card)

- `WT=~/Developer/g-cqd/arcleak-lane`, branch `lane/rules`. Check first: `/bin/bash --noprofile --norc -c 'git -C ~/Developer/g-cqd/arcleak-lane branch --show-current'` prints `lane/rules`, and `/bin/bash --noprofile --norc -c 'git -C ~/Developer/g-cqd/arcleak-lane status --short'` prints nothing. The branch already exists (ARC01-ARC10 and the previous cards of this lane are on it); never create, reset or rebase it.
- The login shell is fish: run every command as `/bin/bash --noprofile --norc -c '...'`, with absolute paths. Never use `~/.agent-harness/bin/work`.
- Edits: use the Edit tool with the "Find" text as `old_string` and the "Replace it with" text as `new_string`, exactly as printed (the four-backtick fences are not part of the text). Every Find text occurs exactly once; if it does not, stop. New files: use the Write tool with the content exactly as printed, plus one final newline. Apply the edits in the order given.
- Gate. `Scripts/ci-local.sh` runs completely in this environment (build, `swift test`, self-dogfood, runtime oracle, LSP smoke, no-gcd, format lint). The card's commands run its sub-commands first (`swift build --build-tests`, `swift test --no-parallel`, `swift run arcleak analyze Sources --strict --no-cache`, `Scripts/lint-format.sh`, `Scripts/no-gcd.sh`), then the whole script. Long commands go to a log in the background (`run_in_background`); wait for the completion notification, then read the `EXIT=` line. One build at a time in WT.
- Commit only with the exact command in the card: unsigned (`--no-gpg-sign`), identity `Gigi <42325924+g-cqd@users.noreply.github.com>`, message in double quotes. A global pre-commit hook may run swift-format checks and print `[OK] pre-commit checks completed successfully.`; if it reports a problem, stop. No push, no amend, no rebase, no other git history operation.
- Stop and report (paste the output) on any unexpected result: a Find text not found exactly once, a compiler error or warning, a test count or summary line that differs from the card, a finding in the self-dogfood run, any output from `Scripts/lint-format.sh`, `git status` listing a file the card does not name, or a hook failure. Do not improvise a fix.
- Export: none. The integrator exports the branch with `git format-patch`; no script, no shell step, no file outside WT is needed.

