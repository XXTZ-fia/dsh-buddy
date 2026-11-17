from types import SimpleNamespace

import pytest

from radar.config import Env, load
from radar.health import from_exception
from radar.http import Throttle, get_body
from radar.sources.base import RateLimited
from radar.sources.bilibili import LIST_URL


@pytest.mark.parametrize(
    ("status", "body", "expected"),
    [
        (412, "private", "RateLimited HTTP 412"),
        (200, '{"code":-352}', "RateLimited HTTP 200 code=-352"),
    ],
)
def test_bili_transport_retains_safe_diagnostics_and_stops_retry(status, body, expected):
    cfg = load(None, Env("", ""))
    calls = []

    def get(url, **kwargs):
        calls.append(url)
        assert kwargs["headers"]["Referer"] == "https://www.bilibili.com/"
        assert kwargs["max_redirects"] == 0
        return SimpleNamespace(status=status, headers={}, ok=status == 200, text=lambda: body)

    ctx = SimpleNamespace(request=SimpleNamespace(get=get))
    throttle = Throttle(cfg)
    with pytest.raises(RateLimited) as raised:
        get_body(ctx, LIST_URL, "bili", cfg, throttle)
    assert from_exception(raised.value, "bili", "now").note == expected
    with pytest.raises(RateLimited):
        get_body(ctx, LIST_URL, "bili", cfg, throttle)
    assert len(calls) == 1
