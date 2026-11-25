#!/system/bin/sh
# gxr-fanctl-focus daemon - drives /sys/class/sec_fan/fan/step from config.
# Runs as root (KernelSU, u:r:ksu:s0).
#
# Fork of BreadDoesStuff/galaxy-xr-modules gxr-fanctl v1.0.0 (MIT). The new
# default MODE=focus runs the fan at FOCUS_STEP (max) only while one of
# FOCUS_PKGS (Steam Link, Virtual Desktop) is the focused app, and otherwise
# falls back to IDLE_MODE (default: stock = Samsung SSRM).

DATA=/data/adb/gxr-fanctl-focus
CONF=$DATA/config.conf
STATUS=$DATA/status
PIDF=$DATA/fand.pid
LOG=$DATA/fand.log
NODE=/sys/devices/virtual/sec_fan/fan/step   # == /sys/class/sec_fan/fan/step
SYSTEM_UID=1000
UPSTREAM_PIDF=/data/adb/gxr-fanctl/fand.pid

mkdir -p $DATA
[ -f $PIDF ] && kill -0 "$(cat $PIDF)" 2>/dev/null && { echo "already running"; exit 0; }
echo $$ > $PIDF
: > $LOG
log() { echo "$(date '+%m-%d %H:%M:%S') $*" >> $LOG; }

[ -e $NODE ] || { log "fan node $NODE missing, exiting"; rm -f $PIDF; exit 1; }

# Two daemons writing the same node would fight; refuse to run next to upstream.
if [ -f $UPSTREAM_PIDF ] && kill -0 "$(cat $UPSTREAM_PIDF)" 2>/dev/null; then
    log "upstream gxr-fanctl daemon is running (pid $(cat $UPSTREAM_PIDF)); disable or remove it. exiting"
    echo "mode=conflict upstream_gxr-fanctl_running" > $STATUS
    rm -f $PIDF; exit 1
fi

# ---- SSRM lock / release (runtime sysfs perms only; reset on reboot) ----
lock_node() {
    [ "$(stat -c %u $NODE)" = "0" ] && return
    chown 0:0 $NODE; chmod 0200 $NODE; log "locked step node (SSRM blocked)"
}
release_node() {
    # Forget what we last wrote so the next locked mode always rewrites the node.
    CUR=-1
    [ "$(stat -c %u $NODE)" = "$SYSTEM_UID" ] && return
    chown $SYSTEM_UID:$SYSTEM_UID $NODE; chmod 0200 $NODE; log "released step node to SSRM"
}

cleanup() { release_node; rm -f $PIDF; echo "mode=stopped" > $STATUS; exit 0; }
trap cleanup TERM INT HUP

# ---- config ----
load_conf() {
    MODE=focus; FIXED_STEP=7; CURVE="36:2 40:3 43:4 46:5 50:6 54:7"; MIN_STEP=1
    HYST=2; INTERVAL=2; SENSORS="cpu-* cpuss-* gpuss-* ddr sys-therm-0"; FAILSAFE_STEP=7
    FOCUS_PKGS="com.valvesoftware.steamlinkvr* virtualdesktop.android* VirtualDesktop.Android*"
    FOCUS_STEP=7; IDLE_MODE=stock; FOCUS_GRACE=10
    [ -f $CONF ] && . $CONF
    case "$INTERVAL" in ''|*[!0-9]*|0) INTERVAL=2;; esac
    case "$HYST" in ''|*[!0-9]*) HYST=2;; esac
    case "$FOCUS_GRACE" in ''|*[!0-9]*) FOCUS_GRACE=10;; esac
    case "$IDLE_MODE" in stock|max|fixed|curve) ;; *) IDLE_MODE=stock;; esac
    FOCUS_STEP=$(clamp_step $FOCUS_STEP)
    resolve_zones
    log "config loaded: MODE=$MODE IDLE=$IDLE_MODE FOCUS_STEP=$FOCUS_STEP GRACE=$FOCUS_GRACE PKGS='$FOCUS_PKGS' FIXED=$FIXED_STEP CURVE='$CURVE' MIN=$MIN_STEP HYST=$HYST INT=$INTERVAL"
}
clamp_step() { case "$1" in [0-7]) echo $1;; *) echo 7;; esac; }

resolve_zones() {
    ZONES=""
    for z in /sys/class/thermal/thermal_zone*; do
        t=$(cat $z/type 2>/dev/null) || continue
        for pat in $SENSORS; do
            case "$t" in $pat)
                v=$(cat $z/temp 2>/dev/null) || break
                case "$v" in ''|*[!0-9-]*) break;; esac
                ZONES="$ZONES $z"; break;;
            esac
        done
    done
}

# Sets TMAX (milli-C) and TSRC; returns 1 if nothing readable.
read_temp() {
    TMAX=-999999; TSRC=none
    for z in $ZONES; do
        v=$(cat $z/temp 2>/dev/null) || continue
        case "$v" in ''|*[!0-9-]*) continue;; esac
        [ "$v" -lt -20000 ] || [ "$v" -gt 150000 ] && continue
        [ "$v" -gt "$TMAX" ] && { TMAX=$v; TSRC=$z; }
    done
    [ "$TSRC" != none ]
}

