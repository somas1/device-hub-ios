use std::{collections::HashMap, ffi::c_void, sync::Mutex};

use super::*;
use crate::{
    abi::{DhEvent, DhGeneration},
    session::EventEmitterTestFixture,
};
use idevice::xpc::XPCObject;

#[path = "tests/input.rs"]
mod input_tests;

const MISSING_LIVE_TARGET: &str = "Live protocol verification requires an explicit target name.";
const TEST_VIDEO_PAYLOAD_TYPE: u8 = 100;
const TEST_VIDEO_SSRC: u32 = 0x1234_5678;
const SYNTHETIC_64_X_64_SPS: &[u8] = &[
    0x42, 0x01, 0x01, 0x04, 0x08, 0x00, 0x00, 0x03, 0x00, 0x9f, 0xa8, 0x00, 0x00, 0x03, 0x00, 0x00,
    0xff, 0xa0, 0x20, 0x81, 0x05, 0x96, 0xea, 0x49, 0x32, 0xbc, 0x05, 0xa0, 0x20, 0x00, 0x00, 0x03,
    0x00, 0x20, 0x00, 0x00, 0x03, 0x00, 0x21,
];

#[derive(Default)]
struct ProtocolMediaCapture {
    events: Mutex<Vec<(DhEventKind, Option<DhDisplayGeometry>)>>,
}

unsafe extern "C" fn capture_protocol_media_event(event: *const DhEvent, context: *mut c_void) {
    // SAFETY: The protocol test keeps both callback pointers alive.
    let event = unsafe { &*event };
    // SAFETY: Context points to a live `ProtocolMediaCapture`.
    let capture = unsafe { &*(context.cast::<ProtocolMediaCapture>()) };
    let geometry = if event.video_access_unit.is_null() {
        None
    } else {
        // SAFETY: The access-unit view is borrowed for this callback.
        Some(unsafe { (*event.video_access_unit).geometry })
    };
    capture.events.lock().unwrap().push((event.kind, geometry));
}

fn test_media_emitter(capture: &ProtocolMediaCapture) -> MediaEmitter {
    MediaEmitter::test_fixture(
        DhGeneration {
            high: 0x1020_3040_5060_7080,
            low: 0x90A0_B0C0_D0E0_F001,
        },
        Some(capture_protocol_media_event),
        std::ptr::from_ref(capture).cast_mut().cast(),
    )
}

#[test]
fn pair_verify_discovery_completes_without_entering_the_tunnel_path() {
    let pair_verify_events = EventEmitterTestFixture::new();
    assert!(
        complete_pair_verify_discovery(&RemoteMode::PairVerify, &pair_verify_events.emitter(),)
            .unwrap()
    );
    assert_eq!(pair_verify_events.pending_event_count(), 1);

    let screenshot_events = EventEmitterTestFixture::new();
    assert!(
        !complete_pair_verify_discovery(&RemoteMode::Screenshot, &screenshot_events.emitter(),)
            .unwrap()
    );
    assert_eq!(screenshot_events.pending_event_count(), 0);
}

#[test]
fn pair_verify_does_not_promote_provisional_records_in_native_code() {
    assert!(!should_promote_provisional_record(
        &RemoteMode::PairVerify,
        DhPairingCompletion::Provisional,
    ));
    assert!(should_promote_provisional_record(
        &RemoteMode::Screenshot,
        DhPairingCompletion::Provisional,
    ));
    assert!(should_promote_provisional_record(
        &RemoteMode::ControlStream,
        DhPairingCompletion::Provisional,
    ));
    assert!(!should_promote_provisional_record(
        &RemoteMode::Screenshot,
        DhPairingCompletion::Committed,
    ));
}

#[test]
fn pair_verify_failures_preserve_secret_safe_protocol_checkpoints() {
    use idevice::remote_pairing::errors::RemotePairingError;

    let cases = [
        (
            IdeviceError::RemotePairing(RemotePairingError::PeerAuthenticationFailed),
            "pair_verify_m2_authentication",
        ),
        (
            IdeviceError::RemotePairing(RemotePairingError::PairVerifyM2DecryptionFailed),
            "pair_verify_m2_decryption",
        ),
        (
            IdeviceError::RemotePairing(RemotePairingError::PairVerifyM2IdentifierMismatch),
            "pair_verify_m2_identifier",
        ),
        (
            IdeviceError::RemotePairing(RemotePairingError::PairVerifyM2SignatureFailed),
            "pair_verify_m2_signature",
        ),
        (
            IdeviceError::RemotePairing(RemotePairingError::PairVerifyFailed),
            "pair_verify_peer_rejection",
        ),
        (
            IdeviceError::RemotePairing(RemotePairingError::PairVerifyCompletionFailed),
            "pair_verify_m4_completion",
        ),
        (
            IdeviceError::UnexpectedResponse("redacted protocol shape".into()),
            "pair_verify_protocol",
        ),
    ];

    for (error, expected_stage) in cases {
        let failure = pair_verify_failure(error);
        assert_eq!(failure.code, "pair_verify_failed");
        assert_eq!(failure.stage, expected_stage);
        assert!(!failure.retryable);
    }
}

fn test_geometry() -> DhDisplayGeometry {
    DhDisplayGeometry {
        pixel_width: 0,
        pixel_height: 0,
        orientation: DhOrientation::Portrait as u32,
        non_flat_orientation: DhOrientation::Portrait as u32,
        orientation_locked: 0,
        reserved: [0; 7],
    }
}

fn test_nal(nal_type: u8, body: &[u8]) -> Vec<u8> {
    let mut nal = vec![nal_type << 1, 1];
    nal.extend_from_slice(body);
    nal
}

fn test_aggregation_packet(nals: &[Vec<u8>]) -> Vec<u8> {
    let mut payload = vec![48 << 1, 1];
    for nal in nals {
        payload.extend_from_slice(&(nal.len() as u16).to_be_bytes());
        payload.extend_from_slice(nal);
    }
    payload
}

fn test_rtp_datagram(
    payload_type: u8,
    sequence_number: u16,
    timestamp: u32,
    marker: bool,
    payload: &[u8],
) -> Vec<u8> {
    let mut datagram = vec![0x80, (u8::from(marker) << 7) | payload_type];
    datagram.extend_from_slice(&sequence_number.to_be_bytes());
    datagram.extend_from_slice(&timestamp.to_be_bytes());
    datagram.extend_from_slice(&TEST_VIDEO_SSRC.to_be_bytes());
    datagram.extend_from_slice(payload);
    datagram
}

