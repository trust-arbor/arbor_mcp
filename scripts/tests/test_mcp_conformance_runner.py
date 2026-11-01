"""Run every official scenario even when a child harness consumes standard input."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


class ConformanceRunnerTest(unittest.TestCase):
    def test_a_stdin_consuming_harness_cannot_swallow_later_scenarios(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            scripts = root / "scripts"
            scripts.mkdir()
            source = Path(__file__).resolve().parents[1] / "conformance.sh"
            script = scripts / "conformance.sh"
            shutil.copy2(source, script)
            binaries = root / "bin"
            binaries.mkdir()

            def executable(name, body):
                path = binaries / name
                path.write_text("#!" + sys.executable + "\n" + body)
                path.chmod(0o755)

            executable("node", "import sys\nprint('24' if '-p' in sys.argv else 'v24.0.0')\n")
            executable("mix", "pass\n")
            executable("curl", "pass\n")
            executable("lsof", "raise SystemExit(1)\n")
            executable("elixir", "import signal\nprint('Server ready on http://localhost:3099/mcp', flush=True)\nsignal.pause()\n")
            executable("npx", """import json, os, sys
args = sys.argv[1:]
# Reproduce a child that consumes its inherited stdin, as observed in CI.
sys.stdin.read()
if 'client' in args:
    name = args[args.index('--scenario') + 1]
    with open(os.environ['CALLS'], 'a') as file:
        file.write(name + '\\n')
""")
            executable("python3", """import json, os, sys
if '--core-inventory' in sys.argv:
    print(json.dumps({'scenarios': {'client': {'one': ['2026-07-28'], 'two': ['2026-07-28']}}}))
elif any('check_mcp_core_evidence.py' in arg for arg in sys.argv):
    if '--begin' not in sys.argv:
        with open(os.environ['CALLS']) as file:
            if file.read().splitlines() != ['one', 'two']:
                raise SystemExit('Official scenarios were dropped')
else:
    os.execv(sys.executable, [sys.executable, *sys.argv[1:]])
""")
            calls = root / "calls.txt"
            env = dict(os.environ, PATH=str(binaries) + os.pathsep + os.environ["PATH"],
                       CALLS=str(calls), CONFORMANCE_PORT="3099")
            result = subprocess.run(["bash", str(script), "modern"], cwd=root, env=env,
                                    stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=15)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(calls.read_text().splitlines(), ["one", "two"])


if __name__ == "__main__":
    unittest.main()
