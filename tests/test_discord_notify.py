# tests/test_discord_notify.py
# Unit and integration tests for Discord notification system
# Author: Sensei002 (https://github.com/Sensei002)

import json
import os
import sys
from datetime import datetime, timezone, timedelta
from unittest.mock import MagicMock, patch

import pytest

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), '../scripts')))

from discord_notify import (
    DiscordNotifier,
    DiscordNotificationError,
    _require,
    _build_extra_fields,
    main,
)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _make_notifier(url: str = "https://discord.com/api/webhooks/0/token") -> DiscordNotifier:
    return DiscordNotifier(url)


def _ok_response():
    r = MagicMock()
    r.status_code = 204
    r.raise_for_status = MagicMock()
    return r


def _rate_limit_response(retry_after: float = 1.0):
    r = MagicMock()
    r.status_code = 429
    r.headers = {'Retry-After': str(retry_after)}
    r.raise_for_status = MagicMock()
    return r


# ---------------------------------------------------------------------------
# DiscordNotifier.__init__
# ---------------------------------------------------------------------------

class TestInit:
    def test_rejects_empty_webhook(self):
        with pytest.raises(DiscordNotificationError):
            DiscordNotifier("")

    def test_accepts_valid_url(self):
        n = _make_notifier()
        assert n.webhook_url.startswith("https://")


# ---------------------------------------------------------------------------
# _truncate
# ---------------------------------------------------------------------------

class TestTruncate:
    def test_short_string_unchanged(self):
        assert DiscordNotifier._truncate("hello") == "hello"

    def test_exact_limit_unchanged(self):
        s = "x" * 1000
        assert DiscordNotifier._truncate(s) == s

    def test_over_limit_truncated_with_ellipsis(self):
        result = DiscordNotifier._truncate("x" * 1050)
        assert len(result) <= 1000
        assert result.endswith("...")

    def test_none_returns_empty(self):
        assert DiscordNotifier._truncate(None) == ""

    def test_custom_limit(self):
        result = DiscordNotifier._truncate("hello world", limit=5)
        assert len(result) <= 5
        assert result.endswith("...")


# ---------------------------------------------------------------------------
# _sanitize_error
# ---------------------------------------------------------------------------

class TestSanitizeError:
    def test_normal_error_passes_through(self):
        assert "some error" in DiscordNotifier._sanitize_error("some error")

    def test_empty_string_returns_default(self):
        assert DiscordNotifier._sanitize_error("") == "No error details captured."

    def test_none_returns_default(self):
        assert DiscordNotifier._sanitize_error(None) == "No error details captured."

    def test_whitespace_only_returns_default(self):
        assert DiscordNotifier._sanitize_error("   ") == "No error details captured."

    def test_triple_backtick_neutralized(self):
        result = DiscordNotifier._sanitize_error("error with ```code block```")
        assert "```" not in result

    def test_long_error_truncated_with_note(self):
        result = DiscordNotifier._sanitize_error("e" * 1100)
        assert len(result) <= 1100
        assert "truncated" in result

    def test_exact_max_length_not_truncated(self):
        result = DiscordNotifier._sanitize_error("e" * 1000)
        assert "truncated" not in result


# ---------------------------------------------------------------------------
# _next_weekly_check
# ---------------------------------------------------------------------------

