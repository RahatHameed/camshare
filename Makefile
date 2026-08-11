# camshare -- share one USB camera with several apps at once.
#
#   make detect           find your camera, write a config for it
#   make install-system   udev rule + module options (sudo, once)
#   make install          scripts + user service
#   make tune             live preview and sliders in a browser
#   make check            diagnose the whole chain
#
# Everything is driven by camshare.conf; see camshare.conf.example.

SHELL := /bin/bash

.DEFAULT_GOAL := help

PREFIX    ?= $(HOME)/.local/bin
UNIT_DIR  ?= $(HOME)/.config/systemd/user
CONF_DIR  ?= $(HOME)/.config/camshare
CONF      ?= $(CONF_DIR)/camshare.conf
SERVICE   := camshare.service
SNAP_DIR  ?= /tmp/camshare-snaps

SCRIPTS   := camshare.sh camlight camtune camdetect camgen camshare-conf

# Config is the single source of truth for device names, so ask it rather than
# hardcoding anything here. Falls back to camshare.conf.example in a fresh clone.
CONFQ     := $(CURDIR)/bin/camshare-conf
CAM       ?= $(shell $(CONFQ) cam 2>/dev/null)
DEVICES   := $(shell $(CONFQ) devices 2>/dev/null)
FIRST_DEV := $(firstword $(DEVICES))
CAMLIGHT  ?= $(PREFIX)/camlight
CAMTUNE   ?= $(PREFIX)/camtune
TUNE_PORT ?= $(shell $(CONFQ) get TUNE_PORT 2>/dev/null)

SYSTEMCTL := systemctl --user

.PHONY: help
help: ## Show this help
	@echo "camshare -- share one USB camera with several apps at once"
	@echo
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
	  | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'
	@echo
	@echo "config: $(CONF)"
	@echo "camera: $(CAM)   virtual: $(DEVICES)"

# ------------------------------------------------------------------ setup ---

.PHONY: detect
detect: ## Find your camera and write a config for it
	@./bin/camdetect --output $(CONF) $(ARGS)

.PHONY: config
config: ## Show the resolved configuration
	@$(CONFQ) dump

.PHONY: install
install: ## Install scripts + user service, then start it
	@mkdir -p $(CONF_DIR)
	@test -f $(CONF) || { cp camshare.conf.example $(CONF); \
	  echo "seeded $(CONF) -- run 'make detect' to fill in your camera"; }
	@for s in $(SCRIPTS); do install -Dm755 bin/$$s $(PREFIX)/$$s; done
	@install -Dm644 systemd/$(SERVICE) $(UNIT_DIR)/$(SERVICE)
	@$(SYSTEMCTL) daemon-reload
	@$(SYSTEMCTL) enable --now $(SERVICE)
	@echo "installed -> $(PREFIX)/{$(shell echo $(SCRIPTS) | tr ' ' ',')}"
	@$(MAKE) --no-print-directory status

.PHONY: install-system
install-system: ## Generate + install udev rule and module options (sudo, once)
	@./bin/camgen udev     | sudo tee /etc/udev/rules.d/99-camshare.rules >/dev/null
	@./bin/camgen modprobe | sudo tee /etc/modprobe.d/v4l2loopback.conf   >/dev/null
	@./bin/camgen modules  | sudo tee /etc/modules-load.d/v4l2loopback.conf >/dev/null
	@sudo udevadm control --reload-rules && sudo udevadm trigger --subsystem-match=video4linux
	@echo
	@echo "Installed. Reboot, or load the module now with:"
	@echo "  sudo modprobe -r v4l2loopback; sudo modprobe v4l2loopback"
	@echo
	@echo "Do NOT reload v4l2loopback while your video apps are running: the"
	@echo "loopbacks vanish for a moment and the apps grab the real camera instead."

.PHONY: uninstall
uninstall: ## Stop the service and remove the user-scope files
	-@$(SYSTEMCTL) disable --now $(SERVICE)
	-@for s in $(SCRIPTS); do rm -f $(PREFIX)/$$s; done
	-@rm -f $(UNIT_DIR)/$(SERVICE)
	@$(SYSTEMCTL) daemon-reload
	@echo "removed. config kept at $(CONF); system files see uninstall-system"

