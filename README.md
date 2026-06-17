# mc-headless-render

Laptop pe ReplayMod se record + keyframe karo → `.mcpr` VPS pe daalo → ek command se
**headless render** (CPU-only VPS, no GPU). Script khud VPS specs detect karke
settings auto-tune karta hai, software OpenGL (llvmpipe) set karta hai, aur Iris
**shaders** bhi support karta hai (slow, par chalta hai).

```
mc-headless-render/
├── render.sh              # main command — yahi chalana hai
├── config/render.conf     # ek baar set: prism path, instance, account, output dir
├── lib/detect.sh          # CPU/RAM/GPU detect
├── lib/autotune.sh        # specs -> heap, res, render dist, llvmpipe threads, ETA
└── mod/                    # AutoRender — Fabric mod jo render headless trigger karta hai
```

---

## ⚠️ Pehle ye padh: No-GPU + shaders ki sachai

- Bina GPU ke render **Mesa llvmpipe** (software rasterizer) se hota hai. Script
  `MESA_GL_VERSION_OVERRIDE=4.6` laga deta hai, isliye Iris shaders **load ho jaate
  hain** — par har frame CPU pe banta hai.
- **Vanilla** render: thik-thaak (CPU ke hisab se ~few fps wall-clock).
- **Shaders**: bohot dheema (often <1 frame/sec). Chhota clip / kam resolution rakho.
- `render.sh` chalate hi tujhe **ETA estimate** mil jayega — render se pehle hi pata
  chal jayega kitna time lagega. `--dry-run` se sirf plan dekh sakta hai.

---

## A) Laptop par (recording side)

1. Minecraft + **Fabric** + **ReplayMod** (+ Iris agar shaders) install karo.
2. Gameplay record karo (ReplayMod auto `.mcpr` banata hai).
3. Replay khol ke **camera path / keyframes** add karo (position + time keyframes).
4. **Timeline SAVE karo** (ReplayMod me path editor → save). ⚠️ Ye step zaroori hai —
   keyframes `.mcpr` ke andar tabhi save hote hain, aur VPS pe wahi render honge.
5. `.mcpr` file `replay_recordings/` se utha lo.

```bash
# laptop -> VPS
scp ~/.minecraft/replay_recordings/2026_xx.mcpr  user@vps:/home/user/clips/
```

---

## B) VPS par — ek command auto-setup (recommended)

Instance manually banane ka jhanjhat nahi. `setup.sh` sab kuch karta hai — deps,
**portablemc** (GUI-free CLI launcher), MC 26.1.2 + Fabric provision, folders, aur
AutoRender mod build (best-effort):

```bash
git clone https://github.com/IceyyDev/Vps-Renderer.git
cd Vps-Renderer
./setup.sh
```

Iske baad sirf apne mods `~/mc/render-instance/mods/` me daal (26.1.x builds):
**Fabric API**, **ReplayMod**, aur shaders ke liye **Iris + Sodium**. (AutoRender
setup.sh khud build+copy karne ki koshish karta hai.)

`setup.sh` options: `--dir <path>` `--mc <ver>` `--loader <ver>` `--user <name>`
`--no-deps` `--no-mod-build`.

> **portablemc** Minecraft ke liye sahi Java 25 JRE khud download karta hai — system
> Java sirf AutoRender *build* ke liye chahiye. SKlauncher/Prism jaisa koi GUI nahi.

Phir seedha render:
```bash
./render.sh --input ~/clips/clip.mcpr --dry-run   # plan + ETA
./render.sh --input ~/clips/clip.mcpr             # render
```

---

## B2) Manual setup (agar setup.sh use nahi karna)

### 1. System deps
```bash
sudo apt update
# MC 26.1+ ko Java 25 chahiye (pehle 21 tha)
sudo apt install -y openjdk-25-jre-headless xvfb x11-utils \
  libgl1-mesa-dri mesa-utils unzip wget ffmpeg
# agar repo me openjdk-25 na ho: Adoptium/Temurin 25 install karo
```

### 2. PrismLauncher (headless launcher)
```bash
mkdir -p ~/mc && cd ~/mc
# latest linux release: https://github.com/PrismLauncher/PrismLauncher/releases
wget -O PrismLauncher.tar.gz <release-url>
tar xf PrismLauncher.tar.gz     # ya AppImage — bin ka path render.conf me daalna
```

