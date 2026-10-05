---
name: Bug report
about: Wrong reading, crash, bad output
title: "[Bug]: "
labels: bug
assignees: ''
---

<!-- Before filing: check the open issues, and if someone has commented that they are working on
this one, comment there instead of sending a duplicate PR. -->

**What you saw**

<!-- Paste the actual output. `./xnumeter --json --once` is the easiest thing to paste. -->

**What you expected**

**How to reproduce**

```sh
# exact commands, including flags and -n sample count
make all && ./xnumeter --once --no-color
```

**Environment**

- Mac model / chip:
- macOS version (`sw_vers -productVersion`):
- Binary version (`defaults read "$(pwd)/Xnumeter.app/Contents/Info" CFBundleShortVersionString` after `make app`, or the git commit):
- Running as root or with sudo? (per-process data is limited for non-root — see Known limits)
