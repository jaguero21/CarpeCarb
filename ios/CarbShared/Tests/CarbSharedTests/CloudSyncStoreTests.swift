import Foundation
import Testing
@testable import CarbShared

/// An in-memory stand-in for NSUbiquitousKeyValueStore: the real one needs a
/// signed-in iCloud account, which a test machine doesn't have.
final class FakeKeyValueStore: KeyValueStoring {
    var values: [String: Any] = [:]
    var synchronizeResult = true
    private(set) var synchronizeCount = 0

    func set(_ value: Any?, forKey key: String) { values[key] = value }
    func object(forKey key: String) -> Any? { values[key] }
    func string(forKey key: String) -> String? { values[key] as? String }

    @discardableResult
    func synchronize() -> Bool {
        synchronizeCount += 1
        return synchronizeResult
    }
}

@MainActor
struct CloudSyncStoreTests {
    private let kvStore = FakeKeyValueStore()

    private func store(available: Bool = true) -> CloudSyncStore {
        CloudSyncStore(kvStore: kvStore, isAvailable: { available })
    }

    // MARK: - Push

    @Test func pushWritesEveryKeyAndReportsSuccess() {
        let pushed = store().pushToCloud([
            "food_items": "[]",
            "food_items_deleted": "[\"a\"]",
            "cloud_last_modified": "2026-09-20T12:00:00Z",
        ])

        #expect(pushed)
        #expect(kvStore.values["food_items"] as? String == "[]")
        #expect(kvStore.values["food_items_deleted"] as? String == "[\"a\"]")
        #expect(kvStore.values["cloud_last_modified"] as? String == "2026-09-20T12:00:00Z")
    }

    @Test func pushFailsWhenICloudIsUnavailable() {
        let pushed = store(available: false).pushToCloud(["food_items": "[]"])

        #expect(!pushed)
        #expect(kvStore.values.isEmpty)
        #expect(kvStore.synchronizeCount == 0)
    }

    @Test func pushFailsWhenThereIsNothingToPush() {
        #expect(!store().pushToCloud([:]))
    }

    @Test func pushFailsWhenTheStoreWillNotSynchronize() {
        kvStore.synchronizeResult = false

        #expect(!store().pushToCloud(["food_items": "[]"]))
    }

    // MARK: - Pull

    @Test func pullReturnsTheDeleteAndChangeKeysTheMergeNeeds() {
        kvStore.values = [
            "cloud_last_modified": "2026-09-20T12:00:00Z",
            "food_items": "[]",
            "food_items_deleted": "[\"a\"]",
            "saved_foods_changes": "{\"bagel\":{\"updatedAt\":1,\"deleted\":true}}",
            "settings_updated_at": 1_758_000_000_000,
            "not_a_synced_key": "ignored",
        ]

        let pulled = try? #require(store().pullFromCloud())

        #expect(pulled?["food_items_deleted"] as? String == "[\"a\"]")
        #expect(pulled?["saved_foods_changes"] as? String
            == "{\"bagel\":{\"updatedAt\":1,\"deleted\":true}}")
        #expect(pulled?["settings_updated_at"] as? Int == 1_758_000_000_000)
        #expect(pulled?["not_a_synced_key"] == nil)
    }

    @Test func pullReturnsNothingWhenICloudHasNoDataYet() {
        #expect(store().pullFromCloud() == nil)
    }

    @Test func pullReturnsNothingWhenICloudIsUnavailable() {
        kvStore.values["cloud_last_modified"] = "2026-09-20T12:00:00Z"

        #expect(store(available: false).pullFromCloud() == nil)
    }

    // MARK: - Remote changes

    @Test func aTimestampThisDeviceHasNotSeenIsANewChange() {
        #expect(CloudSyncStore.isNewRemoteChange(
            previous: "2026-09-20T12:00:00Z", pulled: "2026-09-20T12:05:00Z"))
    }

    @Test func thisDevicesOwnPushIsNotANewChange() {
        #expect(!CloudSyncStore.isNewRemoteChange(
            previous: "2026-09-20T12:00:00Z", pulled: "2026-09-20T12:00:00Z"))
    }

    @Test func theFirstChangeSeenCountsAsNew() {
        #expect(CloudSyncStore.isNewRemoteChange(
            previous: nil, pulled: "2026-09-20T12:00:00Z"))
    }

    @Test func aChangeWithNoTimestampIsIgnored() {
        #expect(!CloudSyncStore.isNewRemoteChange(previous: nil, pulled: nil))
        #expect(!CloudSyncStore.isNewRemoteChange(previous: "2026-09-20T12:00:00Z", pulled: ""))
    }

    // MARK: - The notification path

    /// Holds what the store handed back. A class, so the escaping callback
    /// doesn't capture a local variable.
    private final class Delivery {
        var pulled: [String: Any]?
        var count = 0
    }

    /// Posts the notification the way NSUbiquitousKeyValueStore does, then lets
    /// the store's main-actor hop run before the test looks at the result.
    private func postRemoteChange() async {
        NotificationCenter.default.post(
            name: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: kvStore
        )
        for _ in 0..<100 {
            await Task.yield()
        }
    }

    @Test func aChangeFromAnotherDeviceReachesTheApp() async {
        kvStore.values = [
            "cloud_last_modified": "2026-09-20T12:00:00Z",
            "food_items": "[]",
        ]
        let store = self.store()
        let delivery = Delivery()
        store.startObserving { pulled in
            delivery.pulled = pulled
            delivery.count += 1
        }
        defer { store.stopObserving() }

        await postRemoteChange()

        // Comparing the pulled timestamp against one the pull had already
        // overwritten is what stopped this firing at all.
        #expect(delivery.count == 1)
        #expect(delivery.pulled?["cloud_last_modified"] as? String
            == "2026-09-20T12:00:00Z")
    }

    @Test func thisDevicesOwnPushDoesNotComeBackAsARemoteChange() async {
        let store = self.store()
        let delivery = Delivery()
        store.startObserving { _ in delivery.count += 1 }
        defer { store.stopObserving() }

        store.pushToCloud([
            "food_items": "[]",
            "cloud_last_modified": "2026-09-20T12:00:00Z",
        ])
        await postRemoteChange()

        #expect(delivery.count == 0)
    }
}
