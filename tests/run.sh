#!/usr/bin/env bash
# Test suite. Runs against tests/bin/v4l2-ctl, a fake camera, so it needs no
# hardware and works in CI.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export PATH="$ROOT/tests/bin:$PATH"

PASS=0
FAIL=0

ok()   { PASS=$((PASS + 1)); printf '  \033[32mok\033[0m   %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; [ -n "${2:-}" ] && printf '         %s\n' "$2"; }

is()   { # is <description> <actual> <expected>
    if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected '$3', got '$2'"; fi
}

# Fresh sandbox per test: state file, config, fake device node, camlight state.
setup() {
    SANDBOX=$(mktemp -d)
    export FAKE_CAM_STATE=$SANDBOX/camstate
    export CAMLIGHT_STATE_DIR=$SANDBOX/state
    export CAM=$SANDBOX/fakecam
    : >"$FAKE_CAM_STATE"
    : >"$CAM"
    mkdir -p "$CAMLIGHT_STATE_DIR"

    export CAMSHARE_CONF=$SANDBOX/camshare.conf
    cat >"$CAMSHARE_CONF" <<'EOF'
CAM_VENDOR="1234"
CAM_PRODUCT="5678"
CAM_LINK="testcam"
LOOPBACKS="70:Test A;71:Test B"
WIDTH=1280
HEIGHT=720
FPS=30
STICKY_CONTROLS="power_line_frequency"
PROFILE_day="128 600 5500 1 0"
PROFILE_evening="140 900 3800 1 0"
PROFILE_auto="128 39 4500 3 1"
DEFAULT_PROFILE="day"
EOF
}

teardown() { rm -rf "$SANDBOX"; }

camlight() { "$ROOT/bin/camlight" "$@"; }
getc()     { v4l2-ctl -d "$CAM" --get-ctrl="$1" | awk '{print $2}'; }

echo
echo "camshare tests"
echo

# ---------------------------------------------------------------------------
echo "profiles"
setup
camlight day >/dev/null 2>&1
is "day sets brightness"          "$(getc brightness)" "128"
is "day sets manual exposure"     "$(getc auto_exposure)" "1"
is "day sets exposure value"      "$(getc exposure_time_absolute)" "600"
is "day disables auto white bal"  "$(getc white_balance_automatic)" "0"
is "day sets white balance"       "$(getc white_balance_temperature)" "5500"

camlight evening >/dev/null 2>&1
is "evening changes brightness"   "$(getc brightness)" "140"
is "evening changes exposure"     "$(getc exposure_time_absolute)" "900"
teardown

# ---------------------------------------------------------------------------
# The reported bug: a control no profile names survived every profile switch,
# so a stray hue could not be undone short of replugging the camera.
echo
echo "profile switching resets controls it does not name (regression)"
setup
camlight day >/dev/null 2>&1
v4l2-ctl -d "$CAM" --set-ctrl=hue=145,saturation=160,zoom_absolute=140 >/dev/null 2>&1
is "hue was changed"              "$(getc hue)" "145"

camlight evening >/dev/null 2>&1
is "hue reset by profile switch"        "$(getc hue)" "128"
is "saturation reset by profile switch" "$(getc saturation)" "128"
is "zoom reset by profile switch"       "$(getc zoom_absolute)" "100"
is "profile value still applied"        "$(getc brightness)" "140"

v4l2-ctl -d "$CAM" --set-ctrl=hue=200 >/dev/null 2>&1
camlight reset >/dev/null 2>&1
is "hue reset by 'reset'"               "$(getc hue)" "128"
teardown

# ---------------------------------------------------------------------------
echo
echo "sticky controls survive a profile switch"
setup
v4l2-ctl -d "$CAM" --set-ctrl=power_line_frequency=1 >/dev/null 2>&1
camlight day >/dev/null 2>&1
is "power_line_frequency kept" "$(getc power_line_frequency)" "1"
camlight evening >/dev/null 2>&1
is "still kept after 2nd switch" "$(getc power_line_frequency)" "1"
teardown

# ---------------------------------------------------------------------------
echo
echo "set: validation"
setup
camlight day >/dev/null 2>&1
out=$(camlight set brightness=999 2>&1); rc=$?
is "out-of-range rejected"        "$rc" "1"
case $out in *"between 0 and 255"*) ok "error names the range" ;;
             *) bad "error names the range" "$out" ;; esac
is "clamping did not happen"      "$(getc brightness)" "128"
is "nothing persisted"            "$([ -e "$CAMLIGHT_STATE_DIR/custom" ] && echo yes || echo no)" "no"

camlight set nonsense=1 >/dev/null 2>&1
is "unknown control rejected"     "$?" "1"
camlight set brightness=abc >/dev/null 2>&1
is "non-integer rejected"         "$?" "1"
teardown

