import DeviceHubTransport
import Testing

@Suite("Native video trace")
struct NativeVideoTraceTests {
    @Test("terminal video reasons have distinct payload-free names")
    func terminalRejectionTraceReasons() {
        let failure = NativeSessionFailure(
            code: "video_receiver_rejected",
            stage: "video_start_receiver",
            retryable: true
        )
        let cases: [(NativeVideoStreamTermination, String)] = [
            (.cancelled, "cancelled"),
            (.finished, "finished"),
            (.failed(.bufferSaturated), "bufferSaturated"),
            (.failed(.invalidAccessUnit), "invalidAccessUnit"),
            (.failed(.invalidConfiguration), "invalidConfiguration"),
            (.failed(.invalidSequence), "invalidSequence"),
            (.failed(.missingConfiguration), "missingConfiguration"),
            (.failed(.multipleConsumers), "multipleConsumers"),
            (.failed(.native(failure)), "native")
        ]

        for (termination, expected) in cases {
            #expect(termination.description == "<redacted-native-video-termination \(expected)>")
        }
    }
}
