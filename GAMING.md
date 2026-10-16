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
- [Optional: NVIDIA driver injection](#optional-nvidia-driver-injection)
- [What gets applied](#what-get-applied)
- [The power scheme](#the-power-scheme)
- [Instant window response](#instant-window-response)
- [Game runtimes](#game-runtimes)
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
    -GamingGroups @{ disable_security_mitigations = $false; disable_mpo = $false }

# Use a different profile file
.\scripts\tiny11coremaker-headless.ps1 -ISO E -INDEX 6 -GamingProfile -GamingProfileFile .\my-profile.json
```

`-GamingProfile` is opt-in. A plain Core build is completely unaffected — the profile
engine is only dot-sourced when the switch is present.

---

## Optional: NVIDIA driver injection

If the target machine has an NVIDIA GPU, the Core-Gaming workflow can bake a
**debloated NVIDIA display driver** straight into the ISO, so a fresh install already
has the driver — no separate driver install, no GeForce Experience, no telemetry.

Set the **`nvidia_driver_version`** input to the version you want (e.g. `566.36`).
**Leave it blank and the whole step is skipped** — the image is then built exactly as
before, with no driver work at all.

### What it does

1. Downloads the official NVIDIA DCH package for that version (SHA256-checked by size
   and extracted with 7-Zip) and prunes it down to `Display.Driver`, so every optional
   component — Legacy Control Panel, HD Audio via HDMI, VC++ 2017 runtimes, PhysX,
   USB-C, FrameView, Quadro View, Virtual Audio, Telemetry, NV Platform Controllers,
   DLSSR and the whole NV App block — is left out. The reference **Installation
   Tweaks** are applied as INF/registry edits:
   - Disable Installer Telemetry & Advertising, Unattended Express Install, Allow
     automatic reboot, Perform a Clean Installation, Disable Ansel, Show Expert
     Tweaks, Disable Driver Telemetry, Disable NVIDIA HD Audio sleep timer, Enable MSI,
     Disable HDCP, Rebuild digital signature, Easy-Anti-Cheat-compatible method,
     Auto-accept the "driver unsigned" warning.
2. Rebuilds the driver catalog with `inf2cat` and re-signs the package with a locally
   generated certificate, because the INF edits invalidate NVIDIA's own signature.
   The signing certificate is trusted inside the image so the driver loads without a
   prompt.
3. Injects it into the ISO: the driver goes into the offline `install.wim` DriverStore,
   and the driver, its certificate and an installer are also staged and run from
   `SetupComplete.cmd`, so the driver is trusted and installed on first boot.

The build report is uploaded as an artifact (`nvidia-driver-buildinfo.json`).

### Choosing the build path

The **`nvidia_driver_method`** input selects how the driver is produced:

| Value | Behaviour |
|---|---|
| `fallback` *(default)* | Deterministic: download the official package and prune it. Reproducible and testable. |
| `gui` | Try to drive the NVCleanstall wizard first (using the copy vendored at `tools/NVCleanstall_1.19.0.exe`), then fall back if that fails. |
| `auto` | Defer to `config/nvidia_driver_profile.json`. |

The GUI path is **not the default, and `gui.enabled` is `false` in the profile**, because
it cannot complete unattended: on a clean machine NVCleanstall's first page expects a
driver it downloads through its own wizard, and its component/tweak pages are
owner-drawn Delphi (VCL) controls rather than standard Win32 dialogs, so the selection
cannot be verified from CI. Both paths produce the same debloated component set; the
deterministic one is simply the one that can be trusted to finish.

### Caveats

- NVCleanstall is vendored at `tools/NVCleanstall_1.19.0.exe` so builds never depend on
  TechPowerUp's anti-bot download. It is TechPowerUp freeware — check their terms if you
  redistribute this repository. The engine verifies its SHA256 before running it, and
  falls back to downloading only if the bundled copy is missing.
- The tweaks change the driver's INF, which invalidates NVIDIA's signature — that is
  why the driver is re-signed. The re-signed driver is trusted inside the image, but it
  is **not** the same as NVIDIA's own signed package; treat it accordingly.
- **The INF-level tweaks need the Windows Driver Kit.** Editing the INF invalidates
  NVIDIA's catalog, and a driver whose catalog does not match will **not** install from
  the DriverStore at all. So the tweaks are only baked into the INF when both
  `inf2cat.exe` (WDK) and `signtool.exe` (SDK) are present, which is why the build job
  is pinned to `windows-2022` — `windows-latest` now resolves to the `windows-2025`
  image, which carries only the WDK Visual Studio extension and no `inf2cat.exe`. When
  that tooling is missing the engine leaves the INF untouched so NVIDIA's own signature
  stays valid: the driver still installs, it just doesn't carry the INF-level tweaks.
  The build report records which path was taken in `tweaks_in_inf`.
- Re-signing needs `signtool.exe` (Windows SDK, present on the runners).
- Builds that leave the input blank are unaffected.

### Locally

```powershell
# Build the debloated driver on its own (deterministic path, the default)
.\scripts\nvidia-driver-builder.ps1 -DriverVersion 566.36

# Try the NVCleanstall GUI first, falling back if it fails
.\scripts\nvidia-driver-builder.ps1 -DriverVersion 566.36 -Method gui

# Point at a different NVCleanstall build
.\scripts\nvidia-driver-builder.ps1 -DriverVersion 566.36 -NvCleanstallPath D:\Drivers\NVCleanstall_1.19.0.exe

# Inject it during a Core-Gaming build
.\scripts\tiny11coremaker-headless.ps1 -ISO E -INDEX 6 -GamingProfile `
    -NvidiaDriverPath .\scripts\nvidia-driver
```

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

This is **verified against the real thing**, not approximated. The scheme active on the
maintainer's machine was read with `powercfg -query`, and the result is worth knowing:

> **AtlasOS's power scheme is Ultimate Performance plus exactly two overrides.**
>
> Of its 27 visible settings, **25 are byte-identical to the built-in Ultimate
> Performance scheme.** The only differences are:
>
> | Setting | Ultimate Performance | Atlas |
> |---|---|---|
> | USB selective suspend (AC) | enabled (1) | **disabled (0)** |
> | Turn off display after (AC) | 900 s | **never (0)** |

That has one important consequence: **the base template must be Ultimate Performance**,
not High performance. Duplicating any other base cannot reproduce the scheme. Earlier
versions of this profile duplicated High performance and layered values on top — close,
but not a match.

So `config/gaming_power_settings.json` now:

- duplicates the **Ultimate Performance** template
  (`e9a42b02-d5df-448d-aa00-03f14749eb61`), falling back to High performance then
  Balanced if it is unavailable;
- renames the result to **"Atlas Power Scheme"**;
- writes all **27** settings explicitly, so the outcome matches whichever template was
  actually available;
- then applies the same BCD tuning as before.

### The two Atlas overrides

| Setting | AC | DC |
|---|---|---|
| USB selective suspend | 0 — disabled | 1 |
| Turn off display after | 0 — never | 180 s |

### Where this profile deliberately diverges from Atlas

Atlas leaves **CPU idle enabled**. This profile disables it, forcing C-State 0 and
removing the C-State wake penalty — the most useful single latency tweak for a CPU-bound
esport. It is gated behind its own `disable_cpu_idle` toggle (on by default) and labelled
as a divergence in the profile JSON, so turning that toggle off gives you an exact Atlas
match.

Three further CPU settings — boost mode (Aggressive), performance time-check interval
(15) and core parking (disabled) — are written explicitly too. On the Ultimate
Performance base they are redundant, but they guarantee the same behaviour if the base
template ever falls back to High performance.

> **Power cost.** C-State 0 means higher idle power and higher temperatures. AtlasOS
> itself warns against this on laptops or poorly-cooled machines. Fine on a desktop
> gaming rig; think twice on a laptop.

The scheme is exported to `C:\Windows\Tiny11Gaming\Atlas-Power-Scheme.pow` so you can
move it to another machine.

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

## Game runtimes

**Not bundled, on purpose.** VC++ 2015–2022, DirectX 9.0c and the .NET Desktop Runtime
are deliberately left out. Install them yourself after setup, or let your game launcher
do it.

They could not be integrated into the image at build time anyway: DISM's `/Add-Package`
accepts only `.cab`, `.msu` and `.appx`, and Microsoft does not ship these runtimes in
those formats. The only alternatives were "run the installers during Setup" or
"hand-roll image surgery on the mounted WIM" — neither is worth the ISO size, the build
time, and the untestable failure modes for something most launchers handle themselves.

If a game complains about a missing `VCRUNTIME140.dll`, `d3dx9_43.dll`, or a .NET
runtime, install the redistributable once:

| Runtime | Where to get it |
|---|---|
| Visual C++ 2015–2022 | `https://aka.ms/vs/17/release/vc_redist.x64.exe` — and `vc_redist.x86.exe` for 32-bit games |
| DirectX 9.0c (June 2010) | Microsoft's "DirectX End-User Runtime" download |
| .NET Desktop Runtime | `https://dotnet.microsoft.com/download/dotnet` |

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
and network adapters do not exist until drivers enumerate. Per-user settings do not go
there — they are written into the Default user hive offline so every new profile
inherits them.

Everything is best-effort: a missing service or an unavailable DISM feature logs a
warning and continues. A half-applied gaming profile beats a failed 90-minute build.

---

## Attribution

The tweak set is modelled on [AtlasOS](https://github.com/Atlas-OS/Atlas), which is
GPLv3. No Atlas code or artifacts are redistributed here — the power scheme is
generated from Microsoft's own `powercfg` templates, and every setting is a documented
Windows registry value. Thanks to the Atlas team for documenting their reasoning
publicly.
