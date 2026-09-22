import Flutter
import CarbShared
import os.log

/// Hands Flutter the Siri-logged items waiting in the App Group and empties the
/// buffer in the same step.
///
/// The app used to read the buffer with `home_widget` and clear it in a second
/// call; a Siri log that landed in between was overwritten and lost.
class SiriBufferChannel {
    static let channelName = "com.carpecarb/siribuffer"

    private let channel: FlutterMethodChannel
    private let logger = Logger(subsystem: "com.carpecarb", category: "SiriBufferChannel")

    init(messenger: FlutterBinaryMessenger) {
        channel = FlutterMethodChannel(name: Self.channelName, binaryMessenger: messenger)
        channel.setMethodCallHandler { [weak self] call, result in
            self?.handle(call, result: result)
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
