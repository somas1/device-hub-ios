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
    assert_eq!(
        keyboard.attempts,
        vec![vec![0x04, 0x05, 0xE0, 0xE1], vec![0x05, 0xE1]]
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
        vec![vec![0x04, 0xE0, 0xE7], Vec::new()]
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
    handle_hardware_button_with_sink(intent, &mut button_cleanup, &mut button)
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
    let failure =
        handle_hardware_button_with_sink(intent, &mut failed_button_cleanup, &mut failed_button)
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
