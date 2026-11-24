use super::*;

#[derive(Default)]
struct MockKeyboardStateSink {
    attempts: Vec<Vec<u8>>,
    fail_at: Option<usize>,
}

impl KeyboardStateSink for MockKeyboardStateSink {
    async fn replace(&mut self, pressed: BTreeSet<KeyboardUsage>) -> Result<(), HidError> {
        self.attempts
            .push(pressed.into_iter().map(KeyboardUsage::raw).collect());
        if self.fail_at == Some(self.attempts.len()) {
            Err(HidError::Device(IdeviceError::ServiceNotFound))
        } else {
            Ok(())
        }
    }
}

#[derive(Default)]
struct MockHardwareButtonSink {
    attempts: Vec<(HardwareButton, ButtonState)>,
    fail_at: Option<usize>,
}

impl HardwareButtonSink for MockHardwareButtonSink {
    async fn send(&mut self, button: HardwareButton, state: ButtonState) -> Result<(), HidError> {
        self.attempts.push((button, state));
        if self.fail_at == Some(self.attempts.len()) {
            Err(HidError::Device(IdeviceError::ServiceNotFound))
        } else {
            Ok(())
        }
    }
}

#[test]
fn hardware_button_taps_use_the_device_required_hold_duration() {
    assert_eq!(
        hardware_button_tap_hold(HardwareButton::Home),
        Duration::from_millis(50)
    );
    assert_eq!(
        hardware_button_tap_hold(HardwareButton::Lock),
        Duration::from_millis(300)
    );
    assert_eq!(
        hardware_button_tap_hold(HardwareButton::Siri),
        Duration::from_secs(1)
    );
    assert_eq!(
        hardware_button_tap_hold(HardwareButton::VolumeUp),
        Duration::from_millis(50)
    );
}

#[tokio::test]
async fn shifted_tap_presses_shift_before_the_key_and_unmodified_tap_stays_two_reports() {
    let mut cleanup = InputCleanupState::default();
    let mut keyboard = MockKeyboardStateSink::default();
    handle_keyboard_intent_with_sink(
        KeyboardIntent::Tap {
            usage: 0x34, // apostrophe; with Shift it types a double quote
            modifiers: 0b0000_0010,
        },
        &mut cleanup,
        &mut keyboard,
    )
    .await
    .unwrap();
    assert_eq!(
        keyboard.attempts,
        vec![vec![0xE1], vec![0x34, 0xE1], vec![0xE1], Vec::new()]
    );
    assert!(cleanup.pressed_keys.is_empty());

    let mut plain = MockKeyboardStateSink::default();
    handle_keyboard_intent_with_sink(
        KeyboardIntent::Tap {
            usage: 0x04,
            modifiers: 0,
        },
        &mut cleanup,
        &mut plain,
    )
    .await
    .unwrap();
    assert_eq!(plain.attempts, vec![vec![0x04], Vec::new()]);
}

#[tokio::test]
async fn semantic_taps_emit_ordered_edges_and_retain_failed_releases_for_cleanup() {
    let mut keyboard_cleanup = InputCleanupState {
        pressed_keys: BTreeMap::from([(0x05, 0b0000_0010)]),
        ..Default::default()
    };
    let mut keyboard = MockKeyboardStateSink::default();
    handle_keyboard_intent_with_sink(
        KeyboardIntent::Tap {
            usage: 0x04,
            modifiers: 0b0000_0001,
        },
        &mut keyboard_cleanup,
        &mut keyboard,
    )
    .await
    .unwrap();
    // The tap's modifier lands one report before its key and lifts one
    // report after it, like a physical keyboard; a bitmap report carries
    // no order, so iPadOS would otherwise read the key without it.
    assert_eq!(
        keyboard.attempts,
        vec![
            vec![0x05, 0xE0, 0xE1],
            vec![0x04, 0x05, 0xE0, 0xE1],
            vec![0x05, 0xE0, 0xE1],
            vec![0x05, 0xE1],
        ]
    );
    assert_eq!(
        keyboard_cleanup.pressed_keys,
        BTreeMap::from([(0x05, 0b0000_0010)])
    );

    let mut failed_keyboard_cleanup = InputCleanupState::default();
    let mut failed_keyboard = MockKeyboardStateSink {
        fail_at: Some(2),
        ..Default::default()
    };
    let failure = handle_keyboard_intent_with_sink(
        KeyboardIntent::Tap {
            usage: 0x04,
            modifiers: 0b1000_0001,
        },
        &mut failed_keyboard_cleanup,
        &mut failed_keyboard,
    )
    .await
    .unwrap_err();
    assert_eq!(failure.code, "input_delivery_failed");
    assert_eq!(
        failed_keyboard.attempts,
        vec![vec![0xE0, 0xE7], vec![0x04, 0xE0, 0xE7]]
    );
    assert_eq!(
        failed_keyboard_cleanup.pressed_keys,
        BTreeMap::from([(0x04, 0b1000_0001)])
    );

    let intent = crate::model::HardwareButtonIntent {
        button: DhHardwareButton::Home,
        phase: DhButtonPhase::Tap,
    };
    let mut button_cleanup = InputCleanupState::default();
    let mut button = MockHardwareButtonSink::default();
    handle_hardware_button_with_sink(
        intent,
        DhOrientation::Portrait,
        false,
        &mut button_cleanup,
        &mut button,
    )
    .await
    .unwrap();
    assert_eq!(
        button.attempts,
        vec![
            (HardwareButton::Home, ButtonState::Down),
            (HardwareButton::Home, ButtonState::Up),
        ]
    );
    assert!(button_cleanup.pressed_buttons.is_empty());

    let mut failed_button_cleanup = InputCleanupState::default();
    let mut failed_button = MockHardwareButtonSink {
        fail_at: Some(2),
        ..Default::default()
    };
    let failure = handle_hardware_button_with_sink(
        intent,
        DhOrientation::Portrait,
        false,
        &mut failed_button_cleanup,
        &mut failed_button,
    )
    .await
    .unwrap_err();
    assert_eq!(failure.code, "input_delivery_failed");
    assert_eq!(
        failed_button.attempts,
        vec![
            (HardwareButton::Home, ButtonState::Down),
            (HardwareButton::Home, ButtonState::Up),
        ]
    );
    assert_eq!(
        failed_button_cleanup.pressed_buttons,
        vec![HardwareButton::Home]
    );
}