.PHONY: uninstall-system
uninstall-system: ## Remove the udev rule and module options (sudo)
	sudo rm -f /etc/udev/rules.d/99-camshare.rules \
	           /etc/modprobe.d/v4l2loopback.conf \
	           /etc/modules-load.d/v4l2loopback.conf
	sudo udevadm control --reload-rules

# ---------------------------------------------------------------- service ---

.PHONY: start stop restart
start: ## Start the fan-out service
	@$(SYSTEMCTL) start $(SERVICE) && $(MAKE) --no-print-directory status

stop: ## Stop the fan-out service
	@$(SYSTEMCTL) stop $(SERVICE)

restart: ## Restart the service (drops the feed for a moment)
	@echo "note: the virtual cameras go quiet briefly -- avoid during a call"
	@$(SYSTEMCTL) restart $(SERVICE) && $(MAKE) --no-print-directory status

.PHONY: status
status: ## Show service state and what each virtual camera is carrying
	@printf 'service   : %s\n' "$$($(SYSTEMCTL) is-active $(SERVICE))"
	@printf 'restarts  : %s\n' "$$($(SYSTEMCTL) show $(SERVICE) -p NRestarts --value)"
	@printf 'camera    : %s -> %s\n' "$(CAM)" "$$(readlink -f $(CAM) 2>/dev/null || echo absent)"
	@for d in $(DEVICES); do \
	  if [ -e "$$d" ]; then \
	    printf '%-13s %s | %s\n' "$$d" \
	      "$$(cat /sys/class/video4linux/$${d##*/}/name 2>/dev/null)" \
	      "$$(v4l2-ctl -d $$d --get-fmt-video 2>/dev/null | sed -n -e "s|.*Width/Height *: *|res |p" -e "s|.*Pixel Format *: *'\([A-Z0-9]*\)'.*|fmt \1|p" | tr '\n' ' ')"; \
	  else printf '%-13s MISSING\n' "$$d"; fi; \
	done

.PHONY: logs
logs: ## Follow the service log
	@journalctl --user -u $(SERVICE) -f -n 50

# --------------------------------------------------------------- lighting ---

.PHONY: day evening auto light set reset controls tune
day: ## Lighting profile: daylight (retune for your room)
	@$(CAMLIGHT) day

evening: ## Lighting profile: lamp-lit room
	@$(CAMLIGHT) evening

auto: ## Hand exposure and white balance back to the camera
	@$(CAMLIGHT) auto

set: ## Set controls by hand: make set ARGS="brightness=150 exposure=800"
	@test -n '$(ARGS)' || { echo 'usage: make set ARGS="brightness=150 wb=4200"'; exit 2; }
	@$(CAMLIGHT) set $(ARGS)

reset: ## Discard manual tweaks, back to the base profile
	@$(CAMLIGHT) reset

controls: ## List every camera control with its range and current value
	@$(CAMLIGHT) controls

light: ## Show the active lighting profile and controls
	@$(CAMLIGHT) status

tune: ## Live preview + sliders in a browser (Ctrl-C to stop)
	@$(CAMTUNE) --port $(TUNE_PORT) --loopback $(FIRST_DEV) \
	            --device $(CAM) --camlight $(CAMLIGHT)

# ------------------------------------------------------------ diagnostics ---

