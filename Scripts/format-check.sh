#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# Explicit file arguments avoid hidden-file flags skipping worktree sources.
swift_files=()
while IFS= read -r -d '' file; do
  swift_files+=("$file")
done < <(git ls-files -z -- 'Packages/*.swift' 'Sources/*.swift' 'Tools/*.swift')
if (( ${#swift_files[@]} == 0 )); then
  printf 'format:check: No tracked Swift files found; refusing to pass.\n' >&2
  exit 1
fi

status=0
output=$(swiftformat "${swift_files[@]}" --config .swiftformat --lint 2>&1) || status=$?
printf '%s\n' "$output"
if (( status != 0 )); then
  exit "$status"
fi

if [[ "$output" == *"No eligible files found"* ]] ||
  ! grep -Eq '^[0-9]+/[1-9][0-9]* files require formatting([,.]|$)' <<< "$output"; then
  printf 'format:check: SwiftFormat did not confirm a nonzero checked-file count or reported ineligible paths; refusing to pass.\n' >&2
  exit 1
fi
