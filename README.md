# camshare

**Use one webcam in several apps at the same time, on Linux.**

Slack and Teams cannot both open your webcam. Whoever starts first wins; everyone
else greys out the camera button or reports `Device or resource busy`. camshare
reads the camera once and copies the frames into virtual cameras — one per app —
so there is no contention.

It also fixes the *other* webcam annoyance: exposure and white balance that reset
every time you replug, and a camera that meters for the bright window behind you
and leaves your face in shadow.

```
                      ┌──> /dev/video70   "CamShare A"  ──> Slack
/dev/camshare0 ──tee──┤
  (your camera)       └──> /dev/video71   "CamShare B"  ──> Teams
```

```bash
make detect           # find your camera, write a config
make install-system   # udev rule + kernel module options (sudo, once)
make install          # scripts + a systemd user service
make tune             # live preview and sliders in your browser
```

---

## Contents

- [Requirements](#requirements)
- [Quick start](#quick-start)
- [How many virtual cameras?](#how-many-virtual-cameras)
- [Configuration](#configuration)
- [Lighting profiles](#lighting-profiles)
- [Setting individual controls](#setting-individual-controls)
- [Tuning in a browser](#tuning-in-a-browser)
- [Make targets](#make-targets)
- [How it works](#how-it-works)
- [Troubleshooting](#troubleshooting)
- [Field notes](#field-notes)
- [Limitations](#limitations)
- [Uninstall](#uninstall)

---

## Requirements

- Linux with `v4l2loopback`. Recent kernels ship it; otherwise
  `sudo apt install v4l2loopback-dkms` (or your distro's equivalent).
- `gstreamer` with the good plugins: `gstreamer1.0-tools`, `gstreamer1.0-plugins-good`.
- `v4l-utils` for `v4l2-ctl`.
- Python 3.8+ for `camtune` (standard library only — nothing to pip install).
- A **USB** camera. Built-in laptop cameras behind Intel IPU6 are not UVC devices
  and expose no controls; they will not work here.

```bash
sudo apt install v4l-utils gstreamer1.0-tools gstreamer1.0-plugins-good
```

## Quick start

```bash
git clone <your-fork> camshare && cd camshare

make detect            # writes ~/.config/camshare/camshare.conf
make install-system    # sudo: udev rule + module options
sudo modprobe -r v4l2loopback; sudo modprobe v4l2loopback   # or reboot
make install           # scripts + user service, starts it
make check             # verify the whole chain
```

Then **restart your video apps** — they enumerate cameras only at startup — and
pick `CamShare A` in one and `CamShare B` in the other.

If `make detect` finds more than one camera it will list them and ask you to
choose:

```bash
make detect ARGS="--device /dev/video2"
```

## How many virtual cameras?

One per app that needs the camera **at the same time**. Two is the common case.
They are defined in `camshare.conf`:

```sh
LOOPBACKS="70:CamShare A;71:CamShare B"
```

Each entry is `number:label`:

- **number** becomes `/dev/video<number>`. Use something high — **70 and up** —
  so it cannot collide with real hardware, which numbers upward from 0. On a
  laptop with an Intel IPU6 camera stack, numbers 0–49 may already be taken.
- **label** is what apps show in their camera dropdown. Give each app its own
  label so you can tell which is which. The defaults are deliberately bland;
  rename them to `Slack`, `Teams`, `OBS`, whatever you actually use.

Adding a third:

```sh
LOOPBACKS="70:CamShare Slack;71:CamShare Teams;72:CamShare OBS"
```

then `make install-system` to regenerate the module options, reload the module
(or reboot), and `make restart`. The udev rule, the `v4l2loopback` options and
the gstreamer pipeline are all generated from this one line — there is nothing
else to keep in sync.

**The cost is linear.** Each virtual camera is another full uncompressed copy of
every frame. At 1080p30 that is roughly 124 MB/s of memory traffic per device, so
two costs ~250 MB/s and four ~500 MB/s. CPU rises more gently, since decoding
happens once and only the copies multiply. Two or three is comfortable on any
modern machine; a dozen is not the intended use.

> One virtual camera can also be read by several apps at once, so you do not
> strictly need one per app. Separate devices are still better: each app
> remembers its own choice, and the labels tell you which app is on which.

## Configuration

Everything lives in `~/.config/camshare/camshare.conf`, seeded from
[`camshare.conf.example`](camshare.conf.example). `make config` prints what is
actually resolved.

| key | meaning |
|---|---|
| `CAM_VENDOR`, `CAM_PRODUCT` | USB ids of your camera. `make detect` fills these in. |
| `CAM_SERIAL` | Optional. Only needed to tell two identical cameras apart. |
| `CAM_LINK` | Name of the stable symlink, as `/dev/$CAM_LINK`. |
| `LOOPBACKS` | `number:label` per virtual camera, semicolon separated. |
| `WIDTH`, `HEIGHT`, `FPS` | Capture format. Only sizes listed under MJPG by `make formats` are valid. |
| `TUNE_PORT` | Port for the browser UI. Default 8787. |
| `PROFILE_<name>` | A lighting profile. Add your own; no code change needed. |
| `DEFAULT_PROFILE` | Applied when nothing has been chosen yet. |

`FPS` defaults to **30** on purpose: video-call apps re-encode to 30 or less
anyway, and 60 doubles both USB and memory load for no visible gain in a call.

## Lighting profiles

A camera's own metering will happily expose for a bright window and leave your
face dark, and its auto white balance drifts as you move. Profiles pin both:

```bash
camlight day        # or: make day
camlight evening
camlight auto       # hand exposure and white balance back to the camera
camlight status
```

Switching is **live** — UVC controls can be changed mid-stream — so it is safe
during a call and needs no restart. The choice is saved and reapplied at service
start, which is what makes it survive reboots, replugs and any tool that resets
controls on exit.

**The shipped `day` and `evening` values are placeholders.** Correct exposure and
white balance depend entirely on your room; nobody can ship values that are right
for your desk. Run `make tune`, adjust until the preview looks right, press Save,
then copy what `camlight status` reports into `camshare.conf` so it is version
controlled. Until you do, `DEFAULT_PROFILE="auto"` keeps things looking normal.

Adding your own profile needs no code:

```sh
PROFILE_studio="150 300 5200 1 0"   # brightness exposure wb_temp auto_exposure auto_wb
```

`camlight studio` and a `studio` button in the browser UI both appear on their
own.

## Setting individual controls

```bash
camlight set brightness=150
camlight set exposure=800 wb=4200
camlight evening && camlight set sharpness=90    # profile, then adjust
camlight reset                                   # drop tweaks, back to the profile
camlight controls                                # every control, with its range
```

`set` layers on top of the current profile rather than replacing it, and is saved
the same way. Names may be aliases or the raw v4l2 name:

| alias | real control |
|---|---|
| `exposure`, `exp` | `exposure_time_absolute` |
| `ae` | `auto_exposure` |
| `wb`, `wb_temp` | `white_balance_temperature` |
| `auto_wb`, `awb` | `white_balance_automatic` |
| `focus` / `autofocus` | `focus_absolute` / `focus_automatic_continuous` |
| `zoom` | `zoom_absolute` |

Three behaviours worth knowing:

- **Values are range-checked** before anything is applied, so `brightness=999`
  fails cleanly instead of half-applying a set.
- **Autos are turned off for you.** Setting `exposure`, `wb` or `focus` while its
  auto is on would be silently ignored by the driver, so camlight disables the
  auto and says so. Pass the auto explicitly to override that.
- **Nothing is saved unless it applied**, so a rejected set cannot leave a broken
  config for the service to reapply at boot.

State lives in `~/.config/camshare/profile` (base profile) and
`~/.config/camshare/custom` (the tweak layer). `reset` deletes the second.

## Tuning in a browser

```bash
make tune           # then open http://127.0.0.1:8787
```

Live preview with a slider per control. The point is iteration speed: from the
CLI, tuning means set → snapshot → look → adjust, several seconds a round. Here
the preview updates as you drag.

- **The preview reads a virtual camera, not the real one**, so it never contends
  with the fan-out and shows exactly the frames your apps receive.
- Sliders apply immediately; nothing is written to disk until you press
  **Save to camlight**.
- Profile buttons are generated from your config and call `camlight` directly, so
  the CLI and the UI cannot drift apart.
- Controls gated by an auto are greyed out, since the driver would reject them.

It binds **127.0.0.1 only**, deliberately — it exposes camera controls and a live
video feed of your desk.

**Port.** Defaults to **8787**, not 80: ports below 1024 need root, which this
has no reason to have, and 80 is usually taken anyway. If 8787 is busy — often a
camtune you forgot to stop — it walks forward to the next free port and tells you
which one it used:

```
camtune: port 8787 was busy, using 8788
camtune: http://127.0.0.1:8788
```

Set `TUNE_PORT` in `camshare.conf` to change the default, or override per run:

```bash
make tune TUNE_PORT=9000
camtune --port 0        # let the OS pick any free port
```

> **Careful with Save.** It captures *every* saveable control at its current
> value, including ones you did not touch. If you have been experimenting, hit a
> profile button first to get back to a known state.

## Make targets

Run `make` with no arguments for the full self-documenting list.

| target | what it does |
|---|---|
| `detect` | find your camera, write a config |
| `install` / `uninstall` | scripts + user service |
| `install-system` / `uninstall-system` | udev rule + module options (sudo) |
| `config` / `generated` | show resolved config; show the files that would be installed |
| `status` / `check` / `logs` | state; full diagnostic; follow the journal |
| `start` / `stop` / `restart` | service control |
| `day` / `evening` / `auto` / `light` | lighting profiles |
| `set ARGS="brightness=150"` / `reset` / `controls` | manual control |
| `tune` | browser UI |
| `fps` / `snapshot` / `formats` | measure rate; grab a frame; list camera modes |
| `diff` / `sync` / `lint` | repo vs installed; pull back; syntax checks |

## How it works

**The problem.** `uvcvideo` lets many processes *open* a camera but only one
*stream* from it. The second app to try gets `EBUSY`.

**The fix.** One gstreamer pipeline opens the camera, decodes MJPEG once, and
`tee`s the raw frames into N `v4l2loopback` devices. Apps read those. Since the
service starts at login, it claims the camera before any app can, and the apps
only ever see virtual devices.

Three details that are easy to get wrong:

- **`ATTR{index}=="0"` in the udev rule.** A UVC camera usually exposes *two*
  `/dev/video*` nodes with identical vendor, product and serial. The second is
  metadata-only: it lists zero pixel formats and silently fails for every app.
  Only `index` distinguishes them.
- **`exclusive_caps=1` per loopback.** Chromium-based apps (Slack, Teams, Chrome)
  refuse to list a loopback without it. The flip side is the most confusing
  failure here: a loopback advertises itself as output-only until something is
  streaming into it, so if the fan-out dies the cameras do not go black — they
  *disappear* from every app's device list. `Device Caps: 0x05200001` means a
  loopback is live; `make check` verifies this.
- **Never refer to `/dev/videoN` for the real camera.** The number is assigned in
  USB enumeration order and changes across reboots and dock replugs — on the
  machine this was developed on it moved from `video48` to `video0` in a single
  day. That is what `CAM_LINK` and the udev rule are for.

## Troubleshooting

### `Device or resource busy` / camera button greyed out

Something else is streaming from the real camera:

```bash
fuser -v /dev/camshare0     # substitute your CAM_LINK
```

**Slack is the usual offender, and closing its window is not enough** — it hides
to the tray and its Chromium capture helper keeps the device mmap'd (`ACCESS`
shows `F...m`):

```bash
pkill -f 'video_capture.mojom.VideoCaptureService'
```

Chromium respawns that helper on demand, so Slack itself is unaffected.

### All virtual cameras vanished from every app's list

The worst failure mode, because they disappear rather than going black. The
sequence, observed in the wild:

1. `v4l2loopback` was reloaded, so the loopbacks briefly disappeared.
2. An app lost its virtual camera and fell back to grabbing the **real** one,
   then held it.
3. The fan-out restarted, found the camera busy, and died. `Restart=always`
   retried forever.
4. With no producer streaming into them, `exclusive_caps=1` left every loopback
   advertising output-only, so no app would list any of them.

Fix: evict whoever took the real camera (above), then let the service retry.

**Do not reload `v4l2loopback` while your video apps are running.** Reboot, or
quit them first. The service normally claims the camera before the apps start; a
mid-session reload inverts that ordering.

### `Failed to allocate a buffer` / `Internal data stream error`

Seen at 60fps with an extra reader attached. The service exits and restarts
itself within seconds. Contributing factors:

- `max_buffers` is small by default
  (`cat /sys/module/v4l2loopback/parameters/max_buffers`), which is tight with
  several openers at high frame rates.
- Deep USB hub chains. A camera behind three hubs on a shared 480 Mb/s bus, next
  to a USB audio device, has much less headroom than the spec sheet suggests.

In increasing order of disruption: close `camtune` while on a call, move the
camera to a port that is not behind a hub chain, or set `FPS=30` and
`make restart`.

### Service loops in `activating`

The camera is held or absent. `make logs`. `no matching capture node found` means
neither the symlink nor the sysfs fallback found it — check `lsusb` and, if you
use a dock, the dock connection.

### Camera renumbered after a reboot

The udev rule should prevent this from mattering. If the symlink is missing:

```bash
v4l2-ctl --list-devices     # find it by name
make detect --force         # re-detect and rewrite the config
```

`camshare.sh` also falls back to a sysfs search by USB id automatically.

## Field notes

Measured while tuning a UGREEN FineCam 4K CM973. Details vary by camera, but the
*shapes* generalise and cost real time to rediscover.

- **`exposure_time_absolute` is often coarsely quantised.** On that camera, 10
  through 800 were nearly indistinguishable and 1000 was a large step brighter.
  A sweep at 120/200/300/400 moved the subject by 3 luminance levels out of 255
  and looked like a dead control. Sweep the whole range before concluding
  anything.
- **Long exposure need not cost frame rate.** 1000 (nominally 100 ms) still
  delivered a measured 30 fps at 1080p30 and 60 fps at 1080p60.
- **`white_balance_temperature` names the assumed illuminant**, so *higher*
  values make the image *warmer*. Setting 4000 under daylight produced a strong
  blue cast; 5500 neutralised it. This is backwards from intuition and a common
  source of confusion.
- **`brightness` is a black-level offset, not gain.** Raising it lifts shadows
  and washes the picture out; it does not meaningfully brighten a backlit face.
  Exposure is the lever that does.
- **`v4l2-ctl` silently clamps out-of-range values and exits 0.** An unchecked
  write reports success while the driver stores something else entirely.
- **Grab test frames from a virtual camera, never the real one.** No contention,
  and it is what your apps actually receive.

## Limitations

- **Only formats your camera lists under MJPG** are valid. Check `make formats`.
  60fps generally exists only at 1080p and below.
- **Higher resolutions may not fit the USB link.** A camera negotiating USB 2.0
  at 480 Mb/s has roughly 40 MB/s usable for video. 1080p60 MJPEG fits
  comfortably; 4K30 needs 30–60 MB/s, so the camera compresses harder — giving a
  *mushier* 4K image than clean 1080p — or drops frames. Check with
  `make check`. Note that call apps re-encode to 720p or so regardless, so
  anything above 1080p rarely reaches the far end.
- **Manual exposure does not follow the light.** A profile tuned at midday will
  be wrong after dark. Switch profiles, or use `auto`.
- **Profiles manage five controls** — brightness, the two autos, exposure and
  white balance. Anything else you change (contrast, saturation, sharpness,
  zoom) sticks on the device but is not restored by switching profiles. Use
  `camlight set` to save such values, and `camlight controls` to see what is
  really set. Replugging the camera resets everything to factory defaults.
- **The fan-out is a single point of failure.** It owns the camera and feeds
  every virtual device; if it dies they all go dark. `Restart=always` covers
  crashes.
- **Apps must be restarted** to notice virtual cameras appearing or disappearing.

## Uninstall

```bash
make uninstall          # service + scripts (config kept)
make uninstall-system   # udev rule + module options (sudo)
sudo modprobe -r v4l2loopback
rm -rf ~/.config/camshare
```

If `modprobe -r` reports the module is in use, an app still has a loopback open —
`fuser -v /dev/video70 /dev/video71`, quit it, retry.

Optionally reset the camera to factory defaults **before** removing the udev
rule, while the symlink still resolves:

```bash
v4l2-ctl -d /dev/camshare0 --set-ctrl=brightness=128,contrast=128,saturation=128,hue=128,sharpness=128
v4l2-ctl -d /dev/camshare0 --set-ctrl=auto_exposure=3,white_balance_automatic=1
```

Then repoint your apps back at the real camera — they will not fall back on their
own and will show black until you do.

## License

MIT — see [LICENSE](LICENSE).
