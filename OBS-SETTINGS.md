# OBS Studio - smooth replay buffer on a single GPU

This guide ships inside the image at `C:\Windows\Tiny11Gaming\OBS-SETTINGS.md`.

It exists because of an honest split of responsibility: **Windows can be tuned, but it
cannot stop a game and an encoder from competing for the same GPU.** Most of the OS-side
work is already done by this build (table below). What is left is OBS configuration and
one number you have to choose yourself: your frame cap.

Read the first section, then set the values in the second. The third section is the part
to come back to when it still is not right.

---

## 1. What this image already did

Do not re-apply these from a "gaming tweak" list - they are already set.

| Setting | Value | Where it lives |
|---|---|---|
| Power throttling | off (`PowerThrottlingOff=1`) | `atlas_power_scheme` group |
| PCI Express link state power management | off on AC | Atlas power scheme |
| USB selective suspend / USB 3 link power management | off | Atlas scheme + `latency_input_tweaks` |
| Game DVR / background recording | off | `disable_game_mode`, Core builder |
| Game Mode | off | `disable_game_mode` |
| MMCSS Games class, `SystemResponsiveness` | max priority, 10 | Core builder + `atlas_power_scheme` |
| `Win32PrioritySeparation` | 38 | Core builder |
| Global 1 ms timer resolution requests | allowed | `latency_input_tweaks` |
| Hardware-accelerated GPU scheduling (HAGS) | **on** by default | `-HagsMode` / `hags` input |
| Multi-Plane Overlay (MPO) | **disabled** by default | `disable_mpo` group |
| Fullscreen optimisations (FSO) | **disabled** by default | `disable_fso` group |
| DXGI flip model + VRR optimisation | on | `latency_input_tweaks` |

Two of those defaults can work *against* capture, and they are the first things to
suspect if you have already followed every OBS guide:

- **`disable_fso` forces true fullscreen exclusive.** OBS's game capture hook is weakest
  in true exclusive mode, and some titles drop or tear frames under it. If you capture
  with Game Capture, try a build without it:
  `-GamingGroups @{ disable_fso = $false }`
- **`disable_mpo`** fixes flicker and micro-stutter on many GPUs, but on some driver
  versions it costs desktop-composition performance. If display capture stutters, try
  `-GamingGroups @{ disable_mpo = $false }`.

Verify what your actual image did - do not assume:

```powershell
powershell -ExecutionPolicy Bypass -File C:\Windows\Tiny11Gaming\Tiny11-Report.ps1
```

The **Capture / OBS** section prints every value in the table above as it exists on the
machine.

---

## 2. Settings

### 2.1 The frame cap (do this first)

This is the single largest lever and it is not a Windows setting.

Cap the game a few percent **below** what the GPU can actually hold, in the game's own
limiter or in NVIDIA Control Panel -> Manage 3D settings -> Max Frame Rate. If the game
runs uncapped, the GPU spends its last milliseconds of headroom on frames nobody sees and
OBS misses its own deadlines. That is what produces "the clip is 60 fps but frames arrive
in clumps".

Practical targets on a single dGPU:

| Display | Cap |
|---|---|
| 144 Hz | 120-138 |
| 165 Hz | 140-158 |
| 240 Hz | 200-225 |

If encoding lag persists, lower the cap further before touching anything else. A stable
120 with a clean recording beats a stuttering 160.

### 2.2 Video

Settings -> Video

| Setting | Value | Why |
|---|---|---|
| Base (Canvas) Resolution | your monitor's native resolution | - |
| Output (Scaled) Resolution | **same as canvas** | two different values make OBS scale every frame on the GPU |
| Downscale Filter | irrelevant once the two match | - |
| FPS | 60 (or the cap above if lower) | capturing at 144 doubles encoder load for no visible gain in a clip |

### 2.3 Output - Recording

Settings -> Output -> Output Mode: **Advanced** -> Recording tab

**First, which encoder.** This depends on the GPU generation, and getting it wrong is
the most common reason a replay buffer stutters on older hardware.

| GPU | Encoder | Notes |
|---|---|---|
| RTX 40xx (Ada) | NVENC **AV1** | cheapest per unit of quality |
| RTX 20xx / 30xx, GTX 16xx (Turing+) | NVENC **HEVC**, else H.264 | full preset range, B-frames, look-ahead |
| GTX 10xx (Pascal) | NVENC H.264, HEVC on most | no P1-P7 presets, no look-ahead, no B-frames |
| GTX 9xx and older (Maxwell) | NVENC **H.264 only** | weak encoder; see the x264 note below |

On Maxwell and Pascal the NVENC block is a small part of a GPU that is already fully
loaded by the game. If both rendering and encoding lag are climbing on hardware that old,
**try x264 with the `veryfast` preset instead** - it moves the work to the CPU and takes
the encoder out of the fight entirely. It is the wrong answer on a 6-core CPU running a
CPU-heavy game, and often the right one on an older GPU.

