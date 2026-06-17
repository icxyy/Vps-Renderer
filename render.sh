#!/usr/bin/env bash
###############################################################################
# render.sh — Headless ReplayMod renderer for CPU-only VPS (software OpenGL).
#
#   ./render.sh --input replay.mcpr [options]
#
# Options:
#   -i, --input   FILE     .mcpr file (required)
#   -o, --output  FILE     output video (default: OUTPUT_DIR/<name>.mp4)
#   -s, --shader  PACK     shaderpack .zip ka path (Iris). No-GPU pe slow!
#   -r, --res     WxH      resolution override (warna auto)
#   -f, --fps     N        output fps (default 60)
#   -t, --timeline ID      kaunsa saved timeline render karna hai (default: pehla)
#       --dry-run          sirf detect + plan dikhao, render mat karo
#   -h, --help
#
# Ye script specs detect karta hai, settings auto-tune karta hai, Xvfb +
# llvmpipe software GL set karta hai, Minecraft ko headless launch karta hai
# AutoRender mod ke through, aur final video utha leta hai.
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/detect.sh
source "$SCRIPT_DIR/lib/detect.sh"
# shellcheck source=lib/autotune.sh
source "$SCRIPT_DIR/lib/autotune.sh"
# shellcheck source=config/render.conf
[ -f "$SCRIPT_DIR/config/render.conf" ] && source "$SCRIPT_DIR/config/render.conf"

# ---------- pretty logging ----------
c_reset=$'\e[0m'; c_blue=$'\e[34m'; c_green=$'\e[32m'; c_yellow=$'\e[33m'; c_red=$'\e[31m'
log()  { printf '%s[*]%s %s\n' "$c_blue"  "$c_reset" "$*"; }
ok()   { printf '%s[+]%s %s\n' "$c_green" "$c_reset" "$*"; }
warn() { printf '%s[!]%s %s\n' "$c_yellow" "$c_reset" "$*" >&2; }
die()  { printf '%s[x]%s %s\n' "$c_red"   "$c_reset" "$*" >&2; exit 1; }

# ---------- args ----------
OPT_INPUT=""; OPT_OUTPUT=""; OPT_SHADER=""; OPT_RES=""; OPT_FPS=""
OPT_TIMELINE=""; OPT_DRYRUN=0
while [ $# -gt 0 ]; do
    case "$1" in
        -i|--input)    OPT_INPUT="$2"; shift 2;;
        -o|--output)   OPT_OUTPUT="$2"; shift 2;;
        -s|--shader)   OPT_SHADER="$2"; shift 2;;
        -r|--res)      OPT_RES="$2"; shift 2;;
        -f|--fps)      OPT_FPS="$2"; shift 2;;
        -t|--timeline) OPT_TIMELINE="$2"; shift 2;;
        --dry-run)     OPT_DRYRUN=1; shift;;
        -h|--help)     grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
        *) die "unknown arg: $1";;
    esac
done
export OPT_SHADER OPT_RES OPT_FPS   # autotune inhe dekhta hai

[ -n "$OPT_INPUT" ] || die "--input <file.mcpr> chahiye. --help dekho."
[ -f "$OPT_INPUT" ] || die "input file nahi mila: $OPT_INPUT"
case "$OPT_INPUT" in *.mcpr) ;; *) warn ".mcpr extension nahi hai, phir bhi try kar raha hu";; esac
OPT_INPUT="$(cd "$(dirname "$OPT_INPUT")" && pwd)/$(basename "$OPT_INPUT")"

###############################################################################
# 1. Detect + tune
###############################################################################
log "Hardware detect kar raha hu..."
detect_specs "$PWD"
print_specs

# .mcpr ke andar se duration nikalo (metaData.json -> "duration": ms)
parse_duration_ms() {
    local meta dur
    meta="$(unzip -p "$1" metaData.json 2>/dev/null || true)"
    dur="$(printf '%s' "$meta" | grep -oE '"duration"[ ]*:[ ]*[0-9]+' | grep -oE '[0-9]+' | head -1)"
    echo "${dur:-0}"
}
DUR_MS="$(parse_duration_ms "$OPT_INPUT")"

echo
log "Settings auto-tune kar raha hu..."
autotune
print_tune "$DUR_MS"

if [ "$DET_GPU" = 0 ]; then
    ok "Software OpenGL mode (llvmpipe) — GL 4.6 override on, shaders supported but slow."
fi
if [ "$TUNE_SHADER_WARN" = 1 ]; then
    warn "Shaders + NO GPU detected. Render bohot dheema hoga (seconds/frame)."
    warn "Agar ETA pagal lage to --res 1280x720 ya bina --shader try karo."
fi
if [ "$TUNE_LOW_RAM" = 1 ]; then
    warn "RAM 4GB se kam — heap ${TUNE_HEAP_MB}MB. Crash ho to resolution kam karo."
fi

