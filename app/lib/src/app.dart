import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'state/room_controller.dart';
import 'ui/home_screen.dart';
import 'ui/room_screen.dart';

class SyncSphereApp extends StatelessWidget {
  const SyncSphereApp({super.key});

  @override
  Widget build(BuildContext context) {
    const seed = Color(0xFF3D5AFE);
    return MaterialApp(
      title: 'SyncSphere',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: seed), useMaterial3: true),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: seed, brightness: Brightness.dark),
        useMaterial3: true,
      ),
      home: const _Root(),
    );
  }
}

/// Shows the home screen outside a room and the room screen inside one.
class _Root extends ConsumerWidget {
  const _Root();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(roomControllerProvider.select((s) => s.status));
    final inRoom = status == RoomStatus.active || status == RoomStatus.leaving;
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 250),
      child: inRoom ? const RoomScreen(key: ValueKey('room')) : const HomeScreen(key: ValueKey('home')),
    );
  }
}
