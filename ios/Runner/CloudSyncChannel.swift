import Flutter
import CarbShared
import os.log

/// Bridges Flutter ↔ CloudSyncStore via a MethodChannel.
/// Provides comprehensive logging for debugging iCloud sync issues.
class CloudSyncChannel {
    static let channelName = "com.carpecarb/cloudsync"

    private let channel: FlutterMethodChannel
    private let logger = Logger(subsystem: "com.carpecarb", category: "CloudSyncChannel")
    
    // Track observation state for logging
    private var isObserving = false

    init(messenger: FlutterBinaryMessenger) {
        channel = FlutterMethodChannel(name: Self.channelName, binaryMessenger: messenger)
        channel.setMethodCallHandler { [weak self] call, result in
            self?.handle(call, result: result)
        }
        logger.info("📱 CloudSyncChannel initialized on channel '\(Self.channelName)'")
    }
    
    deinit {
        if isObserving {
            logger.warning("⚠️ CloudSyncChannel deallocated while still observing")
        }
        logger.debug("🔚 CloudSyncChannel deallocated")
    }

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let method = call.method
        logger.debug("📞 Method call received: '\(method)'")
        
        switch method {
        case "isAvailable":
            handleIsAvailable(result: result)
            
        case "pushToCloud":
            handlePushToCloud(arguments: call.arguments, result: result)
            
        case "pullFromCloud":
            handlePullFromCloud(result: result)
            
        case "startObserving":
            handleStartObserving(result: result)
            
        case "stopObserving":
            handleStopObserving(result: result)
            
        default:
            logger.warning("⚠️ Unknown method called: '\(method)'")
            result(FlutterMethodNotImplemented)
        }
    }
    
    // MARK: - Method Handlers
    
    private func handleIsAvailable(result: @escaping FlutterResult) {
        Task { @MainActor in
            let available = CloudSyncStore.shared.isAvailable
            self.logger.info("✓ isAvailable: \(available ? "YES" : "NO")")
            result(available)
        }
    }
    
    private func handlePushToCloud(arguments: Any?, result: @escaping FlutterResult) {
        guard let data = arguments as? [String: Any] else {
            logger.error("❌ pushToCloud: Invalid arguments type - expected dictionary")
            logger.debug("   Received: \(String(describing: arguments))")
            result(false)
            return
        }
        
        if data.isEmpty {
            logger.warning("⚠️ pushToCloud: Empty data dictionary")
            result(false)
            return
        }
        
        let keyCount = data.count
        let keys = data.keys.joined(separator: ", ")
        logger.info("⬆️  pushToCloud: Pushing \(keyCount) key(s): [\(keys)]")
        
        // Log data sizes for debugging
        for (key, value) in data {
            if let stringValue = value as? String {
                logger.debug("   \(key): String (\(stringValue.count) chars)")
            } else if let arrayValue = value as? [Any] {
                logger.debug("   \(key): Array (\(arrayValue.count) items)")
            } else if let dictValue = value as? [String: Any] {
                logger.debug("   \(key): Dictionary (\(dictValue.count) keys)")
            } else {
                logger.debug("   \(key): \(type(of: value))")
            }
        }
        
        Task { @MainActor in
            CloudSyncStore.shared.pushToCloud(data)
            self.logger.info("✓ pushToCloud: Completed")
            result(true)
        }
    }
    
    private func handlePullFromCloud(result: @escaping FlutterResult) {
        logger.info("⬇️  pullFromCloud: Requesting data from iCloud")
        
        Task { @MainActor in
            let pulled = CloudSyncStore.shared.pullFromCloud()
            
            if let data = pulled {
                let keyCount = data.count
                let keys = data.keys.joined(separator: ", ")
                self.logger.info("✓ pullFromCloud: Retrieved \(keyCount) key(s): [\(keys)]")
                
                // Log timestamp if present
                if let timestamp = data["cloud_last_modified"] as? String {
                    self.logger.debug("   Last modified: \(timestamp)")
                }
                
                result(data)
            } else {
                self.logger.info("ℹ️  pullFromCloud: No data in iCloud (nil returned)")
                result(nil)
            }
        }
    }
    
    private func handleStartObserving(result: @escaping FlutterResult) {
        if isObserving {
            logger.warning("⚠️ startObserving: Already observing - ignoring duplicate call")
            result(true)
            return
        }
        
        logger.info("👀 startObserving: Starting to observe iCloud changes")
        
        // Explicit [self]: the short-lived Task holds the channel strongly; the
        // long-lived observer callback below holds it weakly.
        Task { @MainActor [self] in
            CloudSyncStore.shared.startObserving { [weak self] data in
                guard let self = self else {
                    Logger(subsystem: "com.carpecarb", category: "CloudSyncChannel")
                        .warning("⚠️ Observer callback called but channel was deallocated")
                    return
                }
                
                let keyCount = data.count
                let keys = data.keys.joined(separator: ", ")
                self.logger.info("🔔 Remote change detected: \(keyCount) key(s) changed: [\(keys)]")
                
                DispatchQueue.main.async {
                    self.logger.debug("   Invoking Flutter callback 'onRemoteChange'")
                    
                    self.channel.invokeMethod("onRemoteChange", arguments: data) { error in
                        if let error = error {
                            self.logger.error("❌ Failed to send remote change to Flutter: \(String(describing: error))")
                        } else {
                            self.logger.debug("   ✓ Flutter callback completed successfully")
                        }
                    }
                }
            }
            
            self.isObserving = true
            self.logger.info("✓ startObserving: Now observing")
            result(true)
        }
    }
    
    private func handleStopObserving(result: @escaping FlutterResult) {
        if !isObserving {
            logger.debug("ℹ️  stopObserving: Not currently observing")
            result(true)
            return
        }
        
        logger.info("🛑 stopObserving: Stopping observation")
        
        Task { @MainActor in
            CloudSyncStore.shared.stopObserving()
            
            self.isObserving = false
            self.logger.info("✓ stopObserving: Observation stopped")
            result(true)
        }
    }
}
// MARK: - Logging Guide

/*
 Logging Levels Used:
 
 📱 info    - Channel lifecycle (init, method calls)
 📞 debug   - Method call details
 ✓  info    - Successful operations
 ⬆️  info    - Push operations
 ⬇️  info    - Pull operations
 👀 info    - Observer started
 🔔 info    - Remote changes detected
 🛑 info    - Observer stopped
 ℹ️  info    - Informational (no data, etc.)
 ⚠️  warning - Warnings (duplicate calls, edge cases)
 ❌ error   - Errors and failures
 🔚 debug   - Cleanup and deallocation
 
 View logs in Xcode Console:
 Filter: "CloudSyncChannel" or category:CloudSyncChannel
 
 View logs in Console.app:
 1. Open Console.app
 2. Select your device
 3. Filter: subsystem:com.carpecarb category:CloudSyncChannel
 
 Example log output:
 
 📱 CloudSyncChannel initialized on channel 'com.carpecarb/cloudsync'
 📞 Method call received: 'pushToCloud'
 ⬆️  pushToCloud: Pushing 3 key(s): [food_items, daily_carb_goal, last_save_date]
    food_items: Array (5 items)
    daily_carb_goal: Double
    last_save_date: String (24 chars)
 ✓ pushToCloud: Completed
 */

