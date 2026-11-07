#!/usr/bin/env python3
"""Fail unless the selected Xcode and its iPhoneOS SDK meet minimum versions.

Usage: check_xcode_toolchain.py --minimum-xcode 27.1 --minimum-ios-sdk 27.1
Honors DEVELOPER_DIR through xcodebuild and xcrun.
"""
from __future__ import annotations

import argparse
import re
import subprocess
import sys


def version(text: str) -> tuple[int, ...]:
    return tuple(int(part) for part in text.split("."))


def run(*command: str) -> str:
    return subprocess.run(command, capture_output=True, text=True, check=True).stdout


parser = argparse.ArgumentParser()
parser.add_argument("--minimum-xcode", required=True)
parser.add_argument("--minimum-ios-sdk", required=True)
arguments = parser.parse_args()

match = re.search(r"^Xcode (\d+(?:\.\d+)*)", run("xcodebuild", "-version"), re.M)
if not match:
    sys.exit("Could not read the Xcode version from xcodebuild -version.")
xcode = match.group(1)
sdk = run("xcrun", "--sdk", "iphoneos", "--show-sdk-version").strip()

problems = []
if version(xcode) < version(arguments.minimum_xcode):
    problems.append(f"Xcode {xcode} is older than the required {arguments.minimum_xcode}.")
if version(sdk) < version(arguments.minimum_ios_sdk):
    problems.append(f"iOS SDK {sdk} is older than the required {arguments.minimum_ios_sdk}.")
if problems:
    problems.append("Set DEVELOPER_DIR to a newer Xcode installation.")
    sys.exit("\n".join(problems))
