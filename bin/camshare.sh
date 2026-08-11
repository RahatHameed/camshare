#!/usr/bin/env bash
# Read one USB camera and fan it out to N v4l2loopback devices, so several apps
# can use the camera at the same time.
#
# The uvcvideo driver lets many apps *open* a camera but only one stream from it.
# Whoever grabs it first wins and everyone else gets "Device or resource busy".
# One process reading it and copying the frames sidesteps that entirely.
set -uo pipefail

HERE=$(dirname "$(readlink -f "$0")")
# shellcheck source=/dev/null
. "$HERE/camshare-conf"
camshare_conf_load || echo "camshare: no config file found, using defaults" >&2

CAM=${CAM:-$(camshare_cam)}

# Fallback if the udev symlink is missing: find the camera by its USB ids in
# sysfs. index==0 is the Video Capture node; the other one is metadata-only and
# unusable by any application.
detect_cam() {
    local d index dir vendor product
    for d in /sys/class/video4linux/video*; do
        [ -r "$d/index" ] || continue
        index=$(cat "$d/index" 2>/dev/null) || continue
        [ "$index" = 0 ] || continue
        dir=$(readlink -f "$d/device" 2>/dev/null) || continue
        while [ -n "$dir" ] && [ "$dir" != / ]; do
            if [ -r "$dir/idVendor" ]; then
                vendor=$(cat "$dir/idVendor" 2>/dev/null)
                product=$(cat "$dir/idProduct" 2>/dev/null)
                if [ "$vendor" = "$CAM_VENDOR" ] && [ "$product" = "$CAM_PRODUCT" ]; then
                    echo "/dev/${d##*/}"
                    return 0
                fi
                break
            fi
            dir=$(dirname "$dir")
        done
    done
    return 1
}

# The USB camera may not be enumerated yet at login; wait for it.
for ((i = 0; i < 30; i++)); do
    [ -e "$CAM" ] && break
    sleep 1
done

if [ ! -e "$CAM" ]; then
    echo "camshare: $CAM absent, falling back to sysfs detection" >&2
    CAM=$(detect_cam) || { echo "camshare: no matching capture node found" >&2; exit 1; }
    echo "camshare: using $CAM" >&2
fi

# Cold plugs and guvcview reset UVC controls to defaults, so reapply the saved
# lighting profile. camlight owns the values so they can be changed live without
# restarting this service. Resolved next to this script because the systemd user
# unit's PATH does not necessarily include ~/.local/bin.
CAMLIGHT="$HERE/camlight"
if [ -x "$CAMLIGHT" ]; then
    CAM="$CAM" "$CAMLIGHT" restore || echo "camshare: camlight restore failed" >&2
fi

# Build the pipeline: decode once, then tee a branch per virtual camera. Every
# extra branch is another full-frame copy per frame, so the cost is linear in
# the number of loopbacks, not free.
# shellcheck disable=SC2054  # the commas are inside gstreamer caps strings,
# which are single quoted elements, not array separators.
pipeline=(
    gst-launch-1.0 -q
    v4l2src "device=$CAM"
    ! "image/jpeg,width=$WIDTH,height=$HEIGHT,framerate=$FPS/1"
    ! jpegdec
    ! videoconvert
    ! video/x-raw,format=YUY2
    ! tee name=t
)

# The preview device is a convenience; the app-facing ones are the point. A
# missing preview device must not take the whole fan-out down, which would
# otherwise happen in the window between configuring TUNE_LOOPBACK and
# reloading v4l2loopback to actually create it.
TUNE_NUM=$(camshare_tune_entry | awk '{print $1}')

count=0
while read -r num label; do
    [ -n "$num" ] || continue
    if [ ! -e "/dev/video$num" ]; then
        if [ -n "$TUNE_NUM" ] && [ "$num" = "$TUNE_NUM" ]; then
            echo "camshare: preview device /dev/video$num missing, carrying on" \
                 "without it -- run 'make install-system' and reload" \
                 "v4l2loopback to create it" >&2
            continue
        fi
        echo "camshare: /dev/video$num missing -- is v4l2loopback loaded with" \
             "the right video_nr? try: make install-system" >&2
        exit 1
    fi
    pipeline+=(t. ! queue ! v4l2sink "device=/dev/video$num" sync=false)
    count=$((count + 1))
    echo "camshare: /dev/video$num <- $label" >&2
done < <(camshare_all_loopbacks)

if [ "$count" -eq 0 ]; then
    echo "camshare: LOOPBACKS is empty, nothing to feed" >&2
    exit 1
fi

echo "camshare: $CAM -> $count virtual camera(s) at ${WIDTH}x${HEIGHT}@${FPS}" >&2
exec "${pipeline[@]}"
