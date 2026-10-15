import 'package:flutter/widgets.dart';

/// Whether an action snackbar should stay until dismissed. Under VoiceOver
/// (accessible navigation) it stays, so its Undo can still be reached; for
/// everyone else it times out after its duration, as snackbars used to.
/// (This Flutter version makes every snackbar with an action persist.)
bool snackBarPersists(BuildContext context) =>
    MediaQuery.accessibleNavigationOf(context);
