from __future__ import annotations

import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SHARED = ROOT / "BuildSupport" / "shared" / "scripts"
OLD_DEFAULT = "$HOME/code/ios-build-support"
SCRIPTS_USING_SHARED_SUPPORT = (
    "BuildSupport/check_xcode_toolchain.sh",
    "BuildSupport/xcodebuild_test_output.sh",
    "Scripts/build-app.sh",
    "Scripts/build-protocol-xcframework.sh",
    "Scripts/test-core.sh",
    "Scripts/test-rust.sh",
    "mise.toml",
)


class SharedSupportTestCase(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()

    def tearDown(self) -> None:
        self.temp.cleanup()

    def fake_tool(self, name: str, body: str) -> None:
        tool = self.bin / name
        tool.write_text(f"#!/usr/bin/env bash\n{body}\n", encoding="utf-8")
        tool.chmod(0o755)

    def run_script(self, *command: str) -> subprocess.CompletedProcess[str]:
        env = {**os.environ, "PATH": f"{self.bin}{os.pathsep}{os.environ['PATH']}"}
        return subprocess.run(
            command, capture_output=True, text=True, env=env, check=False, timeout=30
        )


class DefaultLocationTests(SharedSupportTestCase):
    def test_no_script_defaults_to_the_private_checkout(self) -> None:
        for relative in SCRIPTS_USING_SHARED_SUPPORT:
            with self.subTest(script=relative):
                source = (ROOT / relative).read_text(encoding="utf-8")
                self.assertFalse(OLD_DEFAULT in source, f"{relative} uses {OLD_DEFAULT}")

    def test_entry_points_default_to_the_in_repo_shared_support(self) -> None:
        for relative in SCRIPTS_USING_SHARED_SUPPORT:
            if relative.startswith("BuildSupport/"):
                continue  # sourced helpers resolve relative to themselves; see below
            with self.subTest(script=relative):
                source = (ROOT / relative).read_text(encoding="utf-8")
                self.assertTrue("BuildSupport/shared" in source, relative)

    def test_sourced_toolchain_check_finds_the_in_repo_checker(self) -> None:
        self.fake_tool("xcodebuild", 'printf "Xcode 27.2\\nBuild version 1A1\\n"')
        self.fake_tool("xcrun", "echo 27.2")
        helper = ROOT / "BuildSupport" / "check_xcode_toolchain.sh"
        env = {k: v for k, v in os.environ.items() if k != "SHARED_IOS_SUPPORT_DIR"}
        env["PATH"] = f"{self.bin}{os.pathsep}{env['PATH']}"
        result = subprocess.run(
            ["bash", "-c", f'source "{helper}" && devicehub_check_xcode_toolchain'],
            cwd=self.root, capture_output=True, text=True, env=env, check=False, timeout=30,
        )

        self.assertEqual(result.returncode, 0, result.stderr)


class RunLoggedTests(SharedSupportTestCase):
    def run_logged(self, log: Path, *command: str, timeout: str = "10"):
        return self.run_script(
            "python3", str(SHARED / "run_logged.py"),
            "--log", str(log), "--label", "fixture", "--timeout", timeout,
            "--", *command,
        )

    def test_success_writes_a_private_log_and_a_receipt(self) -> None:
        log = self.root / "out.log"
        result = self.run_logged(log, "sh", "-c", "echo hello; echo oops >&2")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(log.read_text(encoding="utf-8"), "hello\noops\n")
        self.assertEqual(log.stat().st_mode & 0o777, 0o600)
        receipt = json.loads(result.stdout)
        self.assertEqual(receipt["label"], "fixture")
        self.assertEqual(receipt["exit_code"], 0)
        self.assertNotIn("hello", result.stdout)

    def test_failure_keeps_the_status_and_redacted_diagnostics(self) -> None:
        log = self.root / "out.log"
        result = self.run_logged(
            log, "sh", "-c", "echo 'error: broken build'; echo 'error: password=x'; exit 3"
        )

        self.assertEqual(result.returncode, 3)
        receipt = json.loads(result.stdout)
        self.assertEqual(receipt["exit_code"], 3)
        self.assertEqual(receipt["diagnostics"], ["error: broken build"])

    def test_timeout_exits_124(self) -> None:
        result = self.run_logged(self.root / "out.log", "sleep", "5", timeout="0.2")

        self.assertEqual(result.returncode, 124)

    def test_refuses_to_overwrite_an_existing_log(self) -> None:
        log = self.root / "out.log"
        log.write_text("earlier evidence", encoding="utf-8")
        result = self.run_logged(log, "true")

        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(log.read_text(encoding="utf-8"), "earlier evidence")


class CheckXcodeToolchainTests(SharedSupportTestCase):
    def check(self, xcode: str, sdk: str) -> subprocess.CompletedProcess[str]:
        self.fake_tool("xcodebuild", f'printf "Xcode {xcode}\\nBuild version 1A1\\n"')
        self.fake_tool("xcrun", f'[[ "$*" == "--sdk iphoneos --show-sdk-version" ]] && echo {sdk}')
        return self.run_script(
            "python3", str(SHARED / "check_xcode_toolchain.py"),
            "--minimum-xcode", "27.1", "--minimum-ios-sdk", "27.1",
        )

    def test_accepts_new_enough_xcode_and_sdk(self) -> None:
        for xcode, sdk in (("27.1", "27.1"), ("27.2", "27.2"), ("28.0", "28.0")):
            with self.subTest(xcode=xcode):
                result = self.check(xcode, sdk)
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_rejects_old_xcode(self) -> None:
        result = self.check("27.0", "27.1")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Xcode 27.0", result.stderr)
        self.assertIn("27.1", result.stderr)

    def test_rejects_old_ios_sdk(self) -> None:
        result = self.check("27.1", "27.0")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("iOS SDK 27.0", result.stderr)

    def test_compares_versions_numerically(self) -> None:
        result = self.check("27.10", "27.10")

        self.assertEqual(result.returncode, 0, result.stderr)


class LintSwiftTests(SharedSupportTestCase):
    def test_runs_strict_swiftlint_with_the_adaptive_rule_and_project_config(self) -> None:
        calls = self.root / "calls"
        self.fake_tool("swiftlint", f'printf "%s\\n" "$@" > {calls}')
        result = self.run_script(
            str(SHARED / "lint-swift.sh"), "--project-config", ".swiftlint.yml"
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        arguments = calls.read_text(encoding="utf-8").split("\n")
        self.assertIn("--strict", arguments)
        self.assertIn(".swiftlint.yml", arguments)
        self.assertIn(str(SHARED / "adaptive-layout.yml"), arguments)

    def test_adaptive_rule_rejects_layout_by_device_idiom(self) -> None:
        rule = (SHARED / "adaptive-layout.yml").read_text(encoding="utf-8")

        self.assertIn("userInterfaceIdiom", rule)
        self.assertIn("severity: error", rule)

    def test_propagates_swiftlint_failure(self) -> None:
        self.fake_tool("swiftlint", "exit 2")
        result = self.run_script(
            str(SHARED / "lint-swift.sh"), "--project-config", ".swiftlint.yml"
        )

        self.assertEqual(result.returncode, 2)


if __name__ == "__main__":
    unittest.main()
