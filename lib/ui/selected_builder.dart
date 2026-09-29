import 'package:flutter/widgets.dart';

/// Rebuilds only when the selected value changes, not on every source tick.
/// Select immutable values (records are useful for several scalar fields).
class SelectedBuilder<T> extends StatefulWidget {
  const SelectedBuilder({
    super.key,
    required this.listenable,
    required this.select,
    required this.builder,
    this.child,
  });

  final Listenable listenable;
  final T Function() select;
  final Widget Function(BuildContext, T, Widget?) builder;
  final Widget? child;

  @override
  State<SelectedBuilder<T>> createState() => _SelectedBuilderState<T>();
}

class _SelectedBuilderState<T> extends State<SelectedBuilder<T>> {
  late T _value;

  @override
  void initState() {
    super.initState();
    _value = widget.select();
    widget.listenable.addListener(_changed);
  }

  @override
  void didUpdateWidget(covariant SelectedBuilder<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.listenable != widget.listenable) {
      oldWidget.listenable.removeListener(_changed);
      widget.listenable.addListener(_changed);
    }
    _value = widget.select();
  }

  void _changed() {
    final value = widget.select();
    if (value != _value) setState(() => _value = value);
  }

  @override
  Widget build(BuildContext context) =>
      widget.builder(context, _value, widget.child);

  @override
  void dispose() {
    widget.listenable.removeListener(_changed);
    super.dispose();
  }
}
