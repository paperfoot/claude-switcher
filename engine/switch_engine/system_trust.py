"""Trust the root certificates macOS trusts, using only the standard library.

Python's ``ssl`` uses OpenSSL with whatever CA bundle the interpreter was built
with, which on a standalone or uv-managed Python may be missing or stale. The
token and usage endpoints serve ordinary public chains, so the roots shipped in
``SystemRootCertificates.keychain`` are all that verification needs. Before the
engine was vendored this was the third-party ``truststore`` package; reading
the roots with ``/usr/bin/security`` keeps the engine free of dependencies.

Best-effort: if the roots cannot be read, the interpreter's own defaults apply.
"""

from __future__ import annotations

import ssl
import subprocess
import sys

SYSTEM_ROOTS = "/System/Library/Keychains/SystemRootCertificates.keychain"

_roots: str | None = None


def _system_roots() -> str:
    """PEM text of every macOS system root, read once per process."""
    global _roots
    if _roots is None:
        result = subprocess.run(
            ["/usr/bin/security", "find-certificate", "-a", "-p", SYSTEM_ROOTS],
            capture_output=True,
            timeout=10,
            check=True,
        )
        _roots = result.stdout.decode("ascii")
    return _roots


def use_system_roots() -> None:
    """Make every default HTTPS context also trust the macOS system roots.

    The roots are read lazily, on the first HTTPS request, so commands that
    never touch the network pay nothing.
    """
    if sys.platform != "darwin":
        return
    default = ssl.create_default_context

    def context(*args, **kwargs) -> ssl.SSLContext:
        ctx = default(*args, **kwargs)
        try:
            ctx.load_verify_locations(cadata=_system_roots())
        except (OSError, subprocess.SubprocessError, ssl.SSLError, ValueError):
            pass
        return ctx

    ssl._create_default_https_context = context
