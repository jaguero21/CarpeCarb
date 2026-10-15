/// The status line under the Add Food button while a lookup runs. The app
/// sends one request and gets one answer, so it can't see the server's steps;
/// these messages only ever describe the wait, never a step.
String lookupProgressMessage(Duration elapsed) {
  if (elapsed < const Duration(seconds: 5)) return 'Checking nutrition sources…';
  if (elapsed < const Duration(seconds: 12)) {
    return 'Still checking — some foods take longer';
  }
  if (elapsed < const Duration(seconds: 20)) return 'Still working on it…';
  return 'Taking longer than usual…';
}