#[derive(Default)]
struct MockReleaseSink {
    attempts: Vec<InputReleaseAction>,
    fail: Option<InputReleaseAction>,
}

impl InputReleaseSink for MockReleaseSink {
    async fn release(&mut self, action: InputReleaseAction) -> Result<(), HidError> {
        self.attempts.push(action);
        if self.fail == Some(action) {
            Err(HidError::Device(IdeviceError::ServiceNotFound))
        } else {
            Ok(())
        }
    }
}

#[test]
fn release_all_is_reverse_ordered_idempotent_and_continues_after_failure() {
    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .unwrap();
    runtime.block_on(async {
        let mut cleanup = InputCleanupState {
            touch_active: true,
            pressed_keys: BTreeMap::from([(0x04, 0), (0x05, 0b0000_0010)]),
            pressed_buttons: vec![HardwareButton::Home, HardwareButton::VolumeUp],
            ..Default::default()
        };
        let mut sink = MockReleaseSink {
            fail: Some(InputReleaseAction::Keyboard),
            ..Default::default()
        };

        let failure = release_all_inputs_with_sink(&mut cleanup, &mut sink)
            .await
            .unwrap_err();
        assert_eq!(failure.stage, "input_cleanup");
        assert_eq!(
            sink.attempts,
            vec![
                InputReleaseAction::Touch,
                InputReleaseAction::Keyboard,
                InputReleaseAction::HardwareButton(HardwareButton::VolumeUp),
                InputReleaseAction::HardwareButton(HardwareButton::Home),
            ]
        );
        assert!(!cleanup.touch_active);
        assert_eq!(
            cleanup.pressed_keys,
            BTreeMap::from([(0x04, 0), (0x05, 0b0000_0010)])
        );
        assert!(cleanup.pressed_buttons.is_empty());

        let mut retry = MockReleaseSink::default();
        release_all_inputs_with_sink(&mut cleanup, &mut retry)
            .await
            .unwrap();
        assert_eq!(retry.attempts, vec![InputReleaseAction::Keyboard]);
        assert!(cleanup.release_plan().is_empty());

        let mut idempotent = MockReleaseSink::default();
        release_all_inputs_with_sink(&mut cleanup, &mut idempotent)
            .await
            .unwrap();
        assert!(idempotent.attempts.is_empty());
    });
}

// Bridge the old void cleanup contract so RED is behavioral, not a type error.
trait ReportCleanup {
    fn reported(self) -> Result<(), PublicFailure>;
}
impl ReportCleanup for () {
    fn reported(self) -> Result<(), PublicFailure> {
        Ok(())
    }
}
impl ReportCleanup for Result<(), PublicFailure> {
    fn reported(self) -> Result<(), PublicFailure> {
        self
    }
}

#[derive(Debug)]
struct CleanupSocket {
    mode: std::sync::Arc<std::sync::atomic::AtomicU8>,
    written: std::sync::Arc<std::sync::atomic::AtomicUsize>,
}
impl CleanupSocket {
    fn new(mode: std::sync::Arc<std::sync::atomic::AtomicU8>) -> Self {
        Self {
            mode,
            written: std::sync::Arc::default(),
        }
    }
}
impl tokio::io::AsyncRead for CleanupSocket {
    fn poll_read(
        self: std::pin::Pin<&mut Self>,
        _: &mut std::task::Context<'_>,
        _: &mut tokio::io::ReadBuf<'_>,
    ) -> std::task::Poll<std::io::Result<()>> {
        std::task::Poll::Pending
    }
}
impl tokio::io::AsyncWrite for CleanupSocket {
    fn poll_write(
        self: std::pin::Pin<&mut Self>,
        _: &mut std::task::Context<'_>,
        bytes: &[u8],
    ) -> std::task::Poll<std::io::Result<usize>> {
        let result = match self.mode.load(std::sync::atomic::Ordering::Acquire) {
            1 => std::task::Poll::Ready(Err(std::io::ErrorKind::BrokenPipe.into())),
            2 => std::task::Poll::Pending,
            3 => {
                self.mode.store(2, std::sync::atomic::Ordering::Release);
                std::task::Poll::Ready(Ok(bytes.len().min(8)))
            }
            _ => std::task::Poll::Ready(Ok(bytes.len())),
        };
        if let std::task::Poll::Ready(Ok(count)) = &result {
            self.written
                .fetch_add(*count, std::sync::atomic::Ordering::AcqRel);
        }
        result
    }
    fn poll_flush(
        self: std::pin::Pin<&mut Self>,
        _: &mut std::task::Context<'_>,
    ) -> std::task::Poll<std::io::Result<()>> {
        std::task::Poll::Ready(Ok(()))
    }
    fn poll_shutdown(
        self: std::pin::Pin<&mut Self>,
        _: &mut std::task::Context<'_>,
    ) -> std::task::Poll<std::io::Result<()>> {
        std::task::Poll::Ready(Ok(()))
    }
}

#[test]
fn final_cleanup_reports_release_failure_and_total_deadline() {
    for mode in [1, 2] {
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .start_paused(true)
            .build()
            .unwrap();
        runtime.block_on(async {
            let mode_flag = std::sync::Arc::new(std::sync::atomic::AtomicU8::new(0));
            let stream: Box<dyn idevice::ReadWrite> =
                Box::new(CleanupSocket::new(mode_flag.clone()));
            let mut universal = UniversalHidServiceClient::new(
                idevice::xpc::RemoteXpcClient::new(stream).await.unwrap(),
            );
            let stream: Box<dyn idevice::ReadWrite> =
                Box::new(CleanupSocket::new(mode_flag.clone()));
            let mut indigo =
                IndigoHidClient::new(idevice::xpc::RemoteXpcClient::new(stream).await.unwrap());
            universal
                .send_touch(TouchEvent::Down(TouchPoint::new(1, 2)), None)
                .await
                .unwrap();
            mode_flag.store(mode, std::sync::atomic::Ordering::Release);
            let mut cleanup = InputCleanupState {
                touch_active: true,
                ..Default::default()
            };
            let started = tokio::time::Instant::now();
            let failure = cleanup_inputs(&mut cleanup, &mut universal, 1, &mut indigo)
                .await
                .reported()
                .unwrap_err();
            assert_eq!(failure.stage, "input_cleanup");
            assert_eq!(
                failure.code,
                if mode == 1 {
                    "input_delivery_failed"
                } else {
                    "input_cleanup_timeout"
                }
            );
            assert_eq!(
                started.elapsed(),
                if mode == 1 {
                    Duration::ZERO
                } else {
                    Duration::from_secs(3)
                }
            );
        });
    }
}

