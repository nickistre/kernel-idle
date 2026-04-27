#!/bin/bash

# ==============================================================================
# kernel-idle: Advanced SDDM Power Management
# Description: Turns off the display and suspends the system when idle on the 
#              login screen (SDDM). Yields control to KDE once a user logs in.
# ==============================================================================

# --- CONFIGURATION & INITIALIZATION ---
# Fallback defaults IN MINUTES (used strictly if KDE config is missing or inaccessible)
AC_DPMS=10
AC_SUSPEND=30
BAT_DPMS=5
BAT_SUSPEND=10
LOWBAT_DPMS=2
LOWBAT_SUSPEND=5

# --- INTERNAL CONVERSION ---
# Convert user-defined minutes to seconds for internal engine calculations
AC_DPMS=$((AC_DPMS * 60))
AC_SUSPEND=$((AC_SUSPEND * 60))
BAT_DPMS=$((BAT_DPMS * 60))
BAT_SUSPEND=$((BAT_SUSPEND * 60))
LOWBAT_DPMS=$((LOWBAT_DPMS * 60))
LOWBAT_SUSPEND=$((LOWBAT_SUSPEND * 60))

STAGE=0
CONFIG_SOURCE="Fallback"
LAST_LOG_STATE=""
LAST_LOG_PROFILE=""

# Heartbeat Engine Variables (Prevents blocking I/O during input polling)
IDLE_TIME=0
POLL_INTERVAL=5

STATE_DIR="/run/kernel-idle"
mkdir -p "$STATE_DIR"
chmod 0700 "$STATE_DIR"

# Single-instance execution lock to prevent race conditions
LOCK_FILE="$STATE_DIR/lock"
exec 200>"$LOCK_FILE"
flock -n 200 || { echo "kernel-idle: Another instance is running. Exiting."; exit 1; }

echo "kernel-idle: Service initializing..."

# Generate the external Python polling script
# Includes graceful SIGTERM handling to prevent Bash "Terminated" log spam
POLL_SCRIPT="$STATE_DIR/poll.py"
cat << 'EOF' > "$POLL_SCRIPT"
import select, sys, glob, signal

# Gracefully handle systemctl stop signals to prevent bash log spam
signal.signal(signal.SIGTERM, lambda s, f: sys.exit(124))

paths = glob.glob('/dev/input/by-path/*-event-kbd') + glob.glob('/dev/input/by-path/*-event-mouse')
paths = list(set(paths))
fds = []
for p in paths:
    try: fds.append(open(p, 'rb'))
    except: pass
if not fds:
    sys.exit(124)
try:
    interval = float(sys.argv[1])
    ready, _, _ = select.select(fds, [], [], interval)
except:
    ready = False
for f in fds: f.close()
sys.exit(0 if ready else 124)
EOF

# --- STARTUP CONFIGURATION SYNC ---
# Identify the primary human user (UID >= 1000) to fetch valid KDE Plasma settings
HUMAN_USER=$(awk -F: '$3 >= 1000 && $6 != "" && $6 ~ /^\/home\// {print $1}' /etc/passwd | head -n 1)
USER_HOME=$(getent passwd "$HUMAN_USER" 2>/dev/null | cut -d: -f6)

