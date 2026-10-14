#!/usr/bin/env python3
"""
Discord Notification System for Tiny11 Builds
Author: kelexine (https://github.com/kelexine)
"""

import os
import sys
import json
import time
import argparse
from datetime import datetime, timezone, timedelta
from typing import Dict, List, Optional

import requests
import re

# Discord embed field values are capped at 1024 chars and the whole
# embed at 6000. Keep generous margins below those hard limits.
MAX_FIELD_LENGTH = 1000
MAX_ERROR_LENGTH = 1000


class DiscordNotificationError(Exception):
    """Raised for invalid input/configuration that prevents sending a notification."""


class DiscordNotifier:
    """Send rich notifications to Discord via webhooks"""

    COLORS = {
        'success': 0x00FF00,  # Green
        'error': 0xFF0000,    # Red
        'info': 0x3498DB,     # Blue
        'warning': 0xFFA500,  # Orange
        'release': 0x9B59B6   # Purple
    }

    # Retry/backoff configuration for transient Discord/network failures.
    MAX_ATTEMPTS = 3
    BACKOFF_BASE_SECONDS = 1.5

    def __init__(self, webhook_url: str):
        if not webhook_url:
            raise DiscordNotificationError("Discord webhook URL is empty")
        self.webhook_url = webhook_url

    @staticmethod
    def _truncate(text: str, limit: int = MAX_FIELD_LENGTH) -> str:
        """Truncate text to fit within a Discord embed field value."""
        if text is None:
            return ""
        if len(text) <= limit:
            return text
        return text[: max(limit - 3, 0)].rstrip() + "..."

    @staticmethod
    def _sanitize_error(error: Optional[str]) -> str:
        """Make arbitrary build-log error text safe to embed in a Discord code block."""
        if not error or not error.strip():
            return "No error details captured."
        # Triple backticks would prematurely close the code block; neutralize them.
        cleaned = error.replace('```', "'''").strip()
        if len(cleaned) > MAX_ERROR_LENGTH:
            cleaned = cleaned[:MAX_ERROR_LENGTH].rstrip() + "\n... (truncated, see full logs)"
        return cleaned

    @staticmethod
    def _next_weekly_check(now: Optional[datetime] = None) -> str:
        """Compute the next scheduled weekly-summary run (Sundays at 02:00 UTC)."""
        now = now or datetime.now(timezone.utc)
        days_until_sunday = (6 - now.weekday()) % 7  # Monday=0 ... Sunday=6
        candidate = (now + timedelta(days=days_until_sunday)).replace(
            hour=2, minute=0, second=0, microsecond=0
        )
        if candidate <= now:
            candidate += timedelta(days=7)
        return candidate.strftime('%Y-%m-%d %H:%M UTC')

    def _redact(self, message: str) -> str:
        """Strip the webhook token from log output using regex."""
        return re.sub(
            r'(https://discord(?:app)?\.com/api/webhooks/\d+/)[\w-]+',
            r'\1<token>',
            message,
        )

    def send_embed(
        self,
        title: str,
        description: str,
        color: str = 'info',
        fields: Optional[List[Dict]] = None,
        thumbnail: Optional[str] = None,
        image: Optional[str] = None
    ) -> bool:
        """Send a rich embed message to Discord, with retry/backoff on transient failures."""

        embed = {
            'title': title,
            'description': description,
            'color': self.COLORS.get(color, self.COLORS['info']),
            'timestamp': datetime.now(timezone.utc).isoformat(),
            'footer': {
                'text': 'Tiny11 Automated Builder • kelexine',
                'icon_url': 'https://avatars.githubusercontent.com/u/70432347'
            }
        }

        if fields:
            embed['fields'] = fields

        if thumbnail:
            embed['thumbnail'] = {'url': thumbnail}

        if image:
            embed['image'] = {'url': image}

        payload = {
            'username': 'Tiny11 Builder',
            'avatar_url': 'https://raw.githubusercontent.com/kelexine/tiny11-automated/main/.github/assets/bot-avatar.png',
            'embeds': [embed]
        }

        for attempt in range(1, self.MAX_ATTEMPTS + 1):
            try:
                response = requests.post(self.webhook_url, json=payload, timeout=10)

                if response.status_code == 429:
                    retry_after = self.BACKOFF_BASE_SECONDS * attempt
                    try:
                        retry_after = max(retry_after, float(response.headers.get('Retry-After', 0)))
                    except (TypeError, ValueError):
                        pass
                    print(f"⚠️  Discord rate limit hit (attempt {attempt}/{self.MAX_ATTEMPTS}); "
                          f"retrying in {retry_after:.1f}s")
                    if attempt < self.MAX_ATTEMPTS:
                        time.sleep(retry_after)
                        continue
                    return False

                response.raise_for_status()
                return True

            except requests.exceptions.RequestException as e:
                print(f"❌ Discord notification failed (attempt {attempt}/{self.MAX_ATTEMPTS}): "
                      f"{self._redact(str(e))}")
                if attempt < self.MAX_ATTEMPTS:
                    time.sleep(self.BACKOFF_BASE_SECONDS * attempt)
                    continue
                return False

        return False

    def notify_new_releases(self, releases: List[Dict]) -> bool:
        """Notify about newly detected Windows releases"""

        if releases:
            lines = []
            for r in releases[:10]:  # Limit to 10 for embed size
                version = r.get('version', 'Unknown')
                build_number = r.get('build_number', 'Unknown')
                title = r.get('title', 'Untitled release')
                if len(title) > 50:
                    title = title[:50].rstrip() + '...'
                lines.append(f"• **{version}** - Build {build_number} ({title})")

            release_list = '\n'.join(lines)
            if len(releases) > 10:
                release_list += f"\n... and {len(releases) - 10} more"
        else:
            release_list = "No release details available"

        fields = [
            {
                'name': '📦 Detected Releases',
                'value': self._truncate(release_list),
                'inline': False
            },
            {
                'name': '🏗️ Builds Queued',
                'value': f'{len(releases) * 6} total builds (Standard, Core, Nano × Home, Pro)',
                'inline': True
            },
            {
                'name': '⏱️ Estimated Time',
                'value': f'~{len(releases) * 30}-{len(releases) * 80} minutes',
                'inline': True
            }
        ]

        return self.send_embed(
            title='🆕 New Windows Releases Detected!',
            description=f'Found **{len(releases)}** new Windows 11 build(s) ready for processing.',
            color='release',
            fields=fields,
            thumbnail='https://upload.wikimedia.org/wikipedia/commons/e/e6/Windows_11_logo.svg'
        )

    def notify_build_started(
        self,
        version: str,
        build_type: str,
        edition: str,
        extra_fields: Optional[List[Dict]] = None
    ) -> bool:
        """Notify when a build job starts"""

        fields = [
            {'name': 'Version', 'value': version, 'inline': True},
            {'name': 'Type', 'value': build_type, 'inline': True},
            {'name': 'Edition', 'value': edition, 'inline': True}
        ]

        if extra_fields:
            fields.extend(extra_fields)

        return self.send_embed(
            title='🏗️ Build Started',
            description=f'Starting {build_type} build for Windows {version} ({edition})',
            color='info',
            fields=fields
        )

    def notify_build_completed(
        self,
        version: str,
        build_type: str,
        edition: str,
        duration: str,
        iso_size: str,
        download_url: Optional[str] = None,
        extra_fields: Optional[List[Dict]] = None
    ) -> bool:
        """Notify when a build completes successfully"""

        fields = [
            {'name': 'Version', 'value': version, 'inline': True},
            {'name': 'Type', 'value': build_type, 'inline': True},
            {'name': 'Edition', 'value': edition, 'inline': True},
            {'name': 'Duration', 'value': duration or 'Unknown', 'inline': True},
            {'name': 'ISO Size', 'value': iso_size or 'Unknown', 'inline': True},
            {'name': 'Status', 'value': '✅ Ready', 'inline': True}
        ]

        if extra_fields:
            fields.extend(extra_fields)

        if download_url:
            fields.append({
                'name': '📥 Download',
                'value': f'[SourceForge]({download_url})',
                'inline': False
            })

        return self.send_embed(
            title='✅ Build Completed Successfully!',
            description=f'Tiny11 {build_type} for Windows {version} ({edition}) is ready!',
            color='success',
            fields=fields
        )

    def notify_build_failed(
        self,
        version: str,
        build_type: str,
        edition: str,
        error: str,
        logs_url: str,
        duration: Optional[str] = None
    ) -> bool:
        """Notify when a build fails"""

        fields = [
            {'name': 'Version', 'value': version, 'inline': True},
            {'name': 'Type', 'value': build_type, 'inline': True},
            {'name': 'Edition', 'value': edition, 'inline': True},
        ]

        if duration:
            fields.append({'name': 'Ran for', 'value': duration, 'inline': True})

        fields.append({
            'name': 'Error',
            'value': f'```\n{self._sanitize_error(error)}\n```',
            'inline': False
        })
        fields.append({
            'name': '📋 Logs & Artifacts',
            'value': f'[View Full Logs]({logs_url})',
            'inline': False
        })

        return self.send_embed(
            title='❌ Build Failed',
            description=f'Build failed for Windows {version} ({build_type} - {edition})',
            color='error',
            fields=fields
        )

    def notify_daily_summary(
        self,
        checks_today: int,
        new_releases: int,
        builds_completed: int,
        builds_failed: int
    ) -> bool:
        """Send periodic build/check statistics summary"""

        total_builds = builds_completed + builds_failed
        success_rate = (builds_completed / total_builds * 100) if total_builds else 100.0

        fields = [
            {'name': '🔍 Checks Performed', 'value': str(checks_today), 'inline': True},
            {'name': '🆕 New Releases', 'value': str(new_releases), 'inline': True},
            {'name': '✅ Builds Completed', 'value': str(builds_completed), 'inline': True},
            {'name': '❌ Builds Failed', 'value': str(builds_failed), 'inline': True},
            {'name': '📊 Success Rate', 'value': f'{success_rate:.1f}%', 'inline': True},
            {'name': '⏰ Next Check', 'value': self._next_weekly_check(), 'inline': True}
        ]

        return self.send_embed(
            title='📊 Build Summary',
            description='Summary of recent automated build activity',
            color='info',
            fields=fields
        )

    def notify_builds_triggered(self, builds_count: int, releases: List[Dict]) -> bool:
        """Notify that automated builds have been triggered"""

        release_titles = [r.get('title', 'Unknown Release') for r in releases]
        release_text = "\n".join([f"• {t}" for t in release_titles[:5]])
        if len(release_titles) > 5:
            release_text += f"\n... and {len(release_titles) - 5} more"

        fields = [
            {'name': '🚀 Triggered Builds', 'value': str(builds_count), 'inline': True},
            {'name': 'targets', 'value': 'Standard, Core, Nano (Home & Pro)', 'inline': True},
            {'name': 'For Releases', 'value': self._truncate(release_text) if release_text else "No release info", 'inline': False}
        ]

        return self.send_embed(
            title='🚀 Automated Builds Triggered',
            description=f'Matrix build successfully triggered for {len(releases)} release(s).',
            color='success',
            fields=fields
        )


