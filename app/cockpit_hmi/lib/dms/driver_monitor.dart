// 原生（Android）駕駛監測：前鏡頭 → mediapipe_face_mesh → DriverStateTracker。
//
// 影像只在記憶體裡處理：每一幀送進推論管線後就丟掉，不存檔、不上傳、不顯示。
// 本檔使用 dart:ffi，網頁版請改用 dms_monitor_stub.dart（條件匯入）。
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:flutter/widgets.dart';
import 'package:mediapipe_face_mesh/mediapipe_face_mesh.dart';

import 'camera_frame_source.dart';
import 'dms_monitor_state.dart';
import 'driver_state.dart';
import 'frame_source.dart';

export 'dms_monitor_state.dart';

/// 開前鏡頭做駕駛監測。用 [start]／[stop] 控制；被拒絕權限時 [status] 會是
/// [DmsStatus.permissionDenied]，其他功能照常。
class DriverMonitor extends DriverMonitorState with WidgetsBindingObserver {
  DriverMonitor({DriverStateTracker? tracker})
    : _tracker = tracker ?? DriverStateTracker() {
    WidgetsBinding.instance.addObserver(this);
    if (supported) setStatus(DmsStatus.off);
  }

  /// 只有 Android 原生支援。
  static bool get supported => Platform.isAndroid;

  static const FaceMeshDelegate _delegate = FaceMeshDelegate.xnnpack;

  final DriverStateTracker _tracker;
  CameraFrameSource? _source;
  FaceDetectorProcessor? _detector;
  FaceMeshProcessor? _mesh;
  FaceBlendshapesProcessor? _blendshapes;
  FaceMeshInferencePipeline? _pipeline;
  FaceMeshInferenceStreamProcessor? _streamProcessor;
  StreamController<FaceMeshFrame>? _frames;
  StreamSubscription<FaceMeshInferenceResult>? _results;
  int? _streamRotation;
  bool _busy = false;
  bool _wanted = false;
  bool _paused = false;
  bool _disposed = false;
  int _generation = 0;
  int _fpsCount = 0;
  DateTime _fpsSince = DateTime.now();

  /// 要求開始監測。可重複呼叫。
  Future<void> start() async {
    _wanted = true;
    if (!supported || _paused || _source != null || _disposed) return;
    final generation = ++_generation;
    setStatus(DmsStatus.starting);
    try {
      final cameras = await availableCameras();
      if (!_stillWanted(generation)) return;
      final source = CameraFrameSource(cameras);
      _source = source;
      await _createProcessors();
      if (!_stillWanted(generation)) {
        await _release();
        return;
      }
      source.onFrame = _onFrame;
      final started = await source.start();
      if (!_stillWanted(generation)) {
        await _release();
        return;
      }
      if (!started) {
        final message = source.lastError ?? '無法開啟鏡頭';
        await _release();
        final denied = message.contains('CameraAccessDenied');
        setStatus(
          denied ? DmsStatus.permissionDenied : DmsStatus.failed,
          error: message,
        );
        return;
      }
      _fpsCount = 0;
      _fpsSince = DateTime.now();
      setStatus(DmsStatus.running);
    } catch (error) {
      await _release();
      if (!_disposed) setStatus(DmsStatus.failed, error: '$error');
    }
  }

  /// 停止監測並放掉鏡頭。
  Future<void> stop() async {
    _wanted = false;
    ++_generation;
    await _release();
    if (!_disposed) setStatus(DmsStatus.off);
  }

  bool _stillWanted(int generation) =>
      !_disposed && _wanted && !_paused && generation == _generation;

  Future<void> _createProcessors() async {
    _detector = await FaceDetectorProcessor.create(
      model: FaceDetectionModel.shortRange,
      delegate: _delegate,
      maxResults: 1,
      roiScaleY: 1.7,
      roiShiftY: -0.2,
    );
    _mesh = await FaceMeshProcessor.create(
      model: FaceMeshModel.v2,
      enableIris: true,
      delegate: _delegate,
    );
    _blendshapes = await FaceBlendshapesProcessor.create(delegate: _delegate);
    _pipeline = FaceMeshInferencePipeline(
      detector: _detector!,
      mesh: _mesh!,
      landmarkSmoothing: const LandmarkSmoothingOptions(),
    );
    _streamProcessor = FaceMeshInferenceStreamProcessor(_pipeline!);
  }

