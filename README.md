# kernel-idle: Advanced SDDM Power Management

A deterministic idle monitor that enforces display power-off and suspend policies on the SDDM login screen. It gracefully yields control to KDE Plasma once a user logs in, providing seamless power management across the full session lifecycle.

## Why This Exists

SDDM does not natively honor system power settings when no user is logged in. Existing workarounds often fall short because they:

* Don't work correctly on Wayland — VT switching and fbdev blanking have no effect when kwin_wayland holds DRM master.
* Cause black screens on resume from suspend.
* Trigger false wakes from ACPI events (e.g. a 1% battery fluctuation).
* Block I/O, preventing dynamic adaptation to AC/Battery state changes at the login screen.

## Architecture

`kernel-idle` is a Bash state machine with a small Python footprint for non-blocking input polling and a zero-dependency Python Wayland client for display power control.

### Components

**`kernel-idle.sh`** — the main daemon:
* **Zero-Config Dynamic Sync:** Reads the primary user's KDE Plasma `powerdevilrc` at startup and applies their actual AC, Battery, and Low Battery timeouts. Falls back to built-in defaults if no config is found.
* **Smart Polling:** Uses a 5-second Python `select` heartbeat listening to physical input devices (`/dev/input/by-path/*-event-kbd` and `*-event-mouse`). Ignores ACPI noise; reacts only to real hardware input.
* **Profile Awareness:** Detects chassis type (desktop vs. laptop), battery presence, and AC/battery state, applying the correct timeout profile dynamically.
* **Graceful Handoff:** Yields power management back to the desktop environment when a user logs in, and silently reclaims control after logout.

**`kde-dpms.py`** — a minimal Wayland client that controls display power state directly via kwin's `org_kde_kwin_dpms_manager` Wayland protocol. This is the only reliable path for display blanking on modern KDE Wayland desktops — kscreen-doctor's `--dpms` flag targets a D-Bus interface that does not exist in the SDDM greeter session.

### Why Not fbdev / VT Switching / DDC-CI?

On KMS-only systems (amdgpu, modern Intel/NVIDIA with KMS), several common blanking approaches don't work:

| Approach | Why it fails |
|---|---|
| `/sys/class/graphics/fb*/blank` | No fbdev node on KMS-only drivers |
| `chvt 8` | kwin_wayland retains DRM master regardless of VT switch |
| `kscreen-doctor --dpms off` | Calls a D-Bus path that doesn't exist in the greeter session |
| `ddcutil setvcp d6` | Blanks the monitor but DDC/CI fails immediately after; software wake is impossible |
| `/sys/class/backlight/` | Empty on desktops with external monitors |

`kde-dpms.py` bypasses all of these by speaking the Wayland protocol that kwin actually exposes.

## Compatibility & Requirements

* **Display Manager:** SDDM in Wayland mode (`plasmalogin` / `sddm` greeter user)
* **Compositor:** KWin Wayland (exposes `org_kde_kwin_dpms_manager`)
* **Init system:** systemd (for `loginctl` session tracking and `systemctl suspend`)
* **Python:** 3.6+ (stdlib only — no packages required)
* **Tested on:** Bazzite (Fedora-based), CachyOS, Kubuntu 25.10
* **GPU:** Any KMS driver (amdgpu, i915, nouveau, nvidia-open)

---

## Installation

### 1. Copy the scripts

```bash
sudo cp kernel-idle.sh /usr/local/bin/kernel-idle.sh
sudo cp kde-dpms.py /usr/local/bin/kde-dpms.py
sudo chmod +x /usr/local/bin/kernel-idle.sh
```

### 2. Install the systemd service

```bash
sudo cp kernel-idle.service /etc/systemd/system/kernel-idle.service
```

The service file:

```ini
[Unit]
Description=Kernel Level Hardware Idle Monitor for SDDM
After=display-manager.service

[Service]
Type=simple
ExecStart=/usr/local/bin/kernel-idle.sh
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
```

### 3. Enable and start

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now kernel-idle.service
```

---

## Observability

```bash
journalctl -u kernel-idle.service -f
```

### Example log — full lifecycle

The following shows config sync, display off/on cycles, user login/logout handoff, and a complete suspend/resume cycle.

```text
17:05:23 kernel-idle.sh: Service initializing...
17:05:23 kernel-idle.sh: Startup Config [KDE Plasma] -> AC[Disp:1m | Susp:2m] BAT[Disp:5m | Susp:5m] LOW[Disp:1m | Susp:5m] (User: nick)
17:05:23 kernel-idle.sh: No active user session (SDDM). Took control with 'AC' profile. Timer starting fresh at 0s -> Display: 1m, Suspend: 2m
17:06:25 kernel-idle.sh: Display idle timeout (1m) reached. Turning off display.
17:06:25 kernel-idle.sh: Display off via org_kde_kwin_dpms.
17:07:26 kernel-idle.sh: Suspend idle timeout (2m) reached. Preparing for suspend.
17:07:49 kernel-idle.sh: System resumed. Restoring display state.
17:08:08 kernel-idle.sh: User 'nick' is logged in. Yielding power management to KDE.
17:09:25 kernel-idle.sh: No active user session (SDDM). Took control with 'AC' profile. Timer starting fresh at 0s -> Display: 15m, Suspend: 240m
```