fn prime_test_video_stream(
    assembler: &mut HevcAccessUnitAssembler,
    last_configuration_revision: &mut u64,
    geometry: &mut DhDisplayGeometry,
    media: &MediaEmitter,
    emitter: &EventEmitter,
) {
    let boundary = test_nal(39, &[0xAA]);
    assert!(
        !process_video_datagram(
            test_rtp_datagram(TEST_VIDEO_PAYLOAD_TYPE, 1, 1, true, &boundary),
            VIDEO_SENDER_PORT,
            assembler,
            last_configuration_revision,
            geometry,
            media,
            emitter,
        )
        .unwrap()
    );
    let parameters = test_aggregation_packet(&[
        test_nal(32, &[0x10]),
        SYNTHETIC_64_X_64_SPS.to_vec(),
        test_nal(34, &[0x30]),
    ]);
    assert!(
        !process_video_datagram(
            test_rtp_datagram(TEST_VIDEO_PAYLOAD_TYPE, 2, 2, true, &parameters),
            VIDEO_SENDER_PORT,
            assembler,
            last_configuration_revision,
            geometry,
            media,
            emitter,
        )
        .unwrap()
    );
    let sync_sample = test_nal(19, &[0xD0]);
    assert!(
        process_video_datagram(
            test_rtp_datagram(TEST_VIDEO_PAYLOAD_TYPE, 3, 3, true, &sync_sample),
            VIDEO_SENDER_PORT,
            assembler,
            last_configuration_revision,
            geometry,
            media,
            emitter,
        )
        .unwrap()
    );
    assert_eq!(*last_configuration_revision, 1);
    assert_eq!((geometry.pixel_width, geometry.pixel_height), (64, 64));
}

async fn open_live_rsd_for_target(
    target_name: &str,
    endpoint: &str,
) -> Result<RsdHandshake, String> {
    if target_name.trim().is_empty() {
        return Err(MISSING_LIVE_TARGET.into());
    }
    let stream = tokio::time::timeout(Duration::from_secs(3), TcpStream::connect(endpoint))
        .await
        .map_err(|_| "RSD connection timed out".to_owned())?
        .map_err(|error| format!("RSD connection failed: {error}"))?;
    tokio::time::timeout(Duration::from_secs(3), RsdHandshake::new(stream))
        .await
        .map_err(|_| "RSD handshake timed out".to_owned())?
        .map_err(|error| format!("RSD handshake failed: {error}"))
}

#[test]
fn malformed_stream_discontinuity_drops_predicted_frames_until_a_sync_sample() {
    let capture = ProtocolMediaCapture::default();
    let media = test_media_emitter(&capture);
    let control = EventEmitterTestFixture::new();
    let emitter = control.emitter();
    let mut assembler = HevcAccessUnitAssembler::new(TEST_VIDEO_PAYLOAD_TYPE, TEST_VIDEO_SSRC);
    let mut last_configuration_revision = 0;
    let mut geometry = test_geometry();
    prime_test_video_stream(
        &mut assembler,
        &mut last_configuration_revision,
        &mut geometry,
        &media,
        &emitter,
    );
    capture.events.lock().unwrap().clear();

    process_video_datagram(
        vec![0],
        VIDEO_SENDER_PORT,
        &mut assembler,
        &mut last_configuration_revision,
        &mut geometry,
        &media,
        &emitter,
    )
    .unwrap();
    assert_eq!(last_configuration_revision, 0);

    let sample = test_nal(1, &[0x60]);
    process_video_datagram(
        test_rtp_datagram(TEST_VIDEO_PAYLOAD_TYPE, 4, 4, true, &sample),
        VIDEO_SENDER_PORT,
        &mut assembler,
        &mut last_configuration_revision,
        &mut geometry,
        &media,
        &emitter,
    )
    .unwrap();

    {
        let events = capture.events.lock().unwrap();
        assert_eq!(
            events.iter().map(|(kind, _)| *kind).collect::<Vec<_>>(),
            vec![DhEventKind::VideoDiscontinuity]
        );
    }

    let sync_sample = test_nal(19, &[0xF0]);
    process_video_datagram(
        test_rtp_datagram(TEST_VIDEO_PAYLOAD_TYPE, 5, 5, true, &sync_sample),
        VIDEO_SENDER_PORT,
        &mut assembler,
        &mut last_configuration_revision,
        &mut geometry,
        &media,
        &emitter,
    )
    .unwrap();

    let events = capture.events.lock().unwrap();
    assert_eq!(
        events.iter().map(|(kind, _)| *kind).collect::<Vec<_>>(),
        vec![
            DhEventKind::VideoDiscontinuity,
            DhEventKind::VideoConfiguration,
            DhEventKind::VideoAccessUnit,
        ]
    );
    let access_unit_geometry = events.last().unwrap().1.unwrap();
    assert_eq!(
        (
            access_unit_geometry.pixel_width,
            access_unit_geometry.pixel_height,
            access_unit_geometry.orientation,
        ),
        (64, 64, DhOrientation::Portrait as u32)
    );
}

#[test]
fn authoritative_stream_identity_accepts_the_first_matching_packet() {
    let capture = ProtocolMediaCapture::default();
    let media = test_media_emitter(&capture);
    let control = EventEmitterTestFixture::new();
    let emitter = control.emitter();
    let mut assembler = HevcAccessUnitAssembler::new(TEST_VIDEO_PAYLOAD_TYPE, TEST_VIDEO_SSRC);
    let mut last_configuration_revision = 0;
    let mut geometry = test_geometry();
    let boundary = test_nal(39, &[0xAA]);

    process_video_datagram(
        test_rtp_datagram(TEST_VIDEO_PAYLOAD_TYPE, 1, 1, true, &boundary),
        VIDEO_SENDER_PORT,
        &mut assembler,
        &mut last_configuration_revision,
        &mut geometry,
        &media,
        &emitter,
    )
    .unwrap();

    assert_eq!(
        capture
            .events
            .lock()
            .unwrap()
            .iter()
            .map(|(kind, _)| *kind)
            .collect::<Vec<_>>(),
        Vec::<DhEventKind>::new()
    );
}

#[test]
fn incomplete_display_geometry_is_not_dispatched() {
    let control = EventEmitterTestFixture::new();
    let emitter = control.emitter();
    let mut geometry = test_geometry();

    emit_display_geometry_if_complete(&emitter, geometry).unwrap();
    assert_eq!(control.pending_event_count(), 0);

    geometry.pixel_width = 64;
    geometry.pixel_height = 64;
    emit_display_geometry_if_complete(&emitter, geometry).unwrap();
    assert_eq!(control.pending_event_count(), 1);
}

