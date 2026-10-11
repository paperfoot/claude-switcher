"""One deadline per coordinated switch, passed down to every bounded call.

Deadline ladder. An outer layer always outlasts the layers inside it. Every inner
call gets min(its cap, the time left minus the reserve that later steps, such as
a rollback, still need), so a switch stops and restores before its caller gives up.

  Layer or call                              Bound
  -----------------------------------------  -------------------------------------
  Swift CoordinatedSwitching.run             kills the helper after 350 s
    companion switch, browser-switch         MENU_BUDGET 300 s
    companion snapshot, browser-status       STATUS_BUDGET 120 s
  Extension popup waits for native select    background.js SELECT_REPLY_MS 180 s
    companion select, popup deadline         at most POPUP_BUDGET 150 s; 100 s when an
                                             older popup (it waits 120 s) sends none
  Inside a budget
    claude auth status                       IDENTITY_TIMEOUT 15 s
    cswap switch or list                     CSWAP_TIMEOUT 60 s; a forward switch keeps
                                             CODE_RESTORE_RESERVE 45 s to restore Code
    Code credential cache repair             skipped with under 30 s left
    status of one Chrome profile             STATUS_TIMEOUT 10 s
    switch of one Chrome profile             replies by a host deadline: at most 150 s
                                             away, PROFILE_RESTORE_RESERVE 70 s before
                                             the budget per profile it may have to
                                             restore; not started with under 60 s
      extension stops starting cookie work   host deadline - 40 s (its own rollback)
      native host replies browser_timeout    at the host deadline
      send_request socket wait               host deadline + 2 s
"""
from __future__ import annotations

import math
import time

try:
    from . import native_transport
except ImportError:
    import native_transport


MENU_BUDGET = 300.0
STATUS_BUDGET = 120.0
POPUP_BUDGET = 150.0
LEGACY_POPUP_BUDGET = 100.0
IDENTITY_TIMEOUT = 15.0
CSWAP_TIMEOUT = 60.0
CODE_RESTORE_RESERVE = 45.0
CACHE_REPAIR_MINIMUM = 30.0
STATUS_TIMEOUT = 10.0
PROFILE_SWITCH_TIMEOUT = native_transport.CLIENT_REQUEST_TIMEOUT
PROFILE_SWITCH_MINIMUM = 60.0
PROFILE_RESTORE_RESERVE = STATUS_TIMEOUT + PROFILE_SWITCH_MINIMUM


class DeadlineExceeded(Exception):
    """No time is left for the next bounded call."""


class Deadline:
    def __init__(self, seconds, clock=time.monotonic, wall=time.time):
        self._clock = clock
        self._wall = wall
        self.at = clock() + max(0.0, seconds)

    @classmethod
    def from_unix_ms(cls, value, cap, clock=time.monotonic, wall=time.time):
        """A deadline sent by another process, or None when it is unusable."""
        if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
            return None
        return cls(min(cap, value / 1000 - wall()), clock, wall)

    def remaining(self, reserve=0.0):
        return self.at - reserve - self._clock()

    def timeout(self, cap, reserve=0.0):
        """Seconds for one call: at most `cap`, ending `reserve` before the deadline."""
        left = self.remaining(reserve)
        if left <= 0:
            raise DeadlineExceeded()
        return min(cap, left)

    def unix_ms(self, reserve=0.0):
        """The deadline minus `reserve` as Unix milliseconds, for other processes."""
        return (self._wall() + self.remaining(reserve)) * 1000