def _require(data: Dict, *keys: str) -> None:
    """Raise a clear, actionable error if required JSON fields are missing."""
    missing = [k for k in keys if k not in data or data[k] is None]
    if missing:
        raise DiscordNotificationError(
            f"Missing required field(s) in --data JSON: {', '.join(missing)}"
        )


def _build_extra_fields(data: Dict) -> Optional[List[Dict]]:
    """Build optional Discord embed fields from well-known optional keys in the data payload.

    Currently surfaces:
      - windows_build   → 'Build' field (real detected Windows build number)
      - preserve_winre  → 'WinRE' field (Core / Nano builds)
      - enable_dotnet35 → '.NET 3.5' field (Core builds)
      - gaming_profile  → 'Gaming profile' field (Core-Gaming builds)
      - hags_mode       → 'HAGS' field (Core-Gaming builds)

    Unknown keys are silently ignored so future callers can extend the payload
    without touching this function.
    """
    fields: List[Dict] = []

    if 'windows_build' in data and data['windows_build']:
        fields.append({
            'name': 'Build',
            'value': str(data['windows_build']),
            'inline': True
        })

    if 'preserve_winre' in data and data['preserve_winre'] is not None:
        val = str(data['preserve_winre']).lower()
        fields.append({
            'name': 'WinRE',
            'value': '✅ Preserved' if val == 'true' else '❌ Removed (stub)',
            'inline': True
        })

    if 'enable_dotnet35' in data and data['enable_dotnet35'] is not None:
        val = str(data['enable_dotnet35']).lower()
        fields.append({
            'name': '.NET 3.5',
            'value': '✅ Enabled' if val == 'true' else '❌ Disabled',
            'inline': True
        })

    if 'gaming_profile' in data and data['gaming_profile']:
        fields.append({
            'name': 'Gaming profile',
            'value': str(data['gaming_profile']),
            'inline': True
        })

    if 'hags_mode' in data and data['hags_mode']:
        fields.append({
            'name': 'HAGS',
            'value': str(data['hags_mode']),
            'inline': True
        })

    return fields if fields else None