#[test]
fn access_unit_uses_the_protocol_workers_current_geometry_snapshot() {
    let capture = ProtocolMediaCapture::default();
    let media = test_media_emitter(&capture);
    let control = EventEmitterTestFixture::new();
    let emitter = control.emitter();
    let mut assembler = HevcAccessUnitAssembler::new(TEST_VIDEO_PAYLOAD_TYPE, TEST_VIDEO_SSRC);
    let mut last_configuration_revision = 0;
    let mut geometry = test_geometry();
    prime_test_video_stream(
        &mut assembler,
        &mut last_configuration_revision,
        &mut geometry,
        &media,
        &emitter,
    );
    capture.events.lock().unwrap().clear();

    geometry.orientation = DhOrientation::LandscapeLeft as u32;
    geometry.non_flat_orientation = DhOrientation::LandscapeLeft as u32;
    let sample = test_nal(1, &[0x60]);
    process_video_datagram(
        test_rtp_datagram(TEST_VIDEO_PAYLOAD_TYPE, 4, 4, true, &sample),
        VIDEO_SENDER_PORT,
        &mut assembler,
        &mut last_configuration_revision,
        &mut geometry,
        &media,
        &emitter,
    )
    .unwrap();

    let events = capture.events.lock().unwrap();
    assert_eq!(
        events.iter().map(|(kind, _)| *kind).collect::<Vec<_>>(),
        vec![DhEventKind::VideoAccessUnit]
    );
    let access_unit_geometry = events.last().unwrap().1.unwrap();
    assert_eq!(
        access_unit_geometry.orientation,
        DhOrientation::LandscapeLeft as u32
    );
    assert_eq!(
        access_unit_geometry.non_flat_orientation,
        DhOrientation::LandscapeLeft as u32
    );
    assert_eq!(
        (
            access_unit_geometry.pixel_width,
            access_unit_geometry.pixel_height,
        ),
        (64, 64)
    );
}

#[test]
fn changed_video_configuration_refreshes_orientation_before_access_unit_emission() {
    let capture = ProtocolMediaCapture::default();
    let media = test_media_emitter(&capture);
    let control = EventEmitterTestFixture::new();
    let emitter = control.emitter();
    let mut assembler = HevcAccessUnitAssembler::new(TEST_VIDEO_PAYLOAD_TYPE, TEST_VIDEO_SSRC);
    let mut last_configuration_revision = 0;
    let mut geometry = test_geometry();

    let boundary = test_nal(39, &[0xAA]);
    process_video_datagram(
        test_rtp_datagram(TEST_VIDEO_PAYLOAD_TYPE, 1, 1, true, &boundary),
        VIDEO_SENDER_PORT,
        &mut assembler,
        &mut last_configuration_revision,
        &mut geometry,
        &media,
        &emitter,
    )
    .unwrap();
    let parameters = test_aggregation_packet(&[
        test_nal(32, &[0x10]),
        SYNTHETIC_64_X_64_SPS.to_vec(),
        test_nal(34, &[0x30]),
    ]);
    process_video_datagram(
        test_rtp_datagram(TEST_VIDEO_PAYLOAD_TYPE, 2, 2, true, &parameters),
        VIDEO_SENDER_PORT,
        &mut assembler,
        &mut last_configuration_revision,
        &mut geometry,
        &media,
        &emitter,
    )
    .unwrap();

    let sample = test_nal(19, &[0xD0]);
    let prepared = prepare_video_datagram(
        test_rtp_datagram(TEST_VIDEO_PAYLOAD_TYPE, 3, 3, true, &sample),
        VIDEO_SENDER_PORT,
        &mut assembler,
        &mut last_configuration_revision,
        &media,
    )
    .unwrap()
    .unwrap();
    let orientation = OrientationState {
        orientation: Orientation::LandscapeRight,
        non_flat_orientation: Orientation::LandscapeRight,
        locked: true,
    };
    emit_prepared_video_datagram(
        prepared,
        &assembler,
        &mut last_configuration_revision,
        &mut geometry,
        Some(&orientation),
        &media,
        &emitter,
    )
    .unwrap();

    let access_unit_geometry = capture.events.lock().unwrap().last().unwrap().1.unwrap();
    assert_eq!(
        access_unit_geometry.orientation,
        DhOrientation::LandscapeRight as u32
    );
    assert_eq!(
        access_unit_geometry.non_flat_orientation,
        DhOrientation::LandscapeRight as u32
    );
    assert_eq!(access_unit_geometry.orientation_locked, 1);
    assert_eq!(
        (
            access_unit_geometry.pixel_width,
            access_unit_geometry.pixel_height,
        ),
        (64, 64)
    );
}

#[test]
fn rejected_stream_packet_fails_before_reaching_either_media_consumer() {
    let capture = ProtocolMediaCapture::default();
    let media = test_media_emitter(&capture);
    let control = EventEmitterTestFixture::new();
    let emitter = control.emitter();
    let mut assembler = HevcAccessUnitAssembler::new(TEST_VIDEO_PAYLOAD_TYPE, TEST_VIDEO_SSRC);
    let mut last_configuration_revision = 0;
    let mut geometry = test_geometry();
    prime_test_video_stream(
        &mut assembler,
        &mut last_configuration_revision,
        &mut geometry,
        &media,
        &emitter,
    );
    capture.events.lock().unwrap().clear();

    let unexpected_sample = test_nal(1, &[0x70]);
    let failure = process_video_datagram(
        test_rtp_datagram(TEST_VIDEO_PAYLOAD_TYPE + 1, 4, 4, true, &unexpected_sample),
        VIDEO_SENDER_PORT,
        &mut assembler,
        &mut last_configuration_revision,
        &mut geometry,
        &media,
        &emitter,
    )
    .unwrap_err();

    assert_eq!(failure.code, "video_datagram_rejected");
    assert_eq!(failure.stage, "video_stream_payload_invalid");
    assert!(capture.events.lock().unwrap().is_empty());
}