.PHONY: check
check: ## Full diagnostic: devices, holders, controls, USB link
	@echo "=== config ==="; $(CONFQ) dump
	@echo; echo "=== service ==="; $(MAKE) --no-print-directory status
	@echo; echo "=== who holds the real camera ==="; fuser -v $(CAM) 2>&1 || true
	@echo; echo "=== who is reading the virtual cameras ==="
	@for d in $(DEVICES); do echo "--- $$d ---"; fuser -v $$d 2>&1 || true; done
	@echo; echo "=== device caps (want 0x05200001: Video Capture only) ==="
	@for d in $(DEVICES); do \
	  printf '%-13s %s\n' "$$d" "$$(v4l2-ctl -d $$d --info 2>/dev/null | awk -F': *' '/Device Caps/{print $$2; exit}')"; done
	@echo; echo "=== USB link ==="
	@for p in /sys/bus/usb/devices/*/; do \
	  if [ -r "$$p/idVendor" ] && [ "$$(cat $$p/idVendor)" = "$$($(CONFQ) get CAM_VENDOR)" ]; then \
	    printf '%s: USB %s at %s Mb/s\n' "$$(cat $$p/product 2>/dev/null)" "$$(cat $$p/version | tr -d ' ')" "$$(cat $$p/speed)"; \
	  fi; done
	@echo; echo "=== lighting ==="; $(MAKE) --no-print-directory light
	@echo; echo "=== cpu ==="
	@pid=$$($(SYSTEMCTL) show $(SERVICE) -p MainPID --value); \
	  [ "$$pid" != 0 ] && ps -o pid,etime,time,%cpu,rss,comm -p $$pid || echo "not running"

.PHONY: fps
fps: ## Measure the frame rate actually delivered
	@s=$$(date +%s.%N); \
	 gst-launch-1.0 -q v4l2src device=$(FIRST_DEV) num-buffers=120 ! fakesink 2>/dev/null; \
	 e=$$(date +%s.%N); \
	 echo "$(FIRST_DEV): $$(echo "120/($$e-$$s)" | bc -l | cut -c1-5) fps over 120 frames"

.PHONY: snapshot
snapshot: ## Grab a frame off a virtual camera (no contention with the apps)
	@mkdir -p $(SNAP_DIR)
	@rm -f $(SNAP_DIR)/snap_*.jpg
	@gst-launch-1.0 -q v4l2src device=$(FIRST_DEV) num-buffers=20 \
	  ! videoconvert ! jpegenc quality=95 ! multifilesink location=$(SNAP_DIR)/snap_%03d.jpg 2>/dev/null
	@f=$$(ls $(SNAP_DIR)/snap_*.jpg | tail -1); mv "$$f" $(SNAP_DIR)/latest.jpg; rm -f $(SNAP_DIR)/snap_*.jpg
	@echo "wrote $(SNAP_DIR)/latest.jpg"

.PHONY: formats
formats: ## List the resolutions and frame rates the camera supports
	@v4l2-ctl -d $(CAM) --list-formats-ext

.PHONY: generated
generated: ## Print the udev rule and module options that would be installed
	@./bin/camgen all

# ------------------------------------------------------------------- repo ---

.PHONY: diff
diff: ## Show how the installed copies differ from this repo
	@for s in $(SCRIPTS); do \
	  diff -u bin/$$s $(PREFIX)/$$s >/dev/null 2>&1 || { echo "--- $$s ---"; diff -u bin/$$s $(PREFIX)/$$s || true; }; \
	done
	@diff -u systemd/$(SERVICE) $(UNIT_DIR)/$(SERVICE) >/dev/null 2>&1 || \
	  { echo "--- $(SERVICE) ---"; diff -u systemd/$(SERVICE) $(UNIT_DIR)/$(SERVICE) || true; }
	@echo "(no output above means the repo matches what is installed)"

.PHONY: sync
sync: ## Copy the live installed files back into this repo
	@for s in $(SCRIPTS); do cp $(PREFIX)/$$s bin/$$s; done
	@cp $(UNIT_DIR)/$(SERVICE) systemd/$(SERVICE)
	@echo "repo updated from $(PREFIX) and $(UNIT_DIR)"

.PHONY: lint
lint: ## Syntax-check the shell scripts and camtune
	@for f in bin/camshare.sh bin/camlight bin/camdetect bin/camgen bin/camshare-conf; do \
	  bash -n $$f && echo "$$f OK"; done
	@python3 -m py_compile bin/camtune && echo "bin/camtune OK"
	@rm -rf bin/__pycache__
	@command -v shellcheck >/dev/null \
	  && shellcheck -e SC1090,SC1091 bin/camshare.sh bin/camlight bin/camdetect bin/camgen bin/camshare-conf \
	  || echo "(shellcheck not installed -- skipped)"