# ---------------------------------------------------------------------------
echo
echo "set: applying and persisting"
setup
camlight day >/dev/null 2>&1
camlight set sharpness=150 >/dev/null 2>&1
is "value applied"                "$(getc sharpness)" "150"
is "custom layer written"         "$([ -e "$CAMLIGHT_STATE_DIR/custom" ] && echo yes || echo no)" "yes"
is "base profile unchanged"       "$(cat "$CAMLIGHT_STATE_DIR/profile")" "day"

camlight reset >/dev/null 2>&1
is "reset drops the tweak"        "$(getc sharpness)" "128"
is "custom layer removed"         "$([ -e "$CAMLIGHT_STATE_DIR/custom" ] && echo yes || echo no)" "no"
teardown

# ---------------------------------------------------------------------------
echo
echo "set: auto_* gating"
setup
camlight auto >/dev/null 2>&1
is "auto profile leaves AE on"    "$(getc auto_exposure)" "3"
camlight set exposure=800 >/dev/null 2>&1
is "setting exposure turns AE off" "$(getc auto_exposure)" "1"
is "exposure took effect"          "$(getc exposure_time_absolute)" "800"

camlight auto >/dev/null 2>&1
camlight set exposure=500 ae=3 >/dev/null 2>&1; rc=$?
is "explicit auto wins, exits 0"   "$rc" "0"
is "auto_exposure stayed on"       "$(getc auto_exposure)" "3"
teardown

# ---------------------------------------------------------------------------
echo
echo "restore reapplies saved state"
setup
camlight day >/dev/null 2>&1
camlight set sharpness=90 >/dev/null 2>&1
# Simulate a replug: the camera comes back at factory defaults.
: >"$FAKE_CAM_STATE"
is "camera reset to defaults"      "$(getc sharpness)" "128"
camlight restore >/dev/null 2>&1
is "restore brings back the tweak" "$(getc sharpness)" "90"
is "restore brings back profile"   "$(getc exposure_time_absolute)" "600"
teardown

# ---------------------------------------------------------------------------
echo
echo "config and generators"
setup
is "env overrides the config file" \
   "$(CAM_LINK=fromenv "$ROOT/bin/camshare-conf" cam)" "/dev/fromenv"
is "loopback count"                "$("$ROOT/bin/camshare-conf" count)" "2"
is "device list"                   "$("$ROOT/bin/camshare-conf" devices | tr '\n' ' ')" "/dev/video70 /dev/video71 "
is "profiles enumerated"           "$("$ROOT/bin/camshare-conf" profiles | tr '\n' ' ')" "auto day evening "

udev=$("$ROOT/bin/camgen" udev)
case $udev in *'SYMLINK+="testcam"'*) ok "udev rule names the symlink" ;;
              *) bad "udev rule names the symlink" "$udev" ;; esac
case $udev in *'ATTR{index}=="0"'*) ok "udev rule pins index 0" ;;
              *) bad "udev rule pins index 0" ;; esac
# Only the rule line matters; the comment above it mentions "serial" too.
rule=$(grep '^SUBSYSTEM' <<<"$udev")
case $rule in *'ATTRS{serial}'*) bad "no serial clause when unset" "$rule" ;;
              *) ok "no serial clause when unset" ;; esac
rule=$(CAM_SERIAL=ABC123 "$ROOT/bin/camgen" udev | grep '^SUBSYSTEM')
case $rule in *'ATTRS{serial}=="ABC123"'*) ok "serial clause added when set" ;;
              *) bad "serial clause added when set" "$rule" ;; esac

# A dedicated preview device: camtune must never share a loopback with an app,
# but it still has to be created by the module and fed by the fan-out.
is "no preview device by default" \
   "$("$ROOT/bin/camshare-conf" tune-device)" "/dev/video70"
is "preview device is used when set" \
   "$(TUNE_LOOPBACK='79:Preview' "$ROOT/bin/camshare-conf" tune-device)" "/dev/video79"
is "preview device is not an app device" \
   "$(TUNE_LOOPBACK='79:Preview' "$ROOT/bin/camshare-conf" devices | tr '\n' ' ')" \
   "/dev/video70 /dev/video71 "
is "preview device is fed by the fan-out" \
   "$(TUNE_LOOPBACK='79:Preview' "$ROOT/bin/camshare-conf" loopbacks | tail -1)" "79 Preview"
is "module must create it too" \
   "$(TUNE_LOOPBACK='79:Preview' "$ROOT/bin/camshare-conf" count)" "3"

pv=$(TUNE_LOOPBACK="79:Preview" "$ROOT/bin/camgen" modprobe)
case $pv in *"video_nr=70,71,79"*) ok "modprobe includes the preview device" ;;
            *) bad "modprobe includes the preview device" "$pv" ;; esac
case $pv in *"exclusive_caps=1,1,1"*) ok "caps cover the preview device" ;;
            *) bad "caps cover the preview device" "$pv" ;; esac