async fn assert_inflight_command_cancellation(command: ControlCommand, hardware: bool) {
    use std::sync::{
        Arc,
        atomic::{AtomicU8, Ordering},
    };

    let universal_mode = Arc::new(AtomicU8::new(0));
    let indigo_mode = Arc::new(AtomicU8::new(0));
    let universal_socket = CleanupSocket::new(universal_mode.clone());
    let indigo_socket = CleanupSocket::new(indigo_mode.clone());
    let written = if hardware {
        indigo_socket.written.clone()
    } else {
        universal_socket.written.clone()
    };
    let universal_stream: Box<dyn idevice::ReadWrite> = Box::new(universal_socket);
    let indigo_stream: Box<dyn idevice::ReadWrite> = Box::new(indigo_socket);
    let orientation_stream: Box<dyn idevice::ReadWrite> =
        Box::new(CleanupSocket::new(Arc::new(AtomicU8::new(0))));
    let universal = UniversalHidServiceClient::new(
        idevice::xpc::RemoteXpcClient::new(universal_stream)
            .await
            .unwrap(),
    );
    let indigo = IndigoHidClient::new(
        idevice::xpc::RemoteXpcClient::new(indigo_stream)
            .await
            .unwrap(),
    );
    let orientation = OrientationServiceClient::new(
        idevice::xpc::RemoteXpcClient::new(orientation_stream)
            .await
            .unwrap(),
    );
    let adapter = tcp::adapter::Adapter::new(
        Box::new(CleanupSocket::new(Arc::new(AtomicU8::new(0)))),
        "fd00::1".parse().unwrap(),
        "fd00::2".parse().unwrap(),
    )
    .to_async_handle();
    let video_udp = adapter.bind_udp(0).await.unwrap();
    let (controls, sender, input_ready) = crate::session::control_gate_test_fixture();
    controls.enable_input();
    sender.send(command).await.unwrap();
    sender
        .send(ControlCommand::Touch(TouchIntent::Tap { x: 11, y: 12 }))
        .await
        .unwrap();
    let (cancel, cancellation) = tokio::sync::watch::channel(false);
    let fixture = crate::session::EventEmitterTestFixture::new();
    let emitter = fixture.emitter();
    let media = MediaEmitter::test_fixture(
        crate::abi::DhGeneration { high: 1, low: 2 },
        None,
        std::ptr::null_mut(),
    );
    let video = LiveVideoState {
        assembler: HevcAccessUnitAssembler::new(96, 1),
        last_configuration_revision: 0,
        geometry: DhDisplayGeometry {
            pixel_width: 0,
            pixel_height: 0,
            orientation: DhOrientation::Unknown as u32,
            non_flat_orientation: DhOrientation::Unknown as u32,
            orientation_locked: 0,
            reserved: [0; 7],
        },
    };
    let initial_written = written.load(Ordering::Acquire);
    if hardware {
        indigo_mode.store(3, Ordering::Release);
    } else {
        universal_mode.store(3, Ordering::Release);
    }
    let operation = run_active_control_loop(
        video_udp,
        universal,
        1,
        indigo,
        orientation,
        false,
        controls,
        cancellation,
        video,
        VideoFeedbackState::new(1, 2, "synthetic".into()),
        &emitter,
        &media,
    );
    tokio::pin!(operation);
    let pending = std::future::poll_fn(|context| {
        std::task::Poll::Ready(operation.as_mut().poll(context).is_pending())
    })
    .await;
    assert!(
        pending,
        "The ordinary input write must really be stalled before cancellation"
    );
    assert_eq!(
        written.load(Ordering::Acquire) - initial_written,
        8,
        "The ordinary write made partial progress, so delivery is unconfirmed"
    );
    assert_eq!(
        sender.capacity(),
        7,
        "Exactly one command consumed; later ordinary input still queued"
    );
    cancel.send(true).unwrap();
    let started = tokio::time::Instant::now();
    let result = tokio::time::timeout(
        INPUT_CLEANUP_TIMEOUT + Duration::from_secs(1),
        operation.as_mut(),
    )
    .await;
    let result =
        result.expect("Cancellation must reach bounded cleanup despite stalled ordinary input I/O");
    let failure =
        result.expect_err("Partially written input must not become confirmed successful cleanup");
    assert_eq!(failure.stage, "input_cleanup");
    assert!(started.elapsed() <= INPUT_CLEANUP_TIMEOUT);
    assert!(!input_ready.load(Ordering::Acquire));
    assert!(
        sender.is_closed(),
        "Control queue must close, not escape into replacement input"
    );
    assert_eq!(written.load(Ordering::Acquire) - initial_written, 8);
    assert_eq!(fixture.pending_event_count(), 0);
    drop(adapter);
}

#[tokio::test(start_paused = true)]
async fn cancel_inflight_touch_down_reaches_bounded_cleanup() {
    assert_inflight_command_cancellation(
        ControlCommand::Touch(TouchIntent::Down { x: 1, y: 2 }),
        false,
    )
    .await;
}

#[tokio::test(start_paused = true)]
async fn cancel_inflight_touch_tap_reaches_bounded_cleanup() {
    assert_inflight_command_cancellation(
        ControlCommand::Touch(TouchIntent::Tap { x: 1, y: 2 }),
        false,
    )
    .await;
}

#[tokio::test(start_paused = true)]
async fn cancel_inflight_button_down_reaches_bounded_cleanup() {
    assert_inflight_command_cancellation(
        ControlCommand::HardwareButton(crate::model::HardwareButtonIntent {
            button: DhHardwareButton::Home,
            phase: DhButtonPhase::Down,
        }),
        true,
    )
    .await;
}

#[tokio::test(start_paused = true)]
async fn cancel_inflight_button_tap_reaches_bounded_cleanup() {
    assert_inflight_command_cancellation(
        ControlCommand::HardwareButton(crate::model::HardwareButtonIntent {
            button: DhHardwareButton::Home,
            phase: DhButtonPhase::Tap,
        }),
        true,
    )
    .await;
}

