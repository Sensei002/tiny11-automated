#!/usr/bin/env python3
"""
Windows 11 Release Detection & Monitoring System
Author: Sensei002 (https://github.com/Sensei002)

Monitors multiple sources for new Windows 11 releases and triggers builds.
"""

import os
import sys
import json
import logging
import requests
import re
from datetime import datetime, timedelta
from typing import List, Dict, Optional
from dataclasses import dataclass, asdict
from pathlib import Path

# Import Microsoft Playwright downloader (replaces old scraper)
try:
    from microsoft_direct_downloader import MicrosoftPlaywrightDownloader
except ImportError:
    import sys
    from pathlib import Path
    sys.path.insert(0, str(Path(__file__).parent))
    from microsoft_direct_downloader import MicrosoftPlaywrightDownloader

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)


@dataclass
class WindowsRelease:
    """Represents a Windows 11 release"""
    build_id: str
    build_number: str
    version: str
    title: str
    iso_url: str
    detected_date: str
    architecture: str
    channel: str = "retail"
    language: str = "en-us"
    checksum_sha256: Optional[str] = None
    size_bytes: Optional[int] = None


class ReleaseDetector:
    """Detects new Windows 11 releases from multiple sources"""
    
    def __init__(self, tracking_file: str = "tracked_releases.json"):
        self.tracking_file = Path(tracking_file)
        self.tracked_data = self._load_tracked()
        # Sources are now defined dynamically in detect_new_releases
    
    def _load_tracked(self) -> Dict:
        """Load previously tracked releases"""
        if self.tracking_file.exists():
            try:
                with open(self.tracking_file, 'r') as f:
                    return json.load(f)
            except json.JSONDecodeError:
                logger.warning(f"Invalid JSON in {self.tracking_file}, starting fresh")
        
        return {
            'builds': {},
            'last_check': None,
            'check_count': 0
        }
    
    def _save_tracked(self):
        """Save tracked releases to file"""
        self.tracked_data['last_check'] = datetime.now().isoformat()
        self.tracked_data['check_count'] = self.tracked_data.get('check_count', 0) + 1
        
        with open(self.tracking_file, 'w') as f:
            json.dump(self.tracked_data, f, indent=2)
        
        logger.info(f"✅ Saved tracking data to {self.tracking_file}")
    
    def _check_uupdump(self) -> List[WindowsRelease]:
        """Check UUP Dump API for new releases"""
        logger.info("🔍 Checking UUP Dump...")
        
        try:
            response = requests.get(
                "https://api.uupdump.net/listid.php",
                params={
                    'search': 'Windows 11',
                    'sortByDate': '1'
                },
                timeout=30
            )
            response.raise_for_status()
            data = response.json()
            
            # Debug: Log response structure
            logger.debug(f"API Response keys: {data.keys() if isinstance(data, dict) else 'Not a dict'}")
            
            # Validate response structure
            if not isinstance(data, dict):
                logger.error(f"❌ Invalid response type: {type(data)}")
                return []
            
            if 'response' not in data:
                logger.error(f"❌ Missing 'response' key in data: {list(data.keys())}")
                return []
            
            response_data = data.get('response', {})
            if not isinstance(response_data, dict):
                logger.error(f"❌ Invalid response data type: {type(response_data)}")
                return []
            
            builds_data = response_data.get('builds', {})
            
            # UUP Dump API returns builds as a dict, not a list!
            if not isinstance(builds_data, dict):
                logger.error(f"❌ Unexpected builds data type: {type(builds_data)}")
                return []
            
            logger.info(f"📦 Found {len(builds_data)} total builds from API")
            
            releases = []
            processed = 0
            
            # Convert dict to list of builds and process first 30
            # Sort by key (numeric) to get most recent first
            sorted_keys = sorted(builds_data.keys(), key=lambda x: int(x) if x.isdigit() else 0, reverse=True)
            
            for key in sorted_keys[:30]: # Process only the most recent 30 builds
                build = builds_data[key]
                
                if not isinstance(build, dict):
                    logger.warning(f"⚠️  Skipping non-dict build at key {key}: {type(build)}")
                    continue
                
                processed += 1
                build_id = build.get('uuid')
                title = build.get('title', '')
                arch = build.get('arch', '')
                
                # Filter for x64 Windows 11
                if 'Windows 11' not in title or arch != 'amd64':
                    continue
                
                # Extract version
                version = self._extract_version(title)
                
                release = WindowsRelease(
                    build_id=build_id,
                    build_number=build.get('build', 'Unknown'),
                    version=version,
                    title=title,
                    iso_url=f"https://uupdump.net/download.php?id={build_id}&pack=en-us&edition=professional",
                    detected_date=datetime.now().isoformat(),
                    architecture=arch,
                    channel='retail' if 'Insider' not in title else 'insider'
                )
                
                releases.append(release)
                logger.info(f"  ✨ Found: {title}")
            
            logger.info(f"✅ Processed {processed} builds, found {len(releases)} new Windows 11 x64 releases from UUP Dump")
            return releases
            
        except requests.RequestException as e:
            logger.error(f"❌ Network error during UUP Dump check: {e}")
            return []
        except json.JSONDecodeError as e:
            logger.error(f"❌ Invalid JSON response from UUP Dump: {e}")
            return []
        except KeyError as e:
            logger.error(f"❌ Missing expected key in API response: {e}")
            return []
        except Exception as e:
            logger.error(f"❌ UUP Dump check failed: {type(e).__name__}: {e}")
            import traceback
            logger.debug(traceback.format_exc())
            return []
    
    def _extract_version(self, title: str) -> str:
        """Extract Windows version from title"""
        # Try explicit version strings first (most reliable)
        version_patterns = [
            (r'version\s+(\d{2}H\d)', 'direct'),  # "version 24H2"
            (r'\b(\d{2}H\d)\b', 'standalone'),    # "24H2" standalone
        ]
        
        for pattern, ptype in version_patterns:
            import re
            match = re.search(pattern, title, re.IGNORECASE)
            if match:
                return match.group(1).upper()
        
        # Fallback: map build numbers to versions
        build_match = re.search(r'\((\d{5})', title)
        if build_match:
            build_num = int(build_match.group(1))
            
            # Build number ranges for versions
            if 26200 <= build_num < 27000:
                return '25H2'
            elif 26100 <= build_num < 26200:
                return '24H2'
            elif 26220 <= build_num < 27000:
                return 'Insider-26H2'  # Future insider builds
            elif 28000 <= build_num < 29000:
                return 'Insider-28xxx'  # Canary builds
            elif 22621 <= build_num < 23000:
                return '22H2'
            elif 22631 <= build_num < 23000:
                return '23H2'
        
        # If still unknown, mark as Insider if title contains it
        if 'insider' in title.lower() or 'preview' in title.lower():
            return 'Insider-Preview'
        
        return 'Unknown'
    
    def _check_microsoft_direct(self) -> List[WindowsRelease]:
        """
        Get direct ISO download link from Microsoft via Playwright automation
        This replaces UUP Dump URLs with actual direct Microsoft CDN links
        """
        logger.info("🔍 Checking Microsoft Direct Downloads (Playwright)...")
        
        try:
            downloader = MicrosoftPlaywrightDownloader(headless=True, timeout=60000)
            versions = downloader.get_all_versions()
            
            releases = []
            for v in versions:
                # Skip if already tracked
                if v['build_id'] in self.tracked_data.get('builds', {}):
                    logger.debug(f"  ⏭️  Already tracked: {v['build_id']}")
                    continue
                
                release = WindowsRelease(
                    build_id=v['build_id'],
                    build_number=v['build_number'],
                    version=v['version'],
                    title=v['title'],
                    iso_url=v['iso_url'],  # DIRECT ISO URL from Microsoft!
                    detected_date=v['detected_date'],
                    architecture=v['architecture'],
                    channel=v['channel'],
                    language=v['language']
                )
                
                releases.append(release)
                logger.info(f"  ✨ Found direct ISO: {v['title']}")
            
            logger.info(f"✅ Got {len(releases)} direct download link(s) from Microsoft")
            return releases
            
        except Exception as e:
            logger.error(f"❌ Microsoft Playwright check failed: {e}")
            import traceback
            logger.debug(traceback.format_exc())
            return []
    
    def _compare_builds(self, build1: str, build2: str) -> int:
        """
        Compare two build numbers
        
        Args:
            build1: First build number (e.g., "26100.1234")
            build2: Second build number (e.g., "26100.5678")
        
        Returns:
            1 if build1 > build2, -1 if build1 < build2, 0 if equal
        """
        try:
            # Extract numeric parts (handle formats like "26100.1234" or "26100")
            def parse_build(build: str) -> tuple:
                parts = build.split('.')
                # Convert to integers, pad with 0 if needed
                major = int(parts[0]) if parts else 0
                minor = int(parts[1]) if len(parts) > 1 else 0
                return (major, minor)
            
            b1 = parse_build(build1)
            b2 = parse_build(build2)
            
            if b1 > b2:
                return 1
            elif b1 < b2:
                return -1
            else:
                return 0
        except (ValueError, IndexError) as e:
            logger.warning(f"⚠️  Error comparing builds {build1} vs {build2}: {e}")
            return 0
    
    def _deduplicate_by_version(self, releases: List[WindowsRelease]) -> List[WindowsRelease]:
        """
        Keep only the latest build per version to avoid triggering too many builds
        
        For example, if we detect:
        - 24H2 Build 26100.1000
        - 24H2 Build 26100.2000
        - 25H2 Build 26200.1000
        
        We'll keep only:
        - 24H2 Build 26100.2000 (latest)
        - 25H2 Build 26200.1000
        
        Args:
            releases: List of WindowsRelease objects
        
        Returns:
            Deduplicated list with one release per version
        """
        logger.info(f"📊 Deduplicating {len(releases)} releases by version...")
        
        version_map = {}
        for release in releases:
            version = release.version
            
            if version not in version_map:
                version_map[version] = release
                logger.debug(f"  First {version}: Build {release.build_number}")
            else:
                # Keep the one with higher build number
                existing = version_map[version]
                comparison = self._compare_builds(release.build_number, existing.build_number)
                
                if comparison > 0:
                    logger.info(f"  ✨ Updating {version}: {existing.build_number} → {release.build_number}")
                    version_map[version] = release
                elif comparison < 0:
                    logger.debug(f"  ⏭️  Skipping older {version}: {release.build_number} (keeping {existing.build_number})")
                else:
                    logger.debug(f"  ⏭️  Skipping duplicate {version}: {release.build_number}")
        
        deduped = list(version_map.values())
        logger.info(f"✅ Deduplicated to {len(deduped)} releases (one per version)")
        
        for release in deduped:
            logger.info(f"  📦 {release.version}: Build {release.build_number}")
        
        return deduped
    
    def detect_new_releases(self, force: bool = False) -> List[WindowsRelease]:
        """
        Detect new releases from all sources
        
        Args:
            force: Force check even if recently checked
        
        Returns:
            List of new WindowsRelease objects
        """
        # Check if we should skip (checked recently)
        if not force and self.tracked_data.get('last_check'):
            last_check = datetime.fromisoformat(self.tracked_data['last_check'])
            if datetime.now() - last_check < timedelta(hours=1):
                logger.info("⏭️  Skipping check (checked less than 1 hour ago)")
                return []
        
        all_releases = []
        
        # Define enabled sources (microsoft_direct is primary, UUP Dump is backup)
        sources = {
            'microsoft_direct': True,   # Primary - direct ISO links via Playwright
            'uupdump': True,            # Backup - version detection
        }
        
        # Check each enabled source
        for source_name, enabled in sources.items():
            if not enabled:
                logger.info(f"  ⏭️  Skipping disabled source: {source_name}")
                continue
            
            try:
                logger.info(f"🎯 Checking {source_name}...")
                
                if source_name == 'microsoft_direct':
                    source_releases = self._check_microsoft_direct()
                elif source_name == 'uupdump':
                    source_releases = self._check_uupdump()
                else:
                    logger.warning(f"⚠️  Unknown source: {source_name}")
                    continue
                
                all_releases.extend(source_releases)
            except Exception as e:
                logger.error(f"❌ Source check failed: {e}")
                import traceback
                logger.debug(traceback.format_exc())
                continue
        
        # Deduplicate by build_id first
        unique_releases = {r.build_id: r for r in all_releases}
        
        # Then deduplicate by version (keep only latest build per version)
        # This prevents triggering 90 builds when we should only trigger 12-18
        version_deduped = self._deduplicate_by_version(list(unique_releases.values()))
        
        # Update tracked data with ALL unique releases (not just deduped ones)
        # This ensures we don't re-detect older builds later
        for release in unique_releases.values():
            self.tracked_data['builds'][release.build_id] = asdict(release)
        
        # Save tracking data
        self._save_tracked()
        
        # Return only version-deduplicated releases for building
        return version_deduped
    
    def generate_matrix(self, releases: List[WindowsRelease]) -> Dict:
        """
        Generate GitHub Actions matrix from releases
        
        Returns:
            Dictionary suitable for matrix strategy
        """
        logger.info(f"🎯 Generating build matrix for {len(releases)} versions")
        
        matrix = {
            'include': []
        }
        
        for release in releases:
            logger.info(f"  📦 {release.version}: Build {release.build_number}")
            
            # Generate matrix entries for different build types
            for build_type in ['standard', 'core', 'nano']:
                for edition in [1, 6]:  # Home, Pro
                    matrix['include'].append({
                        'version': release.version,
                        'build': release.build_number,
                        'iso_url': release.iso_url,
                        'build_type': build_type,
                        'edition': edition,
                        'edition_name': 'Home' if edition == 1 else 'Pro',
                        'title': release.title.replace(' ', '_').replace('(', '').replace(')', '')
                    })
        
        total_builds = len(matrix['include'])
        logger.info(f"✅ Generated {total_builds} total builds ({len(releases)} versions × 3 types × 2 editions)")
        
        return matrix
    
    def create_github_issue(self, release: WindowsRelease) -> Dict:
        """
        Generate GitHub issue data for new release
        
        Returns:
            Dictionary with issue title and body
        """
        body = f"""## 🎉 New Windows Release Detected

**Build Information:**
- **Title:** {release.title}
- **Build Number:** {release.build_number}
- **Version:** {release.version}
- **Architecture:** {release.architecture}
- **Channel:** {release.channel}
- **Detection Date:** {release.detected_date}

**ISO Source:**
- {release.iso_url}

**Automated Actions:**
- [ ] Trigger Tiny11 Standard build
- [ ] Trigger Tiny11 Core build
- [ ] Trigger Nano11 build
- [ ] Test builds in VM
- [ ] Upload to SourceForge
- [ ] Update documentation

**Build Matrix:**
- Home Edition (Standard, Core, Nano)
- Pro Edition (Standard, Core, Nano)

---
*This issue was automatically created by the Version Matrix Builder*  
*Author: [Sensei002](https://github.com/Sensei002)*
"""
        
        return {
            'title': f"🆕 New Windows {release.version} Release - Build {release.build_number}",
            'body': body,
            'labels': ['automated', 'new-release', 'build-pending']
        }