| Setting | Turing and newer | Maxwell / Pascal |
|---|---|---|
| Encoder | NVENC H.264 / HEVC / AV1 | NVENC H.264, or x264 `veryfast` |
| Rate Control | **CQP** | **CQP** |
| CQ Level | 18-21 (H.264) / 24-27 (HEVC) | 20-23 |
| Keyframe Interval | 0 (auto) | 0 (auto) |
| Preset | **P5** (P4 if still the bottleneck) | **Low Latency**, else Performance |
| Tuning | Low Latency | not available |
| Multipass Mode | **Disabled** | **Disabled** (two-pass costs GPU time) |
| Profile | High | High |
| Look-ahead | **off** | not available |
| Psycho Visual Tuning | **off** | not available |
| Max B-frames | 2 (0 for lowest latency) | not available |
| Split Encoder Sessions | on, if present | not available |

Lower CQ = bigger files and better quality. CBR is a streaming setting: for a replay
buffer it wastes bitrate on easy scenes and starves hard ones, which is why clips of busy
moments look worse than the game did.

### 2.4 Output - Replay Buffer

Same tab group, Replay Buffer section:

| Setting | Value |
|---|---|
| Enable Replay Buffer | on |
| Max Replay Time | 60-300 s |
| Max Replay Memory | bitrate x seconds / 8. At 50 Mbps for 120 s that is ~750 MB |

The buffer lives in **RAM**, not on disk. Memory pressure is therefore not usually the
problem - but saving is: a 2-4 GB dump to the same drive the game is streaming from will
hitch. Point Settings -> Output -> Recording Path at a different physical drive if you
have one.

### 2.5 Advanced

Settings -> Advanced

| Setting | Value | Why |
|---|---|---|
| Process Priority | **Above Normal** | OBS defaults to Normal; Above Normal stops the game from starving its render thread |
| Renderer | Direct3D 11 | - |
| Color Format | NV12 | the native 8-bit format for both NVENC and x264; anything else needs a conversion pass |
| Color Space | Rec. 709 | - |
| Color Range | Partial | - |

And: **turn the preview off** (right-click the preview -> uncheck Enable Preview, or
View -> Preview). The preview is a second full render of the scene every frame, on the
same GPU you are trying to free up. This alone frequently halves rendering lag.

Keep the scene minimal: one game/display capture, no browser sources, no chains of
colour-correction filters. Each filter is another GPU pass.

---

## 3. When frames still drop

OBS -> View -> Stats. Two numbers matter and they mean different things.

### "Skipped frames due to rendering lag" climbing

OBS cannot render its own scene fast enough. The GPU is saturated.

1. Preview off (section 2.5) - check this first.
2. Cap the frame rate lower (section 2.1).
3. Remove sources and filters.
4. Raise OBS process priority to High.
5. Try `-GamingGroups @{ disable_fso = $false }` if using Game Capture.

### "Frames missed due to encoding lag" climbing

The encoder itself is behind. The GPU is not out of shader throughput, the encode block is
out of time.

1. Preset one step faster (P4 on Turing+, "Performance" on older cards).
2. Look-ahead, psycho visual tuning and multipass all off.
3. Drop Max B-frames to 0.
4. Switch H.264 -> HEVC, but only on Pascal or newer.
5. Reduce output FPS to 60 or 30.
6. Lower the frame cap - less input frame rate means less work per second.
7. **On Maxwell (GTX 9xx) or older, switch the encoder to x264 `veryfast`.** That encoder
   is the weakest link on those cards, and moving the work to the CPU is often the only
   thing that actually clears it.

### Both climbing together

That is saturation, not a bad setting. Frame cap is the answer. Nothing in the registry
fixes a GPU that is already at 100%.

### Check the NVENC session limit

Consumer NVIDIA cards cap how many simultaneous encode sessions they allow (historically
2-3, more on recent drivers). Replay buffer + a stream + another recording app can hit
it, and the failure looks exactly like encoding lag. Close the other encoders.

### HAGS on or off

HAGS changes how the GPU schedules work between the game, the compositor and the encoder.
On a single GPU it helps on most modern drivers, which is why it is on by default here.
It is not universal:

```powershell
# build a variant with HAGS off to compare
-GamingGroups @{ hags = $false }     # or set the hags workflow input to 'off'
```

Test one variable at a time. Changing HAGS, FSO and the frame cap together tells you
nothing about which one helped.

---

## 4. Undo

```powershell
powershell -ExecutionPolicy Bypass -File C:\Windows\Tiny11Gaming\Undo-GamingTweaks.ps1
```

This restores the reversible registry values, including the timer resolution setting,
from the `revert` block of the bundled `gaming_profile.json`.