class TestNextWeeklyCheck:
    def test_returns_string_with_utc(self):
        result = DiscordNotifier._next_weekly_check()
        assert isinstance(result, str)
        assert "UTC" in result

    def test_result_is_in_future(self):
        now = datetime.now(timezone.utc)
        result = DiscordNotifier._next_weekly_check(now)
        dt = datetime.strptime(result, '%Y-%m-%d %H:%M UTC').replace(tzinfo=timezone.utc)
        assert dt > now

    def test_result_is_a_sunday(self):
        now = datetime(2026, 6, 17, 10, 0, tzinfo=timezone.utc)  # Wednesday
        result = DiscordNotifier._next_weekly_check(now)
        dt = datetime.strptime(result, '%Y-%m-%d %H:%M UTC').replace(tzinfo=timezone.utc)
        assert dt.weekday() == 6  # Sunday

    def test_result_is_at_0200_utc(self):
        now = datetime(2026, 6, 17, 10, 0, tzinfo=timezone.utc)
        result = DiscordNotifier._next_weekly_check(now)
        dt = datetime.strptime(result, '%Y-%m-%d %H:%M UTC').replace(tzinfo=timezone.utc)
        assert dt.hour == 2
        assert dt.minute == 0

    def test_sunday_before_run_returns_today(self):
        now = datetime(2026, 6, 21, 0, 30, tzinfo=timezone.utc)  # Sun 00:30
        result = DiscordNotifier._next_weekly_check(now)
        dt = datetime.strptime(result, '%Y-%m-%d %H:%M UTC').replace(tzinfo=timezone.utc)
        assert dt.date() == now.date()

    def test_sunday_after_run_returns_next_week(self):
        now = datetime(2026, 6, 21, 3, 0, tzinfo=timezone.utc)  # Sun 03:00
        result = DiscordNotifier._next_weekly_check(now)
        dt = datetime.strptime(result, '%Y-%m-%d %H:%M UTC').replace(tzinfo=timezone.utc)
        assert dt.date() == (now + timedelta(days=7)).date()


# ---------------------------------------------------------------------------
# _redact
# ---------------------------------------------------------------------------

class TestRedact:
    def test_redacts_webhook_url(self):
        n = _make_notifier("https://discord.com/api/webhooks/123/secret")
        msg = n._redact("error calling https://discord.com/api/webhooks/123/secret: timeout")
        assert "secret" not in msg

    def test_safe_message_unchanged(self):
        n = _make_notifier()
        assert n._redact("connection timeout") == "connection timeout"


# ---------------------------------------------------------------------------
# _build_extra_fields
# ---------------------------------------------------------------------------

class TestBuildExtraFields:
    def test_returns_none_for_empty_data(self):
        assert _build_extra_fields({}) is None

    def test_preserve_winre_true(self):
        fields = _build_extra_fields({'preserve_winre': 'true'})
        assert fields is not None
        winre = next(f for f in fields if f['name'] == 'WinRE')
        assert '✅' in winre['value']

    def test_preserve_winre_false(self):
        fields = _build_extra_fields({'preserve_winre': 'false'})
        assert fields is not None
        winre = next(f for f in fields if f['name'] == 'WinRE')
        assert '❌' in winre['value']

    def test_enable_dotnet35_true(self):
        fields = _build_extra_fields({'enable_dotnet35': 'true'})
        assert fields is not None
        dotnet = next(f for f in fields if f['name'] == '.NET 3.5')
        assert '✅' in dotnet['value']

    def test_enable_dotnet35_false(self):
        fields = _build_extra_fields({'enable_dotnet35': 'false'})
        dotnet = next(f for f in fields if f['name'] == '.NET 3.5')
        assert '❌' in dotnet['value']

    def test_both_fields_present(self):
        fields = _build_extra_fields({'preserve_winre': 'true', 'enable_dotnet35': 'false'})
        assert fields is not None
        names = [f['name'] for f in fields]
        assert 'WinRE' in names
        assert '.NET 3.5' in names

    def test_none_value_ignored(self):
        assert _build_extra_fields({'preserve_winre': None}) is None

    def test_unknown_keys_silently_ignored(self):
        assert _build_extra_fields({'some_future_key': 'value'}) is None

    def test_windows_build_present(self):
        fields = _build_extra_fields({'windows_build': '26200.8655'})
        assert fields is not None
        build = next(f for f in fields if f['name'] == 'Build')
        assert build['value'] == '26200.8655'

    def test_windows_build_empty_string_ignored(self):
        assert _build_extra_fields({'windows_build': ''}) is None

    def test_windows_build_none_ignored(self):
        assert _build_extra_fields({'windows_build': None}) is None

    def test_windows_build_alongside_other_fields(self):
        fields = _build_extra_fields({
            'windows_build': '26200.8655',
            'preserve_winre': 'true',
            'enable_dotnet35': 'false'
        })
        names = [f['name'] for f in fields]
        assert names == ['Build', 'WinRE', '.NET 3.5']


