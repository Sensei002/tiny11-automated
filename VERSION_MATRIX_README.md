# Version Matrix Builder

**Automated Windows 11 Release Detection & Build Trigger System**  
*Author: [Sensei002](https://github.com/Sensei002)*

---

## 🎯 Overview

The Version Matrix Builder automatically monitors for new Windows 11 releases and triggers your Tiny11 build workflows without manual intervention. It checks weekly for new builds from UUP Dump and creates a build matrix for Standard, Core, and Nano variants across Home and Pro editions.

## 🏗️ Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                  weekly Scheduled Check (00:00 UTC)          │
└────────────────────────┬────────────────────────────────────┘
                         │
                         ▼
┌─────────────────────────────────────────────────────────────┐
│            UUP Dump API - Fetch Latest Builds               │
│  • Filter for Windows 11 x64 only                           │
│  • Extract version info (23H2, 24H2, 25H2, Insider)         │
│  • Generate ISO download URLs                               │
└────────────────────────┬────────────────────────────────────┘
                         │
                         ▼
┌─────────────────────────────────────────────────────────────┐
│          Compare Against tracked_releases.json              │
│  • Deduplicate by build_id                                  │
│  • Track detection timestamps                               │
│  • Count check iterations                                   │
└────────────────────────┬────────────────────────────────────┘
                         │
                         ▼
        ┌────────────────┴────────────────┐
        │     New Releases Detected?       │
        └────┬────────────────────────┬────┘
             │ NO                     │ YES
             ▼                        ▼
    ┌────────────────┐    ┌──────────────────────────┐
    │   Exit Clean    │    │   Create GitHub Issues   │
    └────────────────┘    │   (1 per release)        │
                          └────────────┬─────────────┘
                                       │
                                       ▼
                          ┌──────────────────────────┐
                          │  Generate Build Matrix   │
                          │  • Standard × Home/Pro   │
                          │  • Core × Home/Pro       │
                          │  • Nano × Home/Pro       │
                          └────────────┬─────────────┘
                                       │
                                       ▼
                          ┌──────────────────────────┐
                          │  Trigger Build Workflows │
                          │  (Parallel Execution)    │
                          └────────────┬─────────────┘
                                       │
                                       ▼
                          ┌──────────────────────────┐
                          │   Builds Complete        │
                          │   Upload to SourceForge  │
                          └──────────────────────────┘
```

## 📁 File Structure

```
tiny11-automated/
├── .github/
│   └── workflows/
│       ├── version-matrix-builder.yml    # Main automation workflow
│       ├── build-tiny11.yml              # Standard builds
│       ├── build-tiny11-core.yml         # Core builds
│       └── build-nano11.yml              # Nano builds
├── scripts/
│   ├── release_detector.py               # Python detection script
│   └── test_uupdump_api.py              # API testing tool
├── requirements.txt                      # Python dependencies
├── tracked_releases.json                 # Build tracking database
└── README.md
```

## 🚀 Quick Start

### 1. Setup

```bash
# Clone your repository
git clone https://github.com/Sensei002/tiny11-automated.git
cd tiny11-automated

# Run setup script
chmod +x setup_matrix_builder.sh
./setup_matrix_builder.sh
```

### 2. Test Locally

```bash
# Test API connectivity
python3 scripts/test_uupdump_api.py

# Test detection (dry run)
python3 scripts/release_detector.py --force

# Check outputs
cat github_output.txt
cat tracked_releases.json
```

### 3. Deploy to GitHub

```bash
# Commit files
git add .github/workflows/version-matrix-builder.yml
git add scripts/release_detector.py scripts/test_uupdump_api.py
git add requirements.txt tracked_releases.json
git commit -m "🤖 Add Version Matrix Builder"
git push origin main
```

### 4. Trigger First Run

1. Go to **Actions** → **Version Matrix Builder**
2. Click **Run workflow**
3. Enable `force_check` to test
4. Watch logs for detection results

## ⚙️ Configuration

### Workflow Inputs

| Input | Type | Default | Description |
|-------|------|---------|-------------|
| `force_check` | boolean | `false` | Force check even if recently ran |
| `skip_build` | boolean | `false` | Only detect, don't trigger builds |

### Environment Variables

```yaml
UUPDUMP_API: https://api.uupdump.net
RELEASE_TRACKING_FILE: tracked_releases.json
```

### Build Matrix Configuration

Edit `scripts/release_detector.py` to customize:

```python
def generate_matrix(self, releases: List[WindowsRelease]) -> Dict:
    """Customize build types and editions here"""
    for build_type in ['standard', 'core', 'nano']:  # ← Modify build types
        for edition in [1, 6]:  # ← 1=Home, 6=Pro, 4=Education
            # ...
```

## 📊 Tracking Data

The `tracked_releases.json` file maintains:

```json
{
  "builds": {
    "build-uuid": {
      "build_id": "uuid",
      "build_number": "26100.7462",
      "version": "24H2",
      "title": "Windows 11, version 24H2",
      "iso_url": "https://uupdump.net/...",
      "detected_date": "2025-12-21T10:30:17Z",
      "architecture": "amd64",
      "channel": "retail"
    }
  },
  "last_check": "2025-12-21T10:30:17Z",
  "check_count": 42
}
```

## 🔍 Version Detection

The system uses a multi-stage approach:

1. **Explicit Version Strings**: Matches "version 24H2", "version 25H2", etc.
2. **Standalone Markers**: Finds "24H2", "25H2" in titles
3. **Build Number Mapping**:
   - `22621-22999` → 22H2
   - `22631-23000` → 23H2  
   - `26100-26199` → 24H2
   - `26200-26999` → 25H2
   - `28000+` → Insider-28xxx (Canary)
4. **Insider Fallback**: Marks preview builds appropriately

## 🎯 Build Matrix Output

For each detected release, generates 6 build configurations:

```json
{
  "version": "24H2",
  "build": "26100.7462",
  "iso_url": "https://...",
  "build_type": "standard",  // or "core", "nano"
  "edition": 1,               // 1=Home, 6=Pro
  "edition_name": "Home",
  "title": "Windows_11_version_24H2_26100.7462"
}
```
## 🧪 Scraper Testing Suite

To ensure that the direct downloader browser scraping engine behaves correctly even if Microsoft changes their DOM structure, the project maintains a comprehensive mock unit test suite in the `tests/` directory.

To install dependencies and execute the test harness:
```bash
# 1. Initialize local virtual environment
python3 -m venv .venv
source .venv/bin/activate

# 2. Install dependencies & test packages
pip install -r requirements.txt pytest pytest-asyncio

# 3. Run the pytest suite
pytest tests/test_microsoft_downloader.py
```
This test suite is automatically executed inside the GitHub Actions runner during the CI workflow to block and prevent broken builds or matrix dispatches.

## 🐛 Troubleshooting

### No Releases Detected

```bash
# Check API manually
python3 scripts/test_uupdump_api.py

# Force detection
python3 scripts/release_detector.py --force

# View tracking data
cat tracked_releases.json | python3 -m json.tool
```

### Workflow Fails

1. Check **Actions** logs for specific error
2. Verify `requirements.txt` is committed
3. Ensure `scripts/release_detector.py` exists
4. Check Python syntax: `python3 -m py_compile scripts/release_detector.py`

### Builds Not Triggering

1. Verify other workflows exist: `build-tiny11.yml`, `build-tiny11-core.yml`, `build-nano11.yml`
2. Check workflow permissions: Settings → Actions → Workflow permissions
3. Enable workflow dispatch: Edit workflows → Enable "workflow_dispatch"

## 📈 Performance

**Detection Speed:**
- API Query: ~1-2 seconds
- Processing: ~2-5 seconds per 30 builds
- Total: ~10-15 seconds per check

**Build Matrix Scale:**
- 1 release = 6 builds (3 types × 2 editions)
- 15 releases = 90 parallel builds
- GitHub Actions concurrent limit: 20 (adjust with `max-parallel`)

## 🔐 Security

- No API keys required for UUP Dump
- Uses `GITHUB_TOKEN` for workflow triggers
- SourceForge uploads require `SOURCEFORGE_API_KEY` secret

### Adding Secrets

```bash
# GitHub Settings → Secrets → New repository secret
SOURCEFORGE_API_KEY: your-api-key-here
```

## 🎨 Customization

### Add New Build Type

1. Create workflow: `.github/workflows/build-custom.yml`
2. Add to matrix generation:
   ```python
   for build_type in ['standard', 'core', 'nano', 'custom']:
   ```
3. Map to workflow file:
   ```python
   workflowMap = {
       'custom': 'build-custom.yml'
   }
   ```

### Add New Edition

```python
for edition in [1, 4, 6, 7]:  # Home, Education, Pro, Pro N
```

### Change Detection Frequency

```yaml
schedule:
  - cron: '0 */12 * * *'  # Every 12 hours instead of weekly
```

## 📝 Logs & Monitoring

**Check Detection Logs:**
```bash
# View GitHub Actions logs
Actions → Version Matrix Builder → Latest run → check-releases

# View local logs
python3 scripts/release_detector.py --force 2>&1 | tee detection.log
```

**Monitor Build Status:**
- GitHub Issues: Auto-created for each new release
- Actions Dashboard: Shows all triggered builds
- SourceForge: Check upload status

## 🤝 Contributing

Improvements welcome! Areas for enhancement:

- [ ] Add Microsoft Update Catalog as source
- [ ] Implement checksum verification
- [ ] Add Discord/Slack notifications
- [ ] Create web dashboard for tracking
- [ ] Add automated VM testing
- [ ] Support multiple languages

## 📄 License

MIT License - See main repository for details

## 🙏 Attribution

- Original Tiny11 builders: [ntdevlabs](https://github.com/ntdevlabs)
- Version Matrix automation: [Sensei002](https://github.com/Sensei002)
- UUP Dump API: [uupdump.net](https://uupdump.net)

---

**Made with ❤️ for the Windows community by Sensei002**