struct PendingKeyboardSink;
impl KeyboardStateSink for PendingKeyboardSink {
    async fn replace(&mut self, _: BTreeSet<KeyboardUsage>) -> Result<(), HidError> {
        std::future::pending().await
    }
}

#[tokio::test]
async fn cancelled_keyboard_press_retains_unconfirmed_held_state() {
    for intent in [
        KeyboardIntent::Down {
            usage: 0x04,
            modifiers: 1,
        },
        KeyboardIntent::Tap {
            usage: 0x04,
            modifiers: 1,
        },
    ] {
        let mut cleanup = InputCleanupState::default();
        let mut sink = PendingKeyboardSink;
        let operation = handle_keyboard_intent_with_sink(intent, &mut cleanup, &mut sink);
        let mut operation = Box::pin(operation);
        assert!(
            std::future::poll_fn(|context| std::task::Poll::Ready(
                operation.as_mut().poll(context).is_pending()
            ))
            .await
        );
        drop(operation);
        assert_eq!(
            cleanup.pressed_keys,
            BTreeMap::from([(0x04, 1)]),
            "A cancelled press may already have reached the peer"
        );
    }
}

#[tokio::test(start_paused = true)]
async fn first_known_release_failure_survives_later_io_timeout() {
    use std::sync::{
        Arc,
        atomic::{AtomicU8, Ordering},
    };
    let universal_mode = Arc::new(AtomicU8::new(0));
    let indigo_mode = Arc::new(AtomicU8::new(0));
    let universal_stream: Box<dyn idevice::ReadWrite> =
        Box::new(CleanupSocket::new(universal_mode.clone()));
    let indigo_stream: Box<dyn idevice::ReadWrite> =
        Box::new(CleanupSocket::new(indigo_mode.clone()));
    let mut universal = UniversalHidServiceClient::new(
        idevice::xpc::RemoteXpcClient::new(universal_stream)
            .await
            .unwrap(),
    );
    let mut indigo = IndigoHidClient::new(
        idevice::xpc::RemoteXpcClient::new(indigo_stream)
            .await
            .unwrap(),
    );
    universal
        .send_touch(TouchEvent::Down(TouchPoint::new(1, 2)), None)
        .await
        .unwrap();
    indigo
        .send_hardware_button(HardwareButton::Home, ButtonState::Down)
        .await
        .unwrap();
    let mut cleanup = InputCleanupState {
        touch_active: true,
        pressed_buttons: vec![HardwareButton::Home],
        ..Default::default()
    };
    universal_mode.store(1, Ordering::Release);
    indigo_mode.store(2, Ordering::Release);
    let started = tokio::time::Instant::now();
    let failure = cleanup_inputs(&mut cleanup, &mut universal, 1, &mut indigo)
        .await
        .unwrap_err();
    assert_eq!(failure.stage, "input_cleanup");
    assert_eq!(
        failure.code, "input_delivery_failed",
        "A later deadline must not replace the already-known release failure"
    );
    assert_eq!(started.elapsed(), INPUT_CLEANUP_TIMEOUT);
}

struct FailingThenPanickingReleaseSink;
impl InputReleaseSink for FailingThenPanickingReleaseSink {
    async fn release(&mut self, action: InputReleaseAction) -> Result<(), HidError> {
        if action == InputReleaseAction::Touch {
            Err(HidError::Device(IdeviceError::ServiceNotFound))
        } else {
            panic!("synthetic private release panic");
        }
    }
}

#[test]
fn first_release_failure_outlives_unwound_protocol_future() {
    let fixture = crate::session::EventEmitterTestFixture::new();
    let emitter = fixture.emitter();
    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .unwrap();
    let outcome = crate::catch_sanitized_unwind(|| {
        let mut cleanup = InputCleanupState::for_session(&emitter);
        cleanup.touch_active = true;
        cleanup.pressed_buttons.push(HardwareButton::Home);
        runtime.block_on(release_all_inputs_with_sink(
            &mut cleanup,
            &mut FailingThenPanickingReleaseSink,
        ))
    });
    assert!(outcome.is_err());
    let slot = emitter.cleanup_failure_slot();
    let retained = slot.lock().unwrap();
    assert_eq!(
        retained.as_ref().map(|failure| failure.code),
        Some("input_delivery_failed")
    );
}

fn button_intent(
    button: DhHardwareButton,
    phase: DhButtonPhase,
) -> crate::model::HardwareButtonIntent {
    crate::model::HardwareButtonIntent { button, phase }
}

#[tokio::test]
async fn volume_taps_swap_landscape_left_only_on_ipad() {
    use DhOrientation::{LandscapeLeft, LandscapeRight, Portrait, PortraitUpsideDown};
    use HardwareButton::{Home, VolumeDown, VolumeUp};
    let landscape_left = [(false, VolumeUp, VolumeDown), (true, VolumeDown, VolumeUp)];
    for (is_ipad, left_up, left_down) in landscape_left {
        for (button, orientation, sent) in [
            (DhHardwareButton::VolumeUp, Portrait, VolumeUp),
            (DhHardwareButton::VolumeDown, Portrait, VolumeDown),
            (DhHardwareButton::VolumeUp, PortraitUpsideDown, VolumeDown),
            (DhHardwareButton::VolumeDown, PortraitUpsideDown, VolumeUp),
            (DhHardwareButton::VolumeUp, LandscapeLeft, left_up),
            (DhHardwareButton::VolumeDown, LandscapeLeft, left_down),
            (DhHardwareButton::VolumeUp, LandscapeRight, VolumeUp),
            (DhHardwareButton::VolumeDown, LandscapeRight, VolumeDown),
            (DhHardwareButton::Home, PortraitUpsideDown, Home),
        ] {
            let mut cleanup = InputCleanupState::default();
            let mut sink = MockHardwareButtonSink::default();
            handle_hardware_button_with_sink(
                button_intent(button, DhButtonPhase::Tap),
                orientation,
                is_ipad,
                &mut cleanup,
                &mut sink,
            )
            .await
            .unwrap();
            assert_eq!(
                sink.attempts,
                vec![(sent, ButtonState::Down), (sent, ButtonState::Up)],
                "{button:?} while {orientation:?} (iPad={is_ipad})"
            );
            assert!(cleanup.pressed_buttons.is_empty());
        }
    }
}

