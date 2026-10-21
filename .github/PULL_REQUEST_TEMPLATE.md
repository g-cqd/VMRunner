## What and why

<!-- What changes, and why. Link the issue if there is one. -->

## How it was verified

<!-- Tests added or updated, commands run, manual checks on a real Mac (VMs never start in CI). -->

## Security and entitlement impact

<!-- Does this widen what a guest can reach, change an entitlement, a download host or checksum rule, a workflow
permission, or a pinned dependency or action? Write "none" if not. -->

## Checklist

- [ ] `swift run vmr check --full` passes locally
- [ ] Behavior changes have tests; new logic is in the model layer, not in views
- [ ] No change to entitlements, `DownloadPolicy` or security profiles, or it is explained above and covered by a test
- [ ] Analyzer baselines are not regenerated to hide new findings; the coverage minimum did not go down
- [ ] Docs (README, CONTRIBUTING, SECURITY) updated where the change affects them