#[test]
fn unexpected_stream_sender_is_classified_as_an_ssrc_mismatch() {
    let capture = ProtocolMediaCapture::default();
    let media = test_media_emitter(&capture);
    let control = EventEmitterTestFixture::new();
    let emitter = control.emitter();
    let mut assembler = HevcAccessUnitAssembler::new(TEST_VIDEO_PAYLOAD_TYPE, TEST_VIDEO_SSRC);
    let mut last_configuration_revision = 0;
    let mut geometry = test_geometry();
    prime_test_video_stream(
        &mut assembler,
        &mut last_configuration_revision,
        &mut geometry,
        &media,
        &emitter,
    );
    capture.events.lock().unwrap().clear();

    let mut datagram =
        test_rtp_datagram(TEST_VIDEO_PAYLOAD_TYPE, 4, 4, true, &test_nal(1, &[0x70]));
    datagram[8..12].copy_from_slice(&(TEST_VIDEO_SSRC + 1).to_be_bytes());
    let failure = process_video_datagram(
        datagram,
        VIDEO_SENDER_PORT,
        &mut assembler,
        &mut last_configuration_revision,
        &mut geometry,
        &media,
        &emitter,
    )
    .unwrap_err();

    assert_eq!(failure.code, "video_datagram_rejected");
    assert_eq!(failure.stage, "video_stream_ssrc_mismatch");
    assert!(capture.events.lock().unwrap().is_empty());
}

#[test]
fn translated_tunnel_port_does_not_override_authenticated_rtp_identity() {
    let capture = ProtocolMediaCapture::default();
    let media = test_media_emitter(&capture);
    let control = EventEmitterTestFixture::new();
    let emitter = control.emitter();
    let mut assembler = HevcAccessUnitAssembler::new(TEST_VIDEO_PAYLOAD_TYPE, TEST_VIDEO_SSRC);
    let mut last_configuration_revision = 0;
    let mut geometry = test_geometry();
    prime_test_video_stream(
        &mut assembler,
        &mut last_configuration_revision,
        &mut geometry,
        &media,
        &emitter,
    );
    capture.events.lock().unwrap().clear();

    process_video_datagram(
        test_rtp_datagram(TEST_VIDEO_PAYLOAD_TYPE, 4, 4, true, &test_nal(1, &[0x60])),
        VIDEO_SENDER_PORT + 1,
        &mut assembler,
        &mut last_configuration_revision,
        &mut geometry,
        &media,
        &emitter,
    )
    .unwrap();

    assert_eq!(
        capture
            .events
            .lock()
            .unwrap()
            .iter()
            .map(|(kind, _)| *kind)
            .collect::<Vec<_>>(),
        vec![DhEventKind::VideoAccessUnit]
    );
}

#[tokio::test]
async fn live_harness_rejects_missing_target_before_opening_an_endpoint() {
    for target_name in ["", "   "] {
        let error = open_live_rsd_for_target(target_name, "not a socket endpoint")
            .await
            .unwrap_err();

        assert_eq!(error, MISSING_LIVE_TARGET);
    }
}

#[test]
fn pairing_listener_is_dual_stack_and_reports_a_real_ephemeral_port() {
    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .unwrap();
    runtime.block_on(async {
        let listener = bind_pairing_listener(0).unwrap();
        let address = listener.local_addr().unwrap();
        assert!(address.port() > 0);
        assert!(address.is_ipv6());
    });
}

#[test]
fn tunnel_addresses_reject_unspecified_multicast_and_malformed_values() {
    for address in ["", "::", "0.0.0.0", "ff02::1", "224.0.0.1", "not-an-ip"] {
        assert!(parse_tunnel_ip(address).is_err(), "{address}");
    }
    assert_eq!(
        parse_tunnel_ip("fd00::1").unwrap(),
        "fd00::1".parse::<IpAddr>().unwrap()
    );
}

#[test]
fn rsd_snapshot_requires_and_cross_checks_authoritative_device_identity() {
    let target = PeerRecord {
        device_id: "00008140-test".into(),
        account_identifier: "account".into(),
        peer_identifier: "peer".into(),
        peer_public_key: [1; 32],
        peer_alternate_irk: [2; 16],
        display_name: "Target".into(),
        product_type: "iPhone19,1".into(),
        completion: DhPairingCompletion::Committed,
    };
    let properties = HashMap::from([
        ("OSVersion".into(), plist::Value::String("27.0".into())),
        ("BuildVersion".into(), plist::Value::String("24A123".into())),
        (
            "UniqueDeviceID".into(),
            plist::Value::String(target.device_id.clone()),
        ),
        (
            "ProductType".into(),
            plist::Value::String(target.product_type.clone()),
        ),
    ]);
    let handshake = RsdHandshake {
        services: HashMap::new(),
        protocol_version: 2,
        properties: properties.clone(),
        uuid: "1837DF10-6CE8-4272-BC85-D4B287E4D18F".into(),
    };

    let snapshot = rsd_snapshot(&handshake, &target).unwrap();
    assert_eq!(snapshot.operating_system_version, "27.0");
    assert_eq!(snapshot.build_version, "24A123");
    assert_eq!(snapshot.unique_device_id, target.device_id);
    assert_eq!(snapshot.product_type, target.product_type);

    for key in ["UniqueDeviceID", "ProductType"] {
        let mut missing = properties.clone();
        missing.remove(key);
        let handshake = RsdHandshake {
            services: HashMap::new(),
            protocol_version: 2,
            properties: missing,
            uuid: "1837DF10-6CE8-4272-BC85-D4B287E4D18F".into(),
        };
        assert!(rsd_snapshot(&handshake, &target).is_err(), "{key}");
    }

    for key in ["OSVersion", "BuildVersion"] {
        let mut missing = properties.clone();
        missing.remove(key);
        let handshake = RsdHandshake {
            services: HashMap::new(),
            protocol_version: 2,
            properties: missing,
            uuid: "1837DF10-6CE8-4272-BC85-D4B287E4D18F".into(),
        };
        let snapshot = rsd_snapshot(&handshake, &target).unwrap();
        if key == "OSVersion" {
            assert!(snapshot.operating_system_version.is_empty());
        } else {
            assert!(snapshot.build_version.is_empty());
        }
    }

    for (key, value) in [
        ("UniqueDeviceID", "different-device"),
        ("ProductType", "iPad99,9"),
    ] {
        let mut mismatched = properties.clone();
        mismatched.insert(key.into(), plist::Value::String(value.into()));
        let handshake = RsdHandshake {
            services: HashMap::new(),
            protocol_version: 2,
            properties: mismatched,
            uuid: "1837DF10-6CE8-4272-BC85-D4B287E4D18F".into(),
        };
        assert!(rsd_snapshot(&handshake, &target).is_err(), "{key}");
    }
}