if [ -n "$USER_HOME" ] && [ -d "$USER_HOME" ]; then
    if [ -s "$USER_HOME/.config/powerdevilrc" ]; then
        CONF_FILE="$USER_HOME/.config/powerdevilrc"
        
        extract_timeout() {
            local profile=$1
            local target=$2
            local val=""
            if [ "$target" = "dpms" ]; then
                val=$(grep -A 5 "^\[$profile\]\[Display\]" "$CONF_FILE" | grep -m 1 "^TurnOffDisplayIdleTimeoutSec=" | cut -d= -f2)
            else
                val=$(grep -A 5 "^\[$profile\]\[SuspendAndShutdown\]" "$CONF_FILE" | grep -m 1 "^AutoSuspendIdleTimeoutSec=" | cut -d= -f2)
            fi
            echo "$val"
        }

        # Parse configuration values for all power states
        PARSED_AC_DPMS=$(extract_timeout "AC" "dpms")
        PARSED_AC_SUSP=$(extract_timeout "AC" "suspend")
        PARSED_BAT_DPMS=$(extract_timeout "Battery" "dpms")
        PARSED_BAT_SUSP=$(extract_timeout "Battery" "suspend")
        PARSED_LOWBAT_DPMS=$(extract_timeout "LowBattery" "dpms")
        PARSED_LOWBAT_SUSP=$(extract_timeout "LowBattery" "suspend")

        # Validate and apply extracted configuration
        if [ -n "$PARSED_AC_DPMS" ] || [ -n "$PARSED_AC_SUSP" ] || [ -n "$PARSED_BAT_DPMS" ] || [ -n "$PARSED_BAT_SUSP" ]; then
            CONFIG_SOURCE="KDE Plasma"
        fi

        [ -n "$PARSED_AC_DPMS" ] && [ "$PARSED_AC_DPMS" -gt 0 ] && AC_DPMS=$PARSED_AC_DPMS
        [ -n "$PARSED_AC_SUSP" ] && [ "$PARSED_AC_SUSP" -gt 0 ] && AC_SUSPEND=$PARSED_AC_SUSP
        [ -n "$PARSED_BAT_DPMS" ] && [ "$PARSED_BAT_DPMS" -gt 0 ] && BAT_DPMS=$PARSED_BAT_DPMS
        [ -n "$PARSED_BAT_SUSP" ] && [ "$PARSED_BAT_SUSP" -gt 0 ] && BAT_SUSPEND=$PARSED_BAT_SUSP
        [ -n "$PARSED_LOWBAT_DPMS" ] && [ "$PARSED_LOWBAT_DPMS" -gt 0 ] && LOWBAT_DPMS=$PARSED_LOWBAT_DPMS
        [ -n "$PARSED_LOWBAT_SUSP" ] && [ "$PARSED_LOWBAT_SUSP" -gt 0 ] && LOWBAT_SUSPEND=$PARSED_LOWBAT_SUSP
    fi
fi

# Log the finalized synchronization state explicitly (Converted back to minutes for log readability)
if [ "$CONFIG_SOURCE" = "Fallback" ]; then
    echo "kernel-idle: Startup Config [$CONFIG_SOURCE] -> AC[Disp:$((AC_DPMS / 60))m | Susp:$((AC_SUSPEND / 60))m] BAT[Disp:$((BAT_DPMS / 60))m | Susp:$((BAT_SUSPEND / 60))m] LOW[Disp:$((LOWBAT_DPMS / 60))m | Susp:$((LOWBAT_SUSPEND / 60))m] (No config found for: $HUMAN_USER)"
else
    echo "kernel-idle: Startup Config [$CONFIG_SOURCE] -> AC[Disp:$((AC_DPMS / 60))m | Susp:$((AC_SUSPEND / 60))m] BAT[Disp:$((BAT_DPMS / 60))m | Susp:$((BAT_SUSPEND / 60))m] LOW[Disp:$((LOWBAT_DPMS / 60))m | Susp:$((LOWBAT_SUSPEND / 60))m] (User: $HUMAN_USER)"
fi

# Detect desktop chassis once at startup to handle UPS-backed desktops correctly
CHASSIS_TYPE=$(cat /sys/class/dmi/id/chassis_type 2>/dev/null)
case "$CHASSIS_TYPE" in
    3|4|5|6|7|15|16|17|23|24) IS_DESKTOP=1 ;;
    *) IS_DESKTOP=0 ;;
esac

# --- DISPLAY HARDWARE CONTROL ---

DPMS_SCRIPT="/usr/local/bin/kde-dpms.py"

