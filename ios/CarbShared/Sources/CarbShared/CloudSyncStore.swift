import Foundation
import os.log

/// The part of `NSUbiquitousKeyValueStore` that `CloudSyncStore` uses, so tests
/// can run against an in-memory double — the real store needs a signed-in
/// iCloud account and a provisioned entitlement.
public protocol KeyValueStoring: AnyObject {
    func set(_ value: Any?, forKey key: String)
    func object(forKey key: String) -> Any?
    func string(forKey key: String) -> String?
    @discardableResult func synchronize() -> Bool
}

extension NSUbiquitousKeyValueStore: KeyValueStoring {}

/// Syncs app data across devices using NSUbiquitousKeyValueStore (iCloud key-value store).
/// Placed in CarbShared so all targets (app, widget, Siri) can access it.
///
/// Data flows entirely through the MethodChannel: Flutter serializes data on push
/// and writes it back to SharedPreferences on pull. This avoids UserDefaults domain
/// mismatches between the Flutter SharedPreferences store and the App Group store.
///
/// **Thread Safety:** All methods are isolated to `@MainActor`. Call directly from the
/// main thread, or from any async context using `await`.
@MainActor
public final class CloudSyncStore {
    
    // MARK: - Singleton
    
    public static let shared = CloudSyncStore()
    
    // MARK: - Properties

    private let kvStore: any KeyValueStoring
    private let isAvailableCheck: () -> Bool
    private let logger = Logger(subsystem: "com.carpecarb", category: "CloudSyncStore")
    private static let iso8601 = ISO8601DateFormatter()
    
    /// Keys synced to iCloud — must match StorageKeys in Dart
    private enum Key {
        static let foodItems = "food_items"
        static let savedFoods = "saved_foods"
        static let dailyCarbGoal = "daily_carb_goal"
        static let dailyResetHour = "daily_reset_hour"
        static let lastSaveDate = "last_save_date"
        static let lastModified = "cloud_last_modified"
        static let proteinGoal = "protein_goal"
        static let fatGoal = "fat_goal"
        static let fiberGoal = "fiber_goal"
        static let caloriesGoal = "calories_goal"
        static let foodItemsDeleted = "food_items_deleted"
        static let savedFoodsChanges = "saved_foods_changes"
        static let settingsUpdatedAt = "settings_updated_at"
    }

    /// All data keys (excluding the timestamp)
    private static let dataKeys = [
        Key.foodItems, Key.savedFoods, Key.dailyCarbGoal,
        Key.dailyResetHour, Key.lastSaveDate,
        Key.proteinGoal, Key.fatGoal, Key.fiberGoal, Key.caloriesGoal,
        // What was deleted and when things changed — a pull drops any key not
        // listed here, so leaving these out would strip the merge's evidence.
        Key.foodItemsDeleted, Key.savedFoodsChanges, Key.settingsUpdatedAt,
    ]

    /// Callback invoked when remote changes are detected
    /// Thread-safe: stored on MainActor
    private var onChange: (([String: Any]) -> Void)?
    
    /// Track observation state
    /// Thread-safe: stored on MainActor
    private var observing = false
    
    /// Track the last sync timestamp to detect changes
    /// Thread-safe: stored on MainActor
    private var lastKnownTimestamp: String?

    /// - Parameters:
    ///   - kvStore: where synced values are read and written; iCloud's own
    ///     store by default.
    ///   - isAvailable: whether iCloud can be used. The default asks
    ///     `FileManager` for the ubiquity token, which is nil when the user is
    ///     signed out of iCloud.
    public init(
        kvStore: any KeyValueStoring = NSUbiquitousKeyValueStore.default,
        isAvailable: @escaping () -> Bool = {
            FileManager.default.ubiquityIdentityToken != nil
        }
    ) {
        self.kvStore = kvStore
        self.isAvailableCheck = isAvailable
        logger.info("CloudSyncStore initialized")
    }
    
    deinit {
        if observing {
            // Note: deinit is not async, so we do synchronous cleanup.
            // `object: nil` rather than `kvStore`: a nonisolated deinit may not
            // touch a non-Sendable stored property, and since this instance
            // registered exactly one observer for this notification, removing
            // it by observer and name alone removes the same registration.
            NotificationCenter.default.removeObserver(
                self,
                name: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
                object: nil
            )
            logger.info("CloudSyncStore deallocated - cleaned up observers")
        }
    }

