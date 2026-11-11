from __future__ import annotations

import os
import shlex
import shutil
import subprocess
import tempfile
import tomllib
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


class FormatCheckTests(unittest.TestCase):
    def run_check(
        self, output: str, status: int = 0, tracked_files: tuple[str, ...] = ("Sources/App.swift",)
    ) -> tuple[subprocess.CompletedProcess[str], list[str]]:
        command = tomllib.loads((ROOT / "mise.toml").read_text())["tasks"]["format:check"]["run"]
        with tempfile.TemporaryDirectory() as temporary:
            repository = Path(temporary) / "repository"
            (repository / "Scripts").mkdir(parents=True)
            shutil.copy2(ROOT / "Scripts" / "format-check.sh", repository / "Scripts")
            subprocess.run(["git", "init", "-b", "main"], cwd=repository, check=True, capture_output=True)
            for name in (*tracked_files, "Sources/Untracked.swift"):
                path = repository / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("// Synthetic fixture\n")
            if tracked_files:
                subprocess.run(["git", "add", "--", *tracked_files], cwd=repository, check=True, capture_output=True)

            arguments = Path(temporary) / "arguments"
            stub = Path(temporary) / "swiftformat"
            stub.write_text(
                "#!/usr/bin/env bash\n"
                f"printf '%s\\0' \"$@\" > {shlex.quote(str(arguments))}\n"
                f"printf '%s\\n' {shlex.quote(output)} >&2\n"
                f"exit {status}\n"
            )
            stub.chmod(0o755)
            result = subprocess.run(
                ["bash", "-c", command],
                cwd=repository,
                env={**os.environ, "PATH": f"{temporary}:{os.environ['PATH']}"},
                capture_output=True,
                text=True,
                timeout=10,
            )
            argv = arguments.read_bytes().decode().split("\0")[:-1] if arguments.exists() else []
            return result, argv

    def test_passes_only_tracked_swift_file_paths_to_swiftformat(self) -> None:
        result, arguments = self.run_check(
            "0/3 files require formatting.",
            tracked_files=("Packages/Nested/Package.swift", "Sources/Space Name.swift", "Tools/Tool.swift", "Other/Skip.swift"),
        )
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        self.assertEqual(
            ["Packages/Nested/Package.swift", "Sources/Space Name.swift", "Tools/Tool.swift"],
            [argument for argument in arguments if argument.endswith(".swift")],
        )
        self.assertFalse({"Packages", "Sources", "Tools"}.intersection(arguments))

    def test_rejects_an_empty_tracked_swift_file_list_without_running_swiftformat(self) -> None:
        result, arguments = self.run_check("0/12 files require formatting.", tracked_files=())
        self.assertNotEqual(0, result.returncode)
        self.assertIn("format:check", result.stderr)
        self.assertIn("No tracked Swift files", result.stderr)
        self.assertEqual([], arguments)

    def test_rejects_no_eligible_files_even_with_a_positive_summary(self) -> None:
        for summary in ("0 files formatted.", "0/12 files require formatting."):
            with self.subTest(summary=summary):
                output = f"warning: No eligible files found at Sources.\n{summary}"
                result, _ = self.run_check(output)
                self.assertNotEqual(0, result.returncode)
                self.assertIn("format:check", result.stderr)
                self.assertIn(output, result.stdout + result.stderr)

    def test_rejects_zero_or_missing_checked_count(self) -> None:
        for output in ("0/0 files require formatting.", "0 files formatted.", ""):
            with self.subTest(output=output):
                result, _ = self.run_check(output)
                self.assertNotEqual(0, result.returncode)
                self.assertIn("format:check", result.stderr)

    def test_accepts_a_positive_checked_count(self) -> None:
        for output in ("0/12 files require formatting.", "0/1 files require formatting."):
            with self.subTest(output=output):
                result, _ = self.run_check(output)
                self.assertEqual(0, result.returncode, result.stdout + result.stderr)
                self.assertIn(output, result.stdout + result.stderr)

    def test_preserves_swiftformat_failure_status_and_output(self) -> None:
        for status in (1, 2):
            with self.subTest(status=status):
                output = "error: formatting failed.\n1/12 files require formatting."
                result, _ = self.run_check(output, status)
                self.assertEqual(status, result.returncode)
                self.assertIn(output, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