# Runs kde-dpms.py inside the active SDDM greeter's Wayland session.
run_dpms() {
    local sddm_uid runtime wayland_display
    sddm_uid=$(id -u sddm 2>/dev/null) || return 1
    runtime="/run/user/$sddm_uid"
    [ -d "$runtime" ] || return 1
    wayland_display=$(basename "$(ls -1 "$runtime"/wayland-* 2>/dev/null | grep -v '\.lock$' | head -n1)" 2>/dev/null)
    [ -n "$wayland_display" ] || return 1
    runuser -u sddm -- env \
        XDG_RUNTIME_DIR="$runtime" \
        WAYLAND_DISPLAY="$wayland_display" \
        python3 "$DPMS_SCRIPT" "$1" >/dev/null 2>&1
}

turn_off_display() {
    if run_dpms off; then
        echo "kernel-idle: Display off via org_kde_kwin_dpms."
    else
        echo "kernel-idle: WARNING - DPMS off failed; display may remain on."
    fi
}

turn_on_display() {
    run_dpms on || true
}

# --- LIFECYCLE MANAGEMENT ---
cleanup_and_exit() {
    # Disable traps to prevent double execution
    trap - EXIT SIGTERM SIGINT SIGQUIT
    echo "kernel-idle: Termination signal caught. Restoring display state..."
    turn_on_display
    rm -rf "$STATE_DIR" 2>/dev/null
    exit 0
}
trap cleanup_and_exit EXIT SIGTERM SIGINT SIGQUIT