#[test]
fn missing_required_service_after_readiness_is_incompatible() {
    let handshake = RsdHandshake {
        services: HashMap::new(),
        protocol_version: 2,
        properties: HashMap::new(),
        uuid: "1837DF10-6CE8-4272-BC85-D4B287E4D18F".into(),
    };

    let failure = require_prepared_service(&handshake, SCREENSHOT_SERVICE).unwrap_err();

    assert_eq!(failure.code, "developer_image_incompatible");
    assert_eq!(failure.stage, "developer_readiness");
    assert!(!failure.retryable);
}

#[test]
fn advertised_required_service_passes_the_compatibility_gate() {
    let handshake = RsdHandshake {
        services: HashMap::from([(
            SCREENSHOT_SERVICE.into(),
            idevice::rsd::RsdService {
                entitlement: String::new(),
                port: 1,
                uses_remote_xpc: false,
                features: None,
                service_version: None,
            },
        )]),
        protocol_version: 2,
        properties: HashMap::new(),
        uuid: "1837DF10-6CE8-4272-BC85-D4B287E4D18F".into(),
    };

    assert!(require_prepared_service(&handshake, SCREENSHOT_SERVICE).is_ok());
}

#[test]
fn advertised_service_open_failure_is_retryable_connection_failure() {
    let readiness_failure =
        classify_developer_readiness_connection_error(IdeviceError::ServiceNotFound);
    let open_failure = screenshot_service_connection_failed();

    assert_eq!(readiness_failure.code, "developer_image_connection_failed");
    assert_eq!(readiness_failure.stage, "developer_readiness");
    assert!(readiness_failure.retryable);
    assert_eq!(open_failure.code, "screenshot_service_connect_failed");
    assert_eq!(open_failure.stage, "screenshot");
    assert!(open_failure.retryable);
}

#[test]
fn malformed_developer_readiness_metadata_retains_the_failing_probe() {
    let malformed_plist = plist::from_bytes::<plist::Value>(b"not a plist").unwrap_err();
    for (probe, error, expected_code) in [
        (
            DeveloperReadinessProbe::DeveloperModeStatus,
            IdeviceError::UnexpectedResponse("malformed status response".into()),
            "developer_mode_status_unsupported",
        ),
        (
            DeveloperReadinessProbe::PersonalizedImageLookup,
            IdeviceError::UnexpectedResponse(
                "LookupImage returned a malformed ImagePresent value".into(),
            ),
            "developer_image_lookup_presence_malformed",
        ),
        (
            DeveloperReadinessProbe::PersonalizedImageLookup,
            IdeviceError::UnexpectedResponse(
                "LookupImage returned a malformed signature array".into(),
            ),
            "developer_image_lookup_signature_array_malformed",
        ),
        (
            DeveloperReadinessProbe::PersonalizedImageLookup,
            IdeviceError::UnexpectedResponse(
                "LookupImage returned an empty image signature".into(),
            ),
            "developer_image_lookup_signature_empty",
        ),
        (
            DeveloperReadinessProbe::PersonalizedImageLookup,
            IdeviceError::UnexpectedResponse(
                "LookupImage returned an empty signature array".into(),
            ),
            "developer_image_lookup_signature_array_empty",
        ),
        (
            DeveloperReadinessProbe::PersonalizedImageLookup,
            IdeviceError::UnexpectedResponse(
                "LookupImage returned an unsupported image signature type".into(),
            ),
            "developer_image_lookup_signature_type_unsupported",
        ),
        (
            DeveloperReadinessProbe::PersonalizedImageLookup,
            IdeviceError::UnexpectedResponse(
                "LookupImage omitted both absence and signature data".into(),
            ),
            "developer_image_lookup_signature_missing",
        ),
        (
            DeveloperReadinessProbe::PersonalizedImageLookup,
            IdeviceError::Plist(malformed_plist),
            "developer_image_lookup_unsupported",
        ),
    ] {
        let failure = classify_developer_readiness_error(probe, error);
        assert_eq!(failure.code, expected_code);
        assert_eq!(failure.stage, "developer_readiness");
        assert!(!failure.retryable);
    }
}

#[test]
fn every_control_service_is_required_after_developer_readiness() {
    for required in [
        DISPLAY_SERVICE,
        UNIVERSAL_HID_SERVICE,
        INDIGO_HID_SERVICE,
        ORIENTATION_SERVICE,
    ] {
        let handshake = RsdHandshake {
            services: HashMap::new(),
            protocol_version: 2,
            properties: HashMap::new(),
            uuid: "1837DF10-6CE8-4272-BC85-D4B287E4D18F".into(),
        };
        let failure = require_prepared_service(&handshake, required).unwrap_err();
        assert_eq!(failure.code, "developer_image_incompatible", "{required}");
        assert!(!failure.retryable, "{required}");
    }
}

#[test]
fn caller_video_offer_is_embedded_byte_for_byte_and_media_starts_share_identity() {
    let offer = vec![0, 1, 2, 0x80, 0xFF, 0, 7];
    let audio_offer = vec![9, 8, 7];
    let session_id = uuid::Uuid::parse_str("F0C52E3B-10D1-41E4-B9FB-6A53A4FC0784").unwrap();
    let audio = build_start_audio_parameters(
        "fd00::1",
        12_000,
        "fd00::2",
        AUDIO_SENDER_PORT,
        audio_offer,
        CLIENT_SUPPORTED_FEATURES,
        session_id,
    );
    let video = build_start_video_parameters(
        "fd00::1",
        12_001,
        "fd00::2",
        VIDEO_SENDER_PORT,
        offer.clone(),
        CLIENT_SUPPORTED_FEATURES,
        PRIMARY_DISPLAY_ID,
        session_id,
    );

    assert_eq!(video.get("negotiatorOffer"), Some(&XPCObject::Data(offer)));
    for parameters in [&audio, &video] {
        let options = match parameters.get("options") {
            Some(XPCObject::Dictionary(options)) => options,
            other => panic!("missing media options: {other:?}"),
        };
        let session = match options.get("avcMediaStreamOptionClientSessionID") {
            Some(XPCObject::Dictionary(session)) => session,
            other => panic!("missing client session: {other:?}"),
        };
        assert_eq!(session.get("uuid"), Some(&XPCObject::Uuid(session_id)),);
    }
}

#[test]
fn touch_trace_labels_never_contain_coordinates() {
    let command = ControlCommand::Touch(TouchIntent::Tap {
        x: 12_345,
        y: 54_321,
    });

    assert_eq!(input_trace_label(&command).as_deref(), Some("touch_tap"));
}