# ---------------------------------------------------------------------------
# send_embed — HTTP interactions
# ---------------------------------------------------------------------------

class TestSendEmbed:
    @patch('requests.post')
    def test_success_on_204(self, mock_post):
        mock_post.return_value = _ok_response()
        assert _make_notifier().send_embed("T", "D") is True

    @patch('requests.post')
    def test_payload_timestamp_is_tz_aware(self, mock_post):
        mock_post.return_value = _ok_response()
        _make_notifier().send_embed("T", "D")
        ts = mock_post.call_args[1]['json']['embeds'][0]['timestamp']
        parsed = datetime.fromisoformat(ts)
        assert parsed.tzinfo is not None

    @patch('time.sleep')
    @patch('requests.post')
    def test_retries_on_rate_limit(self, mock_post, mock_sleep):
        mock_post.side_effect = [_rate_limit_response(), _ok_response()]
        assert _make_notifier().send_embed("T", "D") is True
        assert mock_post.call_count == 2

    @patch('time.sleep')
    @patch('requests.post')
    def test_fails_after_max_rate_limit_attempts(self, mock_post, mock_sleep):
        mock_post.return_value = _rate_limit_response()
        assert _make_notifier().send_embed("T", "D") is False
        assert mock_post.call_count == DiscordNotifier.MAX_ATTEMPTS

    @patch('time.sleep')
    @patch('requests.post')
    def test_retries_on_network_error(self, mock_post, mock_sleep):
        import requests as req
        mock_post.side_effect = [req.exceptions.RequestException("timeout"), _ok_response()]
        assert _make_notifier().send_embed("T", "D") is True
        assert mock_post.call_count == 2

    @patch('time.sleep')
    @patch('requests.post')
    def test_fails_after_max_network_errors(self, mock_post, mock_sleep):
        import requests as req
        mock_post.side_effect = req.exceptions.RequestException("timeout")
        assert _make_notifier().send_embed("T", "D") is False
        assert mock_post.call_count == DiscordNotifier.MAX_ATTEMPTS


# ---------------------------------------------------------------------------
# notify_build_started — extra_fields surfaced
# ---------------------------------------------------------------------------

class TestNotifyBuildStarted:
    @patch('requests.post')
    def test_preserve_winre_extra_field_surfaced(self, mock_post):
        mock_post.return_value = _ok_response()
        n = _make_notifier()
        # Simulate calling via CLI path that calls _build_extra_fields
        extra = _build_extra_fields({'preserve_winre': 'true'})
        n.notify_build_started("25H2", "Nano", "Home", extra_fields=extra)
        fields = mock_post.call_args[1]['json']['embeds'][0]['fields']
        assert any(f['name'] == 'WinRE' for f in fields)

    @patch('requests.post')
    def test_no_extra_fields_when_none(self, mock_post):
        mock_post.return_value = _ok_response()
        n = _make_notifier()
        n.notify_build_started("25H2", "Standard", "Pro")
        fields = mock_post.call_args[1]['json']['embeds'][0]['fields']
        assert not any(f['name'] == 'WinRE' for f in fields)


# ---------------------------------------------------------------------------
# notify_build_completed — extra_fields + duration
# ---------------------------------------------------------------------------

