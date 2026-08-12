# Changelog

All notable changes to this project are documented here.

The format is loosely based on [Keep a Changelog](https://keepachangelog.com/).

## [Unreleased]

### Fixed

- The browser page died with a JavaScript syntax error and froze on its initial
  markup. Its HTML lives in a Python string, which was consuming the escapes
  meant for JavaScript -- `\n` became a real newline inside a string literal.
  The template is a raw string now, and a test pins it.

- The browser UI's stop button stopped the whole fan-out, taking every
  application's camera down. Pausing the preview is now the primary control and
  affects only this page; stopping the fan-out is a separate, confirmed action.
- camtune could leave a stale gstreamer holding the preview device. Since this
  driver allows only one reader per device, that locked camtune out of its own
  preview and every retry failed with `Device is busy`. Exactly one preview
  pipeline is now tracked and replaced per request.

- Every preview reload 404'd. Routing compared `self.path`, which includes the
  query string, so the cache-busting `?t=...` the page appends on each reload
  never matched `/stream.mjpg`. Only the very first request, made without a
  query, ever worked.
- Clicking start in the browser UI left a broken preview. systemd reports the
  unit active the moment it forks, but gstreamer has not prerolled, so the
  stream endpoint sent 200 headers and then no data — which a browser treats as
  a permanently broken image and never retries. The endpoint now waits for real
  frames before committing to a 200 and returns 503 otherwise, and the page
  retries a bounded number of times while the service is meant to be running.
  Retrying happens inside a single request: each attempt holds a v4l2loopback
  opener while its gstreamer is torn down, so retrying from the browser piled
  those up against `max_openers` until every attempt failed.
- Requests are logged to the journal again, and gstreamer's stderr is reported
  in the 503 body instead of being discarded. The underlying error was
  `Device '/dev/videoN' is not a capture device`, which exclusive_caps produces
  until the fan-out is actually pushing frames; discarding it cost two wrong
  diagnoses.
- The page is served with `Cache-Control: no-store`, so an open tab cannot keep
  running JavaScript from an older camtune.

### Added

- `make cameras`: lists real and virtual cameras with their formats and whether
  something is reading them, filtering out the unusable IPU6 nodes that bury
  `v4l2-ctl --list-devices` on this kind of laptop.

- `TUNE_LOOPBACK`: a virtual camera used only by camtune's preview, so the
  tuning UI never shares a loopback with an application. Sharing one made the
  app go blank while the preview looked fine. A missing preview device is a
  warning rather than fatal, so configuring it cannot take the fan-out down
  in the window before the module is reloaded.
- CI and license badges in the README.
- `camtune.service` with `make tune-enable` / `make tune-disable`, so the browser
  UI can survive reboots. Installed but not enabled by default; gstreamer is
  only spawned while a browser tab is connected, so it is idle at rest.
- Start/stop controls for the fan-out in the browser UI, with a status pill. The
  camera's indicator light is on whenever camshare runs, by design, and stopping
  it is the only way to release the camera; the UI now makes that reachable
  without a terminal. The preview shades over with an explanation while stopped,
  and `/stream.mjpg` returns 503 rather than spawning gstreamer against a
  loopback with no producer.

## [0.1.0] - 2026-08-11

First public version. Generalised from a single-machine setup into something
installable on any Linux box with a UVC camera.

### Added

- `camshare.sh` — reads one USB camera and fans it out to N v4l2loopback
  devices via a gstreamer `tee`, so several apps can use the camera at once.
- `camlight` — named lighting profiles applied live with `v4l2-ctl`, plus
  `set` for individual controls, layered on top of a base profile. Persists to
  `~/.config/camshare/`, reapplied at service start.
- `camtune` — browser UI on `127.0.0.1` with a live MJPEG preview and a slider
  per control. Standard library Python, no dependencies. Previews a *virtual*
  camera so it never contends with the fan-out.
- `camdetect` — finds the USB camera and writes a config for it, filtering out
  metadata-only nodes and non-USB pipelines such as Intel IPU6.
- `camgen` — generates the udev rule and v4l2loopback module options from the
  config, so the number and names of virtual cameras live in one place.
- `camshare-conf` — config loader shared by every script and by the Makefile.
- Makefile with `detect`, `install`, `check`, `tune`, `fps`, `snapshot` and
  friends; `make` alone prints self-documenting help.
- Configurable number of virtual cameras via `LOOPBACKS` in `camshare.conf`.
- GitHub Actions CI running shellcheck, a Python compile check and the tests.
- Test suite (`make test`) running against a fake `v4l2-ctl`, so it needs no
  camera. The fake reproduces the real tool's silent clamping and auto-gating.
- `make edit` to open the active config, and `make link`/`make unlink` to keep
  the config in the checkout symlinked into `~/.config`, for tracking it in a
  private fork. A dangling symlink is reported rather than silently falling back
  to defaults.

### Fixed

- `camlight set` wrote its state file *before* applying, so a rejected set left
  a broken config that the service would reapply at every boot. It now applies
  first and only persists on success.
- `camtune` trusted the slider range. `v4l2-ctl` silently clamps out-of-range
  values and still exits 0, so an out-of-range write reported success while the
  driver stored something else, and Save then persisted the clamped value.
  Values are now range-checked server-side.
- Setting a manual control while its auto counterpart was on failed with
  `VIDIOC_S_EXT_CTRLS: Permission denied`. Such controls are now either skipped
  with a warning, or the gating auto is turned off automatically.
- Loading the config overwrote settings passed in the environment, so
  `CAM_VENDOR=046d camgen udev` silently used the config's value instead. The
  environment now wins.
- Applying a profile left controls it did not name wherever they happened to be,
  so a stray hue, saturation or zoom survived every profile switch and `reset`
  could not undo it. A profile now returns every control it manages to the
  camera default, except those listed in `STICKY_CONTROLS`.
- `camtune` refused to start if its port was in use. It now walks forward to the
  next free port, or takes any free port with `--port 0`.

### Known issues

- Long exposures at 60fps with several readers attached can produce
  `Failed to allocate a buffer` from gstreamer; the service restarts itself
  within seconds. Lower `FPS`, reduce readers, or avoid deep USB hub chains.
  See the troubleshooting section in the README.
