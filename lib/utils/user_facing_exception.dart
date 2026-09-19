/// An exception whose message is safe to display directly to the user.
///
/// Throw this (instead of a generic [Exception]) whenever the message has
/// already been translated into a user-friendly string. Callers can then
/// distinguish it from unexpected internal errors and show the message
/// verbatim rather than a generic fallback.
class UserFacingException implements Exception {
  const UserFacingException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The server refused a lookup because this free user has used today's
/// quota. [used], [limit], and [dayKey] come from the error details and may
/// be null if the server omitted them.
class DailyLimitReachedException extends UserFacingException {
  DailyLimitReachedException({this.used, this.limit, this.dayKey})
      : super(limit == null
            ? "You've used today's free AI lookups."
            : "You've used all $limit free AI lookups for today.");

  final int? used;
  final int? limit;

  /// Local calendar day (YYYY-MM-DD) the server counted [used] against.
  final String? dayKey;
}