    // MARK: - Availability

    /// Checks if iCloud is available for this user
    /// Thread-safe: FileManager is thread-safe for this property
    public var isAvailable: Bool {
        let available = isAvailableCheck()
        logger.debug("iCloud availability checked: \(available)")
        return available
    }

    // MARK: - Push (Flutter → iCloud)

    /// Writes the data dict received from Flutter directly into iCloud KV store.
    /// Flutter is responsible for providing all syncable keys.
    ///
    /// - Parameter data: Dictionary of key-value pairs to sync
    /// - Returns: false when iCloud is unavailable, there was nothing to push,
    ///   or the store refused to synchronize. The app shows a failed sync and
    ///   retries on the next change, so this must not report success blindly.
    /// - Note: Thread-safe. Can be called from any thread.
    @discardableResult
    public func pushToCloud(_ data: [String: Any]) -> Bool {
        guard isAvailable else {
            logger.warning("Push aborted: iCloud not available")
            return false
        }
        
        guard !data.isEmpty else {
            logger.warning("Push aborted: Empty data provided")
            return false
        }

        // Use the caller's timestamp when it sent one (so Flutter can track
        // what it pushed), otherwise stamp it now.
        var timestamp = Self.iso8601.string(from: Date())
        if let supplied = data[Key.lastModified] as? String, !supplied.isEmpty {
            timestamp = supplied
        }

        logger.info("Pushing \(data.count) keys to iCloud")

        // Write to NSUbiquitousKeyValueStore
        // Note: NSUbiquitousKeyValueStore is thread-safe
        for (key, value) in data {
            kvStore.set(value, forKey: key)
            logger.debug("Set key '\(key)'")
        }

        kvStore.set(timestamp, forKey: Key.lastModified)
        lastKnownTimestamp = timestamp
        
        // Note: synchronize() is deprecated but still used for forcing sync
        // The system will sync automatically, but this is best-effort
        let synced = kvStore.synchronize()
        
        if synced {
            logger.info("Successfully pushed to iCloud (timestamp: \(timestamp))")
        } else {
            logger.warning("Push completed but synchronize() returned false")
        }
        return synced
    }

    // MARK: - Pull (iCloud → Flutter)

    /// Reads all data from iCloud KV store and returns it so Flutter can write
    /// it to SharedPreferences. Returns nil if iCloud is unavailable or empty.
    ///
    /// - Returns: Dictionary of synced data, or nil if unavailable/empty
    /// - Note: Thread-safe. Can be called from any thread.
    @discardableResult
    public func pullFromCloud() -> [String: Any]? {
        guard isAvailable else {
            logger.debug("Pull aborted: iCloud not available")
            return nil
        }

        // Best-effort sync from iCloud
        kvStore.synchronize()

        guard let timestamp = kvStore.string(forKey: Key.lastModified),
              !timestamp.isEmpty else {
            logger.info("Pull returned nil: No data in iCloud yet")
            return nil
        }

        var pulled: [String: Any] = [Key.lastModified: timestamp]

        for key in Self.dataKeys {
            if let value = kvStore.object(forKey: key) {
                pulled[key] = value
            }
        }
        
        lastKnownTimestamp = timestamp
        logger.info("Successfully pulled \(pulled.count) keys from iCloud (timestamp: \(timestamp))")

        return pulled
    }

    // MARK: - Observe Remote Changes
    
    /// Start listening for data pushed from other devices.
    ///
    /// - Parameter onChange: Callback invoked when remote changes are detected.
    ///   Called on the main thread.
    /// - Note: Thread-safe. Can be called from any thread.
    public func startObserving(onChange: @escaping ([String: Any]) -> Void) {
        // Check if already observing
        if observing {
            logger.warning("startObserving called but already observing - updating callback")
            self.onChange = onChange
            return
        }
        
        guard isAvailable else {
            logger.warning("Cannot start observing: iCloud not available")
            return
        }
        
        self.onChange = onChange
        observing = true

        // Add observer for external changes
        // NotificationCenter is thread-safe
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(kvStoreDidChange(_:)),
            name: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: kvStore
        )
        
        logger.info("Started observing iCloud changes")
        