#[test]
fn negotiation_failures_are_typed_by_ownership_boundary() {
    let target = video_negotiation_rejected();
    assert_eq!(target.code, "video_negotiation_rejected");
    assert_eq!(target.stage, "video_negotiation");
    assert!(!target.retryable);

    let extraction = unsupported_video_answer_extraction();
    assert_eq!(extraction.code, "unsupported_protocol_version");
    assert_eq!(extraction.stage, "video_answer_extraction");
    assert!(!extraction.retryable);

    let answer = unsupported_video_negotiation("video_negotiation", "unsupported");
    assert_eq!(answer.code, "unsupported_protocol_version");
    assert_eq!(answer.stage, "video_negotiation");
    assert!(!answer.retryable);
}

#[test]
fn screen_answer_parser_failures_preserve_the_protocol_stage() {
    use idevice::core_device::ScreenVideoAnswerError;

    let cases = [
        (
            ScreenVideoAnswerError::InvalidEnvelope,
            "video_answer_parse",
        ),
        (
            ScreenVideoAnswerError::VideoGroupMissing,
            "video_stream_group_missing",
        ),
        (
            ScreenVideoAnswerError::HevcPayloadMissing,
            "video_stream_payload_missing",
        ),
        (
            ScreenVideoAnswerError::PayloadTypeMissing,
            "video_stream_payload_missing",
        ),
        (
            ScreenVideoAnswerError::PayloadTypeInvalid,
            "video_stream_payload_invalid",
        ),
        (
            ScreenVideoAnswerError::PayloadEncrypted,
            "video_stream_payload_encrypted",
        ),
        (
            ScreenVideoAnswerError::SsrcMissing,
            "video_stream_ssrc_missing",
        ),
        (ScreenVideoAnswerError::SsrcZero, "video_stream_ssrc_zero"),
        (
            ScreenVideoAnswerError::SsrcInvalid,
            "video_stream_ssrc_invalid",
        ),
        (
            ScreenVideoAnswerError::AmbiguousStream,
            "video_stream_selection_ambiguous",
        ),
    ];

    for (error, expected_stage) in cases {
        assert_eq!(screen_video_answer_failure(error).stage, expected_stage,);
    }
}

#[test]
fn negotiator_answer_extraction_requires_one_bounded_data_value() {
    let answer = vec![1, 2, 3];
    let valid = plist::Value::Dictionary(plist::Dictionary::from_iter([(
        "nested".to_owned(),
        plist::Value::Array(vec![plist::Value::Dictionary(
            plist::Dictionary::from_iter([(
                "negotiatorAnswer".to_owned(),
                plist::Value::Data(answer.clone()),
            )]),
        )]),
    )]));
    assert_eq!(extract_negotiator_answer(&valid).unwrap(), answer);

    for invalid in [
        plist::Value::Dictionary(plist::Dictionary::new()),
        plist::Value::Dictionary(plist::Dictionary::from_iter([(
            "negotiatorAnswer".to_owned(),
            plist::Value::Data(Vec::new()),
        )])),
        plist::Value::Dictionary(plist::Dictionary::from_iter([
            ("negotiatorAnswer".to_owned(), plist::Value::Data(vec![1])),
            (
                "duplicate".to_owned(),
                plist::Value::Dictionary(plist::Dictionary::from_iter([(
                    "negotiatorAnswer".to_owned(),
                    plist::Value::Data(vec![2]),
                )])),
            ),
        ])),
    ] {
        let failure = extract_negotiator_answer(&invalid).unwrap_err();
        assert_eq!(failure.code, "unsupported_protocol_version");
        assert_eq!(failure.stage, "video_answer_extraction");
    }
}

#[test]
fn negotiated_answer_selects_the_authoritative_sender_payload_and_ssrc() {
    let answer = idevice::core_device::build_screen_video_offer(
        "B87A251C-5B5C-46DA-B3B8-B26DB6D39131",
        &CallInfoBlob::default(),
        3,
    )
    .unwrap();

    let negotiated = parse_negotiated_video(&answer).unwrap();

    assert_eq!(negotiated.ssrc, 3);
    assert_eq!(negotiated.payload_type, 100);
}

#[test]
fn userspace_video_offer_and_feedback_remain_one_owned_protocol() {
    let our_ssrc = 0x1020_3040;
    let device_ssrc = 0x5060_7080;
    let call_id = "B87A251C-5B5C-46DA-B3B8-B26DB6D39131";
    let offer = build_userspace_video_offer(call_id, &CallInfoBlob::default(), our_ssrc).unwrap();
    let negotiated_offer = parse_screen_video_answer(&offer).unwrap();
    assert_eq!(negotiated_offer.ssrc, our_ssrc);

    let mut feedback = VideoFeedbackState::new(our_ssrc, device_ssrc, call_id.into());
    let first = VideoDatagramOutcome {
        completed_frame_timestamps: vec![0xA0B0_C0D0],
        emitted_access_unit: true,
        highest_sequence_number: Some(u16::MAX - 1),
        requires_keyframe: false,
        ..Default::default()
    };
    let start = std::time::Instant::now();
    assert_eq!(
        feedback.consume(&first, start),
        vec![build_frame_ack(our_ssrc, 0xA0B0_C0D0)]
    );
    assert_eq!(
        feedback.periodic_report(Duration::from_millis(50)),
        Some(build_rctl(our_ssrc, 50, 1, 0))
    );

    let wrapped = VideoDatagramOutcome {
        highest_sequence_number: Some(0),
        requires_keyframe: true,
        ..Default::default()
    };
    assert_eq!(
        feedback.consume(&wrapped, start),
        vec![build_keyframe_request(
            our_ssrc,
            call_id,
            device_ssrc,
            &[],
            0,
        )]
    );
    assert_eq!(
        feedback.periodic_report(Duration::from_millis(100)),
        Some(build_rctl(our_ssrc, 100, 1, 2))
    );
}

#[test]
fn a_silent_video_socket_stalls_only_after_the_timeout() {
    // The device keeps sending RTCP sender reports while the screen is static,
    // so a silent video socket means the path is gone.
    let start = std::time::Instant::now();
    assert!(!video_stream_stalled(start, start));
    assert!(!video_stream_stalled(
        start,
        start + MEDIA_STALL_TIMEOUT - Duration::from_millis(1)
    ));
    assert!(video_stream_stalled(start, start + MEDIA_STALL_TIMEOUT));
    assert!(
        !video_stream_stalled(start + Duration::from_secs(1), start),
        "a datagram newer than the tick is not a stall"
    );
    let failure = media_stalled();
    assert_eq!(failure.code, "media_stalled");
    assert_eq!(failure.stage, "video_stream");
    assert!(failure.retryable);
}

