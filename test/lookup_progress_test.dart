import 'package:carb_tracker/utils/lookup_progress.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  String at(int seconds) => lookupProgressMessage(Duration(seconds: seconds));

  test('the message changes at 5, 12 and 20 seconds', () {
    expect(at(0), 'Checking nutrition sources…');
    expect(at(4), 'Checking nutrition sources…');
    expect(at(5), 'Still checking — some foods need a second source');
    expect(at(11), 'Still checking — some foods need a second source');
    expect(at(12), 'Almost there…');
    expect(at(19), 'Almost there…');
    expect(at(20), 'Taking longer than usual…');
    expect(at(90), 'Taking longer than usual…');
  });
}
