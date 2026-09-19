/// The caller's AI-lookup quota as reported by the getMultipleCarbCounts
/// Cloud Function. The server is the authority; the app caches this for
/// display and as a fast pre-check.
class ServerQuota {
  const ServerQuota({required this.premium, this.used, this.limit, this.dayKey});

  final bool premium;

  /// Lookups used today. Null for premium users.
  final int? used;

  /// Free lookups per day. Null for premium users.
  final int? limit;

  /// Local calendar day (YYYY-MM-DD) the server counted `used` against. Null for
  /// premium users or older servers.
  final String? dayKey;

  /// Parses the `quota` object from a lookup response, or returns null if it
  /// is missing or malformed (e.g. an older function deployment).
  static ServerQuota? fromJson(Object? json) {
    if (json is! Map) return null;
    final premium = json['premium'];
    if (premium is! bool) return null;
    final used = json['used'];
    final limit = json['limit'];
    final dayKey = json['dayKey'];
    return ServerQuota(
      premium: premium,
      used: used is int ? used : null,
      limit: limit is int ? limit : null,
      dayKey: dayKey is String ? dayKey : null,
    );
  }
}
