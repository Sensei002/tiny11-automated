# Tiny11 LTSC

**Windows 11 / Windows 10 Enterprise LTSC builds, driven by a name instead of an index.**

---

## What this adds

Two workflows alongside the existing ones:

| Workflow | File | Builder | Serviceable |
|----------|------|---------|-------------|
| **Build and Release Tiny11 LTSC** | `build-tiny11-ltsc.yml` | `tiny11maker-headless.ps1` | ✅ Yes |
| **Build and Release Tiny11 Core LTSC** | `build-tiny11-core-ltsc.yml` | `tiny11coremaker-headless.ps1` | ❌ No (WinSxS stripped) |

Both take a pasted ISO URL and an edition name. Neither takes an image index.

## Why there is no index menu

On a consumer ISO the indexes are stable and well known — 1 Home, 4 Education,
6 Pro, 7 Pro N. LTSC media is a different animal:

| Media | Index | Edition |
|-------|-------|---------|
| Windows 11 Enterprise LTSC 2024 (26100) | 1 | Windows 11 Enterprise LTSC |
| | 2 | Windows 11 IoT Enterprise LTSC |
| | 3 | Windows 11 IoT Enterprise Subscription LTSC |
| Windows 10 Enterprise LTSC 2021 (19044) | 1 | Windows 10 Enterprise LTSC |
| | 2 | Windows 10 IoT Enterprise LTSC |

Three images on one media, two on the other, and the numbers mean different things
depending on which ISO was pasted. A dropdown of `1 / 2 / 3` would be a trap: pick 3
against Windows 10 media and the build fails late, pick 2 and you get IoT when you
wanted plain Enterprise — silently, because both build fine.

So the index is **derived**, then **verified**:

1. The edition name is looked up in `scripts/ltsc-edition-catalog.ps1`.
2. The ISO is mounted, and `Get-WindowsImage` is asked what it actually carries.
3. The image is matched **by name**, and the ISO's own index is used for the build.
4. The builder gets `-ExpectedEdition` and re-checks the name after it mounts the
   image. A mismatch fails the build instead of shipping the wrong SKU.

If Microsoft ever reorders the media, step 3 logs a warning and follows the ISO. If
you paste a Windows 10 ISO while a Windows 11 edition is selected, the run stops in
about a second with `Wrong ISO`.

## Getting the ISO

LTSC media is not on Microsoft's public download page, so there is no runtime
resolver and no default URL. Paste a direct link into `windows_iso_url`:

- **VLSC / MVS** — if you have a volume or Visual Studio subscription, download the
  LTSC ISO and copy the link from the download manager.
- **Evaluation Center** — the Windows 11 Enterprise LTSC 2024 evaluation ISO is
  public and works with the IoT indexes too.
- Any mirror you trust. The run records the SHA256 of what it built, not of what it
  downloaded, so verify your source separately.

The link only needs to live for the duration of the run — it is fetched once, at the
start.

## What the build changes

Everything the Standard or Core variant already does, on an LTSC base:

- Edge, EdgeWebView and Edge Update removed
- OneDrive removed
- Xbox / Game Bar, Teams, Copilot, Chat removed
- Telemetry and diagnostics disabled
- TPM / Secure Boot / CPU / RAM checks bypassed
- Offline local account, OOBE skipped (`auto-admin`) or your own name (`classic`)

LTSC already ships without the Store, Copilot and the consumer app set, so the
removal list is shorter than on a consumer ISO. That is the point of starting here.

## Things worth knowing

**Servicing.** Windows 11 Enterprise LTSC 2024 gets five years (to roughly late 2029);
the IoT editions get ten (to roughly late 2034). Windows 10 Enterprise LTSC 2021 ends
in January 2027, while Windows 10 IoT Enterprise LTSC 2021 runs to January 2032 —
a difference of five years for one dropdown entry. Check Microsoft's lifecycle page
before you commit a fleet.

**Core gives that away.** A Core build strips WinSxS, which is exactly what makes it
non-serviceable. On an LTSC base you are trading the one thing LTSC exists for — a
decade of security updates — for a smaller image. Use the serviceable workflow if
servicing matters.

**Subscription LTSC.** Index 3 needs a subscription licence to stay activated. It
builds and installs fine without one; it just will not stay activated.

**Windows 10 LTSC is not a Windows 11 build.** The tweak set is applied best-effort
and skips anything the OS does not have. Windows 11-only registry paths are written
anyway and simply have no effect.

## Building locally

The builders take the same parameter, so a local build gets the same protection:

```powershell
.\scripts\tiny11maker-headless.ps1 -ISO E -INDEX 2 -ExpectedEdition 'Windows 11 IoT Enterprise LTSC'
```

`-INDEX` is a hint. The name wins: if the edition is not at that index, the builder
logs `Index shifted!` and uses the real one. If it is not on the ISO at all, the build
stops and prints every image the ISO does contain.

`-ExpectedEdition` is optional, so nothing about the existing consumer builds changes.

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| `Wrong ISO` | The pasted media is the other Windows family | Pick an edition from the same family as the ISO |
| `Index shifted!` warning | Microsoft reordered the media | Nothing — the build follows the ISO |
| `Unable to determine Windows build number` | `install.wim` metadata unreadable | Fill the `windows_build` fallback input |
| Build stops at ~10% | Something removed `winre.wim` | Not possible here; WinRE is always kept |
| ISO installs the wrong edition | Should not happen | Check the run log for the `Selected:` line |

## Where things live

```
scripts/ltsc-edition-catalog.ps1          the five editions, their indexes and slugs
scripts/tiny11maker-headless.ps1          -ExpectedEdition support (Standard)
scripts/tiny11coremaker-headless.ps1      -ExpectedEdition support (Core)
.github/workflows/build-tiny11-ltsc.yml        serviceable LTSC build
.github/workflows/build-tiny11-core-ltsc.yml   Core LTSC build
tests/Test-LtscEditions.Tests.ps1         44 assertions over all of the above
```

The catalogue is the only place an index is written down. If Microsoft adds an
edition, that file plus the dropdown in both workflows are the only two edits.
