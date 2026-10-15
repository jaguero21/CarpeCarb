import 'package:flutter/material.dart';

/// Fades and grows its child in once, when first built with [animate] true.
/// Rows that were already there when the screen loaded are built with
/// [animate] false and just appear.
class AppearOnce extends StatefulWidget {
  const AppearOnce({super.key, required this.animate, required this.child});

  final bool animate;
  final Widget child;

  @override
  State<AppearOnce> createState() => _AppearOnceState();
}

class _AppearOnceState extends State<AppearOnce>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 400),
    value: widget.animate ? 0 : 1,
  );

  late final CurvedAnimation _curve =
      CurvedAnimation(parent: _controller, curve: Curves.easeOut);

  @override
  void initState() {
    super.initState();
    if (widget.animate) _controller.forward();
  }

  @override
  void dispose() {
    _curve.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizeTransition(
      sizeFactor: _curve,
      child: FadeTransition(opacity: _curve, child: widget.child),
    );
  }
}