#[test]
fn keyframe_requests_repeat_until_a_sync_frame_arrives() {
    // After a gap the assembler drops every frame until a sync sample, and the
    // device often ignores a lone request.
    let (our_ssrc, device_ssrc, call_id) = (0x1020_3040, 0x5060_7080, "call");
    let mut feedback = VideoFeedbackState::new(our_ssrc, device_ssrc, call_id.into());
    let start = std::time::Instant::now();
    let gap = VideoDatagramOutcome {
        requires_keyframe: true,
        ..Default::default()
    };
    assert_eq!(
        feedback.consume(&gap, start),
        vec![build_keyframe_request(
            our_ssrc,
            call_id,
            device_ssrc,
            &[],
            0
        )]
    );
    assert_eq!(
        feedback.keyframe_retry(start + Duration::from_secs(2)),
        None
    );
    assert_eq!(
        feedback.keyframe_retry(start + KEYFRAME_RETRY_INTERVAL),
        Some(build_keyframe_request(
            our_ssrc,
            call_id,
            device_ssrc,
            &[],
            1
        )),
        "an ignored keyframe request is repeated"
    );
    let synced = VideoDatagramOutcome {
        emitted_access_unit: true,
        emitted_sync_access_unit: true,
        ..Default::default()
    };
    feedback.consume(&synced, start + KEYFRAME_RETRY_INTERVAL);
    assert_eq!(
        feedback.keyframe_retry(start + Duration::from_secs(60)),
        None,
        "a sync frame ends the retries"
    );
}

#[test]
fn a_sync_sample_after_a_gap_in_the_same_batch_needs_no_keyframe_request() {
    let capture = ProtocolMediaCapture::default();
    let media = test_media_emitter(&capture);
    let control = EventEmitterTestFixture::new();
    let emitter = control.emitter();
    let mut assembler = HevcAccessUnitAssembler::new(TEST_VIDEO_PAYLOAD_TYPE, TEST_VIDEO_SSRC);
    let mut last_configuration_revision = 0;
    let mut geometry = test_geometry();
    prime_test_video_stream(
        &mut assembler,
        &mut last_configuration_revision,
        &mut geometry,
        &media,
        &emitter,
    );

    // Sequence 4 is lost. The assembler holds later packets until its reorder
    // buffer overflows, then drains the gap, the IDR at 5 and the frames after
    // it in one batch: the IDR's configuration needs the orientation, and the
    // IDR already recovered the picture.
    let mut outcome = VideoDatagramOutcome::default();
    let frames = (6u16..=140).map(|sequence| (sequence, test_nal(1, &[0x61])));
    for (sequence, payload) in std::iter::once((5u16, test_nal(19, &[0xF0]))).chain(frames) {
        let next = process_video_datagram_outcome(
            test_rtp_datagram(
                TEST_VIDEO_PAYLOAD_TYPE,
                sequence,
                u32::from(sequence),
                true,
                &payload,
            ),
            VIDEO_SENDER_PORT,
            &mut assembler,
            &mut last_configuration_revision,
            &mut geometry,
            &media,
            &emitter,
        )
        .unwrap();
        outcome.emitted_sync_access_unit |= next.emitted_sync_access_unit;
        outcome.requires_keyframe =
            next.requires_keyframe || (outcome.requires_keyframe && !next.emitted_sync_access_unit);
    }
    assert!(outcome.emitted_sync_access_unit, "the IDR was decoded");
    assert!(
        !outcome.requires_keyframe,
        "the IDR after the gap already recovered the picture"
    );
}

#[test]
fn video_feedback_replies_to_the_port_the_device_sends_from() {
    // The device sends RTP and RTCP from its own port and drops RTCP sent to
    // the senderPort we offered, so keyframe requests and reports must follow
    // the source port of the device's datagrams.
    let mut feedback = VideoFeedbackState::new(0x1020_3040, 0x5060_7080, "call".into());
    assert_eq!(feedback.peer_port(), VIDEO_SENDER_PORT);

    feedback.observe_source_port(61_234);
    assert_eq!(feedback.peer_port(), 61_234);

    feedback.observe_source_port(61_240);
    assert_eq!(feedback.peer_port(), 61_240);
}

#[test]
fn orientation_mapping_fails_closed_for_unknown_values() {
    assert_eq!(
        orientation_value(&Orientation::LandscapeLeft),
        DhOrientation::LandscapeLeft
    );
    assert_eq!(
        effective_orientation(&Orientation::FaceUp, &Orientation::LandscapeRight).unwrap(),
        DhOrientation::LandscapeRight
    );
    assert_eq!(
        effective_orientation(&Orientation::Portrait, &Orientation::LandscapeRight).unwrap(),
        DhOrientation::Portrait
    );
    assert!(
        effective_orientation(
            &Orientation::Unknown("future".into()),
            &Orientation::FaceDown
        )
        .is_err()
    );
    assert_eq!(
        orientation_value(&Orientation::Unknown("future".into())),
        DhOrientation::Unknown
    );
    assert_eq!(orientation_from_raw(u32::MAX), DhOrientation::Unknown);
}

fn live_orientation(
    orientation: Orientation,
    non_flat_orientation: Orientation,
) -> OrientationState {
    OrientationState {
        orientation,
        non_flat_orientation,
        locked: false,
    }
}

