import 'package:flutter/foundation.dart';

/// What the library views show changed by itself while they're open - Komga back after it couldn't be reached
/// (lib/offline/connection.dart): the view on top loads again at once, the others as they come back on top, as they do
/// anyway (lib/widgets/refresh_on_return.dart). Counts up once per change.
final contentChanged = ValueNotifier<int>(0);
