@preconcurrency import Flutter
import CarbShared
import os.log

/// Hands Flutter the Siri-logged items waiting in the App Group and empties the
/// buffer in the same step.
///
/// The app used to read the buffer with `home_widget` and clear it in a second
/// call; a Siri log that landed in between was overwritten and lost.
/// Main-actor isolated: Flutter invokes method-channel handlers on the platform
/// thread, and every handler here already hopped to the main actor to touch the
/// store. Saying so once lets the `FlutterResult` callbacks — which are not
/// Sendable — stay on one actor instead of being sent across boundaries.
@MainActor
class SiriBufferChannel {
    static let channelName = "com.carpecarb/siribuffer"

    private let channel: FlutterMethodChannel
    private let logger = Logger(subsystem: "com.carpecarb", category: "SiriBufferChannel")

    init(messenger: FlutterBinaryMessenger) {
        channel = FlutterMethodChannel(name: Self.channelName, binaryMessenger: messenger)
        channel.setMethodCallHandler { [weak self] call, result in
            // Flutter calls this on the platform thread, which is the main
            // thread; asserting that is what lets a nonisolated closure reach
            // main-actor state without sending anything across actors.
            MainActor.assumeIsolated {
                self?.handle(call, result: result)
            }
        }
    }

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "takeLoggedItems":
            Task { @MainActor in
                let items = CarbDataStore.shared.takeSiriLoggedItems()
                self.logger.info("takeLoggedItems: \(items == nil ? "buffer empty" : "handed over and cleared")")
                result(items)
            }
        default:
            result(FlutterMethodNotImplemented)
        }
    }
}
