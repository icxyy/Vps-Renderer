#!/usr/bin/env bash
# detect.sh — VPS hardware/OS ko detect karta hai aur env vars export karta hai.
# Source kiya jata hai render.sh se:  source lib/detect.sh ; detect_specs
# Sab values stdout pe nahi, variables me jaati hain (DET_* prefix).

detect_specs() {
    # ---- CPU ----
    DET_CORES="$(nproc 2>/dev/null || echo 2)"
    DET_CPU_MODEL="$(grep -m1 'model name' /proc/cpuinfo 2>/dev/null | cut -d: -f2- | sed 's/^ *//' || echo unknown)"

    # ---- RAM (MB) ----
    if [ -r /proc/meminfo ]; then
        local kb
        kb="$(awk '/^MemTotal:/{print $2}' /proc/meminfo)"
        DET_RAM_MB=$(( kb / 1024 ))
    else
        DET_RAM_MB=2048
    fi

    # ---- Disk free in target dir (MB) ----
    DET_DISK_FREE_MB="$(df -Pm "${1:-$PWD}" 2>/dev/null | awk 'NR==2{print $4}' || echo 0)"

    # ---- Distro ----
    if [ -r /etc/os-release ]; then
        # shellcheck disable=SC1091
        DET_DISTRO="$(. /etc/os-release && echo "${ID:-unknown} ${VERSION_ID:-}")"
    else
        DET_DISTRO="unknown"
    fi

    # ---- GPU detection (teen tareeke, koi bhi hit kare to GPU=1) ----
    DET_GPU=0
    DET_GPU_NAME=""
    DET_GPU_VENDOR=""

    if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1; then
        DET_GPU=1
        DET_GPU_VENDOR="nvidia"
        DET_GPU_NAME="$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)"
    elif [ -d /dev/dri ] && ls /dev/dri/renderD* >/dev/null 2>&1; then
        # render node maujood — par VPS pe ye akser virtio/llvmpipe hi hota hai
        DET_GPU=1
        DET_GPU_VENDOR="dri"
        DET_GPU_NAME="$(ls /dev/dri/renderD* 2>/dev/null | tr '\n' ' ')"
    elif command -v lspci >/dev/null 2>&1; then
        local vga
        vga="$(lspci 2>/dev/null | grep -iE 'vga|3d|display' | grep -ivE 'virtio|cirrus|qxl|vmware|bochs' || true)"
        if [ -n "$vga" ]; then
            DET_GPU=1
            DET_GPU_VENDOR="pci"
            DET_GPU_NAME="$vga"
        fi
    fi

    export DET_CORES DET_CPU_MODEL DET_RAM_MB DET_DISK_FREE_MB DET_DISTRO \
           DET_GPU DET_GPU_NAME DET_GPU_VENDOR
}

print_specs() {
    cat <<EOF
  CPU      : ${DET_CORES} cores  (${DET_CPU_MODEL})
  RAM      : ${DET_RAM_MB} MB
  Disk free: ${DET_DISK_FREE_MB} MB
  Distro   : ${DET_DISTRO}
  GPU      : $( [ "$DET_GPU" = 1 ] && echo "detected (${DET_GPU_VENDOR}: ${DET_GPU_NAME})" || echo "none — software rendering (llvmpipe)" )
EOF
}
