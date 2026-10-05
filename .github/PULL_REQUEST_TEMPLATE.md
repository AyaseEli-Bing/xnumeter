## Related issue

<!-- e.g. Closes #12 / Refs #12. A behaviour change without an issue should start as one. -->

## What changed

<!-- Files and functions, not "improved the code". -->

## Why

<!-- Root cause. If you tried another approach first, say why you dropped it. -->

## Verification

```sh
make all
make test    # must end with ALL CHECKS PASSED
```

Paste the last lines of `make test` here. If a check was flaky on your machine, say so instead of
relaxing the assertion.

- [ ] `make test` passes with `ALL CHECKS PASSED`
- [ ] `make app` builds (if I touched GUI code — `make test` alone does not compile the app)
- [ ] New user-facing strings added to **both** `en.lproj` and `zh-Hans.lproj`
- [ ] README "Known limits" / usage updated if behaviour changed
- [ ] Commit messages match the existing style (capitalized imperative, no `type:` prefix)

## AI assistance

<!-- If an AI tool wrote or reshaped any of this, say so in one line and describe how you checked
it. Disclosure is expected, not punished. -->
