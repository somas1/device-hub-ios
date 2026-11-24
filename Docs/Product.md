# Product Contract

## North star

Device Hub is a remote session, not a protocol dashboard.

The first screen answers one question: **What is on this device, and can I
control it right now?**

The selected device's screen is the primary visual anchor. Device identity,
connection status, switching, and hardware controls remain immediately
available but visually secondary.

## Information architecture

```text
Remote Session
├── Device picker
│   ├── Available
│   ├── Offline or needs attention
│   └── Pair another device
├── Pair Device sheet
├── Device Details sheet
└── Remote Canvas
    ├── Screen
    ├── Connection-state overlay
    ├── Keyboard capture
    └── Contextual hardware controls
```

There is no dashboard and no Devices, Control, Logs, or Settings tab bar.

## Remote-session invariants

- Switching devices clears the old frame before changing the selected name.
- A frame older than one second is `Delayed`, never `Live`.
- A frame older than three seconds is dimmed and labeled `Last frame`; input is
  paused while the session reconnects.
- Touch input is enabled only after a fresh decoded frame and the matching HID
  channel are both ready for the same session generation.
- The screen is aspect-fit without a decorative device bezel. Letterboxed
  regions do not send input.
- Remote orientation changes the canvas shape; it does not rotate the controller
  app.
- Clipboard transfer is explicit. Automatic clipboard synchronization is not a
  first-release feature.
- The Clipboard control offers Cut, Copy, and Paste when remote input is
  available. Each action sends one keyboard shortcut to the remote device,
  which uses its own selection and clipboard. Device Hub never accesses or
  transfers clipboard contents for these actions.
- Hardware keyboards, including a Mac keyboard shared through Mac Virtual
  Display, type on the remote device whenever input is enabled; the Keyboard
  control is needed only for the on-screen keyboard. If another controller
  control takes focus, it keeps Tab and arrow keys until the user taps or
  touches the remote screen. While Device Hub holds focus, Tab and printable
  ASCII shortcuts using Command or Control go to the remote device. The
  controller OS keeps reserved shortcuts such as Cmd+Tab and Cmd+Space.
  Hardware Cmd+V sends a key press so the remote device uses its own clipboard.
  The edit menu's Paste action types the controller clipboard to the remote
  device and is available only with the on-screen keyboard shown. The on-screen
  keyboard's Done and system dismiss keys hide it without dropping hardware
  keys. A sheet or alert temporarily takes keyboard focus, which returns after
  it closes. Held keys are released when the scene deactivates or the window
  resigns key.

After Stop Viewing, choosing or pairing a device, returning to the app, and
using Retry leave viewing stopped. Start Viewing is available when the app
is active, a paired device is selected, any input cleanup has finished, and
any cleanup failure has been acknowledged. Starting with an offline paired
device allows it to connect when it returns.

## Primary controls

The corner More menu contains Keyboard, Rotate, Siri, device selection,
pairing, About, Device Details, and session options as available. At compact
width it also contains Home, Lock, Volume Up, Volume Down, and Mute, with the
volume and mute actions keeping the menu open after a tap.

## Platform adaptation

- iPhone and iPad use one full-window remote-session screen. The More menu
  contains device selection. Device details use a sheet.
- At regular width with a selected device, Home, Lock, Volume Up, Volume Down,
  and Mute move beside More and dim when remote input is unavailable.
- On iPhone Duo 27.1, half-open mode places the remote screen above a dedicated
  touch-control area (or beside it when rotated). Home, Lock, Keyboard, and
  Rotate are directly available there. Opening the keyboard uses the existing
  native responder; selection, session, and remote hit coordinates stay shared.
  Flat and cover displays still use the full-window canvas and corner menu.
- Both platforms support light and dark appearance, Dynamic Type, portrait and
  landscape targets, reduced motion, VoiceOver, and hardware keyboards.

## Product failures

The following block release even when the underlying protocol works:

- stale pixels labeled live;
- fake devices or fixture fallback in the shipping app;
- controls without a working effect;
- protocol identifiers, addresses, or raw error codes in ordinary UI;
- thick device bezels or a terminal-style developer aesthetic;
- indefinite progress without a timeout or useful remedy;
- iPad merely stretching the iPhone layout;
- app chrome that reserves space around the device image or covers more than
  the small floating controls require.
