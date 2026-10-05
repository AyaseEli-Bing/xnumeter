# Contributing

Short version: **open an issue (or leave a comment claiming an existing one) before sending a
PR.** It stops two people from doing the same task, and it lets the maintainer redirect a wrong
approach before you spend an evening on it.

## What you need

- macOS with the Xcode Command Line Tools (`swiftc` from Swift 6.x is enough — no Xcode project,
  no GUI session needed for the tests).
- A real Mac. `scripts/selftest.sh` cross-checks the binary against `netstat`, `vm_stat`,
  `sysctl` and `top`, so it cannot run on Linux or in a container.
- No root. Nothing here needs `sudo`.

## Build and verify

```sh
make all     # builds the CLI binary and the .app bundle
make test    # runs scripts/selftest.sh — the acceptance gate
```

`make test` must end with `ALL CHECKS PASSED`. Two things worth knowing:

- **`make test` does not build the app target.** It depends on the CLI binary only. If you touch
  GUI code, also run `make app` (CI runs `make all`, which covers both).
- The selftest asserts on live kernel readings, so a few checks are inherently timing-sensitive.
  If a check goes red, re-run it and say so in the PR rather than loosening the assertion.

## Conventions

- **Commit messages**: capitalized imperative, no `type:` prefix — match `git log`, e.g.
  `Localize the dashboard into Simplified Chinese`.
- **Localization**: user-facing strings go through `NSLocalizedString` with **both** tables kept
  in sync — `Sources/XnumeterApp/en.lproj/Localizable.strings` and
  `Sources/XnumeterApp/zh-Hans.lproj/Localizable.strings`. Add a key to both files in the same
  commit; a one-sided addition shows up as English text on a Chinese system.
- **Sampling code**: `Sources/Xnumeter/Sampler.swift` reads counters from the kernel. Rate
  calculations are validated by the selftest against their own byte deltas, so if you change one
  reading, run the full selftest rather than only eyeballing the CLI output.
- **Disk list**: `Sampler.swift` sorts mounts by name length, which puts `/` first, and
  `scripts/selftest.sh` compares `disks[0]` against `df -k /`. If you change that sort, update the
  assertion in the same PR and say why.

## Pull requests

- One change per PR. Keep refactors separate from behaviour changes.
- Fill in the PR template, especially **how you verified it** — paste the tail
  of `make test`. There is no way for CI to know your change is correct beyond
  these two targets.
- For a bug fix, add the failing check first: run it against unmodified code, confirm it fails for
  the reported reason, then fix it. A test that passes either way proves nothing.

## License

By submitting a PR you agree your contribution is licensed under the MIT license in `LICENSE`.
