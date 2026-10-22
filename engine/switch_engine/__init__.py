"""Claude Switcher's account engine: saves, switches and auto-switches Claude Code logins.

Forked from claude-swap 0.26.0 (MIT, see ThirdParty/claude-swap-LICENSE) and
maintained here. Standard library only.
"""

__version__ = "1.0.0"

from switch_engine.switcher import ClaudeAccountSwitcher

__all__ = ["ClaudeAccountSwitcher", "__version__"]