        // Initial sync
        kvStore.synchronize()
    }

    /// Stop listening for remote changes.
    /// - Note: Thread-safe. Safe to call multiple times.
    public func stopObserving() {
        guard observing else {
            logger.debug("stopObserving called but not currently observing")
            return
        }
        
        NotificationCenter.default.removeObserver(
            self,
            name: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: kvStore
        )
        
        observing = false
        onChange = nil
        
        logger.info("Stopped observing iCloud changes")
    }

    // MARK: - Notification Handlers
    
    /// Called when NSUbiquitousKeyValueStore detects external changes
    /// - Note: This is called on a background thread by NotificationCenter
    @objc private func kvStoreDidChange(_ notification: Notification) {
        logger.debug("Received external change notification")
        
        // Verify the notification is from our store
        guard let store = notification.object as AnyObject?,
              store === (kvStore as AnyObject) else {
            logger.warning("Notification from unexpected store - ignoring")
            return
        }
        
        // Get the change reason
        if let changeReason = notification.userInfo?[NSUbiquitousKeyValueStoreChangeReasonKey] as? Int {
            logChangeReason(changeReason)
        }
        
        // Get changed keys if available
        if let changedKeys = notification.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String] {
            logger.debug("Changed keys: \(changedKeys.joined(separator: ", "))")
        }
        
        // Pull the latest data
        // MainActor isolated method called from background thread needs await
        Task { @MainActor in
            // Capture the timestamp before pulling: `pullFromCloud` overwrites
            // `lastKnownTimestamp`, so comparing after it always found them
            // equal — which is why remote changes never reached the app.
            let previous = self.lastKnownTimestamp
            if let pulled = self.pullFromCloud() {
                if Self.isNewRemoteChange(
                    previous: previous,
                    pulled: pulled[Key.lastModified] as? String
                ) {
                    self.logger.info("Notifying of remote change")
                    self.onChange?(pulled)
                } else {
                    self.logger.debug("Skipping notification - timestamp unchanged")
                }
            }
        }
    }

    /// Whether a pulled timestamp is a change this device hasn't seen yet.
    /// Pure, so the comparison can be tested without an iCloud account.
    public static func isNewRemoteChange(previous: String?, pulled: String?) -> Bool {
        guard let pulled, !pulled.isEmpty else { return false }
        return pulled != previous
    }
    
    // MARK: - Helpers
    
    /// Logs the change reason from the notification
    private func logChangeReason(_ reason: Int) {
        switch reason {
        case NSUbiquitousKeyValueStoreServerChange:
            logger.debug("Change reason: Server change")
        case NSUbiquitousKeyValueStoreInitialSyncChange:
            logger.debug("Change reason: Initial sync")
        case NSUbiquitousKeyValueStoreQuotaViolationChange:
            logger.error("Change reason: Quota violation!")
        case NSUbiquitousKeyValueStoreAccountChange:
            logger.info("Change reason: Account change")
        default:
            logger.debug("Change reason: Unknown (\(reason))")
        }
    }
}
// MARK: - Thread Safety Documentation

/*
 Thread Safety Implementation:
 
 1. @MainActor Isolation:
    - All public methods and properties are isolated to the MainActor
    - This ensures all state mutations happen on the main thread
    - Prevents data races on onChange, observing, and lastKnownTimestamp
 
 2. NSUbiquitousKeyValueStore Safety:
    - NSUbiquitousKeyValueStore is thread-safe by design
    - Can be accessed from any thread safely
 
 3. NotificationCenter Safety:
    - NotificationCenter is thread-safe
    - Notifications may be delivered on background threads
    - We use Task { @MainActor } to safely access isolated state
 
 4. Observer Pattern:
    - kvStoreDidChange may be called on a background thread
    - Uses Task { @MainActor } to hop to main thread for state access
    - onChange callback is invoked on main thread via MainActor
 
 Usage from any thread:
 
 ```swift
 // Safe to call from background thread
 Task {
     await CloudSyncStore.shared.pushToCloud(data)
 }
 
 // Safe to call from main thread
 await CloudSyncStore.shared.pushToCloud(data)
 ```
 
 Alternative: If @MainActor causes issues with existing code,
 see CloudSyncStore+SerialQueue.swift for a serial queue implementation.
 */

