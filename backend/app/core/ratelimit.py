"""Small in-memory sliding-window rate limiter.

Good for a single API process (our Docker setup). With several replicas this must move to Redis;
the interface (hit/fail/reset) stays the same.
"""
import math
import time
from collections import deque

from app.core.errors import RateLimited


class RateLimiter:
    def __init__(self) -> None:
        self._hits: dict[str, deque[float]] = {}
        self._calls = 0

    def _window(self, key: str, window: float, now: float) -> deque[float]:
        q = self._hits.setdefault(key, deque())
        while q and q[0] <= now - window:
            q.popleft()
        return q

    def check(self, key: str, limit: int, window: float) -> None:
        """Raise 429 if `key` already has `limit` events in the last `window` seconds."""
        now = time.monotonic()
        q = self._window(key, window, now)
        if len(q) >= limit:
            raise RateLimited(max(1, math.ceil(q[0] + window - now)))

    def add(self, key: str) -> None:
        self._hits.setdefault(key, deque()).append(time.monotonic())
        self._calls += 1
        if self._calls % 1000 == 0:
            self._sweep()

    def hit(self, key: str, limit: int, window: float) -> None:
        """Count every call (e.g. chat send): check, then record."""
        self.check(key, limit, window)
        self.add(key)

    def reset(self, key: str) -> None:
        self._hits.pop(key, None)

    def clear(self) -> None:
        self._hits.clear()

    def _sweep(self, max_age: float = 3600) -> None:
        now = time.monotonic()
        for k in [k for k, q in self._hits.items() if not q or q[-1] <= now - max_age]:
            del self._hits[k]


limiter = RateLimiter()
