#!/usr/bin/env bash
# Run strict SwiftLint with the shared adaptive-layout rule and a project config.
# Usage: lint-swift.sh --project-config FILE [extra swiftlint arguments...]
set -euo pipefail

shared_rule="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/adaptive-layout.yml"
if [[ "${1:-}" != "--project-config" || -z "${2:-}" ]]; then
  echo "usage: $0 --project-config FILE [swiftlint arguments...]" >&2
  exit 2
fi
project_config="$2"
shift 2
exec swiftlint lint --strict --config "$project_config" --config "$shared_rule" "$@"
