#!/usr/bin/env bash
###############################################################################
# setup.sh — VPS ko ek command me render-ready bana deta hai (GUI bilkul nahi).
#
#   ./setup.sh
#
# Kya karta hai:
#   1. System deps install (Xvfb, Mesa software GL, unzip, python, ffmpeg...)
#   2. portablemc install (CLI launcher — koi GUI instance setup nahi)
#   3. Minecraft 26.1.2 + Fabric loader ko non-interactively provision karta hai
#   4. mods/ replay_recordings/ replay_videos/ shaderpacks/ config/ banata hai
#   5. AutoRender mod build karne ki koshish (best-effort; fail ho to skip)
#
# Iske baad tu sirf apne mods (Fabric API, ReplayMod, Iris+Sodium) instance ke
# mods/ folder me daal — phir ./render.sh chala.
#
# Options:
#   --dir DIR        instance/game dir (default: ~/mc/render-instance)
#   --mc VERSION     minecraft version (default: 26.1.2)
#   --loader VER     fabric loader version (default: 0.19.3)
#   --user NAME      offline username (default: RenderBot)
#   --no-deps        system package install skip karo
#   --no-mod-build   AutoRender mod build skip karo
#   -h, --help
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

c_reset=$'\e[0m'; c_blue=$'\e[34m'; c_green=$'\e[32m'; c_yellow=$'\e[33m'; c_red=$'\e[31m'
log()  { printf '%s[*]%s %s\n' "$c_blue"  "$c_reset" "$*"; }
ok()   { printf '%s[+]%s %s\n' "$c_green" "$c_reset" "$*"; }
warn() { printf '%s[!]%s %s\n' "$c_yellow" "$c_reset" "$*" >&2; }
die()  { printf '%s[x]%s %s\n' "$c_red"   "$c_reset" "$*" >&2; exit 1; }

# ---------- args ----------
INSTANCE_DIR="$HOME/mc/render-instance"
MC_VERSION="26.1.2"
LOADER_VERSION="0.19.3"
MC_USER="RenderBot"
DO_DEPS=1
DO_MOD_BUILD=1
GRADLE_VERSION="9.4.0"

while [ $# -gt 0 ]; do
    case "$1" in
        --dir)          INSTANCE_DIR="$2"; shift 2;;
        --mc)           MC_VERSION="$2"; shift 2;;
        --loader)       LOADER_VERSION="$2"; shift 2;;
        --user)         MC_USER="$2"; shift 2;;
        --no-deps)      DO_DEPS=0; shift;;
        --no-mod-build) DO_MOD_BUILD=0; shift;;
        -h|--help)      grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
        *) die "unknown arg: $1";;
    esac
done

# sudo helper
SUDO=""
if [ "$(id -u)" -ne 0 ]; then command -v sudo >/dev/null && SUDO="sudo"; fi

###############################################################################
# 1. System dependencies
###############################################################################
install_deps() {
    log "System dependencies install kar raha hu..."
    if   command -v apt-get >/dev/null; then
        $SUDO apt-get update -y
        $SUDO apt-get install -y \
            xvfb x11-utils libgl1-mesa-dri mesa-utils \
            unzip wget curl ca-certificates ffmpeg \
            python3 python3-pip pipx || warn "kuch apt packages install nahi hue"
        # Java 25 sirf mod BUILD ke liye (game ke liye portablemc khud JRE laata hai)
        $SUDO apt-get install -y openjdk-25-jdk-headless 2>/dev/null \
            || warn "openjdk-25-jdk repo me nahi — mod build ke liye Temurin 25 manually lagana padega."
    elif command -v dnf >/dev/null; then
        $SUDO dnf install -y \
            xorg-x11-server-Xvfb mesa-dri-drivers glx-utils \
            unzip wget curl ffmpeg python3 python3-pip pipx \
            java-25-openjdk-devel 2>/dev/null || warn "kuch dnf packages install nahi hue"
    elif command -v pacman >/dev/null; then
        $SUDO pacman -Sy --noconfirm \
            xorg-server-xvfb mesa mesa-utils \
            unzip wget curl ffmpeg python python-pipx jdk-openjdk \
            || warn "kuch pacman packages install nahi hue"
    elif command -v zypper >/dev/null; then
        $SUDO zypper install -y \
            xorg-x11-server Mesa-dri Mesa-demo-x \
            unzip wget curl ffmpeg python3 python3-pip python3-pipx \
            java-25-openjdk-devel || warn "kuch zypper packages install nahi hue"
    else
        warn "Distro pehchaan nahi paaya — ye manually install karo:"
        warn "  Xvfb, mesa software GL (libgl1-mesa-dri), unzip, wget, ffmpeg, python3-pip, pipx"
    fi
    ok "deps step done"
}
[ "$DO_DEPS" = 1 ] && install_deps || warn "--no-deps: system packages skip"

###############################################################################
# 2. portablemc install
###############################################################################
export PATH="$HOME/.local/bin:$PATH"
install_portablemc() {
    if command -v portablemc >/dev/null; then
        ok "portablemc already installed: $(portablemc --version 2>/dev/null || echo ok)"
        return
    fi
    log "portablemc install kar raha hu..."
    if command -v pipx >/dev/null; then
        pipx install portablemc >/dev/null 2>&1 || pipx install portablemc
        pipx ensurepath >/dev/null 2>&1 || true
    else
        python3 -m pip install --user --upgrade portablemc \
            || die "portablemc install fail — manually: pipx install portablemc"
    fi
    command -v portablemc >/dev/null \
        || die "portablemc PATH me nahi aaya. 'export PATH=\$HOME/.local/bin:\$PATH' kar ke dubara chala."
    ok "portablemc ready"
}
install_portablemc

