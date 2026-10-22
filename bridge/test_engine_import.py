import subprocess
import sys
import unittest
from pathlib import Path

BRIDGE = Path(__file__).resolve().parent


class EngineImportTests(unittest.TestCase):
    """The companion imports the engine's Keychain, OAuth and lock code in-process."""

    @unittest.skipIf(sys.version_info < (3, 12), "the engine needs Python 3.12 or newer")
    def test_the_companion_finds_the_real_engine_beside_it(self):
        # A fresh isolated interpreter: no mocks, no inherited sys.path, as the native host runs.
        check = ("import sys; sys.path.insert(0, sys.argv[1]); import companion, code_cache; "
                 "from switch_engine import macos_keychain, oauth, claude_locks; "
                 "print(companion.ENGINE_DIR)")
        result = subprocess.run([sys.executable, "-I", "-c", check, str(BRIDGE)],
                                capture_output=True, text=True, timeout=60)
        self.assertEqual(result.returncode, 0, result.stderr)
        # samefile: on a case-insensitive disk the repository's engine/ also answers to Engine/.
        self.assertTrue(Path(result.stdout.strip()).samefile(BRIDGE.parent / "engine"))


if __name__ == "__main__":
    unittest.main()
