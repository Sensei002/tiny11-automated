# Tiny11 Automated Builder

## 🏠 Project Overview

This is the **SourceForge download page** for Tiny11 Automated Builder - a streamlined Windows 11 ISO creation tool. For the latest source code, documentation, and to contribute, please visit our GitHub repository.

## 📥 Downloads

Browse our organized folders below to find the edition and version you need:

### 📁 Folder Structure
- **Tiny11-HOME-{VERSION}** - Standard Tiny11 builds for Home edition
- **Tiny11-PRO-{VERSION}** - Standard Tiny11 builds for Pro edition
- **Tiny11-EDUCATION-{VERSION}** - Standard Tiny11 builds for Education edition
- **Tiny11Core-HOME-{VERSION}** - Minimal Core builds for Home edition
- **Tiny11Core-PRO-{VERSION}** - Minimal Core builds for Pro edition
- **Nano11-HOME-{VERSION}** - EXTREME minimal builds (VM testing only)
- **Nano11-PRO-{VERSION}** - EXTREME minimal builds (VM testing only)

### 🔍 Finding Your Build
Each folder contains:
- `.iso` - The Windows 11 image file
- `.iso.sha256` - SHA256 checksum for verification
- `.iso.md5` - MD5 checksum for verification
- `.iso.txt` - Build information and file details (includes WinRE/recovery status for Core/Nano)

## 🚀 Quick Links

- **GitHub Repository**: [https://github.com/Sensei002/tiny11-automated](https://github.com/Sensei002/tiny11-automated)
- **Latest Releases**: Check GitHub for the most recent builds
- **Documentation**: Full documentation available on GitHub
- **Issues & Support**: Report issues on GitHub


## 📋 Build Types

### Tiny11 (Standard)
- Serviceable Windows 11 image
- Removes 50+ bloatware apps including AI/Copilot/Recall
- Complete removal of Microsoft Edge WebView2 footprints (Program Files and WinSxS assemblies)
- Enhanced telemetry blocking and privacy protection
- VRAM gaming optimization
- Maintains WinSxS for updates
- Suitable for regular use
- **NEW**: 4 non-essential services disabled

### Tiny11 Core
- Ultra-minimal Windows 11 image
- Complete removal of Microsoft Edge WebView2 footprints (Program Files and WinSxS assemblies)
- Aggressive WinSxS removal
- Windows Update binaries removed (~300 MB saved)
- No Windows Updates possible (NON-SERVICEABLE)
- WinRE (Recovery Environment) removed by default — preservable via build flag for real-hardware installs
- Designed for VMs and testing only
- **NOT suitable for daily use**
- **NEW**: 13 non-essential services disabled

### Nano11
- EXTREME minimal Windows 11 image
- Complete removal of Microsoft Edge WebView2 footprints (Program Files and WinSxS assemblies)
- Removes drivers, fonts, services, apps
- Windows Update binaries removed (~300 MB saved)
- No printing, no Notepad/Paint
- WinRE (Recovery Environment) removed by default — preservable via build flag for real-hardware installs
- **FOR VM TESTING ONLY**
- Smallest possible footprint (~1.7-2.5GB)
- **NEW**: 14 services removed, AI/Recall fully purged

## ⚠️ Important Notes

1. **License**: You need a valid Windows license from Microsoft
2. **Security**: These images remove Windows Defender and disable updates
3. **Purpose**: Educational and testing purposes only
4. **Support**: No affiliation with Microsoft

## 🔧 Build Information

All builds are created automatically via GitHub Actions with:
- Latest Windows 11 versions (24H2, 25H2)
- Multiple language support
- Various editions (Home, Pro, Education)
- Optional .NET Framework 3.5 support
- Optional WinRE (Recovery Environment) preservation for Core/Nano builds — recommended for real-hardware installs to avoid setup error 0x8007000B
- Bypassed hardware requirements (TPM, Secure Boot, RAM)

## 📧 Contact

For questions, issues, or contributions, please use the GitHub repository:
- Issues: [https://github.com/Sensei002/tiny11-automated/issues](https://github.com/Sensei002/tiny11-automated/issues)
- Discussions: [https://github.com/Sensei002/tiny11-automated/discussions](https://github.com/Sensei002/tiny11-automated/discussions)

## ⚖️ Disclaimer

This is an unofficial Windows 11 modification. Use at your own risk. Not affiliated with Microsoft. Requires valid Windows license.

---

**Built with ❤️ by the community, for the community**