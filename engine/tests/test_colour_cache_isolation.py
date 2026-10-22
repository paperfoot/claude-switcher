"""One test must not decide the styling of the next one.

Scrubbing ``FORCE_COLOR``/``NO_COLOR`` is only half the job, because detection
CACHES. ``colors_enabled()`` latches its first answer into
``printer._colors_enabled`` and every later call returns it, so a single
earlier test that latched ``True`` styles every assertion after it no matter
how thoroughly the environment is cleaned. Same story for ``printer._theme``.

pytest runs tests in definition order within a file, so each pair below is a
real ordering: the first test latches, the second reads. THE PAIR IS THE
GUARD; EITHER ALONE PROVES NOTHING, and the ordering it needs is not
guaranteed — a run that selects only the reader, or that splits the pair
across `-n` workers, is green over a broken fixture for a reason that has
nothing to do with the fixture working.

What actually closes the hole is the post-condition in
`conftest._deterministic_colour`, which asserts both globals are unlatched on
entry to EVERY test — no ordering required, and mutation-killed directly (not
via ordering) by `TestEntryAssertionsCatchAPoisonedGlobal` in
`test_printer.py`. These pairs stay as the readable narrative of what the
leak looks like; they are not what makes the suite safe.
"""

from __future__ import annotations

import os
import sys
from io import StringIO

import pytest

from switch_engine import printer


def test_a_test_may_latch_the_colour_cache():
    """Stands in for the ordinary tests that latch it in a real run."""
    printer._colors_enabled = True
    assert printer.colors_enabled() is True


def test_the_next_test_is_not_styled_by_it(monkeypatch):
    """The reset in ``_deterministic_colour`` is what makes this pass.

    Without it this test inherits the ``True`` latched above and
    ``accent()`` returns the escape-wrapped string — the exact failure the
    eleven ``test_switcher`` assertions report.

    stdout is pinned to a StringIO as the rest of the suite does, so that with
    the cache cleared detection falls through to ``isatty()`` and answers
    False. Asserting on OUTPUT rather than on ``printer._colors_enabled``:
    checking the private flag would pass for free on any run where nothing had
    latched it yet, which is most of them.
    """
    monkeypatch.setattr(sys, "stdout", StringIO())
    assert printer.accent("Skipping") == "Skipping"
    assert "\x1b[" not in printer.muted("usage")



def test_a_test_may_latch_the_theme(monkeypatch):
    """Stands in for `tui/app.py`'s `set_theme("light")`, which nothing restores."""
    monkeypatch.setenv("FORCE_COLOR", "1")
    printer._colors_enabled = None
    printer.set_theme("light")
    assert "38;2;149;76;42" in printer.accent("x")   # premise: light is live


def test_the_next_test_is_not_themed_by_it(monkeypatch):
    """The `_theme` reset is what makes this pass.

    `printer._theme` is the other latched global in this module, and the leak
    is real: with the reset removed, tests in several later files enter with
    the light palette, so the latch outlives the file that set it. Green
    without it only because none of them asserts a palette code — which is
    exactly what was true of `_colors_enabled` until someone exported
    FORCE_COLOR.

    (The count and per-file breakdown that used to be here were hand-copied
    from `conftest.py` and were wrong in both copies; they are gone from both.
    See the note beside the `_theme` reset.)

    Asserts on the palette bytes rather than on `printer._theme`, for the same
    reason the cache guard above asserts on output: the private name being
    right proves nothing about what a caller renders.
    """
    monkeypatch.setenv("FORCE_COLOR", "1")
    printer._colors_enabled = None
    assert "38;5;173" in printer.accent("x"), (
        "the previous test's light theme outlived it"
    )



class TestScopedContextDoesNotLeakTheAutouseScrub:
    """H-1 regression: pytest hands out ONE `MonkeyPatch` per test regardless
    of how many fixtures request it, so `monkeypatch.undo()` in a test body
    also unwinds `_deterministic_colour`'s scrub -- which is what
    `tests/test_move_accounts.py` and `tests/test_swap_accounts.py` did at 8
    sites before this branch moved them to a scoped `MonkeyPatch.context()`.

    `FORCE_COLOR` is exported class-scoped, the way `test_printer.py`'s
    `_exported` simulates a real developer shell (ahead of the
    function-scoped autouse fixture), so this test fails if the fix pattern
    ever regresses back to a shared-instance `.undo()`.
    """

    @pytest.fixture(autouse=True, scope="class")
    def _exported(self):
        with pytest.MonkeyPatch.context() as mp:
            mp.setenv("FORCE_COLOR", "3")
            yield

    def test_scoped_context_does_not_leak_it(self):
        with pytest.MonkeyPatch.context() as mp:
            mp.setattr(sys, "platform", sys.platform)
        assert os.environ.get("FORCE_COLOR") is None, (
            "a scoped MonkeyPatch.context() must not touch the autouse scrub"
        )