### 3. Ek instance banao (`ReplayRender`)
Pehli baar GUI chahiye — ya to local pe Prism me instance bana ke `instances/`
folder VPS pe copy karo, ya VPS pe X-forwarding se:
- Minecraft **26.1.2** + **Fabric** instance (Prism instance settings me Java 25 runtime select karo)
- `mods/` me daalo: **Fabric API** (`0.145.4+26.1.2`), **ReplayMod** (26.1.x build),
  (optional **Iris+Sodium** 26.1.x), aur hamara **AutoRender** mod (niche build karo)
- Prism me ek **offline account** add karo (naam: `RenderBot`)

> ℹ️ **26.1 = bada change.** Mojang ne year-based versioning + *unobfuscated* code
> shuru kiya. Mods ko Mojang official mappings + Java 25 chahiye. Sab mods 26.1.x ke
> liye specifically build hone chahiye — 1.21.x ke jar yahan nahi chalenge.

### 4. AutoRender mod build
JDK 25 chahiye build ke liye (Gradle khud download kar lega via wrapper).
```bash
cd mc-headless-render/mod
gradle wrapper --gradle-version 9.4.0   # ek baar, agar wrapper na ho
./gradlew build
# jar: build/libs/autorender-1.0.0.jar  ->  instance ke mods/ me copy karo
```
> Mod ReplayMod ki API ko **reflection** se call karta hai, isliye kisi bhi ReplayMod
> jar ke saath compile ho jaata hai. Target: **MC 26.1.2 / ReplayMod 26.1.x**. Agar
> render trigger fail kare, log me `[AutoRender]` lines dekho — `buildRenderSettings` /
> `startReplay` wala part tweak karna padega (ReplayMod ka internal API kabhi-kabhi badalta hai).

### 5. config/render.conf set karo
```bash
PRISM_BIN="$HOME/mc/PrismLauncher"      # ya AppImage path
PRISM_INSTANCE="ReplayRender"
PRISM_ACCOUNT="RenderBot"
OUTPUT_DIR="$HOME/renders"
# MC_DIR khaali chhodo — auto-detect ho jayega
```

---

## C) Render karo

```bash
cd mc-headless-render

# plan dekho (kuch render nahi hoga, sirf specs + ETA)
./render.sh --input ~/clips/2026_xx.mcpr --dry-run

# vanilla render (auto resolution/settings)
./render.sh --input ~/clips/2026_xx.mcpr

# shaders ke saath (slow!)
./render.sh --input ~/clips/2026_xx.mcpr --shader ~/clips/BSL.zip

# manual overrides
./render.sh -i clip.mcpr -o out.mp4 -r 1280x720 -f 30
```

Options:
| flag | matlab |
|------|--------|
| `-i, --input`    | `.mcpr` file (required) |
| `-o, --output`   | output video path |
| `-s, --shader`   | Iris shaderpack `.zip` |
| `-r, --res`      | `WxH` (warna auto specs se) |
| `-f, --fps`      | output fps (default 60) |
| `-t, --timeline` | kaunsa saved timeline (default: pehla) |
| `--dry-run`      | sirf plan + ETA |

Process: specs detect → auto-tune → `.mcpr` instance me copy → `options.txt` +
shader + mod config likho → **Xvfb** + software-GL env → Prism se MC launch →
AutoRender mod replay khol ke render karta hai → done-marker → final `.mp4`
`OUTPUT_DIR` me. Pura headless, koi screen nahi.

---

## Long render? Background me chalao
```bash
nohup ./render.sh -i clip.mcpr > render.out 2>&1 &
tail -f render.out
# ya: tmux new -s render   phir andar render.sh
```

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| `Koi saved timeline nahi mila` | Laptop pe ReplayMod me **timeline save** karna bhool gaya. |
| Render fail, `.autorender_error` file | `OUTPUT_DIR/<name>.render.log` me `[AutoRender]` lines dekho. |
| Black/empty video | GL override nahi laga — `glxinfo` Xvfb ke andar check karo; mesa-dri install hai? |
| OOM / crash | RAM kam — `--res 1280x720` ya `854x480`, ya chhota clip. |
| Bohot slow (shaders) | Expected. Resolution/length ghatao ya GPU VPS lo. |
| Prism launch nahi hota | `PRISM_BIN` galat, ya account add nahi — `render.conf` check. |

### Software GL working hai ya nahi (Xvfb ke andar):
```bash
Xvfb :99 -screen 0 1280x720x24 & DISPLAY=:99 \
LIBGL_ALWAYS_SOFTWARE=1 GALLIUM_DRIVER=llvmpipe glxinfo -B | grep -i renderer
# "llvmpipe" dikhna chahiye
```