#[test]
fn polled_orientation_relabels_same_revision_access_units_without_a_new_configuration() {
    let capture = ProtocolMediaCapture::default();
    let media = test_media_emitter(&capture);
    let control = EventEmitterTestFixture::new();
    let emitter = control.emitter();
    let mut assembler = HevcAccessUnitAssembler::new(TEST_VIDEO_PAYLOAD_TYPE, TEST_VIDEO_SSRC);
    let mut last_configuration_revision = 0;
    let mut geometry = test_geometry();
    geometry.orientation = DhOrientation::LandscapeLeft as u32;
    geometry.non_flat_orientation = DhOrientation::LandscapeLeft as u32;
    prime_test_video_stream(
        &mut assembler,
        &mut last_configuration_revision,
        &mut geometry,
        &media,
        &emitter,
    );
    capture.events.lock().unwrap().clear();
    control.pending_event_count();

    // The iPad was turned; the encoder keeps its parameter sets.
    let portrait = live_orientation(Orientation::Portrait, Orientation::Portrait);
    assert!(refresh_live_orientation(&mut geometry, &portrait, &emitter).unwrap());
    assert_eq!(control.pending_event_count(), 1);

    let sample = test_nal(1, &[0x60]);
    process_video_datagram(
        test_rtp_datagram(TEST_VIDEO_PAYLOAD_TYPE, 4, 4, true, &sample),
        VIDEO_SENDER_PORT,
        &mut assembler,
        &mut last_configuration_revision,
        &mut geometry,
        &media,
        &emitter,
    )
    .unwrap();
    {
        let events = capture.events.lock().unwrap();
        assert_eq!(
            events.iter().map(|(kind, _)| *kind).collect::<Vec<_>>(),
            vec![DhEventKind::VideoAccessUnit]
        );
        let access_unit_geometry = events.last().unwrap().1.unwrap();
        assert_eq!(
            access_unit_geometry.orientation,
            DhOrientation::Portrait as u32
        );
        assert_eq!(
            (
                access_unit_geometry.pixel_width,
                access_unit_geometry.pixel_height
            ),
            (64, 64)
        );
    }
    assert_eq!(last_configuration_revision, 1);

    assert!(!refresh_live_orientation(&mut geometry, &portrait, &emitter).unwrap());
    assert_eq!(control.pending_event_count(), 0);
}

#[test]
fn live_orientation_never_labels_a_portrait_shaped_stream_landscape() {
    let control = EventEmitterTestFixture::new();
    let emitter = control.emitter();
    let portrait_shaped = DhDisplayGeometry {
        pixel_width: 1032,
        pixel_height: 1376,
        ..test_geometry()
    };

    for landscape in [Orientation::LandscapeLeft, Orientation::LandscapeRight] {
        let mut geometry = portrait_shaped;
        let state = live_orientation(landscape.clone(), landscape);
        assert!(!refresh_live_orientation(&mut geometry, &state, &emitter).unwrap());
        assert_eq!(geometry.orientation, DhOrientation::Portrait as u32);
        assert_eq!(
            geometry.non_flat_orientation,
            DhOrientation::Portrait as u32
        );
    }
    assert_eq!(control.pending_event_count(), 0);

    let mut geometry = portrait_shaped;
    let upside_down = live_orientation(
        Orientation::PortraitUpsideDown,
        Orientation::PortraitUpsideDown,
    );
    assert!(refresh_live_orientation(&mut geometry, &upside_down, &emitter).unwrap());
    assert_eq!(
        geometry.orientation,
        DhOrientation::PortraitUpsideDown as u32
    );

    // A landscape-shaped stream shows every label: portrait as a transposed frame.
    let mut geometry = DhDisplayGeometry {
        pixel_width: 1376,
        pixel_height: 1032,
        orientation: DhOrientation::LandscapeLeft as u32,
        non_flat_orientation: DhOrientation::LandscapeLeft as u32,
        ..test_geometry()
    };
    let portrait = live_orientation(Orientation::Portrait, Orientation::Portrait);
    assert!(refresh_live_orientation(&mut geometry, &portrait, &emitter).unwrap());
    assert_eq!(geometry.orientation, DhOrientation::Portrait as u32);
    assert_eq!(control.pending_event_count(), 2);
}

#[test]
fn unusable_live_orientation_is_ignored_and_flat_uses_the_last_upright_side() {
    let control = EventEmitterTestFixture::new();
    let emitter = control.emitter();
    let landscape_shaped = DhDisplayGeometry {
        pixel_width: 1376,
        pixel_height: 1032,
        orientation: DhOrientation::LandscapeLeft as u32,
        non_flat_orientation: DhOrientation::LandscapeLeft as u32,
        ..test_geometry()
    };

    for unusable in [
        live_orientation(Orientation::Unknown("future".into()), Orientation::FaceDown),
        live_orientation(Orientation::FaceUp, Orientation::Unknown("future".into())),
        live_orientation(Orientation::FaceDown, Orientation::FaceUp),
    ] {
        let mut geometry = landscape_shaped;
        assert!(!refresh_live_orientation(&mut geometry, &unusable, &emitter).unwrap());
        assert_eq!(geometry.orientation, DhOrientation::LandscapeLeft as u32);
        assert_eq!(
            geometry.non_flat_orientation,
            DhOrientation::LandscapeLeft as u32
        );
    }
    assert_eq!(control.pending_event_count(), 0);

    let mut geometry = landscape_shaped;
    let flat = live_orientation(Orientation::FaceUp, Orientation::LandscapeRight);
    assert!(refresh_live_orientation(&mut geometry, &flat, &emitter).unwrap());
    assert_eq!(geometry.orientation, DhOrientation::LandscapeRight as u32);
    assert_eq!(control.pending_event_count(), 1);
}

#[test]
fn configuration_time_orientation_still_fails_closed() {
    let mut geometry = test_geometry();
    let unusable = live_orientation(Orientation::Unknown("future".into()), Orientation::FaceDown);
    let failure = update_geometry_orientation(&mut geometry, &unusable).unwrap_err();
    assert_eq!(failure.code, "unsupported_device_orientation");
}

#[tokio::test]
#[ignore = "requires an already-established trusted Xcode tunnel"]
async fn live_ios_rsd_property_contract() {
    let target_name = std::env::var("DEVICE_HUB_TEST_TARGET_NAME")
        .expect("set DEVICE_HUB_TEST_TARGET_NAME to the explicit test device name");
    let endpoint = std::env::var("DEVICE_HUB_RSD_ENDPOINT")
        .expect("set DEVICE_HUB_RSD_ENDPOINT to the trusted tunnel RSD endpoint");
    let handshake = open_live_rsd_for_target(&target_name, &endpoint)
        .await
        .expect("guarded live RSD verification failed");
    let string_property = |key| {
        handshake
            .properties
            .get(key)
            .and_then(plist::Value::as_string)
    };

    println!(
        "OSVersion={:?} ProductVersion_present={} BuildVersion={:?} \
             UniqueDeviceID_present={} ProductType={:?}",
        string_property("OSVersion"),
        handshake.properties.contains_key("ProductVersion"),
        string_property("BuildVersion"),
        string_property("UniqueDeviceID").is_some(),
        string_property("ProductType"),
    );
    assert!(string_property("OSVersion").is_some());
    assert!(!handshake.properties.contains_key("ProductVersion"));
    assert!(string_property("UniqueDeviceID").is_some());
    assert!(string_property("ProductType").is_some());
}