###############################################################################
# 3. Minecraft + Fabric instance provision (non-interactive, --dry = no launch)
###############################################################################
log "Minecraft ${MC_VERSION} + Fabric ${LOADER_VERSION} provision kar raha hu (dir: $INSTANCE_DIR)..."
mkdir -p "$INSTANCE_DIR"
# --dry: install karo par launch mat karo. portablemc khud sahi Java (25) JRE download karta hai.
if portablemc --main-dir "$INSTANCE_DIR" --work-dir "$INSTANCE_DIR" \
        start --dry -u "$MC_USER" "fabric:${MC_VERSION}:${LOADER_VERSION}"; then
    ok "Minecraft + Fabric installed (portablemc ne JRE bhi download kar liya)"
else
    die "Fabric provision fail. Internet check karo; ya version galat (fabric:${MC_VERSION}:${LOADER_VERSION})."
fi

###############################################################################
# 4. Folders
###############################################################################
for d in mods replay_recordings replay_videos shaderpacks config; do
    mkdir -p "$INSTANCE_DIR/$d"
done
ok "Folders ready: mods/ replay_recordings/ replay_videos/ shaderpacks/ config/"

###############################################################################
# 5. AutoRender mod build (best-effort)
###############################################################################
java_major() {
    command -v java >/dev/null || { echo 0; return; }
    java -version 2>&1 | grep -oE 'version "[0-9]+' | grep -oE '[0-9]+' | head -1
}

build_mod() {
    local jv; jv="$(java_major)"
    if [ "${jv:-0}" -lt 25 ]; then
        warn "JDK 25 nahi mila (current: ${jv:-none}) — AutoRender mod build skip."
        warn "  Mod kahin aur build karke jar ko is folder me daal: $INSTANCE_DIR/mods/"
        return
    fi
    log "AutoRender mod build kar raha hu (JDK ${jv})..."

    local gradle_cmd=""
    if command -v gradle >/dev/null; then
        gradle_cmd="gradle"
    else
        # Gradle 9.4 dist download (wrapper jar repo me nahi)
        local gdir="$SCRIPT_DIR/.gradle-dist/gradle-${GRADLE_VERSION}"
        if [ ! -x "$gdir/bin/gradle" ]; then
            log "Gradle ${GRADLE_VERSION} download..."
            mkdir -p "$SCRIPT_DIR/.gradle-dist"
            wget -q -O "$SCRIPT_DIR/.gradle-dist/g.zip" \
                "https://services.gradle.org/distributions/gradle-${GRADLE_VERSION}-bin.zip" \
                && unzip -q -o "$SCRIPT_DIR/.gradle-dist/g.zip" -d "$SCRIPT_DIR/.gradle-dist" \
                || { warn "Gradle download fail — mod build skip."; return; }
            rm -f "$SCRIPT_DIR/.gradle-dist/g.zip"
        fi
        gradle_cmd="$gdir/bin/gradle"
    fi

    ( cd "$SCRIPT_DIR/mod" && "$gradle_cmd" --no-daemon build ) \
        || { warn "Mod build fail (loom/java mismatch ho sakta hai). Log upar dekho."; return; }

    local jar; jar="$(ls -t "$SCRIPT_DIR"/mod/build/libs/autorender-*.jar 2>/dev/null \
        | grep -v sources | head -1 || true)"
    if [ -n "$jar" ]; then
        cp -f "$jar" "$INSTANCE_DIR/mods/"
        ok "AutoRender mod built + copied: mods/$(basename "$jar")"
    else
        warn "Build hua par jar nahi mila — manually mod/build/libs/ check karo."
    fi
}
[ "$DO_MOD_BUILD" = 1 ] && build_mod || warn "--no-mod-build: skip"

###############################################################################
# 6. render.conf update (instance dir + versions)
###############################################################################
CONF="$SCRIPT_DIR/config/render.conf"
if [ -f "$CONF" ]; then
    log "config/render.conf me values likh raha hu..."
    set_conf() {  # key value
        if grep -qE "^${1}=" "$CONF"; then
            sed -i "s|^${1}=.*|${1}=\"${2}\"|" "$CONF"
        else
            echo "${1}=\"${2}\"" >> "$CONF"
        fi
    }
    set_conf "LAUNCHER" "portablemc"
    set_conf "INSTANCE_DIR" "$INSTANCE_DIR"
    set_conf "MC_VERSION" "$MC_VERSION"
    set_conf "LOADER_VERSION" "$LOADER_VERSION"
    set_conf "MC_USERNAME" "$MC_USER"
    ok "render.conf updated"
fi

###############################################################################
# Done
###############################################################################
echo
ok "SETUP COMPLETE ✅"
AR_STATUS="build/libs se copy karo ya VPS pe build kar"
ls "$INSTANCE_DIR"/mods/autorender-*.jar >/dev/null 2>&1 && AR_STATUS="✓ already copied"
cat <<EOF

  Instance dir : $INSTANCE_DIR
  Mods folder  : $INSTANCE_DIR/mods/
  MC + Fabric  : ${MC_VERSION} / ${LOADER_VERSION}  (Java JRE portablemc ne handle kiya)

  Ab ye mods $INSTANCE_DIR/mods/ me daal (26.1.x builds):
    • Fabric API
    • ReplayMod
    • (optional) Iris + Sodium  — shaders ke liye
    • AutoRender                — ${AR_STATUS}

  Phir render:
    ./render.sh --input /path/to/clip.mcpr --dry-run   # plan + ETA
    ./render.sh --input /path/to/clip.mcpr             # asli render
EOF