class TestNotifyBuildCompleted:
    @patch('requests.post')
    def test_real_duration_included(self, mock_post):
        mock_post.return_value = _ok_response()
        _make_notifier().notify_build_completed("25H2", "Nano", "Home", "42m 17s", "3.20 GB")
        fields = mock_post.call_args[1]['json']['embeds'][0]['fields']
        dur = next(f for f in fields if f['name'] == 'Duration')
        assert dur['value'] == '42m 17s'

    @patch('requests.post')
    def test_download_field_added_when_url_given(self, mock_post):
        mock_post.return_value = _ok_response()
        _make_notifier().notify_build_completed(
            "25H2", "Nano", "Home", "42m", "3.20 GB",
            "https://sourceforge.net/projects/tiny11-automated/"
        )
        fields = mock_post.call_args[1]['json']['embeds'][0]['fields']
        assert any(f['name'] == '📥 Download' for f in fields)

    @patch('requests.post')
    def test_winre_and_dotnet_fields_surfaced(self, mock_post):
        mock_post.return_value = _ok_response()
        extra = _build_extra_fields({'preserve_winre': 'false', 'enable_dotnet35': 'true'})
        _make_notifier().notify_build_completed(
            "25H2", "Core", "Home", "55m", "3.10 GB", extra_fields=extra
        )
        fields = mock_post.call_args[1]['json']['embeds'][0]['fields']
        names = [f['name'] for f in fields]
        assert 'WinRE' in names
        assert '.NET 3.5' in names


# ---------------------------------------------------------------------------
# notify_build_failed — error sanitization + duration
# ---------------------------------------------------------------------------

class TestNotifyBuildFailed:
    @patch('requests.post')
    def test_triple_backtick_sanitized(self, mock_post):
        mock_post.return_value = _ok_response()
        _make_notifier().notify_build_failed(
            "25H2", "Nano", "Home",
            "error with ```block```",
            "https://github.com/Sensei002/tiny11-automated/actions/runs/1"
        )
        error_field = next(
            f for f in mock_post.call_args[1]['json']['embeds'][0]['fields']
            if f['name'] == 'Error'
        )
        # Only the two fence markers should appear, not a 3rd from the error text
        assert error_field['value'].count('```') == 2

    @patch('requests.post')
    def test_duration_field_present_when_provided(self, mock_post):
        mock_post.return_value = _ok_response()
        _make_notifier().notify_build_failed(
            "25H2", "Nano", "Home", "err", "https://x.com", duration="12m 34s"
        )
        fields = mock_post.call_args[1]['json']['embeds'][0]['fields']
        assert any(f['name'] == 'Ran for' for f in fields)

    @patch('requests.post')
    def test_duration_absent_when_not_provided(self, mock_post):
        mock_post.return_value = _ok_response()
        _make_notifier().notify_build_failed("25H2", "Nano", "Home", "err", "https://x.com")
        fields = mock_post.call_args[1]['json']['embeds'][0]['fields']
        assert not any(f['name'] == 'Ran for' for f in fields)


# ---------------------------------------------------------------------------
# notify_daily_summary
# ---------------------------------------------------------------------------

class TestNotifyDailySummary:
    @patch('requests.post')
    def test_100_percent_when_no_failures(self, mock_post):
        mock_post.return_value = _ok_response()
        _make_notifier().notify_daily_summary(10, 2, 8, 0)
        fields = mock_post.call_args[1]['json']['embeds'][0]['fields']
        rate = next(f for f in fields if f['name'] == '📊 Success Rate')
        assert '100.0%' in rate['value']

    @patch('requests.post')
    def test_100_percent_when_no_builds(self, mock_post):
        mock_post.return_value = _ok_response()
        _make_notifier().notify_daily_summary(5, 0, 0, 0)
        fields = mock_post.call_args[1]['json']['embeds'][0]['fields']
        rate = next(f for f in fields if f['name'] == '📊 Success Rate')
        assert '100.0%' in rate['value']

    @patch('requests.post')
    def test_next_check_is_dynamic(self, mock_post):
        mock_post.return_value = _ok_response()
        _make_notifier().notify_daily_summary(1, 0, 1, 0)
        fields = mock_post.call_args[1]['json']['embeds'][0]['fields']
        nc = next(f for f in fields if f['name'] == '⏰ Next Check')
        assert 'Tomorrow' not in nc['value']
        assert 'UTC' in nc['value']


# ---------------------------------------------------------------------------
# notify_new_releases
# ---------------------------------------------------------------------------

