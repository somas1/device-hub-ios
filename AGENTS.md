# Device Hub agent guide

This file defines the repository contract for coding agents and automated
contributors.

## Start here

1. Read `README.md`, `Docs/Architecture.md`, and the documentation for the
   layer being changed.
2. Run `mise install` and `mise run setup`.
3. Use `mise` tasks for builds, tests, generation, linting, previews, and
   archives. Run `mise tasks` for the supported entry points.
4. Inspect the complete diff before finishing. Do not include generated build
   products, credentials, personal infrastructure, or device data.

## Architecture

- Keep business logic in a functional core and side effects in thin shell
  layers.
- Put reusable Swift code in `Packages/DeviceHubKit`; app composition belongs
  in `Sources/DeviceHubApp` and `Sources/DeviceHubLive`.
- Keep protocol and FFI ownership in `Rust/DeviceHubFFI`.
- Features must not receive raw pointers, pair records, network addresses,
  packets, or codec buffers.
- Model asynchronous work with explicit connection generations and
  cancellation.
- Prefer removing obsolete paths to adding compatibility layers.
- Document new non-obvious APIs and security-sensitive invariants.

## Testing

- Reproduce a defect before changing production code.
- Add a regression that fails for the observed behavior, then implement the
  fix and rerun it.
- Use Swift Testing for Swift tests.
- Protocol changes require malformed-input, authentication-failure, and
  teardown coverage.
- UI changes require preview or snapshot evidence at relevant iPhone and iPad
  sizes.
- Run the strongest focused task while iterating and `mise run ci` before
  finishing.

## Process safety

- Run only one heavyweight build, test, archive, simulator, or device
  operation at a time.
- Let `BuildSupport/simulator_setup.py` own simulators: each `test:app`,
  `test:media`, or snapshot run creates one fresh simulator and deletes only
  that exact device afterwards. Do not add a host-wide lease, lock, or
  watcher. See "Simulator ownership" in `Docs/Testing.md`.
- Treat detached, aborted, timed-out, or signal-terminated simulator commands
  as unresolved. Before retrying, inspect the interrupted device's identity
  and state, then run the helper's `cleanup` command with its original UDID
  and name.
- Do not create, boot, shut down, or delete simulators directly from another
  test script.
- Do not leave detached processes, background jobs, simulators, or device
  sessions running after a task.
- Bound reverse-engineering commands by image, address range, runtime, and
  output.
- Never print provisioning material, environment contents, credentials, or
  full process command lines that may contain secrets.

## Device and data safety

- Pair with and control only devices owned by the tester or explicitly
  authorized for the test.
- Do not rotate controller identity, reset pairing, unregister a device,
  uninstall the app, or delete device data without explicit authorization for
  that action.
- Never commit pairing codes, pair records, private keys, PSKs, provisioning
  profiles, tokens, device identifiers, addresses, screenshots, screen
  contents, raw packets, or diagnostic databases.
- Keep fixtures synthetic and diagnostics inside the typed, redacted schema
  documented in `Docs/ProtocolSecurity.md`.

## This fork

These rules add to the ones above for work on
[somas1/device-hub-ios](https://github.com/somas1/device-hub-ios). Where they
overlap, follow the stricter rule.

### How changes arrive

- Change one topic at a time. Each topic is one branch and one pull request
  into this fork's `main`, not into `JaviSoto/device-hub-ios`. Offer a fix to
  the original project only when this fork's maintainer asks for it.
- Give every pull request a plain-language description: what changes, why,
  and how to check it. Explain anything non-obvious for a reader who is still
  learning the code.
- Commits taken from another fork keep their original author. Port by hand
  when the code has diverged, and credit the source in the commit message.

### Understand before changing

- Read the relevant code, tests and docs before editing. Trace callers and
  affected behaviour, and fix root causes rather than symptoms.
- Agree on what "done" means before starting a change of behaviour, and keep
  the change to what that needs.

### Test first

- For a new behaviour, a bug fix or a refactor, write a focused test, watch
  it fail for the expected reason, then make it pass. Do not weaken a test to
  make wrong code pass.
- A genuinely trivial one-line change, such as a typo in displayed text, may
  skip the new test. Security, data integrity, concurrency and anything with
  real behavioural risk never qualify. Say in the pull request why the
  exception applies.
- Documentation-only changes need no new test; say so in the pull request.

### Documentation

- Documentation is part of the change. Update the README and affected docs in
  the same pull request when behaviour, setup or limits change.

### Safe commands

- Keep commands non-interactive, but never destructive by default. Check
  paths and scope before deleting or overwriting anything.
- Never force-push, rewrite published history, or discard someone else's
  changes.
- Never commit secrets, credentials or personal infrastructure details.