  void _onFrame(DemoFrame frame) {
    if (_busy) return;
    final rotation = _source?.rotationCompensationDegrees;
    final input = frame.nv21 ?? frame.image;
    if (rotation == null || input == null) return;
    _ensureStream(rotation);
    final controller = _frames;
    if (controller == null || controller.isClosed) return;
    _busy = true;
    controller.add(input);
  }

  void _ensureStream(int rotation) {
    if (_results != null && _streamRotation == rotation) return;
    _closeStream();
    _pipeline?.resetTracking();
    _streamRotation = rotation;
    final controller = StreamController<FaceMeshFrame>();
    _frames = controller;
    _results = _streamProcessor!
        .process(
          controller.stream,
          runMeshResolver: (_) => true,
          rotationDegrees: rotation,
          mirrorHorizontal: false,
        )
        .listen(_onResult, onError: _onInferenceError);
  }

  void _closeStream() {
    unawaited(_results?.cancel());
    _results = null;
    unawaited(_frames?.close());
    _frames = null;
    _streamRotation = null;
    _busy = false;
  }

  void _onResult(FaceMeshInferenceResult result) {
    _busy = false;
    if (_disposed || !_wanted) return;
    _tickFps();
    final mesh = result.meshResult;
    final blendshapes = mesh == null ? null : _blendshapes?.process(mesh);
    if (mesh == null || blendshapes == null) {
      _tracker.onFaceLost();
      applyNoFace();
      return;
    }
    final closure = math.max(
      blendshapes[FaceBlendshape.eyeBlinkLeft],
      blendshapes[FaceBlendshape.eyeBlinkRight],
    );
    double yaw = 0, pitch = 0, roll = 0;
    try {
      final pose = mesh.estimateGeometry().headPose;
      yaw = pose.yawDegrees;
      pitch = pose.pitchDegrees;
      roll = pose.rollDegrees;
    } on Object {
      // 姿態算不出來就當作面向前方，閉眼判讀照常。
    }
    applyDriverState(
      _tracker.update(
        eyeClosure: closure,
        yawDegrees: yaw,
        pitchDegrees: pitch,
        rollDegrees: roll,
      ),
    );
  }

  void _onInferenceError(Object error) {
    _busy = false;
    if (_disposed) return;
    _tracker.onFaceLost();
    applyNoFace();
  }

  void _tickFps() {
    _fpsCount++;
    final now = DateTime.now();
    final elapsed = now.difference(_fpsSince).inMilliseconds;
    if (elapsed >= 1000) {
      applyFps(_fpsCount * 1000 / elapsed);
      _fpsCount = 0;
      _fpsSince = now;
    }
  }

  Future<void> _release() async {
    _closeStream();
    final source = _source;
    _source = null;
    if (source != null) {
      source.onFrame = null;
      try {
        await source.stop();
      } catch (_) {}
      source.dispose();
    }
    _detector?.close();
    _mesh?.close();
    _blendshapes?.close();
    _detector = null;
    _mesh = null;
    _blendshapes = null;
    _pipeline = null;
    _streamProcessor = null;
    _tracker.reset();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!supported) return;
    if (state == AppLifecycleState.resumed) {
      if (_paused) {
        _paused = false;
        if (_wanted) unawaited(start());
      }
    } else if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      if (!_paused && _source != null) {
        _paused = true;
        ++_generation;
        unawaited(
          _release().then((_) {
            if (!_disposed) setStatus(DmsStatus.off);
          }),
        );
      } else if (_wanted) {
        _paused = true;
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _wanted = false;
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_release());
    super.dispose();
  }
}