# step_for <milliC>
step_for() {
    s=$MIN_STEP
    for p in $CURVE; do
        th=${p%%:*}; st=${p##*:}
        [ "$1" -ge $((th * 1000)) ] && s=$st
    done
    [ "$s" -lt "$MIN_STEP" ] && s=$MIN_STEP
    clamp_step $s
}

curve_target() {
    if [ $HAVE_T = 1 ]; then
        TARGET=$(step_for $TMAX)
        if [ "$CUR" -ge 0 ] && [ "$TARGET" -lt "$CUR" ]; then
            d=$(step_for $((TMAX + HYST * 1000)))
            [ "$d" -lt "$CUR" ] && TARGET=$d || TARGET=$CUR
        fi
    else
        TARGET=$(clamp_step $FAILSAFE_STEP)
    fi
}

# ---- focus detection ----
pkg_matches() {
    for p in $FOCUS_PKGS; do case "$1" in $p) return 0;; esac; done
    return 1
}

# Cheap pre-check (reads /proc only): is any FOCUS_PKGS process alive at all?
# Lets us skip the system_server dumpsys entirely when neither app is running.
target_running() {
    for n in $(ps -A -o NAME= 2>/dev/null); do
        pkg_matches "${n%%:*}" && return 0
    done
    return 1
}

# Prints the package of the focused (top resumed) activity, or nothing.
# On I610UEU2AZF3 the dump has "ResumedActivity: ActivityRecord{...}" and
# "mFocusedApp=ActivityRecord{...}"; newer AOSP prints "topResumedActivity=".
focused_pkg() {
    dumpsys activity activities 2>/dev/null \
        | grep -m1 -E '(topResumedActivity=|ResumedActivity: |mFocusedApp=)ActivityRecord[{]' \
        | sed -n 's/.*ActivityRecord{[^ ]* u[0-9]* \([^ /}]*\)\/.*/\1/p'
}

# Sets FOCUSED (0/1) and FPKG. Applies FOCUS_GRACE so a brief focus loss
# (system menu, notification shade, app switch) does not flap the fan.
update_focus() {
    FPKG=-
    now_focused=0
    if target_running; then
        FPKG=$(focused_pkg); [ -n "$FPKG" ] || FPKG=-
        pkg_matches "$FPKG" && now_focused=1
    fi
    if [ $now_focused = 1 ]; then
        LAST_FOCUS=$NOW
        [ $FOCUSED = 1 ] || log "focus gained: $FPKG"
        FOCUSED=1
    elif [ $FOCUSED = 1 ]; then
        if [ $((NOW - LAST_FOCUS)) -ge $FOCUS_GRACE ]; then
            FOCUSED=0; log "focus lost (now: $FPKG)"
        fi
    fi
}

write_step() {
    echo $1 > $NODE 2>/dev/null || { log "write step $1 failed"; return; }
    CUR=$1; LAST_WRITE=$NOW
}

write_status() {
    echo "mode=$MODE$1 step=$2 focus=$FOCUSED fpkg=$FPKG temp=${TMAX:--} src=$(cat $TSRC/type 2>/dev/null || echo -) ts=$NOW" > $STATUS
}

CUR=-1; LAST_WRITE=0; CONF_M=""; FOCUSED=0; LAST_FOCUS=0; FPKG=-
log "fand start pid $$"
while :; do
    m=$(stat -c '%Y.%s.%i' $CONF 2>/dev/null)
    [ "$m" != "$CONF_M" ] && { CONF_M=$m; load_conf; CUR=-1; }
    NOW=$(date +%s)
    [ "$(stat -c %s $LOG 2>/dev/null || echo 0)" -gt 131072 ] && : > $LOG
    TMAX=""; TSRC=""; HAVE_T=0
    if read_temp; then HAVE_T=1; else TMAX=""; TSRC=""; fi

    EFF=$MODE; SUFFIX=""
    if [ "$MODE" = focus ]; then
        update_focus
        if [ $FOCUSED = 1 ]; then EFF=focused; SUFFIX="(active)"
        else EFF=$IDLE_MODE; SUFFIX="(idle:$IDLE_MODE)"; fi
    else
        FOCUSED=0; FPKG=-
    fi

    case "$EFF" in
    stock)
        release_node
        write_status "$SUFFIX" ssrm
        sleep $INTERVAL; continue;;
    focused) TARGET=$FOCUS_STEP;;
    max)     TARGET=7;;
    fixed)   TARGET=$(clamp_step $FIXED_STEP);;
    *)       curve_target;;
    esac

    lock_node
    # write on change, or every 30s as a refresh
    if [ "$TARGET" != "$CUR" ] || [ $((NOW - LAST_WRITE)) -ge 30 ]; then
        [ "$TARGET" != "$CUR" ] && log "step $CUR -> $TARGET ($EFF, T=${TMAX:-?} ${TSRC##*/})"
        write_step $TARGET
    fi
    write_status "$SUFFIX" $CUR
    sleep $INTERVAL
done
