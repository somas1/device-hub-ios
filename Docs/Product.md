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
- Hardware keyboards, including a Mac keyboard shared through Mac Virtual
  Display, type on the remote device whenever input is enabled; the Keyboard
  control is needed only for the on-screen keyboard. If another controller
  control takes focus, it keeps Tab and arrow keys until the user taps or
  touches the remote screen. While Device Hub holds focus, Tab goes to the
  remote device. The on-screen keyboard's Done and system dismiss keys hide it
  without dropping hardware keys. Keys are not forwarded while a sheet or alert
  covers the window, and focus returns after it closes. Held keys are released
  when the scene deactivates or the window resigns key. Paste is refused unless
  the on-screen keyboard is shown; then it types the clipboard to the device.

## Primary controls

The More menu stays close to the top-right corner and contains:

1. Home
2. Lock
3. Keyboard
4. Rotate

Secondary hardware controls, device selection, pairing, reconnect, and
stop-viewing live in the same menu. Volume Up, Volume Down and Mute leave the
menu open after a tap, so the volume can be stepped repeatedly without
reopening it. There is no bottom action bar or trailing control rail. The
remote canvas has no app-added padding.

## Platform adaptation

- iPhone and iPad use one full-window remote-session screen. The More menu
  contains device selection. Device details use a sheet.
- Flat and cover displays keep hardware actions inside the corner menu.
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