def main():
    """CLI interface for Discord notifications"""

    parser = argparse.ArgumentParser(description='Send Discord notifications')
    parser.add_argument(
        '--webhook',
        required=False,
        default=None,
        help='Discord webhook URL (falls back to the DISCORD_WEBHOOK env var if omitted)'
    )
    parser.add_argument('--type', required=True, choices=[
        'new-releases', 'build-started', 'build-completed',
        'build-failed', 'daily-summary', 'builds-triggered'
    ])
    parser.add_argument('--data', help='JSON data for notification')

    args = parser.parse_args()

    webhook_url = args.webhook or os.environ.get('DISCORD_WEBHOOK', '')
    if not webhook_url:
        print(f"⚠️  No Discord webhook configured for '--type {args.type}' "
              "(pass --webhook or set DISCORD_WEBHOOK); skipping notification.")
        return 0

    try:
        data = json.loads(args.data) if args.data else {}
    except json.JSONDecodeError as e:
        print(f"❌ Invalid JSON in --data: {e}")
        return 1

    if args.data and not isinstance(data, (dict, list)):
        print("❌ --data must be a JSON object or array")
        return 1

    # Coerce known embed fields to strings so Discord doesn't 400 on numeric values
    if isinstance(data, dict):
        for k in ('version', 'build_type', 'edition', 'duration', 'iso_size', 'error', 'logs_url', 'windows_build', 'gaming_profile', 'hags_mode'):
            if k in data and data[k] is not None:
                data[k] = str(data[k])

    try:
        notifier = DiscordNotifier(webhook_url)

        if args.type == 'new-releases':
            # Handle both list (direct releases) and dict (wrapped in 'releases' key)
            releases = data if isinstance(data, list) else data.get('releases', [])
            success = notifier.notify_new_releases(releases)

        elif args.type == 'builds-triggered':
            success = notifier.notify_builds_triggered(
                data.get('builds_count', 0),
                data.get('releases', [])
            )

        elif args.type == 'build-started':
            _require(data, 'version', 'build_type', 'edition')
            extra_fields = _build_extra_fields(data)
            success = notifier.notify_build_started(
                data['version'], data['build_type'], data['edition'],
                extra_fields=extra_fields
            )

        elif args.type == 'build-completed':
            _require(data, 'version', 'build_type', 'edition', 'duration', 'iso_size')
            extra_fields = _build_extra_fields(data)
            success = notifier.notify_build_completed(
                data['version'], data['build_type'], data['edition'],
                data['duration'], data['iso_size'], data.get('download_url'),
                extra_fields=extra_fields
            )

        elif args.type == 'build-failed':
            _require(data, 'version', 'build_type', 'edition', 'error', 'logs_url')
            success = notifier.notify_build_failed(
                data['version'], data['build_type'], data['edition'],
                data['error'], data['logs_url'], data.get('duration')
            )

        elif args.type == 'daily-summary':
            _require(data, 'checks_today', 'new_releases', 'builds_completed', 'builds_failed')
            success = notifier.notify_daily_summary(
                data['checks_today'], data['new_releases'],
                data['builds_completed'], data['builds_failed']
            )

        else:
            print(f"Unknown notification type: {args.type}")
            return 1

    except DiscordNotificationError as e:
        print(f"❌ {e}")
        return 1

    return 0 if success else 1


if __name__ == '__main__':
    sys.exit(main())