class TestNotifyNewReleases:
    @patch('requests.post')
    def test_handles_empty_list(self, mock_post):
        mock_post.return_value = _ok_response()
        assert _make_notifier().notify_new_releases([]) is True

    @patch('requests.post')
    def test_caps_at_10_in_list_field(self, mock_post):
        mock_post.return_value = _ok_response()
        releases = [{'version': '25H2', 'build_number': str(i), 'title': f'B{i}'} for i in range(15)]
        _make_notifier().notify_new_releases(releases)
        detected = next(
            f for f in mock_post.call_args[1]['json']['embeds'][0]['fields']
            if f['name'] == '📦 Detected Releases'
        )
        assert "5 more" in detected['value']


# ---------------------------------------------------------------------------
# notify_update_available
# ---------------------------------------------------------------------------

class TestNotifyUpdateAvailable:
    @patch('requests.post')
    def test_empty_list_is_a_no_op(self, mock_post):
        mock_post.return_value = _ok_response()
        assert _make_notifier().notify_update_available([]) is False
        mock_post.assert_not_called()

    @patch('requests.post')
    def test_lists_updates_with_kb_build_and_previous(self, mock_post):
        mock_post.return_value = _ok_response()
        updates = [{'family': '26300', 'kb': 'KB5127648', 'build': '26300.9711', 'previous_kb': 'KB5129195'}]
        _make_notifier().notify_update_available(updates)
        embed = mock_post.call_args[1]['json']['embeds'][0]
        assert embed['color'] == DiscordNotifier.COLORS['update']
        field = next(f for f in embed['fields'] if f['name'] == '🔄 New Cumulative Update(s)')
        assert 'KB5127648' in field['value']
        assert '26300.9711' in field['value']
        assert 'KB5129195' in field['value']   # previous KB is surfaced
        assert '26H2' in field['value']        # friendly family label

    @patch('requests.post')
    def test_new_family_has_no_previous(self, mock_post):
        mock_post.return_value = _ok_response()
        updates = [{'family': '26100', 'kb': 'KB-A', 'build': '26100.1', 'previous_kb': ''}]
        _make_notifier().notify_update_available(updates)
        field = next(
            f for f in mock_post.call_args[1]['json']['embeds'][0]['fields']
            if f['name'] == '🔄 New Cumulative Update(s)'
        )
        assert 'was' not in field['value']

    @patch('requests.post')
    def test_cli_update_available(self, mock_post, monkeypatch):
        mock_post.return_value = _ok_response()
        monkeypatch.setattr(sys, 'argv', [
            'discord_notify.py',
            '--webhook', 'https://discord.com/api/webhooks/0/tok',
            '--type', 'update-available',
            '--data', json.dumps([{'family': '26300', 'kb': 'KB5127648', 'build': '26300.9711', 'previous_kb': ''}]),
        ])
        assert main() == 0
        embed = mock_post.call_args[1]['json']['embeds'][0]
        assert any('KB5127648' in f['value'] for f in embed['fields'])


# ---------------------------------------------------------------------------
# _require helper
# ---------------------------------------------------------------------------

class TestRequireHelper:
    def test_passes_when_all_keys_present(self):
        _require({'a': 1, 'b': 2}, 'a', 'b')

    def test_raises_on_missing_key(self):
        with pytest.raises(DiscordNotificationError) as exc:
            _require({'a': 1}, 'a', 'b')
        assert 'b' in str(exc.value)

    def test_lists_all_missing(self):
        with pytest.raises(DiscordNotificationError) as exc:
            _require({}, 'a', 'b', 'c')
        msg = str(exc.value)
        assert 'a' in msg and 'b' in msg and 'c' in msg

    def test_raises_on_none_value(self):
        # Remote version treats None as missing
        with pytest.raises(DiscordNotificationError):
            _require({'a': None}, 'a')


# ---------------------------------------------------------------------------
# CLI main() integration tests
# ---------------------------------------------------------------------------