#[test]
fn volume_orientation_comes_from_the_live_query_and_falls_back_unswapped() {
    let state = |orientation, non_flat_orientation| OrientationState {
        orientation,
        non_flat_orientation,
        locked: false,
    };
    let upside_down = state(
        Orientation::PortraitUpsideDown,
        Orientation::PortraitUpsideDown,
    );
    let flat_after_upside_down = state(Orientation::FaceUp, Orientation::PortraitUpsideDown);
    let landscape = state(Orientation::LandscapeLeft, Orientation::LandscapeLeft);
    let flat_unknown = state(Orientation::FaceUp, Orientation::FaceDown);
    assert_eq!(
        volume_orientation(Some(&upside_down)),
        DhOrientation::PortraitUpsideDown
    );
    assert_eq!(
        volume_orientation(Some(&flat_after_upside_down)),
        DhOrientation::PortraitUpsideDown
    );
    assert_eq!(
        volume_orientation(Some(&landscape)),
        DhOrientation::LandscapeLeft
    );
    assert_eq!(
        volume_orientation(Some(&flat_unknown)),
        DhOrientation::Portrait
    );
    assert_eq!(volume_orientation(None), DhOrientation::Portrait);
}

#[tokio::test]
async fn volume_release_after_turning_lets_go_of_the_button_that_was_pressed() {
    for (is_ipad, initial_orientation) in [
        (false, DhOrientation::PortraitUpsideDown),
        (true, DhOrientation::PortraitUpsideDown),
        (true, DhOrientation::LandscapeLeft),
    ] {
        for (release, released) in [
            (DhButtonPhase::Up, ButtonState::Up),
            (DhButtonPhase::Cancel, ButtonState::Canceled),
        ] {
            let mut cleanup = InputCleanupState::default();
            let mut sink = MockHardwareButtonSink::default();
            handle_hardware_button_with_sink(
                button_intent(DhHardwareButton::VolumeUp, DhButtonPhase::Down),
                initial_orientation,
                is_ipad,
                &mut cleanup,
                &mut sink,
            )
            .await
            .unwrap();
            handle_hardware_button_with_sink(
                button_intent(DhHardwareButton::VolumeUp, release),
                DhOrientation::Portrait,
                is_ipad,
                &mut cleanup,
                &mut sink,
            )
            .await
            .unwrap();
            assert_eq!(
                sink.attempts,
                vec![
                    (HardwareButton::VolumeDown, ButtonState::Down),
                    (HardwareButton::VolumeDown, released),
                ],
                "{initial_orientation:?} to Portrait (iPad={is_ipad}) on {release:?}"
            );
            assert!(cleanup.pressed_buttons.is_empty());
        }
    }
}

/// Orientation service stand-in: answers from a fixed script of replies, then
/// stays silent, or fails every read.
#[derive(Debug, Default)]
struct OrientationSocket {
    replies: std::collections::VecDeque<Vec<u8>>,
    fail_reads: bool,
    /// Bytes the client has written: its handshake and each request.
    written: std::sync::Arc<std::sync::atomic::AtomicUsize>,
}
impl tokio::io::AsyncRead for OrientationSocket {
    fn poll_read(
        self: std::pin::Pin<&mut Self>,
        _: &mut std::task::Context<'_>,
        buf: &mut tokio::io::ReadBuf<'_>,
    ) -> std::task::Poll<std::io::Result<()>> {
        let socket = self.get_mut();
        if socket.fail_reads {
            return std::task::Poll::Ready(Err(std::io::ErrorKind::BrokenPipe.into()));
        }
        match socket.replies.pop_front() {
            Some(reply) => {
                buf.put_slice(&reply);
                std::task::Poll::Ready(Ok(()))
            }
            None => std::task::Poll::Pending,
        }
    }
}
impl tokio::io::AsyncWrite for OrientationSocket {
    fn poll_write(
        self: std::pin::Pin<&mut Self>,
        _: &mut std::task::Context<'_>,
        bytes: &[u8],
    ) -> std::task::Poll<std::io::Result<usize>> {
        self.written
            .fetch_add(bytes.len(), std::sync::atomic::Ordering::AcqRel);
        std::task::Poll::Ready(Ok(bytes.len()))
    }
    fn poll_flush(
        self: std::pin::Pin<&mut Self>,
        _: &mut std::task::Context<'_>,
    ) -> std::task::Poll<std::io::Result<()>> {
        std::task::Poll::Ready(Ok(()))
    }
    fn poll_shutdown(
        self: std::pin::Pin<&mut Self>,
        _: &mut std::task::Context<'_>,
    ) -> std::task::Poll<std::io::Result<()>> {
        std::task::Poll::Ready(Ok(()))
    }
}

/// One orientation reply as an HTTP/2 DATA frame on the XPC reply stream.
fn orientation_reply(orientation: &str, non_flat_orientation: &str) -> Vec<u8> {
    let payload = idevice::xpc::Dictionary::from_iter([
        (
            "currentDeviceOrientation".to_owned(),
            XPCObject::String(orientation.into()),
        ),
        (
            "currentDeviceNonFlatOrientation".to_owned(),
            XPCObject::String(non_flat_orientation.into()),
        ),
        (
            "currentDeviceOrientationLocked".to_owned(),
            XPCObject::Bool(false),
        ),
    ]);
    let body = idevice::xpc::XPCMessage::new(None, Some(XPCObject::Dictionary(payload)), Some(1))
        .encode(1)
        .unwrap();
    let mut frame = (body.len() as u32).to_be_bytes()[1..].to_vec();
    frame.extend_from_slice(&[0x00, 0x00, 0, 0, 0, 3]);
    frame.extend_from_slice(&body);
    frame
}

struct LiveLoopRun {
    /// Set when the loop ended by itself before cancellation.
    early_result: Option<Result<(), PublicFailure>>,
    result: Option<Result<(), PublicFailure>>,
    events_before_cancel: usize,
    events_after_cancel: usize,
    cleanup_bytes_after_cancel: usize,
    teardown: Duration,
}