def main():
    """Main execution function"""
    import argparse
    
    parser = argparse.ArgumentParser(
        description='Windows 11 Release Detection System'
    )
    parser.add_argument(
        '--force',
        action='store_true',
        help='Force check even if recently checked'
    )
    parser.add_argument(
        '--output',
        default='github_output.txt',
        help='GitHub Actions output file'
    )
    parser.add_argument(
        '--tracking-file',
        default='tracked_releases.json',
        help='Release tracking file'
    )
    
    args = parser.parse_args()
    
    # Initialize detector
    detector = ReleaseDetector(tracking_file=args.tracking_file)
    
    # Detect new releases
    logger.info("🚀 Starting release detection...")
    new_releases = detector.detect_new_releases(force=args.force)
    
    if not new_releases:
        logger.info("📭 No new releases detected")
        
        # Write outputs for GitHub Actions
        with open(args.output, 'w') as f:
            f.write("has_new=false\n")
            f.write("new_releases=[]\n")
            f.write("releases_matrix=[]\n")
        
        return 0
    
    # We found new releases!
    logger.info(f"✅ Found {len(new_releases)} new release(s)!")
    
    for release in new_releases:
        logger.info(f"  - {release.title} (Build {release.build_number})")
    
    # Generate matrix
    # note: we output the list of releases directly. The YAML workflow handles
    # the expansion of build types and editions via its own matrix strategy.
    
    # Prepare data for GitHub Actions output
    # Use compact JSON to avoid multi-line issues
    new_releases_json = json.dumps([asdict(r) for r in new_releases], separators=(',', ':'))
    
    # Write outputs for GitHub Actions (single line format)
    with open(args.output, 'w') as f:
        f.write("has_new=true\n")
        f.write(f"new_releases={new_releases_json}\n")
        f.write(f"releases_matrix={new_releases_json}\n")
        f.write(f"release_count={len(new_releases)}\n")
    
    logger.info("✅ Detection complete!")
    return 0


if __name__ == '__main__':
    sys.exit(main())