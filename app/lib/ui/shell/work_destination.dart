import 'package:flutter/widgets.dart';

/// Lets notification/deep-link entry points reveal the preserved work tab,
/// even when the selected session has not changed.
class WorkDestination extends InheritedWidget {
  const WorkDestination({super.key, required this.reveal, required super.child});
  final VoidCallback reveal;

  static void open(BuildContext context) {
    context.getInheritedWidgetOfExactType<WorkDestination>()?.reveal();
  }

  @override
  bool updateShouldNotify(WorkDestination oldWidget) => false;
}