/// Runs the real control loop over a configured stream for `cancel_after`,
/// then cancels it.
async fn run_live_loop(
    orientation_socket: OrientationSocket,
    geometry: DhDisplayGeometry,
    commands: Vec<ControlCommand>,
    cancel_after: Duration,
) -> LiveLoopRun {
    use std::sync::{
        Arc,
        atomic::{AtomicU8, Ordering},
    };

    let universal_socket = CleanupSocket::new(Arc::new(AtomicU8::new(0)));
    let universal_written = universal_socket.written.clone();
    let universal_stream: Box<dyn idevice::ReadWrite> = Box::new(universal_socket);
    let indigo_stream: Box<dyn idevice::ReadWrite> =
        Box::new(CleanupSocket::new(Arc::new(AtomicU8::new(0))));
    let orientation_stream: Box<dyn idevice::ReadWrite> = Box::new(orientation_socket);
    let universal = UniversalHidServiceClient::new(
        idevice::xpc::RemoteXpcClient::new(universal_stream)
            .await
            .unwrap(),
    );
    let indigo = IndigoHidClient::new(
        idevice::xpc::RemoteXpcClient::new(indigo_stream)
            .await
            .unwrap(),
    );
    let orientation = OrientationServiceClient::new(
        idevice::xpc::RemoteXpcClient::new(orientation_stream)
            .await
            .unwrap(),
    );
    let adapter = tcp::adapter::Adapter::new(
        Box::new(CleanupSocket::new(Arc::new(AtomicU8::new(0)))),
        "fd00::1".parse().unwrap(),
        "fd00::2".parse().unwrap(),
    )
    .to_async_handle();
    let video_udp = adapter.bind_udp(0).await.unwrap();
    let (controls, sender, _input_ready) = crate::session::control_gate_test_fixture();
    controls.enable_input();
    for command in commands {
        sender.send(command).await.unwrap();
    }
    let (cancel, cancellation) = tokio::sync::watch::channel(false);
    let fixture = crate::session::EventEmitterTestFixture::new();
    let emitter = fixture.emitter();
    let media = MediaEmitter::test_fixture(
        crate::abi::DhGeneration { high: 1, low: 2 },
        None,
        std::ptr::null_mut(),
    );
    let video = LiveVideoState {
        assembler: HevcAccessUnitAssembler::new(96, 1),
        last_configuration_revision: 1,
        geometry,
    };
    let operation = run_active_control_loop(
        video_udp,
        universal,
        1,
        indigo,
        orientation,
        false,
        controls,
        cancellation,
        video,
        VideoFeedbackState::new(1, 2, "synthetic".into()),
        &emitter,
        &media,
    );
    tokio::pin!(operation);
    let early_result = tokio::select! {
        result = &mut operation => Some(result),
        () = tokio::time::sleep(cancel_after) => None,
    };
    let mut run = LiveLoopRun {
        early_result,
        result: None,
        events_before_cancel: fixture.pending_event_count(),
        events_after_cancel: 0,
        cleanup_bytes_after_cancel: 0,
        teardown: Duration::ZERO,
    };
    if run.early_result.is_none() {
        let written_at_cancel = universal_written.load(Ordering::Acquire);
        cancel.send(true).unwrap();
        let started = tokio::time::Instant::now();
        run.result = Some(operation.await);
        run.teardown = started.elapsed();
        run.cleanup_bytes_after_cancel =
            universal_written.load(Ordering::Acquire) - written_at_cancel;
        run.events_after_cancel = fixture.pending_event_count();
    }
    drop(adapter);
    run
}

fn landscape_shaped_geometry(orientation: DhOrientation) -> DhDisplayGeometry {
    DhDisplayGeometry {
        pixel_width: 1376,
        pixel_height: 1032,
        orientation: orientation as u32,
        non_flat_orientation: orientation as u32,
        orientation_locked: 0,
        reserved: [0; 7],
    }
}

/// Preload the real userspace UDP socket over a fake tunnel.
async fn preload_video_udp<'a>(
    payloads: impl IntoIterator<Item = &'a [u8]>,
) -> (tcp::handle::UdpSocketHandle, tokio::io::DuplexStream) {
    use tcp::packets::{Ipv6Packet, ProtocolNumber, UdpPacket};
    use tokio::io::AsyncWriteExt;

    let host_ip: std::net::Ipv6Addr = "2001:db8::1".parse().unwrap();
    let peer_ip: std::net::Ipv6Addr = "2001:db8::2".parse().unwrap();
    let (mut tunnel, transport) = tokio::io::duplex(32 * 1024);
    let adapter = tcp::adapter::Adapter::new(Box::new(transport), host_ip.into(), peer_ip.into())
        .to_async_handle();
    let video_udp = adapter.bind_udp(0).await.unwrap();
    let barrier_udp = adapter.bind_udp(0).await.unwrap();
    let packet = |port, payload: &[u8]| {
        let udp = UdpPacket::create(peer_ip.into(), host_ip.into(), 5000, port, payload);
        Ipv6Packet::create(peer_ip, host_ip, ProtocolNumber::Udp, 64, &udp)
    };
    let rtcp = [0x80, 201, 0, 1, 0, 0, 0, 1];
    let mut datagrams: Vec<u8> = payloads
        .into_iter()
        .flat_map(|payload| packet(video_udp.local_port(), payload))
        .collect();
    datagrams.extend(packet(barrier_udp.local_port(), &rtcp));
    tunnel.write_all(&datagrams).await.unwrap();
    tokio::time::timeout(Duration::from_secs(1), barrier_udp.recv())
        .await
        .expect("The fake tunnel must preload the video receive queue")
        .unwrap();
    (video_udp, tunnel)
}

async fn fake_xpc(
    transport: impl idevice::ReadWrite + 'static,
) -> idevice::xpc::RemoteXpcClient<Box<dyn idevice::ReadWrite>> {
    idevice::xpc::RemoteXpcClient::new(Box::new(transport) as Box<dyn idevice::ReadWrite>)
        .await
        .unwrap()
}

