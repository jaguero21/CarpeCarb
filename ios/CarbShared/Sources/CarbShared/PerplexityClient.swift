import Foundation

/// One food from a carb lookup.
public struct LookupItem: Equatable, Sendable {
    public let name: String
    public let carbs: Double
    public let protein: Double?
    public let fat: Double?
    public let fiber: Double?
    public let calories: Double?
    public let details: String?

    public init(name: String, carbs: Double, protein: Double? = nil, fat: Double? = nil,
                fiber: Double? = nil, calories: Double? = nil, details: String? = nil) {
        self.name = name
        self.carbs = carbs
        self.protein = protein
        self.fat = fat
        self.fiber = fiber
        self.calories = calories
        self.details = details
    }
}

/// Every food the server found for one lookup ("burger and fries" → 2 items).
public struct LookupResult: Equatable, Sendable {
    public let items: [LookupItem]
    public let citations: [String]
    /// Foods the server found but had no reliable carb value for. Siri doesn't
    /// log them and says so; they never become a `LookupItem`, whose carbs are
    /// always a number.
    public let unknownCarbs: [String]

    public init(items: [LookupItem], citations: [String], unknownCarbs: [String] = []) {
        self.items = items
        self.citations = citations
        self.unknownCarbs = unknownCarbs
    }
}

extension LoggedFood {
    /// The buffered form of a looked-up item, keeping its macros.
    public init(item: LookupItem, citations: [String]) {
        self.init(name: item.name, carbs: item.carbs, protein: item.protein, fat: item.fat,
                  fiber: item.fiber, calories: item.calories, details: item.details,
                  citations: citations)
    }
}

/// Serializes the gap between requests.
///
/// The previous version read a static `lastRequestTime`, slept, then wrote it
/// back. Two concurrent lookups could both read the same value, both decide
/// enough time had passed, and both go — so the 1.5s floor the server expects
/// was not actually enforced. An actor makes the check and the write one step.
private actor RequestPacer {
    static let shared = RequestPacer()

    private var lastRequestTime: Date?
    private let minInterval: TimeInterval = 1.5

    func waitForTurn() async {
        if let last = lastRequestTime {
            let elapsed = Date().timeIntervalSince(last)
            if elapsed < minInterval {
                try? await Task.sleep(
                    nanoseconds: UInt64((minInterval - elapsed) * 1_000_000_000))
            }
        }
        lastRequestTime = Date()
    }
}

public struct PerplexityClient {

    // Firebase Cloud Function endpoint
    private static let cloudFunctionURL = "https://us-central1-carpecarb.cloudfunctions.net/getMultipleCarbCounts"

    /// Looks up every food in `foodItem` via the Cloud Function.
    ///
    /// - Parameter idToken: a current Firebase ID token for the signed-in user.
    ///   CarbShared stays free of Firebase, so the caller supplies it.
    public static func lookupCarbs(for foodItem: String, idToken: String) async throws -> LookupResult {
        await RequestPacer.shared.waitForTurn()

        guard let url = URL(string: cloudFunctionURL) else {
            throw IntentError.message("Invalid server address.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(idToken)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30 // Siri users won't wait a minute

        let body: [String: Any] = [
            "data": requestData(
                for: foodItem,
                tzOffsetMinutes: TimeZone.current.secondsFromGMT() / 60
            )
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch is URLError {
            throw IntentError.message("Couldn't reach CarpeCarb. Check your connection and try again.")
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw IntentError.message("Invalid response from server.")
        }

        guard httpResponse.statusCode == 200 else {
            throw IntentError.message(errorMessage(status: httpResponse.statusCode, body: data))
        }

        return try parseResponse(data)
    }

    /// The `data` payload for one lookup. Separate so it can be tested:
    /// `acceptsUnknownCarbs` is what tells the server this build can receive a
    /// food with no carb value, and without it the server drops those foods and
    /// Siri never says it skipped one.
    static func requestData(for foodItem: String, tzOffsetMinutes: Int) -> [String: Any] {
        [
            "input": foodItem,
            // Lets the server count the free quota per local calendar day.
            "tzOffsetMinutes": tzOffsetMinutes,
            "acceptsUnknownCarbs": true,
        ]
    }

    /// Parses a 200 response. Firebase callable functions wrap it in
    /// `{"result": {"items": [...], "citations": [...]}}`.
    static func parseResponse(_ data: Data) throws -> LookupResult {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let result = json["result"] as? [String: Any],
              let rawItems = result["items"] as? [[String: Any]] else {
            throw IntentError.message("Could not parse server response.")
        }

        var items: [LookupItem] = []
        var unknownCarbs: [String] = []
        for raw in rawItems {
            let name = raw["name"] as? String ?? "Unknown"
            // No carb value means the server couldn't find one. Never read as
            // 0: a confident 0 g is worse than no answer for someone dosing
            // insulin, so Siri skips the food and says so.
            guard let carbs = number(raw["carbs"]) else {
                unknownCarbs.append(name)
                continue
            }
            items.append(LookupItem(
                name: name,
                carbs: carbs,
                protein: number(raw["protein"]),
                fat: number(raw["fat"]),
                fiber: number(raw["fiber"]),
                calories: number(raw["calories"]),
                details: raw["details"] as? String
            ))
        }
        // Siri can't hand a food to Manual entry the way the app does, so
        // finding no carb values is the same as finding nothing.
        guard !items.isEmpty else {
            throw IntentError.message("I couldn't find nutrition info for that.")
        }
        return LookupResult(
            items: items,
            citations: result["citations"] as? [String] ?? [],
            unknownCarbs: unknownCarbs
        )
    }

    /// A finite, non-negative number, or nil. Nutrition values can't be
    /// negative, and a NaN or infinity would make `JSONSerialization` in
    /// `CarbDataStore.addFood` raise an Objective-C exception Swift can't catch.
    private static func number(_ value: Any?) -> Double? {
        let parsed = (value as? NSNumber)?.doubleValue ?? (value as? String).flatMap { Double($0) }
        guard let parsed, parsed.isFinite, parsed >= 0 else { return nil }
        return parsed
    }

    /// Maps a non-200 response from the callable function to a message Siri
    /// can speak. Callable errors have the body
    /// `{"error": {"message", "status", "details"}}`.
    static func errorMessage(status: Int, body: Data) -> String {
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let details = (json?["error"] as? [String: Any])?["details"] as? [String: Any]

        if status == 429, details?["reason"] as? String == "daily-quota" {
            let limit = (details?["limit"] as? NSNumber)?.intValue
            let count = limit.map { "\($0) " } ?? ""
            return "You've used today's \(count)free lookups. Open CarpeCarb to go unlimited."
        }
        if status == 429 {
            return "Rate limit exceeded. Try again shortly."
        }
        return "Server error (\(status))."
    }
}
