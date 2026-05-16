import 'package:flutter/foundation.dart' show kIsWeb;

import 'native/utils.dart' if (dart.library.js_interop) 'web/utils.dart';
import 'outgoing_video_filter_ids.dart';

/// High-level API for registering outgoing (pre-encode) video filters on a **local** video track.
///
/// On Web and desktop targets this is a no-op (methods complete without calling native code).
/// On Android and iOS it uses [WebRTC.invokeMethod] with stable method names documented in the
/// fork README.
///
/// Use [MediaStreamTrack.id] from `getUserMedia` as [trackId].
class OutgoingVideoFilterController {
  OutgoingVideoFilterController._();

  static bool get isSupported =>
      !kIsWeb && (WebRTC.platformIsAndroid || WebRTC.platformIsIOS);

  static Future<void> _invoke(String method, Map<String, dynamic> args) async {
    if (!isSupported) {
      return;
    }
    await WebRTC.invokeMethod(method, args);
  }

  /// Registers [OutgoingVideoFilterIds.wholeFrameBlur] on the local video [trackId].
  ///
  /// Optional [config] keys: `radius` or `sigma` (1–32, mapped to box radius), `downscale`
  /// (0.1–1.0, default 0.25). Re-registering the same filter id replaces the previous instance.
  static Future<void> registerBlur(
    String trackId, {
    Map<String, dynamic>? config,
  }) {
    return _invoke('outgoingVideoFiltersRegister', <String, dynamic>{
      'trackId': trackId,
      'filterId': OutgoingVideoFilterIds.wholeFrameBlur,
      if (config != null) 'config': config,
    });
  }

  static Future<void> unregisterBlur(String trackId) {
    return _invoke('outgoingVideoFiltersUnregister', <String, dynamic>{
      'trackId': trackId,
      'filterId': OutgoingVideoFilterIds.wholeFrameBlur,
    });
  }

  static Future<void> setBlurEnabled(String trackId, bool enabled) {
    return _invoke('outgoingVideoFiltersSetEnabled', <String, dynamic>{
      'trackId': trackId,
      'filterId': OutgoingVideoFilterIds.wholeFrameBlur,
      'enabled': enabled,
    });
  }

  static Future<void> updateBlurConfig(
    String trackId,
    Map<String, dynamic> config,
  ) {
    return _invoke('outgoingVideoFiltersUpdateConfig', <String, dynamic>{
      'trackId': trackId,
      'filterId': OutgoingVideoFilterIds.wholeFrameBlur,
      'config': config,
    });
  }

  /// Clears all outgoing filters for [trackId] (same effect as native clear).
  static Future<void> clear(String trackId) {
    return _invoke('outgoingVideoFiltersClear', <String, dynamic>{
      'trackId': trackId,
    });
  }

  /// Alias for [clear] for symmetry with app lifecycle naming.
  static Future<void> disposeForTrack(String trackId) => clear(trackId);
}
