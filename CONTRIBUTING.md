# Contributing

Thanks for taking the time. This is a small project with a narrow purpose:
share one USB camera with several applications on Linux, and make its exposure
and white balance predictable. Changes that serve that are welcome.

## Getting set up

```bash
git clone https://github.com/RahatHameed/camshare.git && cd camshare
make test          # runs against a fake camera -- no hardware needed
make lint          # bash -n, shellcheck, python compile
```

`make test` and `make lint` are the whole local gate, and both run in CI. You do
**not** need a camera to work on most of this: the test suite drives the scripts
through a fake `v4l2-ctl` in `tests/bin/`.

To try it against real hardware, follow the Quick start in the
[README](README.md). `make install` is safe to re-run; `make diff` shows how
your working tree differs from what is installed.

## Branches and pull requests

`main` is protected: it takes no direct pushes. Everything goes through a pull
request that CI has passed and a maintainer has approved.

```bash
git switch -c fix/exposure-clamping
# ... work, commit ...
git push -u origin fix/exposure-clamping
gh pr create --fill
```

Name branches `<type>/<short-description>`:

| prefix | for |
|---|---|
| `feat/` | new capability |
| `fix/` | a bug |
| `docs/` | documentation only |
| `refactor/` | no behaviour change |
| `ci/` | workflows and tooling |

Keep a pull request to one idea. A README fix and a control-handling change are
two pull requests, not one — they get reviewed differently and reverted
differently.

## Commit messages

Imperative subject, sentence case, no `feat:`/`chore:` prefixes, no trailing
full stop. Under ~70 characters:

```
Reset unnamed controls when applying a profile
```

If the change is not self-evident, add a body explaining **why**, not what — the
diff already says what. The most useful commit messages here record the
behaviour of the hardware that forced the change:

```
Reject out-of-range values before writing them

v4l2-ctl silently clamps out-of-range values and still exits 0, so an
unchecked write reports success while the driver stores something else,
and Save then persists the clamped value.
```

Group related files into one commit. Do not mix a fix with unrelated
reformatting.

## Tests

Anything touching control handling needs a test. The suite lives in
`tests/run.sh` and uses `tests/bin/v4l2-ctl`, a fake camera.

The fake deliberately reproduces the real tool's awkward behaviour, and that is
the point of it:

- out-of-range values are **clamped silently** and still exit 0
- writing a control gated by an `auto_*` fails with a permission error
- gated controls report `flags=inactive` rather than disappearing

If you make the fake more polite than the real thing, the tests stop meaning
anything. When you fix a bug, **check that the new test fails without your
fix** — revert the fix, run `make test`, confirm red, put it back.

Adding a case:

```bash
setup                                  # fresh sandbox: fake camera, config, state
camlight day >/dev/null 2>&1
is "description" "$(getc hue)" "128"   # is <description> <actual> <expected>
teardown
```

## Code style

**Shell.** Bash, `set -uo pipefail`, four-space indent. Quote expansions. Keep
functions small and name them for what they answer. shellcheck must pass; if a
warning is a genuine false positive, disable it *inline with a comment saying
why*, never repo-wide.

**Python.** `camtune` only. Standard library exclusively — no dependencies, no
packaging, no build step. That constraint is deliberate: it must run from a
clone on a fresh machine.

**Comments** explain why, not what. A comment restating the code is noise; one
recording a hardware quirk or a non-obvious ordering constraint is the reason
the next person does not lose an afternoon.

## Things worth knowing before you change them

- **Config is the single source of truth.** The udev rule, the v4l2loopback
  module options and the gstreamer pipeline are all generated from
  `camshare.conf`. Do not hardcode device numbers or labels anywhere; ask
  `camshare-conf`.
- **Order matters when writing controls.** An `auto_*` must be written before
  the manual control it gates, or the driver rejects the manual value. See
  `ORDER` and `IMPLIES` in `bin/camlight`.
- **Never preview the real camera.** `camtune` reads a virtual device on
  purpose: previewing the real one would contend with the fan-out and show you
  something different from what your apps receive.
- **`camtune` binds to 127.0.0.1.** It exposes camera controls and a live video
  feed. Keep it that way.
- **Do not commit a config.** `camshare.conf` is gitignored because it contains
  your camera's serial number.

## Reporting a bug

Include the output of:

```bash
make check
make config
```

and say what camera you have, what you expected, and what happened. If it
involves the picture rather than the plumbing, `make snapshot` writes a frame to
`/tmp/camshare-snaps/latest.jpg`.

Hardware differs more than you would expect — control ranges, which controls
exist at all, and how coarsely a value is quantised are all camera-specific. Say
which model you are on.

## Releases

[CHANGELOG.md](CHANGELOG.md) follows [Keep a Changelog](https://keepachangelog.com/).
Add an entry under `Unreleased` in the same pull request as your change, in the
appropriate section (`Added`, `Fixed`, `Changed`, `Removed`).

## License

By contributing you agree that your contributions are licensed under the
[MIT License](LICENSE).