class TestMain:
    @patch('requests.post')
    def test_build_started_cli(self, mock_post, monkeypatch):
        mock_post.return_value = _ok_response()
        monkeypatch.setattr(sys, 'argv', [
            'discord_notify.py',
            '--webhook', 'https://discord.com/api/webhooks/0/tok',
            '--type', 'build-started',
            '--data', json.dumps({'version': '25H2', 'build_type': 'Nano', 'edition': 'Home'})
        ])
        assert main() == 0

    @patch('requests.post')
    def test_build_completed_cli(self, mock_post, monkeypatch):
        mock_post.return_value = _ok_response()
        monkeypatch.setattr(sys, 'argv', [
            'discord_notify.py',
            '--webhook', 'https://discord.com/api/webhooks/0/tok',
            '--type', 'build-completed',
            '--data', json.dumps({
                'version': '25H2', 'build_type': 'Nano', 'edition': 'Home',
                'duration': '42m 17s', 'iso_size': '3.10 GB'
            })
        ])
        assert main() == 0

    @patch('requests.post')
    def test_build_completed_with_preserve_winre(self, mock_post, monkeypatch):
        mock_post.return_value = _ok_response()
        monkeypatch.setattr(sys, 'argv', [
            'discord_notify.py',
            '--webhook', 'https://discord.com/api/webhooks/0/tok',
            '--type', 'build-completed',
            '--data', json.dumps({
                'version': '25H2', 'build_type': 'Core', 'edition': 'Home',
                'duration': '55m', 'iso_size': '3.10 GB',
                'preserve_winre': 'true', 'enable_dotnet35': 'false'
            })
        ])
        assert main() == 0
        fields = mock_post.call_args[1]['json']['embeds'][0]['fields']
        assert any(f['name'] == 'WinRE' for f in fields)

    @patch('requests.post')
    def test_build_failed_cli(self, mock_post, monkeypatch):
        mock_post.return_value = _ok_response()
        monkeypatch.setattr(sys, 'argv', [
            'discord_notify.py',
            '--webhook', 'https://discord.com/api/webhooks/0/tok',
            '--type', 'build-failed',
            '--data', json.dumps({
                'version': '25H2', 'build_type': 'Nano', 'edition': 'Home',
                'error': 'CommandNotFoundException: Remove-RegistryValue',
                'logs_url': 'https://github.com/Sensei002/tiny11-automated/actions/runs/1'
            })
        ])
        assert main() == 0

    def test_missing_required_field_returns_1(self, monkeypatch):
        monkeypatch.setattr(sys, 'argv', [
            'discord_notify.py',
            '--webhook', 'https://discord.com/api/webhooks/0/tok',
            '--type', 'build-started',
            '--data', json.dumps({'version': '25H2'})
        ])
        assert main() == 1

    def test_invalid_json_returns_1(self, monkeypatch):
        monkeypatch.setattr(sys, 'argv', [
            'discord_notify.py',
            '--webhook', 'https://discord.com/api/webhooks/0/tok',
            '--type', 'build-started',
            '--data', '{bad json'
        ])
        assert main() == 1

    def test_no_webhook_skips_gracefully(self, monkeypatch):
        monkeypatch.delenv('DISCORD_WEBHOOK', raising=False)
        monkeypatch.setattr(sys, 'argv', [
            'discord_notify.py',
            '--type', 'build-started',
            '--data', json.dumps({'version': '25H2', 'build_type': 'Nano', 'edition': 'Home'})
        ])
        assert main() == 0

    @patch('requests.post')
    def test_webhook_env_var_fallback(self, mock_post, monkeypatch):
        mock_post.return_value = _ok_response()
        monkeypatch.setenv('DISCORD_WEBHOOK', 'https://discord.com/api/webhooks/0/tok')
        monkeypatch.setattr(sys, 'argv', [
            'discord_notify.py',
            '--type', 'build-started',
            '--data', json.dumps({'version': '25H2', 'build_type': 'Nano', 'edition': 'Home'})
        ])
        assert main() == 0