mp=$(LOOPBACKS="70:A;71:B;72:C" "$ROOT/bin/camgen" modprobe)
case $mp in *"devices=3"*)            ok "modprobe device count" ;; *) bad "modprobe device count" "$mp" ;; esac
case $mp in *"video_nr=70,71,72"*)    ok "modprobe video_nr" ;;    *) bad "modprobe video_nr" "$mp" ;; esac
case $mp in *"exclusive_caps=1,1,1"*) ok "exclusive_caps per device" ;; *) bad "exclusive_caps per device" "$mp" ;; esac
teardown

# ---------------------------------------------------------------------------
# camtune's HTTP contract, against fake systemctl and gstreamer.
#
# Regression: clicking "start" in the UI left a broken preview. systemd reports
# the unit active the moment it forks, but gstreamer has not prerolled yet, so
# the stream endpoint used to send 200 headers and then no data. A browser
# treats that as a permanently broken image and never retries.
echo
echo "camtune HTTP contract"
setup
export FAKE_SVC_STATE=$SANDBOX/svcstate
export FAKE_GST_MODE_FILE=$SANDBOX/gstmode
# The suite must not depend on the caller's environment: with the production
# 12s budget the server would still be retrying when curl gives up, and the
# assertion would see 000 instead of 503.
export CAMTUNE_FIRST_FRAME_TIMEOUT=2
echo active >"$FAKE_SVC_STATE"
echo frames >"$FAKE_GST_MODE_FILE"

CAMTUNE_LOG=$SANDBOX/camtune.log
"$ROOT/bin/camtune" --port 0 --device "$CAM" \
    --loopback "$CAM" >"$CAMTUNE_LOG" 2>&1 &
CAMTUNE_PID=$!
URL=""
for _ in $(seq 1 100); do
    URL=$(sed -n 's|.*\(http://127.0.0.1:[0-9]*\).*|\1|p' "$CAMTUNE_LOG" 2>/dev/null | head -1)
    [ -n "$URL" ] && curl -s -o /dev/null --max-time 1 "$URL/api/service" && break
    sleep 0.1
done

code() { curl -s -o /dev/null -w '%{http_code}' --max-time 6 "$@"; }
post() { curl -s --max-time 6 -X POST -H 'Content-Type: application/json' -d "$2" "$1"; }

if [ -z "$URL" ]; then
    bad "camtune started" "no URL in $CAMTUNE_LOG: $(cat "$CAMTUNE_LOG")"
else
    ok "camtune started on $URL"

    is "reports the service state" \
       "$(curl -s --max-time 5 "$URL/api/service" | sed -n 's/.*"state": "\([a-z]*\)".*/\1/p')" "active"

    # The bug, from the server side: never answer 200 without frames.
    echo inactive >"$FAKE_SVC_STATE"
    is "stream is 503 while the service is stopped" "$(code "$URL/stream.mjpg")" "503"

    echo active >"$FAKE_SVC_STATE"
    echo silent >"$FAKE_GST_MODE_FILE"
    is "stream is 503 when the pipeline yields nothing" \
       "$(code "$URL/stream.mjpg")" "503"
    echo frames >"$FAKE_GST_MODE_FILE"

    is "stream is 200 once frames flow" "$(code "$URL/stream.mjpg")" "200"

    # Regression: routing compared the raw path, which includes the query
    # string, so the cache-busting ?t=... the page adds on every reload made
    # each retry a 404. curl against the bare URL could never catch it.
    is "stream honours a cache-busting query" "$(code "$URL/stream.mjpg?t=12345")" "200"
    is "api honours a query string"           "$(code "$URL/api/service?t=1")" "200"
    is "controls honour a query string"       "$(code "$URL/api/controls?t=1")" "200"

    body=$(curl -s --max-time 3 "$URL/stream.mjpg" | head -c 200)
    case $body in *FRAME*) ok "stream carries frame data" ;;
                  *) bad "stream carries frame data" "got: $body" ;; esac

    # Service control endpoint.
    is "stop is accepted" \
       "$(post "$URL/api/service" '{"action":"stop"}' | sed -n 's/.*"state": "\([a-z]*\)".*/\1/p')" "inactive"
    is "start is accepted" \
       "$(post "$URL/api/service" '{"action":"start"}' | sed -n 's/.*"state": "\([a-z]*\)".*/\1/p')" "active"
    is "unknown action rejected" \
       "$(code -X POST -H 'Content-Type: application/json' -d '{"action":"disable"}' "$URL/api/service")" "400"

    # The client half cannot be driven headlessly, so assert the retry wiring is
    # at least present: without it a single early failure is never retried.
    page=$(curl -s --max-time 5 "$URL/")
    for marker in 'reloadPreview' 'img.onerror' 'previewTries'; do
        case $page in *"$marker"*) ok "page wires up $marker" ;;
                      *) bad "page wires up $marker" ;; esac
    done
fi

kill "$CAMTUNE_PID" 2>/dev/null
wait "$CAMTUNE_PID" 2>/dev/null
teardown

# ---------------------------------------------------------------------------
echo
printf '%d passed, %d failed\n\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
