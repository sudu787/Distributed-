import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:syncsphere_core/syncsphere_core.dart';

import 'state/room_controller.dart';
import 'ui/home_screen.dart';
import 'ui/room_screen.dart';
import 'ui/share_receiver.dart';
import 'ui/widgets.dart';

class SyncSphereApp extends StatelessWidget {
  const SyncSphereApp({super.key});

  @override
  Widget build(BuildContext context) {
    const seed = Color(0xFF3D5AFE);
    return MaterialApp(
      title: 'SyncSphere',
      debugShowCheckedModeBanner: false,
      theme: _theme(ColorScheme.fromSeed(seedColor: seed)),
      darkTheme: _theme(ColorScheme.fromSeed(seedColor: seed, brightness: Brightness.dark)),
      home: const _Root(),
      // Deep links (`syncsphere://app/join?...`, e.g. from a QR code scanned
      // with the camera app) arrive as the route `/join?...`.
      onGenerateRoute: (settings) {
        final link = JoinLink.tryParse(settings.name ?? '');
        if (link == null) return null;
        return PageRouteBuilder<void>(
          settings: settings,
          opaque: false,
          pageBuilder: (context, animation, secondary) => _JoinFromLink(link),
        );
      },
      onUnknownRoute: (settings) => PageRouteBuilder<void>(
        settings: settings,
        opaque: false,
        pageBuilder: (context, animation, secondary) => const _PopImmediately(),
      ),
    );
  }
}

/// One look for light and dark: rounded cards and sheets, floating
/// snackbars, a calmer tab bar.
ThemeData _theme(ColorScheme cs) => ThemeData(
      colorScheme: cs,
      useMaterial3: true,
      cardTheme: CardThemeData(
        elevation: 0,
        color: cs.surfaceContainerLow,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        showDragHandle: true,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      ),
      dialogTheme: DialogThemeData(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24))),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      navigationBarTheme: NavigationBarThemeData(
        height: 68,
        backgroundColor: cs.surfaceContainer,
        indicatorColor: cs.secondaryContainer,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      ),
      listTileTheme: const ListTileThemeData(contentPadding: EdgeInsets.symmetric(horizontal: 16)),
      chipTheme: ChipThemeData(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
      sliderTheme: const SliderThemeData(showValueIndicator: ShowValueIndicator.never),
      appBarTheme: AppBarTheme(backgroundColor: cs.surface, scrolledUnderElevation: 2, centerTitle: false),
    );

/// Joins the room in a deep link (unless already in one) and returns to
/// the root screen, which then shows the room.
class _JoinFromLink extends ConsumerStatefulWidget {
  final JoinLink link;
  const _JoinFromLink(this.link);

  @override
  ConsumerState<_JoinFromLink> createState() => _JoinFromLinkState();
}

class _JoinFromLinkState extends ConsumerState<_JoinFromLink> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final ctl = ref.read(roomControllerProvider.notifier);
      final status = ref.read(roomControllerProvider).status;
      final nav = Navigator.of(context);
      if (status != RoomStatus.none) {
        showMessage(context, 'Leave the current room before joining another.', error: true);
      }
      nav.popUntil((r) => r.isFirst);
      if (status == RoomStatus.none) await ctl.joinWithLink(widget.link);
    });
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

class _PopImmediately extends StatelessWidget {
  const _PopImmediately();

  @override
  Widget build(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (context.mounted) Navigator.of(context).popUntil((r) => r.isFirst);
    });
    return const SizedBox.shrink();
  }
}

/// Shows the home screen outside a room and the room screen inside one.
class _Root extends ConsumerWidget {
  const _Root();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(roomControllerProvider.select((s) => s.status));
    final inRoom = status == RoomStatus.active || status == RoomStatus.leaving;
    return ShareReceiver(
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 250),
        child: inRoom ? const RoomScreen(key: ValueKey('room')) : const HomeScreen(key: ValueKey('home')),
      ),
    );
  }
}
