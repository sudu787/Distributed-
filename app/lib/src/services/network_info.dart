import 'dart:io';

/// Describes how this device is attached to a local network, for the home
/// screen's "connection mode" indicator.
class NetworkSummary {
  final List<String> ipv4;
  final List<String> interfaces;
  const NetworkSummary(this.ipv4, this.interfaces);

  bool get hasLan => ipv4.isNotEmpty;

  /// Android hotspots commonly use 192.168.43.x / 192.168.49.x or a
  /// randomized 10.x / 172.x subnet on `ap0`/`swlan0`/`wlan1`; this is a hint.
  bool get looksLikeHotspotHost =>
      interfaces.any((n) => n.startsWith('ap') || n.startsWith('swlan') || n == 'wlan1');

  String get label {
    if (!hasLan) return 'No local network';
    if (looksLikeHotspotHost) return 'Hotspot · ${ipv4.join(', ')}';
    return 'Wi-Fi/LAN · ${ipv4.join(', ')}';
  }
}

Future<NetworkSummary> readNetworkSummary() async {
  try {
    final list = await NetworkInterface.list(type: InternetAddressType.IPv4);
    final ips = <String>[], names = <String>[];
    for (final ni in list) {
      final addrs = ni.addresses.where((a) => !a.isLoopback).toList();
      if (addrs.isEmpty) continue;
      names.add(ni.name);
      ips.addAll(addrs.map((a) => a.address));
    }
    return NetworkSummary(ips, names);
  } on SocketException {
    return const NetworkSummary([], []);
  }
}
