# Changelog

All notable changes to this project are documented here.

The format is loosely based on [Keep a Changelog](https://keepachangelog.com/).

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
