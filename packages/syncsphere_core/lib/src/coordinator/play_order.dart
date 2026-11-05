/// The room's play order: the playlist order, or a shuffle order that
/// visits every track once per cycle and survives playlist edits. Split out
/// of `RoomCoordinator`, which owns the playlist and the shuffle switch.
library;

import 'dart:math';

import '../model/room_state.dart';

class PlayOrder {
  final Random _random;
  List<String> _shuffled = const [];

  PlayOrder(this._random);

  /// Play order of [playlist]: as listed, or the shuffle order.
  List<String> order(List<TrackInfo> playlist, {required bool shuffle}) {
    final ids = [for (final t in playlist) t.id];
    if (!shuffle) return ids;
    final present = ids.toSet();
    final order = [for (final id in _shuffled) if (present.contains(id)) id];
    final missing = ids.where((id) => !order.contains(id)).toList()..shuffle(_random);
    order.addAll(missing);
    _shuffled = order;
    return order;
  }

  /// Draws a new shuffle order, starting with [keepFirst] if given.
  void reshuffle(List<TrackInfo> playlist, {String? keepFirst}) {
    final ids = [for (final t in playlist) t.id]..shuffle(_random);
    if (keepFirst != null && ids.remove(keepFirst)) ids.insert(0, keepFirst);
    _shuffled = ids;
  }

  /// Track [delta] steps from [current] in play order (null at the ends
  /// unless [wrap]). With no current track, the first track.
  String? neighbor(List<TrackInfo> playlist, String? current, int delta,
      {required bool shuffle, required bool wrap}) {
    final order = this.order(playlist, shuffle: shuffle);
    if (order.isEmpty) return null;
    final i = current == null ? -1 : order.indexOf(current);
    if (i < 0) return delta > 0 ? order.first : null;
    var j = i + delta;
    if (j < 0 || j >= order.length) {
      if (!wrap) return null;
      j = j % order.length;
      if (j < 0) j += order.length;
    }
    return order[j];
  }
}