if [ "$OPT_DRYRUN" = 1 ]; then
    echo; ok "Dry run — plan upar hai. Render skip kiya."
    exit 0
fi

###############################################################################
# 2. Resolve paths / preconditions
###############################################################################
command -v Xvfb     >/dev/null || die "Xvfb missing — setup.sh chalao ya 'sudo apt install xvfb'"
command -v unzip    >/dev/null || die "unzip missing — 'sudo apt install unzip'"

LAUNCHER="${LAUNCHER:-portablemc}"
case "$LAUNCHER" in
    portablemc)
        command -v portablemc >/dev/null \
            || die "portablemc nahi mila — pehle ./setup.sh chalao (ya 'pipx install portablemc')."
        # setup.sh dwara banaya instance dir = game dir (mods/, replay_*/ yahin)
        MC_DIR="${INSTANCE_DIR:-$HOME/mc/render-instance}"
        [ -d "$MC_DIR" ] \
            || die "Instance dir nahi mila: $MC_DIR — pehle ./setup.sh chalao."
        ;;
    prism)
        [ -x "$PRISM_BIN" ] || command -v "$PRISM_BIN" >/dev/null \
            || die "PrismLauncher nahi mila: $PRISM_BIN (config/render.conf me PRISM_BIN set karo)"
        if [ -z "${MC_DIR:-}" ]; then
            for base in \
                "$HOME/.local/share/PrismLauncher/instances/$PRISM_INSTANCE" \
                "$HOME/.var/app/org.prismlauncher.PrismLauncher/data/PrismLauncher/instances/$PRISM_INSTANCE"; do
                for sub in ".minecraft" "minecraft"; do
                    [ -d "$base/$sub" ] && MC_DIR="$base/$sub" && break 2
                done
            done
        fi
        [ -n "${MC_DIR:-}" ] && [ -d "$MC_DIR" ] \
            || die "MC_DIR auto-detect fail. config/render.conf me MC_DIR set karo."
        ;;
    *) die "unknown LAUNCHER: $LAUNCHER (portablemc ya prism)";;
esac
ok "Launcher: $LAUNCHER  |  game dir: $MC_DIR"

mkdir -p "$OUTPUT_DIR"
OUT_NAME="$(basename "${OPT_INPUT%.mcpr}")"
[ -n "$OPT_OUTPUT" ] || OPT_OUTPUT="$OUTPUT_DIR/${OUT_NAME}.mp4"

###############################################################################
# 3. .mcpr ko instance me copy + configs likho
###############################################################################
REPLAY_DIR="$MC_DIR/replay_recordings"
RENDER_OUT_DIR="$MC_DIR/replay_videos"
mkdir -p "$REPLAY_DIR" "$RENDER_OUT_DIR"
cp -f "$OPT_INPUT" "$REPLAY_DIR/"
REPLAY_BASENAME="$(basename "$OPT_INPUT")"
ok "Replay copied: $REPLAY_DIR/$REPLAY_BASENAME"

# ---- options.txt (resolution, render distance, fps) ----
write_option() {  # key value file
    local key="$1" val="$2" f="$3"
    [ -f "$f" ] || touch "$f"
    if grep -q "^${key}:" "$f" 2>/dev/null; then
        sed -i "s|^${key}:.*|${key}:${val}|" "$f"
    else
        echo "${key}:${val}" >> "$f"
    fi
}
OPTS="$MC_DIR/options.txt"
write_option "overrideWidth"   "$TUNE_W"            "$OPTS"
write_option "overrideHeight"  "$TUNE_H"            "$OPTS"
write_option "renderDistance"  "$TUNE_RENDER_DIST"  "$OPTS"
write_option "maxFps"          "260"               "$OPTS"
write_option "graphicsMode"    "1"                 "$OPTS"
write_option "gamma"           "1.0"               "$OPTS"
ok "options.txt tuned"

# ---- shaderpack copy + Iris config ----
if [ -n "$OPT_SHADER" ]; then
    [ -f "$OPT_SHADER" ] || die "shaderpack nahi mila: $OPT_SHADER"
    mkdir -p "$MC_DIR/shaderpacks"
    cp -f "$OPT_SHADER" "$MC_DIR/shaderpacks/"
    SHADER_NAME="$(basename "$OPT_SHADER")"
    mkdir -p "$MC_DIR/config"
    cat > "$MC_DIR/config/iris.properties" <<EOF
enableShaders=true
shaderPack=$SHADER_NAME
EOF
    ok "Shaderpack set: $SHADER_NAME (Iris enabled)"
fi

# ---- AutoRender mod config: kya load karna hai + settings ----
AR_CFG_DIR="$MC_DIR/config"
mkdir -p "$AR_CFG_DIR"
DONE_MARKER="$RENDER_OUT_DIR/.autorender_done"
rm -f "$DONE_MARKER"
cat > "$AR_CFG_DIR/autorender.properties" <<EOF
# render.sh dwara generate — ise haath se mat chhedo
replay=$REPLAY_BASENAME
timeline=${OPT_TIMELINE}
width=$TUNE_W
height=$TUNE_H
fps=$TUNE_FPS
outputDir=$RENDER_OUT_DIR
doneMarker=$DONE_MARKER
quitWhenDone=true
EOF
ok "AutoRender config likha"

