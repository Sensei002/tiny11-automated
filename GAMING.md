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
- [The essentials pass](#the-essentials-pass)
- [The power scheme](#the-power-scheme)
- [Device latency and 1% lows](#device-latency-and-1-lows)
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
# (Defender and the whole Windows Update stack are removed automatically)
.\scripts\tiny11coremaker-headless.ps1 -ISO E -INDEX 6 -GamingProfile -PreserveWinRE

# Dial a few groups back
.\scripts\tiny11coremaker-headless.ps1 -ISO E -INDEX 6 -GamingProfile -HagsMode off `
    -GamingGroups @{ disable_security_mitigations = $false; disable_mpo = $false }

# Use a different profile file
.\scripts\tiny11coremaker-headless.ps1 -ISO E -INDEX 6 -GamingProfile -GamingProfileFile .\my-profile.json
```

`-GamingProfile` is opt-in. A plain Core build is completely unaffected — the profile
engine is only dot-sourced when the switch is present.

---

## What gets applied

Everything below lives in [`config/gaming_profile.json`](config/gaming_profile.json).
Group names match the workflow input names exactly.

> **Input budget.** `workflow_dispatch` allows at most 25 inputs, and this workflow is
> now at 25 (10 inherited from Core, 15 gaming). A new group can no longer be exposed as
> a toggle without removing one — fold new tweaks into an existing group, or move the
> toggle surface to a config file.

### Power & CPU

| Group | What it does |
|---|---|
| `atlas_power_scheme` | Creates and activates a new power scheme (see [below](#the-power-scheme)), disables hibernation and power throttling, keeps the storage link out of low-power states, and sets MMCSS `SystemResponsiveness` to 10 |
| `disable_cpu_idle` | Forces the CPU to stay in C-State 0 — no idle states, so there is no C-State wake penalty on a frame spike. Also sets the energy-performance preference to 0 and the boost policy to 100, which is the hint HWP/CPPC parts actually act on |

### Security (the aggressive part)

| Group | What it does |
|---|---|
| `disable_security_mitigations` | VBS off, HVCI / Memory Integrity off, Credential Guard off, System Guard off, `FeatureSettingsOverride=3` (Spectre/Meltdown mitigations off), plus `bcdedit /set hypervisorlaunchtype off` at first boot |

### Latency

| Group | What it does |
|---|---|
| `network_latency_tweaks` | Nagle's algorithm off (global + per-adapter at first boot), QoS reserved bandwidth set to 0, Delivery Optimization P2P off, WU auto-reboot blocked |
| `disable_mpo` | Disables Multi-Plane Overlay (`Dwm\OverlayTestMode=5`) — the standard fix for flicker and micro-stutter on some NVIDIA/AMD drivers |
| `latency_input_tweaks` | Mouse acceleration off, Sticky Keys / Toggle Keys hotkeys off, DXGI flip model enabled with VRR optimisation on, USB 3 link power management off |
| `interrupt_latency` | Per-device work that only exists on a live machine: MSI interrupts with high priority, NIC interrupt moderation off / RSS on / EEE and flow control off, USB and HID power management off — see [Device latency](#device-latency-and-1-lows) |
| `disable_fso` | Forces true fullscreen exclusive instead of Fullscreen Optimizations |

### Behaviour

| Group | What it does |
|---|---|
| `disable_game_mode` | Turns Windows Game Mode **off** — see the note below |
| `strip_background_noise` | Windows Search indexing off, Bluetooth off, Delivery Optimization service off, background apps globally denied, visual effects off, scripted diagnostics off, memory compression off on 16 GB+ machines |
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
deliberately overrides six of its choices:

| Setting | Core default | Core-Gaming |
|---|---|---|
| Game Mode | on | **off** |
| `SystemResponsiveness` | 0 | **10** (AtlasOS value) |
| Fullscreen Optimizations | on | **off** |
| HAGS | forced on | **toggleable** |
| `useplatformtick` | `yes` (RunOnce) | **deleted** — it is slower than the invariant TSC |
| Memory compression | on | **off** on machines with 16 GB or more |

### Defender and Windows Update are removed, not disabled

Core-Gaming always removes both. This is **not** a group toggle — `-GamingGroups` cannot
turn it off. Build a plain Core image if you want either kept.

**Windows Defender / Security.** A plain Core build only *disables* the Defender services,
which is worse than it sounds: Security Center notices antivirus is off and starts nagging
with "Turn on Windows Security". Core-Gaming instead removes the Defender feature package,
the Windows Security app, the on-disk definition store and the Security Health tray agent,
and deletes the `WinDefend` / `WdNisSvc` / `WdFilter` / `Sense` / `SecurityHealthService`
service keys outright. `wscsvc` (Security Center) and the System Guard services are disabled
rather than deleted, because they are shared Windows plumbing.

**Windows Update.** Disabling `wuauserv` alone does not hold on modern Windows, and it is
why a Core image can still show *"Updates are underway, do not turn off your PC"* on restart:

- `WaaSMedicSvc` (Windows Update Medic) exists specifically to detect a disabled or broken
  Windows Update and **put it back**.
- `UsoSvc` (Update Orchestrator) runs the servicing pass at boot.

Core-Gaming deletes all three service keys, removes the Update Orchestrator scheduled tasks,
sets `NoAutoUpdate`, and hides the Windows Update and Windows Security pages in Settings via
the `SettingsPageVisibility` policy (`hide:windowsupdate;windowsdefender`).

> **What hiding the Settings pages does and does not do.** `SettingsPageVisibility` is a
> *navigation-level* hide — it removes the pages from the Settings list. It is not a removal,
> so a leftover tile, an `ms-settings:windowsupdate` link or a notification can still open the
> page. When that happens the page will fail to render, because the Update Orchestrator and
> Medic services backing it have been deleted. An error there is expected, not a build fault.

`wuaueng.dll` and `wuapi.dll` are deliberately **left in place** — other inbox components
link them, and a missing DLL fails hard rather than degrading. With the services gone,
Windows Update cannot run regardless.

---

## The essentials pass

The gaming groups above are about latency. This layer is about the other thing people
do to a fresh install: the debloat pass. It reproduces the "Essential Tweaks" and
"Advanced Tweaks" list that would otherwise be clicked through by hand after every
install, and bakes the result into the image.

**It has no toggle.** There is no group flag, no `-GamingGroups` key and no workflow
input — a Core-Gaming build always applies it, the same way it always removes Defender
and the Windows Update stack. That is deliberate: the workflow is at GitHub's 25-input
cap, and this is meant to be part of what Core-Gaming *is*, not an option.

Everything lives in [`config/essentials_profile.json`](config/essentials_profile.json).
Every entry carries the name of the checkbox it implements, so the file can be diffed
against the source list item by item.

### What it applies

| Source item | Implementation |
|---|---|
| Activity History — Disable | `EnableActivityFeed`, `PublishUserActivities`, `UploadUserActivities` = 0 |
| BitLocker — Disable | `PreventDeviceEncryption` = 1 (stops 24H2 auto-encrypting on its own) + `BDESVC` disabled |
| Delivery Optimization — Disable | `DODownloadMode` = 0 (policy + config) + `DoSvc` disabled |
| End Task With Right Click — Enable | `TaskbarEndTask` = 1 |
| File Explorer Automatic Folder Discovery — Disable | `FolderType` = `NotSpecified` |
| Hibernation — Disable | `HibernateEnabled` = 0, plus `powercfg -hibernate off` at first boot |
| Location Tracking — Disable | `DisableLocation` / `DisableLocationScripting` / `DisableWindowsLocationProvider` + `lfsvc` disabled |
| Microsoft Store Recommended Search Results — Disable | `SilentInstalledAppsEnabled`, `PreInstalledAppsEnabled`, `SystemPaneSuggestionsEnabled` and the `SubscribedContent-*` set = 0 |
| Prevent Device Companion Apps | `PreventDeviceCompanionAppInstall` = 1 |
| Services — Set to Manual | 58 services across the layer: 40 moved to Manual, 18 disabled (see below) |
| Start Menu Previous Layout — Enable | `Start_Layout` = 1 |
| Telemetry — Disable | `AllowTelemetry` (Core) + `DoNotShowFeedbackNotifications`, `AllowDeviceNameInTelemetry`, `DiagTrack` |
| Widgets — Remove | `AllowNewsAndInterests` = 0, `TaskbarDa` = 0, WebExperience package (Core) |
| Windows Platform Binary Table — Disable | `DisableWpbtExecution` = 1 |
| Microsoft OneDrive — Remove | `DisableFileSyncNGSC` = 1, nav-pane `NameSpace` key deleted, `OneDriveSetup.exe` deleted (Core) |
| Right-Click Menu Previous Layout — Enable | Empty default value on the `{86ca1aa0-…}` `InprocServer32` key |
| Windows AI — Disable And Remove | `DisableAIDataAnalysis`, `AllowRecallEnablement` = 0, AI/Recall packages (Core) |

That is **20 boxes: 17 Essential Tweaks and 3 Advanced Tweaks**, all ticked in the source
list. **17 are implemented here** and **3 are handled elsewhere** — recorded in the
`handledElsewhere` block of the JSON rather than in prose, so the file accounts for all
20 and a test can assert the total:

| Item | Handled by | Why not here |
|---|---|---|
| ConsumerFeatures — Disable | Core `Apply-RegistryTweaks` | `DisableWindowsConsumerFeatures=1` is already set for every image; repeating it would be two sources of truth |
| Temporary Files — Remove | first boot | There is no populated `%TEMP%` inside `install.wim` |
| Restore Point — Create | first boot | Needs a running VSS and a real system volume |

`ESSENTIALS_PROFILE.md` in the image opens with a 20-row coverage table showing, for each
box, which mechanism handles it and where.

### Services: manual vs disabled

The distinction matters, and it is the main reason the process count drops.

- **Manual (40)** — demand-start. The service does not run at boot and no process
  exists until something asks for it. This is safe for the long tail: `AJRouter`,
  `ALG`, `AppReadiness`, `AppXSvc`, `camsvc`, `CDPSvc`, `ClipSVC`, `WdiServiceHost`,
  `WpnService`, `TokenBroker`, `VSS` and friends. `CDPSvc` in particular stays
  **Manual, not Disabled**, because Bluetooth pairing and nearby sharing start it on
  demand.
- **Disabled (18)** — nothing is left to demand it: `BDESVC`, `lfsvc`, `WMPNetworkSvc`,
  `RemoteRegistry`, `WpcMonSvc`, `SEMgrSvc`, `SDRSVC`, `wisvc`, `SharedAccess`,
  `SNMPTRAP`, `RetailDemo`, plus the per-user services behind the removed apps
  (`OneSyncSvc`, `CDPUserSvc`, `UnistoreSvc`, `UserDataSvc`, `PimIndexMaintenanceSvc`,
  `ContactData`, `WalletService`).

The per-user services are the ones that matter for process count. Each of
`UnistoreSvc`, `UserDataSvc`, `PimIndexMaintenanceSvc`, `ContactData`, `CDPUserSvc` and
`OneSyncSvc` normally spawns its own `svchost` at logon. They back Mail, Calendar,
People, Phone Link and clipboard sync — all removed by this build — so disabling them
costs nothing here.

### The safety guard

`essentials-profile.ps1` refuses to touch a hardcoded list of boot-critical services
(`RpcSs`, `DcomLaunch`, `LSM`, `Power`, `PlugPlay`, `EventLog`, `Schedule`, `Winmgmt`,
`AudioSrv`, `BFE`, `mpssvc`, …). A profile edit that tries to disable one is **rejected
at validation time** — before the ISO is downloaded — rather than producing an
unbootable image. Services that do not exist in the image are skipped, never created.

### Process count

The whole point of the list is that a fresh install idles around **100–115** processes
and this lands it at **50–65**. That number is not asserted, it is measurable:

```powershell
powershell -ExecutionPolicy Bypass -File C:\Windows\Tiny11Gaming\Tiny11-Report.ps1
```

The report prints the process count, the service breakdown, every essentials registry
value with an OK/MISS mark, and the startup entries. `-Detailed` adds the full process
and service lists. The build log also records the count during the SetupComplete
session, which reads lower than an interactive desktop — compare like with like.

If you are still above ~70 after logon, the usual causes are a vendor utility
(iCUE, Armoury Crate, Synapse) reinstalled itself, or a driver package that brought its
own tray service.

### First-boot half

Four things cannot be done offline and run from `gaming-firstboot.ps1`, unconditionally,
before the power scheme (because `powercfg -hibernate off` can reset the active scheme):

| Action | Why not offline |
|---|---|
| `powercfg -hibernate off` | Deletes `hiberfil.sys`; the file only exists on an installed system |
| Temp cleanup | `install.wim` ships an empty `%TEMP%`, but setup fills it while laying the image down |
| Restore point | Needs a running VSS and a real system volume. Best-effort — it logs a warning and continues if System Restore is unavailable |
| Process count | Only meaningful on the target machine |

### Deliberately not implemented

- **The Customize Preferences column.** Dark theme, taskbar alignment, scrollbars,
  num lock, S3 sleep and the rest are cosmetic. The two settings from that column that
  actually affect performance — Game Mode and mouse acceleration — are already handled
  by the gaming profile, which stays the single source of truth for those.
- **Disk Cleanup / WinSxS cleanup.** Not ticked in the source list, and `Optimize-WinSxS`
  already handles the WinSxS side.
- **Scheduled defrag/trim, Teredo, IPv6, Visual Effects, Xbox Game Bar, Edge removal.**
  All present in the tool but not ticked, so not carried over. Several are already
  covered by Core anyway (Edge and the Xbox stack are removed unconditionally).

### Things that will feel different

- **OneDrive is gone**, including the Explorer nav-pane entry. Files already in
  `%USERPROFILE%\OneDrive` are untouched, but the client will not start.
- **The Windows 10 right-click menu is back** (no "Show more options" step). Delete
  `HKCU\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}` to restore the
  Windows 11 menu.
- **BitLocker is off and cannot be re-enabled without turning the service back on.**
  On a machine that will hold real data, re-enable `BDESVC` first.
- **A restore point exists but System Restore is not otherwise managed.** It is one
  known-good baseline, not a backup strategy.

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

## Device latency and 1% lows

Average FPS is set by the GPU and the CPU clock. **1% lows are set by waiting**: a frame
that arrives late is usually a frame that was held up by something else finishing — a
DPC, an interrupt shared with another device, a NIC that batched its packets, a storage
link that had to wake up, a USB port that suspended the mouse.

The Core builder works on `install.wim`, where none of that exists yet: there is no PnP
tree, no adapter, no device instance. So this layer is applied at first boot by
`gaming-firstboot.ps1`, gated by the `interrupt_latency` group.

| Applied | Why it moves 1% lows |
|---|---|
| **MSI mode** (`MSISupported=1`) on display, network, USB and audio devices | A line-based interrupt shares an IRQ line with whatever the firmware put there, so one device's ISR delays another's. MSI is a memory write: no sharing, no line to release. |
| **`DevicePriority=High`** on the GPU and NIC | When two ISRs are ready at once, the kernel services the high-priority one first. |
| **NIC interrupt moderation off** | Moderation batches interrupts to save CPU. Batching means the last packet of a burst waits for the timer — directly a late frame in an online game. |
| **RSS on** | Receive queues spread across cores instead of serialising on one. |
| **EEE, flow control, RSC, LSO off** | Each one is a batching or sleep mechanism on the wire. All four trade latency for throughput or power. |
| **USB/HID power management off** (`EnhancedPowerManagementEnabled`, `SelectiveSuspendEnabled`, `AllowIdleIrpInD3`, `DeviceIdleEnabled`) | A suspended port has to wake before it can report. That is not input lag on average — it is an occasional late frame. |
| **Memory compression off** on 16 GB+ | The compression worker is a CPU spike that lands exactly when the game is streaming assets. Below 16 GB the RAM saving is worth more than the spike, so it stays on. |

### What is deliberately not done

Being explicit about the rejected tweaks is more useful than the list above.

- **Interrupt affinity (`DevicePolicy`) is left at the machine default.** Pinning GPU
  interrupts to specific cores is a per-machine experiment; the right answer depends on
  the core topology, and a wrong default is worse than what Windows picks.
- **`useplatformtick` is removed, not set.** Earlier revisions set
  `bcdedit /set useplatformtick yes`. That forces the platform timer (HPET-class) as the
  tick source, which makes every timer read more expensive than the invariant TSC — it
  *raises* DPC cost. It is now deleted at first boot and no longer written by the Core
  builder, so older images get corrected.
- **`useplatformclock true` is not used.** Same class of myth, larger effect. The
  invariant TSC is the correct clock on every CPU this profile targets.
- **`disabledynamictick yes` is kept, but only under `disable_cpu_idle`.** It stops the
  timer going tickless while idle. Mild consistency gain, real idle-power cost.
- **No standby-list "cleaners".** Emptying the standby list on a timer throws away the
  file cache and causes the stutter it claims to fix.
- **No per-vendor GPU registry edits.** Power-management mode belongs in the driver
  profile (NVIDIA Control Panel / AMD Software), where it is supported and reversible.

MSI is the one setting here with a real (if small) hardware risk. It is written **only**
where the driver has already published `MessageSignaledInterruptProperties` — that key
means the driver claims MSI support. A device that rejects the flag keeps its line
interrupt and still boots; nothing here can prevent boot.

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
| Windows Update — service, Update Medic (`WaaSMedicSvc`), Update Orchestrator (`UsoSvc`) and the Settings page | Always removed on a Core-Gaming build |
| Windows Defender / Windows Security Center | Always removed on a Core-Gaming build |
| Memory Integrity / Core Isolation UI | `disable_security_mitigations` |

Steam, Ubisoft Connect and Epic titles are unaffected by the Xbox removal.

---

## Reverting

Two files are written into the image:

| File | Purpose |
|---|---|
| `C:\Windows\Tiny11Gaming\Undo-GamingTweaks.ps1` | Restores the reversible settings |
| `C:\Windows\Tiny11Gaming\GAMING_PROFILE.md` | The exact list of what was changed in *your* build |
| `C:\Windows\Tiny11Gaming\ESSENTIALS_PROFILE.md` | The essentials pass, item by item |
| `C:\Windows\Tiny11Gaming\Tiny11-Report.ps1` | Read-only post-install report: process count, services, every essentials value |
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

- Windows Defender and Windows Update — both are always removed on a Core-Gaming
  build, so there is nothing left to switch back on
- The printing optional features
- The removed Xbox AppX packages
- The `bcdedit` mitigation flags (changeable with `bcdedit`, but not by this script)
- The `interrupt_latency` device settings — MSI mode, interrupt priority and NIC
  advanced properties are written per device on the live machine. They are harmless to
  leave in place, and Device Manager / `Set-NetAdapterAdvancedProperty` is the supported
  way to change them back
- **The essentials pass is not touched by the undo script at all.** It is a separate
  layer with its own data file, and undoing it would mean re-enabling telemetry and
  reinstalling OneDrive — which is not what anyone running this build wants. The
  individual keys are listed in `ESSENTIALS_PROFILE.md` if you need to reverse one by
  hand

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
  (C-State 0, no core parking, mitigations off, MPO off, MSI mode) mostly show up in 1%
  lows and input latency, not in a big average-FPS number.
- **Disabling VBS/HVCI is the largest single lever**, typically quoted at 5–15% on
  affected titles. It is also the biggest security cost.
- **The device layer is worth more on some machines than others.** MSI mode and
  interrupt moderation matter most when a machine has several devices on one IRQ line or
  a NIC with aggressive moderation — both are common on consumer boards and both are
  invisible in a benchmark average.
- **Some tweaks are marginal or hardware-specific.** Timer settings in particular help
  some rigs and do nothing — or regress — on others. That is why the profile now removes
  `useplatformtick` instead of setting it.
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
├── essentials-profile.ps1    # debloat engine (dot-sourced by the builder, always on)
├── gaming-firstboot.ps1      # runs once as SYSTEM on the target machine
├── Tiny11-Report.ps1         # read-only post-install report
└── Undo-GamingTweaks.ps1     # revert, shipped inside the image

config/
├── gaming_profile.json       # every tweak, grouped
├── gaming_power_settings.json# power scheme + bcdedit definition
└── essentials_profile.json   # the debloat pass, one entry per checkbox
```

Order of operations during a build:

1. **Image-level removals** — AppX packages, system packages and optional features,
   while the registry hives are still unloaded.
2. **Essentials registry** — between `Apply-RegistryTweaks` and
   `Apply-PerformanceTweaks`, so performance and gaming settings always outrank privacy
   and cosmetic ones if two ever collide.
3. **Registry tweaks** — after `Apply-PerformanceTweaks`, so Core-Gaming can override
   the Core defaults. Hives are `HKLM\zSYSTEM`, `zSOFTWARE`, `zDEFAULT`, `zNTUSER`.
4. **Service tweaks** — essentials first, then gaming. A service key that does not
   exist in the image is skipped rather than created.
5. **Payload injection** — before `Dismount-AndExport`, so files land inside
   `install.wim`. Only `install.wim` is touched; `boot.wim` is left alone because
   Ventoy inspects and patches it.

At first boot, `Windows\Setup\Scripts\SetupComplete.cmd` runs
`gaming-firstboot.ps1` **as SYSTEM, before the first logon**. That hook is used because
the power scheme GUID is machine-specific, the BCD store is not part of `install.wim`,
network adapters do not exist until drivers enumerate, and the PnP tree (MSI-capable
devices, USB instances) does not exist until the target machine boots. Per-user settings
do not go there — they are written into the Default user hive offline so every new
profile inherits them.

The essentials stage runs first inside that script, because `powercfg -hibernate off`
can reset the active power scheme and the scheme must be created last.

Everything is best-effort: a missing service or an unavailable DISM feature logs a
warning and continues. A half-applied gaming profile beats a failed 90-minute build.

---

## Attribution

The tweak set is modelled on [AtlasOS](https://github.com/Atlas-OS/Atlas), which is
GPLv3. No Atlas code or artifacts are redistributed here — the power scheme is
generated from Microsoft's own `powercfg` templates, and every setting is a documented
Windows registry value. Thanks to the Atlas team for documenting their reasoning
publicly.