# --- MAIN EVENT LOOP ---
while true; do
    # 1. Modern loginctl session parsing
    ACTIVE_SESSION=$(loginctl show-seat seat0 -p ActiveSession --value 2>/dev/null)

    if [ -n "$ACTIVE_SESSION" ]; then
        ACTIVE_USER=$(loginctl show-session "$ACTIVE_SESSION" -p Name --value 2>/dev/null)
    else
        ACTIVE_USER=""
    fi

    # Core Logic Gatekeeper: Execute strictly if NO human user is logged in
    if [ "$ACTIVE_USER" = "plasmalogin" ] || [ "$ACTIVE_USER" = "sddm" ] || [ -z "$ACTIVE_USER" ] || [ $STAGE -eq 1 ]; then

        # Detect Handover Event (User Logged Off)
        if [ "$LAST_LOG_STATE" != "ACTIVE" ]; then
            LAST_LOG_STATE="ACTIVE"
            JUST_TOOK_CONTROL=1
        else
            JUST_TOOK_CONTROL=0
        fi

        # 2. Dynamic Power & Battery State Detection
        POWER_STATE=$(grep -h . /sys/class/power_supply/A*/online 2>/dev/null | head -n1)
        [ -z "$POWER_STATE" ] && POWER_STATE=$(grep -h . /sys/class/power_supply/*/online 2>/dev/null | head -n1)
        HAS_BATTERY=$(ls -d /sys/class/power_supply/BAT* 2>/dev/null | head -n1)

        if [ "$IS_DESKTOP" -eq 1 ] && [ -z "$HAS_BATTERY" ]; then
            # Desktop with no exposed battery (UPS managed via NUT or hidden) — always AC
            DISPLAY_TIMEOUT=$AC_DPMS
            SUSPEND_TIMEOUT=$AC_SUSPEND
            CURRENT_PROFILE="AC"
        elif [ -n "$HAS_BATTERY" ] && { [ -z "$POWER_STATE" ] || [ "$POWER_STATE" = "0" ]; }; then
            BAT_CAP=$(grep -h . /sys/class/power_supply/BAT*/capacity 2>/dev/null | head -n 1)
            # Low Battery threshold enforced at 20%
            if [ -n "$BAT_CAP" ] && [ "$BAT_CAP" -le 20 ]; then
                DISPLAY_TIMEOUT=$LOWBAT_DPMS
                SUSPEND_TIMEOUT=$LOWBAT_SUSPEND
                CURRENT_PROFILE="LowBattery"
            else
                DISPLAY_TIMEOUT=$BAT_DPMS
                SUSPEND_TIMEOUT=$BAT_SUSPEND
                CURRENT_PROFILE="Battery"
            fi
        else
            DISPLAY_TIMEOUT=$AC_DPMS
            SUSPEND_TIMEOUT=$AC_SUSPEND
            CURRENT_PROFILE="AC"
        fi

        # 3. State Machine Logging & Timer Management

        # SCENARIO 1: Script took control due to user logoff (Physical Input Event)
        if [ "$JUST_TOOK_CONTROL" -eq 1 ]; then
            echo "kernel-idle: No active user session (SDDM). Took control with '$CURRENT_PROFILE' profile. Timer starting fresh at 0s -> Display: $((DISPLAY_TIMEOUT / 60))m, Suspend: $((SUSPEND_TIMEOUT / 60))m"
            IDLE_TIME=0
            LAST_LOG_PROFILE="$CURRENT_PROFILE"
        fi

        # SCENARIO 2: Physical power state changed while waiting in SDDM
        if [ "$LAST_LOG_PROFILE" != "$CURRENT_PROFILE" ] && [ "$JUST_TOOK_CONTROL" -eq 0 ]; then
            echo "kernel-idle: Power state changed to '$CURRENT_PROFILE'. Resetting timer. Timeouts -> Display: $((DISPLAY_TIMEOUT / 60))m, Suspend: $((SUSPEND_TIMEOUT / 60))m"
            IDLE_TIME=0
            LAST_LOG_PROFILE="$CURRENT_PROFILE"
        fi

        # 4. Hardware Input Listener (Heartbeat Engine - External File Execution)
        python3 "$POLL_SCRIPT" "$POLL_INTERVAL"
        EXIT_CODE=$?

        # --- TICK-BASED STATE MACHINE DISPATCHER ---
        if [ $EXIT_CODE -eq 0 ]; then
            # Input detected within the polling interval
            IDLE_TIME=0
            if [ $STAGE -eq 1 ]; then
                echo "kernel-idle: Hardware input detected. Restoring display state."
                turn_on_display
                STAGE=0
            fi
            sleep 1
        elif [ $EXIT_CODE -eq 124 ]; then
            # Polling interval passed without user input
            IDLE_TIME=$((IDLE_TIME + POLL_INTERVAL))

            if [ $STAGE -eq 0 ] && [ $IDLE_TIME -ge $DISPLAY_TIMEOUT ]; then
                echo "kernel-idle: Display idle timeout ($((DISPLAY_TIMEOUT / 60))m) reached. Turning off display."
                turn_off_display
                STAGE=1
            elif [ $STAGE -eq 1 ] && [ $IDLE_TIME -ge $SUSPEND_TIMEOUT ]; then
                echo "kernel-idle: Suspend idle timeout ($((SUSPEND_TIMEOUT / 60))m) reached. Preparing for suspend."
                sync

                # Restore display before suspend so the greeter is in a sane state on resume
                turn_on_display

                # Execute kernel suspend safely without wall messages
                systemctl suspend --no-wall

                # Post-suspend delay to allow GPU and driver re-initialization
                sleep 3
                echo "kernel-idle: System resumed. Restoring display state."
                turn_on_display
                STAGE=0
                IDLE_TIME=0
            fi
        else
            # Safeguard: Python script failed/crashed
            echo "kernel-idle: Warning - Input listener encountered an unexpected error. Retrying..."
            sleep $POLL_INTERVAL
        fi
    else
        # A human user has logged in. Yield hardware control to the desktop environment.
        if [ "$LAST_LOG_STATE" != "YIELDED" ]; then
            # Safety Net: Ensure display is physically restored before KDE takes over
            if [ $STAGE -eq 1 ]; then
                echo "kernel-idle: Display was off. Restoring before yielding control..."
                turn_on_display
            fi
            echo "kernel-idle: User '$ACTIVE_USER' is logged in. Yielding power management to KDE."
            LAST_LOG_STATE="YIELDED"
        fi

        # Reset script states entirely during yield
        STAGE=0
        IDLE_TIME=0
        sleep 10
    fi
done
