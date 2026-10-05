---
name: Feature request
about: New gauge, new flag, output or format change
title: "[Feat]: "
labels: enhancement
assignees: ''
---

**The problem you are trying to solve**

<!-- What can't you answer today about your machine? "Add a button" is a solution, not a problem. -->

**Proposed behaviour**

<!-- For a CLI flag: name, default value, output shape. For a gauge: what it reads and how you
would verify the number is right against netstat / vm_stat / sysctl / iostat / top. -->

**Verification plan**

- [ ] The number can be cross-checked with a stock tool on macOS
- [ ] `scripts/selftest.sh` can assert on it (say which check you would add)
- [ ] Needs no root / no entitlements
- [ ] Needs new keys in **both** `.strings` tables (en + zh-Hans)
