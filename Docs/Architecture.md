# Architecture

## Shape

Device Hub follows a functional-core, imperative-shell architecture:

```text
DeviceHubApp
└── DeviceHubUI
    └── DeviceHubFeature
        ├── DeviceHubCore
        ├── DeviceHubDiagnostics
        └── DeviceHubClient
            └── DeviceHubTransport
                ├── DeviceHubPersistence
                ├── DeviceHubMedia
                └── DeviceHubFFI.xcframework
                    └── pinned and patched idevice
```

- `DeviceHubApp` composes dependencies and lifecycle only.
- `DeviceHubCore` owns pure values and derivations.
- `DeviceHubFeature` owns explicit TCA state, actions, effects, and cancellation.
- `DeviceHubUI` renders feature state and sends user intents.
- `DeviceHubClient` is the only contract visible to product features.
- `DeviceHubTransport` owns Swift/Rust lifetime bridging.
- `DeviceHubMedia` owns the complete-access-unit VideoToolbox boundary and
  latest-frame delivery.
- Swift owns Foundation/Network.framework Bonjour advertisement, browsing,
  resolution, and TXT validation. Rust owns pairing, tunnels, Remote Service
  Discovery, media, HID, and their structured tasks after Swift supplies a
  validated endpoint.
- `DeviceHubDiagnostics` accepts only a deliberately redacted event vocabulary.

The app and every package hard-target iOS/iPadOS 27.0. There are no legacy
transport modes; any availability check must protect a specific API introduced
after the deployment floor.

## Session ownership

Each remote-session scene owns one active target. Every connection receives a
new `SessionGeneration` value. Asynchronous events carry that generation, and
reducers reject events from any prior generation. This ownership model keeps
sessions isolated and allows future iPadOS windows to host independent
connections.

Changing targets performs this sequence:

1. Disable input immediately.
2. Invalidate the current generation.
3. Release held touches, buttons, keys, and modifiers.
4. Cancel media and the userspace tunnel.
5. Await bounded, idempotent teardown.
6. Clear the old image.
7. Create the next generation.

Freeing a Rust session cancels and joins its structured tasks. Its callback
context cannot be invoked after the corresponding free operation returns.

### Input cleanup outcome

`DeviceSession.disconnect` and the coordinator's `close` are async throwing.
All callers share one settled release-then-disconnect task: a release failure
does not skip the disconnect, and a replacement session cannot connect until
the previous close has settled. Only an explicit Retry acknowledges a failed
outcome and creates fresh ownership; no old commands or contacts carry over.

A terminal release joins its transport owner's complete cleanup task,
including native cancellation and device-claim release, instead of sending a
new command to a closed lane. The session control keeps an explicit settled
success or failure after cleanup, even when its weak transport owner is gone.
Only release may use that result; no recorded result and ordinary commands
still fail closed, and a failure cannot be replaced by a later success. The
session facade rejects every command, including release, during and after its
own disconnect.

The feature keeps the exact attempt and session cleanup owner after removing
the visible session. A matching teardown failure latches `inputCleanupFailed`
("Input Release Is Unconfirmed"). Late frames, readiness, foreground, roster
updates, selection, and Start Viewing cannot clear it, and cleanup results
from a superseded attempt cannot change its successor. A successful cleanup
is not proof that the device physically released input.

The Rust worker's final input cleanup returns its outcome under one total
three-second deadline, still attempting the remaining known releases after a
failure. The first known release failure is kept in a slot shared by the
input cleanup state and the session's event emitter, so it survives a later
successful release, an interrupted cleanup future, and the suppression of
terminal callbacks during cancel and free. A cleanup failure takes priority
over an unrelated stream failure.

Cancellation races the whole ready control loop, including awaited HID,
orientation, and media-control writes. If input was opened, the worker still
runs its cleanup instead of being dropped. Presses that may have been
delivered are recorded before their writes are awaited, and release state is
cleared only after a successful release. A caught worker panic after input
opened counts as an unknown release outcome. `dh_session_cancel` joins the
worker and returns the kept cleanup failure through its existing status and
error-out, also after the session has ended. `dh_session_free` proves the
handle was destroyed, not that the device released input.

## Dependency rules

- Features never receive raw Rust pointers, pair records, network addresses,
  RSD ports, service handles, RTP packets, or codec buffers.
- The live client does not silently become a fixture client.
- Test clients fail loudly for every unimplemented endpoint.
- Errors cross module boundaries as typed, redacted domain errors with a stage
  and retry classification.
- Long-lived observations use `AsyncStream` or `AsyncThrowingStream` with an
  explicit termination path.

## Build system

- mise is the supported entry point for setup, generation, builds, tests,
  linting, previews, and archives.
- XcodeGen owns the Xcode project definition.
- Reusable code remains in the local Swift package.
- Swift Testing is the only test framework.
- SwiftFormat, SwiftLint, Periphery, jscpd, XcodeGen, and AXe are verification
  gates.
- Rust source and `Cargo.lock` are pinned; the XCFramework is reproducibly built
  for arm64 device and arm64 simulator.
- Signing configuration is local and never committed. Unsigned simulator builds
  and locally signed device archives use the same generated project.