###############################################################################
# 4. Software-GL + JVM env, Xvfb start
###############################################################################
export DISPLAY=":${XVFB_DISPLAY}"
if [ "$DET_GPU" = 0 ]; then
    export LIBGL_ALWAYS_SOFTWARE=1
    export GALLIUM_DRIVER=llvmpipe
    export MESA_GL_VERSION_OVERRIDE=4.6
    export MESA_GLSL_VERSION_OVERRIDE=460
    export LP_NUM_THREADS="$TUNE_LP_THREADS"
fi
# JVM heap — _JAVA_OPTIONS har JVM launch pe apply hota hai (launcher-independent).
export _JAVA_OPTIONS="-Xmx${TUNE_HEAP_MB}M -Xms${TUNE_HEAP_MB}M -XX:ActiveProcessorCount=${DET_CORES}"

XVFB_PID=""
cleanup() {
    [ -n "$XVFB_PID" ] && kill "$XVFB_PID" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

log "Xvfb start kar raha hu @ ${DISPLAY} (${TUNE_W}x${TUNE_H})..."
Xvfb "$DISPLAY" -screen 0 "${TUNE_W}x${TUNE_H}x24" -nolisten tcp >/dev/null 2>&1 &
XVFB_PID=$!
sleep 2
kill -0 "$XVFB_PID" 2>/dev/null || die "Xvfb start nahi hua"
ok "Xvfb up (pid $XVFB_PID)"

###############################################################################
# 5. Minecraft headless launch + render-done monitor
###############################################################################
LOG_FILE="$OUTPUT_DIR/${OUT_NAME}.render.log"
MC_VERSION="${MC_VERSION:-26.1.2}"
LOADER_VERSION="${LOADER_VERSION:-0.19.3}"
MC_USERNAME="${MC_USERNAME:-RenderBot}"

# Launcher ke hisaab se command banao
case "$LAUNCHER" in
    portablemc)
        log "Minecraft launch via portablemc (fabric:${MC_VERSION}:${LOADER_VERSION})... log: $LOG_FILE"
        ( portablemc --main-dir "$MC_DIR" --work-dir "$MC_DIR" \
            start -u "$MC_USERNAME" --resolution "${TUNE_W}x${TUNE_H}" \
            "fabric:${MC_VERSION}:${LOADER_VERSION}" \
            >"$LOG_FILE" 2>&1 ; echo "MC_EXIT=$?" >>"$LOG_FILE" ) &
        ;;
    prism)
        log "Minecraft launch via Prism (instance: $PRISM_INSTANCE)... log: $LOG_FILE"
        ( "$PRISM_BIN" -l "$PRISM_INSTANCE" -a "$PRISM_ACCOUNT" \
            >"$LOG_FILE" 2>&1 ; echo "MC_EXIT=$?" >>"$LOG_FILE" ) &
        ;;
esac
MC_WRAP_PID=$!

log "Render chal raha hai — done marker ka wait..."
waited=0
while [ ! -f "$DONE_MARKER" ]; do
    if ! kill -0 "$MC_WRAP_PID" 2>/dev/null; then
        warn "Minecraft process exit ho gaya done-marker se pehle. Log dekho: $LOG_FILE"
        break
    fi
    sleep 5
    waited=$(( waited + 5 ))
    if [ "$RENDER_TIMEOUT" -gt 0 ] && [ "$waited" -ge "$RENDER_TIMEOUT" ]; then
        warn "RENDER_TIMEOUT (${RENDER_TIMEOUT}s) hit — abort."
        kill "$MC_WRAP_PID" 2>/dev/null || true
        break
    fi
    [ $(( waited % 60 )) -eq 0 ] && log "  ... ${waited}s elapsed"
done

###############################################################################
# 6. Output collect
###############################################################################
# AutoRender ne done-marker me final file ka path likha hai (agar safal).
FINAL=""
if [ -f "$DONE_MARKER" ]; then
    FINAL="$(head -1 "$DONE_MARKER" 2>/dev/null || true)"
fi
# Fallback: replay_videos me sabse naya mp4
if [ -z "$FINAL" ] || [ ! -f "$FINAL" ]; then
    FINAL="$(ls -t "$RENDER_OUT_DIR"/*.mp4 2>/dev/null | head -1 || true)"
fi

[ -n "$FINAL" ] && [ -f "$FINAL" ] || die "Rendered video nahi mila. Log: $LOG_FILE"
mv -f "$FINAL" "$OPT_OUTPUT"
ok "Done! 🎬  Output: $OPT_OUTPUT"
ls -lh "$OPT_OUTPUT" | awk '{print "    size: "$5}'
