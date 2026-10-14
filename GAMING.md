# Tiny11 Core-Gaming

A latency-first build of Tiny11 Core, modelled on what [AtlasOS](https://github.com/Atlas-OS/Atlas)
does. It targets competitive esports on older hardware — the reference workload is
Rainbow Six Siege on a CPU-bound machine.

> **Read this first.** This profile disables VBS, Memory Integrity (HVCI), Credential
> Guard and the Spectre/Meltdown kernel mitigations, and it removes the Xbox stack.
> That is a deliberate, measurable performance trade-off, not a free win. It is **not**
> a safe daily-driver configuration. A revert script ships inside the image.

---

## Contents

- [Building it](#building-it)
- [What gets applied](#what-get-applied)
- [The power scheme](#the-power-scheme)
- [Instant window response](#instant-window-response)
- [What breaks](#what-breaks)
- [Reverting](#reverting)
- [Customising without editing PowerShell](#customising-without-editing-powershell)
- [Honest expectations](#honest-expectations)
- [Rainbow Six Siege notes](#rainbow-six-siege-notes)
- [How it is wired into the builder](#how-it-is-wired-into-the-builder)

---

## Building it

### GitHub Actions

Run the **Build and Release Tiny11 Core-Gaming** workflow. It is a copy of
*Build and Release Tiny11 Core* with the same inputs plus a set of gaming toggles —
so anything you already know about the Core workflow still applies.

Each toggle maps to one group in `config/gaming_profile.json`. Turning a toggle off
skips that group entirely; it does not half-apply.

### Locally

```powershell
# Full Core-Gaming build for competitive esports
.\scripts\tiny11coremaker-headless.ps1 -ISO E -INDEX 6 -GamingProfile -RemoveDefender -PreserveWinRE

# Dial a few groups back
.\scripts\tiny11coremaker-headless.ps1 -ISO E -INDEX 6 -GamingProfile -HagsMode off `
    -GamingGroups @{ disable_security_mitigations = $false; install_game_runtimes = $false }

# Use a different profile file
.\scripts\tiny11coremaker-headless.ps1 -ISO E -INDEX 6 -GamingProfile -GamingProfileFile .\my-profile.json
```

`-GamingProfile` is opt-in. A plain Core build is completely unaffected — the profile
engine is only dot-sourced when the switch is present.

---

## What gets applied

Everything below lives in [`config/gaming_profile.json`](config/gaming_profile.json).
Group names match the workflow input names exactly.

### Power & CPU

| Group | What it does |
|---|---|
| `atlas_power_scheme` | Creates and activates a new power scheme (see [below](#the-power-scheme)), disables hibernation and power throttling, and sets MMCSS `SystemResponsiveness` to 10 |
| `disable_cpu_idle` | Forces the CPU to stay in C-State 0 — no idle states, so there is no C-State wake penalty on a frame spike |

### Security (the aggressive part)

| Group | What it does |
|---|---|
| `disable_security_mitigations` | VBS off, HVCI / Memory Integrity off, Credential Guard off, System Guard off, `FeatureSettingsOverride=3` (Spectre/Meltdown mitigations off), plus `bcdedit /set hypervisorlaunchtype off` at first boot |

### Latency

| Group | What it does |
|---|---|
| `network_latency_tweaks` | Nagle's algorithm off (global + per-adapter at first boot), QoS reserved bandwidth set to 0, Delivery Optimization P2P off, WU auto-reboot blocked |
| `disable_mpo` | Disables Multi-Plane Overlay (`Dwm\OverlayTestMode=5`) — the standard fix for flicker and micro-stutter on some NVIDIA/AMD drivers |
| `latency_input_tweaks` | Mouse acceleration off, Sticky Keys / Toggle Keys hotkeys off, DXGI flip model enabled |
| `disable_fso` | Forces true fullscreen exclusive instead of Fullscreen Optimizations |

### Behaviour

| Group | What it does |
|---|---|
| `disable_game_mode` | Turns Windows Game Mode **off** — see the note below |
| `strip_background_noise` | Windows Search indexing off, Bluetooth off, Delivery Optimization service off, background apps globally denied, visual effects off, scripted diagnostics off |
| `instant_windows` | Removes window/menu/hover animations and shell delays, and shortens the app-close timeouts — see [Instant window response](#instant-window-response) |
| `disable_fast_startup` | Hibernation and Fast Startup off |
| `disable_printing` | Print services disabled **and** the printing optional features removed from the image |
| `remove_xbox_gaming_stack` | Xbox Live Auth, Xbox Game Save, Xbox Networking, Xbox Accessory Management, Gaming Services and Gaming Services Network all disabled; Xbox AppX packages removed |
| `install_game_runtimes` | VC++ 2015–2022 (x64 + x86), DirectX 9.0c (June 2010) and .NET 8 Desktop Runtime downloaded at build time and silently installed at first boot |

Plus `-HagsMode on|off|leave` for Hardware Accelerated GPU Scheduling.

### Why Game Mode is off

Windows Game Mode's useful work is: block Windows Update driver installs and reboots,
suppress notifications, deprioritise background processes, and prioritise game threads.
On this build the first three are already handled more aggressively — Windows Update is
disabled outright, telemetry and background apps are stripped, and Game Bar is gone.
What remains is runtime thread-priority juggling, which on a CPU-bound esports title can
add frame-time variance rather than remove it.

AtlasOS ships it off for the same reason. It is a one-line change if you disagree —
see [Customising](#customising-without-editing-powershell).

### Overrides of the Core defaults

The Core builder already applies an aggressive performance profile. Core-Gaming
deliberately overrides four of its choices:

| Setting | Core default | Core-Gaming |
|---|---|---|
| Game Mode | on | **off** |
| `SystemResponsiveness` | 0 | **10** (AtlasOS value) |
| Fullscreen Optimizations | on | **off** |
| HAGS | forced on | **toggleable** |

---

## The power scheme

AtlasOS does not distribute a standalone `.pow` file — it configures power through
`powercfg` and the registry. So this profile does the same thing: it **generates** a new
scheme at first boot from [`config/gaming_power_settings.json`](config/gaming_power_settings.json).

It is explicitly **not** the built-in Ultimate Performance scheme. It is created by
duplicating the High performance template, renaming the result to
**"Tiny11 Core-Gaming"**, and then applying these values:

| Setting | Value | Why |
|---|---|---|
| Processor idle disable | **1 (no idle)** | C-State 0 only — the core esports setting |
| Minimum / maximum processor state | 100% / 100% | No downclocking, no clock ramp lag |
| Processor performance boost mode | Aggressive | Hidden by default; the script unhides it first |
| Performance time check interval | 15 | Faster response to load changes |
| Core parking min cores | 100% | No core parking |
| Hard disk turn off | never | No spin-down latency |
| Sleep after / display off | never | — |
| USB selective suspend | disabled | Keeps mouse / keyboard / controller polling constant |
| PCI Express ASPM | off | Removes PCIe link power-state latency for the GPU |
| Wireless adapter power saving | max performance | — |
| Energy saver policy | off | — |

The scheme is also exported to `C:\Windows\Tiny11Gaming\Tiny11-Core-Gaming.pow` so you
can move it to another machine.

> **Power cost.** C-State 0 means higher idle power and higher temperatures. AtlasOS
> itself warns against this on laptops or poorly-cooled machines. Fine on a desktop
> gaming rig; think twice on a laptop.

---

## Instant window response

The `instant_windows` group makes windows open, close and respond as fast as the
hardware allows.

It is a separate group because the "adjust for best performance" preset
(`VisualFXSetting=2`, set by `strip_background_noise`) is **not sufficient on its own**.
The preset does not reliably override `MinAnimate`, and it does not touch any of the
shell delays or the close-path timeouts at all.

### Animations and delays

| Value | Default | Set to |
|---|---|---|
| `MinAnimate` | 1 | **0** — the actual minimize/maximize animation toggle |
| `MenuShowDelay` | **400 ms** | **0** — delay before any menu appears |
| `MouseHoverTime` | **400 ms** | **0** |
| `ExtendedUIHoverTime` | 400 ms | **0** — taskbar thumbnail hover |
| `ThumbnailLivePreviewHoverTime` | 400 ms | **0** — live preview hover |
| `TaskbarAnimations` | 1 | 0 |
| `ListviewAlphaSelect` | 1 | 0 — selection fade in Explorer |
| `ListviewShadow` | 1 | 0 — icon label drop shadow |
| `EnableTransparency` | 1 | **0** — Windows 11 acrylic/blur, costs work on every window draw |
| `EnableAeroPeek` | 1 | 0 |
| `DisallowShaking` | 0 | 1 — disables Aero Shake |

### Close-path timeouts

This is the part that actually governs how fast a window **closes** when the app is
slow to exit. Windows is very patient by default.

| Value | Default | Set to | Effect |
|---|---|---|---|
| `WaitToKillAppTimeout` | **20 000 ms** | **2000 ms** | How long a slow app may linger on exit |
| `HungAppTimeout` | 5000 ms | 1000 ms | How long before Windows calls a window unresponsive |
| `WaitToKillServiceTimeout` | 5000 ms | 2000 ms | Same, for services |
| `AutoEndTasks` | 0 | 1 | End hung tasks instead of waiting for a prompt |

### Shell bookkeeping

| Value | Set to | Effect |
|---|---|---|
| `Start_TrackProgs` | 0 | Stop the shell maintaining a most-used-programs list on every launch |
| `Start_TrackDocs` | 0 | Stop the recent-documents list |

### What is deliberately *not* changed

- **`UserPreferencesMask`** — the master binary bitmask that `VisualFXSetting` writes.
  It is left alone because hand-crafting the hex is error-prone and it also controls
  ClearType font smoothing; getting it wrong makes text render worse for no speed gain.
  The granular values above cover the effects that matter.
- **`DragFullWindows`** — dragging a window still redraws its contents. Turning it off
  makes a window collapse to a wireframe while dragged, which looks broken on modern
  hardware and has nothing to do with opening or closing.
- **`ForegroundLockTimeout`** — left at its default. Setting it to 0 lets background
  windows steal focus, which is worse than the responsiveness it claims to add.
- **Prefetch / SysMain** — still disabled, consistent with AtlasOS. Worth knowing:
  this does slow *cold app launches*. Re-enabling it properly means re-enabling the
  SysMain service, which is the opposite of what a stripped gaming build wants. If you
  care more about launch speed than background footprint, see
  [Customising](#customising-without-editing-powershell) — but note that
  `EnablePrefetcher` alone does little while SysMain is off.

---

## What breaks

| Broken | Because |
|---|---|
| Game Pass, Microsoft Store games, Xbox Play Anywhere | `remove_xbox_gaming_stack` |
| Printing of any kind | `disable_printing` |
| Windows Search indexing (Start-menu search quality drops) | `strip_background_noise` |
| Bluetooth devices | `strip_background_noise` |
| Windows Update (already true for Core) | Core baseline |
| Windows Defender | `-RemoveDefender` (only if you pass it) |
| Memory Integrity / Core Isolation UI | `disable_security_mitigations` |

Steam, Ubisoft Connect and Epic titles are unaffected by the Xbox removal.

---

## Reverting

Two files are written into the image:

| File | Purpose |
|---|---|
| `C:\Windows\Tiny11Gaming\Undo-GamingTweaks.ps1` | Restores the reversible settings |
| `C:\Windows\Tiny11Gaming\GAMING_PROFILE.md` | The exact list of what was changed in *your* build |
| `C:\Windows\Tiny11Gaming\gaming-firstboot.log` | What the first-boot payload actually did |

```powershell
# Elevated PowerShell
powershell -ExecutionPolicy Bypass -File C:\Windows\Tiny11Gaming\Undo-GamingTweaks.ps1
```

It re-enables Game Mode, Fullscreen Optimizations, VBS / Memory Integrity, the
Spectre/Meltdown mitigations, Fast Startup, mouse acceleration, background apps, and
Windows Search / Bluetooth services, then switches the active power plan back to
Balanced.

**Not reversible from inside Windows** — the script tells you this too:

- Windows Defender, if it was removed with `-RemoveDefender`
- The printing optional features
- The removed Xbox AppX packages
- The `bcdedit` mitigation flags (changeable with `bcdedit`, but not by this script)

---

## Customising without editing PowerShell

`config/gaming_profile.json` is the single source of truth. Every registry value,
service, package and feature is a data entry tagged with a group. To change behaviour:

```jsonc
// Turn a group off by default
"defaultGroups": {
  "disable_mpo": false
}

// Or disable it per build
// .\scripts\tiny11coremaker-headless.ps1 ... -GamingGroups @{ disable_mpo = $false }
```

Adding a new tweak is one JSON object — no PowerShell edit:

```jsonc
{
  "group": "network_latency_tweaks",
  "hive": "SYSTEM",
  "path": "ControlSet001\\Services\\Tcpip\\Parameters",
  "name": "TcpMaxDataRetransmissions",
  "type": "REG_DWORD",
  "value": "5",
  "note": "Optional human-readable explanation, surfaced in the log and manifest"
}
```

Valid `hive` values are `SYSTEM`, `SOFTWARE`, `DEFAULT` and `NTUSER` — they map to the
offline hives the builder loads (`HKLM\zSYSTEM`, `zSOFTWARE`, `zDEFAULT`, `zNTUSER`).

---

## Honest expectations

This matters more than the tweak list.

- **Frame-time consistency improves more than average FPS.** The latency tweaks
  (C-State 0, no core parking, mitigations off, MPO off) mostly show up in 1% lows and
  input latency, not in a big average-FPS number.
- **Disabling VBS/HVCI is the largest single lever**, typically quoted at 5–15% on
  affected titles. It is also the biggest security cost.
- **Some tweaks are marginal or hardware-specific.** HPET / timer settings in
  particular help some rigs and do nothing — or regress — on others.
- **Benchmark your own machine.** No profile can tell you what your CPU/motherboard/
  GPU combination will do.

---

## Rainbow Six Siege notes

- R6 Siege is **CPU-bound**, so `disable_cpu_idle`, the 100% min processor state,
  mitigations off and MPO off are the changes that matter most here.
- **BattlEye is unaffected** by anything in this profile. It does not object to VBS
  being off, to Xbox services being removed, or to the network tweaks.
- **Disable fullscreen optimizations** (`disable_fso`, on by default here) is what most
  competitive R6 players want — true fullscreen exclusive.
- Xbox / Gaming Services removal does not touch R6 if you play it through Steam or
  Ubisoft Connect.
- Turn off in-game: V-Sync, and use a frame-rate cap below your refresh rate if your
  frame times are spiky.

---

## How it is wired into the builder

```
scripts/
├── gaming-profile.ps1        # profile engine (dot-sourced by the builder)
├── gaming-firstboot.ps1      # runs once as SYSTEM on the target machine
└── Undo-GamingTweaks.ps1     # revert, shipped inside the image

config/
├── gaming_profile.json       # every tweak, grouped
└── gaming_power_settings.json# power scheme + bcdedit definition
```

Order of operations during a build:

1. **Image-level removals** — AppX packages, system packages and optional features,
   while the registry hives are still unloaded.
2. **Registry tweaks** — after `Apply-PerformanceTweaks`, so Core-Gaming can override
   the Core defaults. Hives are `HKLM\zSYSTEM`, `zSOFTWARE`, `zDEFAULT`, `zNTUSER`.
3. **Service tweaks** — a service key that does not exist in the image is skipped
   rather than created.
4. **Payload injection** — before `Dismount-AndExport`, so files land inside
   `install.wim`. Only `install.wim` is touched; `boot.wim` is left alone because
   Ventoy inspects and patches it.

At first boot, `Windows\Setup\Scripts\SetupComplete.cmd` runs
`gaming-firstboot.ps1` **as SYSTEM, before the first logon**. That hook is used because
the power scheme GUID is machine-specific, the BCD store is not part of `install.wim`,
network adapters do not exist until drivers enumerate, and runtime installers have to
actually execute. Per-user settings do not go there — they are written into the Default
user hive offline so every new profile inherits them.

Everything is best-effort: a missing service or an unavailable DISM feature logs a
warning and continues. A half-applied gaming profile beats a failed 90-minute build.

---

## Attribution

The tweak set is modelled on [AtlasOS](https://github.com/Atlas-OS/Atlas), which is
GPLv3. No Atlas code or artifacts are redistributed here — the power scheme is
generated from Microsoft's own `powercfg` templates, and every setting is a documented
Windows registry value. Thanks to the Atlas team for documenting their reasoning
publicly.