/// A rejected second video packet ends the loop, so later queued packets
/// cannot hide starvation.
async fn taps_before_second_video_datagram(queued_taps: usize) -> usize {
    use std::sync::{
        Arc,
        atomic::{AtomicU8, Ordering},
    };

    let rtcp = [0x80, 201, 0, 1, 0, 0, 0, 1];
    let wrong_payload_type_rtp = [0x80, 97, 0, 1, 0, 0, 0, 0, 0, 0, 0, 1, 2, 1];
    let video_payloads = [rtcp.as_slice(), wrong_payload_type_rtp.as_slice()]
        .into_iter()
        .chain(std::iter::repeat_n(rtcp.as_slice(), 256));
    let (video_udp, _tunnel) = preload_video_udp(video_payloads).await;
    let socket = || CleanupSocket::new(Arc::new(AtomicU8::new(0)));
    let universal_socket = socket();
    let written = universal_socket.written.clone();
    let mut universal = UniversalHidServiceClient::new(fake_xpc(universal_socket).await);
    let indigo = IndigoHidClient::new(fake_xpc(socket()).await);
    let orientation = OrientationServiceClient::new(fake_xpc(socket()).await);
    let before_reference_tap = written.load(Ordering::Acquire);
    universal.tap(1, 2).await.unwrap();
    let before_stream = written.load(Ordering::Acquire);
    let tap_bytes = before_stream - before_reference_tap;
    assert!(tap_bytes > 0);

    let (controls, sender, _) = crate::session::control_gate_test_fixture();
    controls.enable_input();
    assert!(queued_taps <= sender.capacity());
    for _ in 0..queued_taps {
        sender
            .send(ControlCommand::Touch(TouchIntent::Tap { x: 1, y: 2 }))
            .await
            .unwrap();
    }
    tokio::time::advance(Duration::from_millis(125)).await;
    let (_cancel, cancellation) = tokio::sync::watch::channel(false);
    let fixture = crate::session::EventEmitterTestFixture::new();
    let media = MediaEmitter::test_fixture(
        crate::abi::DhGeneration { high: 1, low: 2 },
        None,
        std::ptr::null_mut(),
    );
    let video = LiveVideoState {
        assembler: HevcAccessUnitAssembler::new(96, 1),
        last_configuration_revision: 1,
        geometry: landscape_shaped_geometry(DhOrientation::LandscapeLeft),
    };
    let result = tokio::time::timeout(
        Duration::from_secs(1),
        run_active_control_loop(
            video_udp,
            universal,
            1,
            indigo,
            orientation,
            false,
            controls,
            cancellation,
            video,
            VideoFeedbackState::new(1, 1, "synthetic".into()),
            &fixture.emitter(),
            &media,
        ),
    )
    .await
    .expect("The ready stream must reach the second video datagram")
    .expect_err("The second video datagram must be rejected");
    assert_eq!(result.code, "video_datagram_rejected");
    let stream_bytes = written.load(Ordering::Acquire) - before_stream;
    assert_eq!(stream_bytes % tap_bytes, 0, "Each tap must be complete");
    stream_bytes / tap_bytes
}

#[tokio::test(start_paused = true)]
async fn queued_tap_is_delivered_before_second_ready_video_datagram() {
    assert_eq!(
        taps_before_second_video_datagram(1).await,
        1,
        "The HID tap must complete before the second ready video datagram"
    );
}

#[tokio::test(start_paused = true)]
async fn backlogged_video_progresses_while_input_stays_queued() {
    let delivered = taps_before_second_video_datagram(8).await;
    assert!(
        (1..=2).contains(&delivered),
        "Both lanes must progress while input is still queued (delivered {delivered} of 8 taps)"
    );
}

#[test]
fn bootstrap_trace_prints_only_redacted_input_timing_to_stdout() {
    let run_tap = |trace| {
        std::process::Command::new(std::env::current_exe().unwrap())
            .args([
                "--exact",
                "protocol::tests::input_tests::queued_tap_is_delivered_before_second_ready_video_datagram",
                "--nocapture",
                "--format=terse",
            ])
            .env("DEVICE_HUB_BOOTSTRAP_TRACE", trace)
            .output()
            .unwrap()
    };
    for (trace, expected) in [
        (
            "1",
            &[
                "devicehub.native input_dequeued kind=touch_tap waited_ms=125",
                "devicehub.native input_delivered kind=touch_tap",
            ][..],
        ),
        ("0", &[][..]),
    ] {
        let output = run_tap(trace);
        let stdout = String::from_utf8(output.stdout).unwrap();
        let stderr = String::from_utf8(output.stderr).unwrap();
        assert!(output.status.success(), "{stdout}\n{stderr}");
        let lines: Vec<_> = stdout
            .lines()
            .filter(|line| line.starts_with("devicehub.native input_"))
            .collect();
        assert_eq!(lines, expected, "Bootstrap input lines belong on stdout");
        assert!(!stderr.contains("input_delivered"));
    }
}

#[tokio::test(start_paused = true)]
async fn video_queued_during_a_slow_orientation_read_prevents_false_stall() {
    use super::{
        SYNTHETIC_64_X_64_SPS, TEST_VIDEO_PAYLOAD_TYPE, TEST_VIDEO_SSRC, test_aggregation_packet,
        test_media_emitter, test_nal, test_rtp_datagram,
    };
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    let config = test_aggregation_packet(&[
        test_nal(32, &[0x10]),
        SYNTHETIC_64_X_64_SPS.to_vec(),
        test_nal(34, &[0x30]),
    ]);
    let frame = [
        test_rtp_datagram(TEST_VIDEO_PAYLOAD_TYPE, 1, 1, true, &test_nal(39, &[0xAA])),
        test_rtp_datagram(TEST_VIDEO_PAYLOAD_TYPE, 2, 2, true, &config),
        test_rtp_datagram(TEST_VIDEO_PAYLOAD_TYPE, 3, 3, true, &test_nal(19, &[0xD0])),
    ];
    let rtcp = vec![0x80, 201, 0, 1, 0, 0, 0, 1];
    let terminal_packet = test_rtp_datagram(97, 4, 4, true, &test_nal(39, &[0xAA]));
    let (video_udp, mut tunnel) = preload_video_udp(
        frame
            .iter()
            .chain([&rtcp, &terminal_packet])
            .map(Vec::as_slice),
    )
    .await;
    let sink = || CleanupSocket::new(std::sync::Arc::default());
    let (mut reply, orientation_io) = tokio::io::duplex(4096);
    let orientation = OrientationServiceClient::new(fake_xpc(orientation_io).await);
    let (controls, _sender, _) = crate::session::control_gate_test_fixture();
    let (_cancel, cancellation) = tokio::sync::watch::channel(false);
    let fixture = crate::session::EventEmitterTestFixture::new();
    let emitter = fixture.emitter();
    let capture = super::ProtocolMediaCapture::default();
    let media = test_media_emitter(&capture);
    let operation = run_active_control_loop(
        video_udp,
        UniversalHidServiceClient::new(fake_xpc(sink()).await),
        1,
        IndigoHidClient::new(fake_xpc(sink()).await),
        orientation,
        false,
        controls,
        cancellation,
        LiveVideoState {
            assembler: HevcAccessUnitAssembler::new(TEST_VIDEO_PAYLOAD_TYPE, TEST_VIDEO_SSRC),
            last_configuration_revision: 0,
            geometry: landscape_shaped_geometry(DhOrientation::LandscapeLeft),
        },
        VideoFeedbackState::new(1, TEST_VIDEO_SSRC, "synthetic".into()),
        &emitter,
        &media,
    );
    let delayed_orientation = async {
        tokio::time::sleep(MEDIA_STALL_TIMEOUT + Duration::from_secs(1)).await;
        reply
            .write_all(&orientation_reply("portrait", "portrait"))
            .await
            .unwrap();
    };
    let (result, ()) = tokio::join!(
        tokio::time::timeout(INPUT_TIMEOUT + Duration::from_secs(1), operation),
        delayed_orientation,
    );
    assert_eq!(
        result.unwrap().unwrap_err().code,
        "video_datagram_rejected",
        "An overdue feedback tick must let a queued video datagram prove the socket is active"
    );
    let mut feedback = Vec::new();
    tokio::time::timeout(Duration::from_secs(1), tunnel.read_to_end(&mut feedback))
        .await
        .expect("The fake tunnel must close after the video socket drops")
        .unwrap();
    assert!(
        feedback.windows(4).any(|bytes| bytes == b"RCTL"),
        "An overdue feedback report must still be sent"
    );
}

