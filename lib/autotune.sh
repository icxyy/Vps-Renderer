#!/usr/bin/env bash
# autotune.sh — DET_* specs ko leke render settings nikalta hai (TUNE_* export).
# detect.sh ke baad source karo:  detect_specs ; autotune

autotune() {
    # ---------- JVM heap (MB) ----------
    # OS + offheap (llvmpipe buffers, native libs) ke liye headroom chhodo.
    local reserve=2048
    [ "$DET_RAM_MB" -ge 16384 ] && reserve=3072
    local heap=$(( DET_RAM_MB * 60 / 100 ))
    local max_heap=$(( DET_RAM_MB - reserve ))
    [ "$heap" -gt "$max_heap" ] && heap="$max_heap"
    [ "$heap" -lt 2048 ] && heap=2048
    TUNE_HEAP_MB="$heap"
    TUNE_LOW_RAM=0
    [ "$DET_RAM_MB" -lt 4096 ] && TUNE_LOW_RAM=1

    # ---------- llvmpipe threads ----------
    # Software rasterizer ko jitne cores do utna tez. Modern Mesa 32+ allow karta hai.
    local lp="$DET_CORES"
    [ "$lp" -gt 32 ] && lp=32
    [ "$lp" -lt 1 ] && lp=1
    TUNE_LP_THREADS="$lp"

    # ---------- Resolution (agar user ne override na diya ho) ----------
    if [ -z "${OPT_RES:-}" ]; then
        if   [ "$DET_RAM_MB" -ge 8192 ] && [ "$DET_CORES" -ge 8 ]; then TUNE_RES="1920x1080"
        elif [ "$DET_RAM_MB" -ge 4096 ] && [ "$DET_CORES" -ge 4 ]; then TUNE_RES="1280x720"
        else                                                            TUNE_RES="854x480"
        fi
    else
        TUNE_RES="$OPT_RES"
    fi
    TUNE_W="${TUNE_RES%x*}"
    TUNE_H="${TUNE_RES#*x}"

    # ---------- Render distance ----------
    if   [ "$DET_CORES" -ge 12 ]; then TUNE_RENDER_DIST=12
    elif [ "$DET_CORES" -ge 8 ];  then TUNE_RENDER_DIST=10
    elif [ "$DET_CORES" -ge 4 ];  then TUNE_RENDER_DIST=8
    else                                TUNE_RENDER_DIST=6
    fi

    # ---------- Output fps ----------
    TUNE_FPS="${OPT_FPS:-60}"

    # ---------- Shader decision ----------
    # No GPU + shaders = chalega par bohot dheema. Estimate karke faisla.
    TUNE_SHADER_WARN=0
    if [ -n "${OPT_SHADER:-}" ] && [ "$DET_GPU" = 0 ]; then
        TUNE_SHADER_WARN=1
    fi

    # ---------- Frame-time / ETA estimate ----------
    # Bohot rough model — sirf user ko expectation set karne ke liye.
    # base: 720p vanilla software fps ≈ cores * 0.9
    local base_fps_x100=$(( DET_CORES * 90 ))           # fps*100 @720p vanilla
    # resolution scale
    local px=$(( TUNE_W * TUNE_H ))
    local ref_px=$(( 1280 * 720 ))
    [ "$px" -lt 1 ] && px=$ref_px
    local fps_x100=$(( base_fps_x100 * ref_px / px ))
    # shader penalty (~12x slower)
    if [ -n "${OPT_SHADER:-}" ]; then
        fps_x100=$(( fps_x100 * 8 / 100 ))
    fi
    [ "$fps_x100" -lt 1 ] && fps_x100=1
    TUNE_EST_RENDER_FPS_X100="$fps_x100"   # render speed (frames/sec wall-clock), *100

    export TUNE_HEAP_MB TUNE_LOW_RAM TUNE_LP_THREADS TUNE_RES TUNE_W TUNE_H \
           TUNE_RENDER_DIST TUNE_FPS TUNE_SHADER_WARN TUNE_EST_RENDER_FPS_X100
}

# duration_ms diya jaye to total frames + ETA print karta hai
print_tune() {
    local dur_ms="${1:-0}"
    local render_fps_int=$(( TUNE_EST_RENDER_FPS_X100 / 100 ))
    [ "$render_fps_int" -lt 1 ] && render_fps_int=1

    echo "  Heap         : ${TUNE_HEAP_MB} MB"
    echo "  llvmpipe thr : ${TUNE_LP_THREADS}"
    echo "  Resolution   : ${TUNE_RES}"
    echo "  Render dist  : ${TUNE_RENDER_DIST} chunks"
    echo "  Output FPS   : ${TUNE_FPS}"
    printf  "  Est. speed   : ~%d.%02d frames/sec (wall-clock)\n" \
            "$render_fps_int" "$(( TUNE_EST_RENDER_FPS_X100 % 100 ))"

    if [ "$dur_ms" -gt 0 ]; then
        local dur_s=$(( dur_ms / 1000 ))
        local total_frames=$(( dur_s * TUNE_FPS ))
        local eta_s=$(( total_frames * 100 / TUNE_EST_RENDER_FPS_X100 ))
        printf  "  Replay len   : %dm %ds  (%d frames @ %dfps)\n" \
                $(( dur_s / 60 )) $(( dur_s % 60 )) "$total_frames" "$TUNE_FPS"
        printf  "  Est. ETA     : ~%dh %dm  ⏱\n" \
                $(( eta_s / 3600 )) $(( (eta_s % 3600) / 60 ))
    fi
}
