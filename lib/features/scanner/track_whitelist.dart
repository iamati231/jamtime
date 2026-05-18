import 'dart:convert';
import 'package:flutter/services.dart';

class TrackWhitelist {
  static List<String>? _allowedUrls;

  static Future<void> load() async {
    final data = await rootBundle.loadString('assets/allowed_tracks.json');
    final json = jsonDecode(data) as Map<String, dynamic>;
    _allowedUrls = List<String>.from(json['allowed_urls'] as List);
  }

  static bool isAllowed(String url) {
    if (_allowedUrls == null) return false;
    return _allowedUrls!.contains(url);
  }
}