#[tokio::test(start_paused = true)]
async fn periodic_orientation_check_relabels_the_live_stream_once_per_change() {
    let run = run_live_loop(
        OrientationSocket {
            replies: [
                orientation_reply("portrait", "portrait"),
                orientation_reply("portrait", "portrait"),
            ]
            .into(),
            ..Default::default()
        },
        landscape_shaped_geometry(DhOrientation::LandscapeLeft),
        Vec::new(),
        Duration::from_millis(2_500),
    )
    .await;
    assert!(run.early_result.is_none(), "{:?}", run.early_result);
    assert_eq!(
        run.events_before_cancel, 1,
        "One turn of the iPad publishes exactly one display geometry"
    );
    run.result.unwrap().unwrap();
    assert_eq!(run.events_after_cancel, 0);
}

#[tokio::test(start_paused = true)]
async fn failed_orientation_checks_do_not_end_the_session() {
    for fail_reads in [true, false] {
        // false: the service never answers, so every check times out and the
        // last one is still pending when the session is cancelled.
        let run = run_live_loop(
            OrientationSocket {
                replies: Default::default(),
                fail_reads,
                ..Default::default()
            },
            landscape_shaped_geometry(DhOrientation::LandscapeLeft),
            vec![ControlCommand::Touch(TouchIntent::Down { x: 1, y: 2 })],
            Duration::from_millis(4_500),
        )
        .await;
        assert!(
            run.early_result.is_none(),
            "fail_reads={fail_reads}: {:?}",
            run.early_result
        );
        assert_eq!(run.events_before_cancel, 0);
        run.result.unwrap().unwrap();
        assert!(
            run.cleanup_bytes_after_cancel > 0,
            "The held touch is released after cancellation"
        );
        assert!(run.teardown <= INPUT_CLEANUP_TIMEOUT);
        assert_eq!(run.events_after_cancel, 0);
    }
}

#[tokio::test(start_paused = true)]
async fn rotate_reply_relabels_the_live_stream() {
    let run = run_live_loop(
        OrientationSocket {
            replies: [orientation_reply("landscapeLeft", "landscapeLeft")].into(),
            ..Default::default()
        },
        landscape_shaped_geometry(DhOrientation::Portrait),
        vec![ControlCommand::Rotate(RotationIntent::Left)],
        Duration::from_millis(500),
    )
    .await;
    assert!(run.early_result.is_none(), "{:?}", run.early_result);
    assert_eq!(run.events_before_cancel, 1);
    run.result.unwrap().unwrap();
}

#[tokio::test(start_paused = true)]
async fn rejected_rotation_still_fails_the_session() {
    let run = run_live_loop(
        OrientationSocket {
            fail_reads: true,
            ..Default::default()
        },
        landscape_shaped_geometry(DhOrientation::Portrait),
        vec![ControlCommand::Rotate(RotationIntent::Left)],
        Duration::from_millis(500),
    )
    .await;
    let failure = run
        .early_result
        .expect("A rejected rotation ends the session")
        .unwrap_err();
    assert_eq!(failure.code, "rotation_failed");
}

#[tokio::test(start_paused = true)]
async fn an_unanswered_orientation_check_stops_further_checks() {
    // The reply to a timed-out request could still arrive and be taken as the
    // answer to the next one, so no further request may go out.
    let mut written = Vec::new();
    for cancel_after in [Duration::from_millis(1_500), Duration::from_millis(6_500)] {
        let socket = OrientationSocket::default();
        let bytes = socket.written.clone();
        let run = run_live_loop(
            socket,
            landscape_shaped_geometry(DhOrientation::LandscapeLeft),
            Vec::new(),
            cancel_after,
        )
        .await;
        assert!(run.early_result.is_none(), "{:?}", run.early_result);
        run.result.unwrap().unwrap();
        written.push(bytes.load(std::sync::atomic::Ordering::Acquire));
    }
    assert_eq!(
        written[0], written[1],
        "Only the first check's request is written in 6.5 s of silence"
    );
}

#[tokio::test(start_paused = true)]
async fn orientation_checks_continue_after_a_service_error() {
    let mut written = Vec::new();
    for cancel_after in [Duration::from_millis(1_500), Duration::from_millis(3_500)] {
        let socket = OrientationSocket {
            fail_reads: true,
            ..Default::default()
        };
        let bytes = socket.written.clone();
        let run = run_live_loop(
            socket,
            landscape_shaped_geometry(DhOrientation::LandscapeLeft),
            Vec::new(),
            cancel_after,
        )
        .await;
        run.result.unwrap().unwrap();
        written.push(bytes.load(std::sync::atomic::Ordering::Acquire));
    }
    assert!(written[1] > written[0], "{written:?}");
}
