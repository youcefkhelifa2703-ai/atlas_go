import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:path_provider/path_provider.dart';
import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:mbtiles/mbtiles.dart';
import 'package:vector_map_tiles/vector_map_tiles.dart';
import 'package:vector_map_tiles_mbtiles/vector_map_tiles_mbtiles.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Hive.initFlutter();
  await Hive.openBox('waypoints');
  await Hive.openBox('config');
  runApp(const AtlasGoApp());
}

class AtlasGoApp extends StatelessWidget {
  const AtlasGoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ATLAS GO • Garmin DZ',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF080C10),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF10161F),
          elevation: 0,
        ),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF00E676),
          secondary: Color(0xFFFF9100),
        ),
      ),
      home: const GarminDashboardScreen(),
    );
  }
}

class GarminDashboardScreen extends StatefulWidget {
  const GarminDashboardScreen({super.key});

  @override
  State<GarminDashboardScreen> createState() => _GarminDashboardScreenState();
}

class _GarminDashboardScreenState extends State<GarminDashboardScreen> {
  final MapController _mapController = MapController();
  final Box _waypointsBox = Hive.box('waypoints');
  final Box _configBox = Hive.box('config');

  Position? _pos;
  double _heading = 0.0;
  bool _isRecordingTrack = false;
  final List<LatLng> _recordedTrack = [];
  Map<String, dynamic>? _targetPoint;

  MbTiles? _algeriaMap;
  bool _isDownloading = false;
  double _progress = 0.0;
  String _statusText = 'خريطة الجزائر التفصيلية غير محملة بعد';

  StreamSubscription<Position>? _posStream;
  StreamSubscription<CompassEvent>? _compassStream;

  // مصدر خريطة الجزائر المتجهة الكاملة (Vector MBTiles)
  final String _algeriaTilesUrl =
      'https://huggingface.co/datasets/protomaps/openmaptiles-samples/resolve/main/algeria.mbtiles';

  @override
  void initState() {
    super.initState();
    _initLocalMap();
    _initGnssHardware();
  }

  Future<void> _initLocalMap() async {
    String? path = _configBox.get('algeria_map_path');
    if (path == null) {
      final dir = await getApplicationDocumentsDirectory();
      path = '${dir.path}/algeria_detailed.mbtiles';
    }

    final file = File(path);
    if (await file.exists() && await file.length() > 1024 * 1024) {
      try {
        final mb = MbTiles(mbtilesPath: file.path);
        setState(() {
          _algeriaMap = mb;
          _statusText = 'خريطة الجزائر الكاملة نشطة (أوفلاين 100%)';
        });
      } catch (e) {
        setState(() => _statusText = 'ملف الخريطة غير صالح، أعد التحميل أو الاستيراد');
      }
    }
  }

  Future<void> _downloadAlgeriaMap() async {
    setState(() {
      _isDownloading = true;
      _progress = 0.0;
      _statusText = 'جاري تحميل خريطة الجزائر الكاملة بأدق التفاصيل...';
    });

    try {
      final dir = await getApplicationDocumentsDirectory();
      final savePath = '${dir.path}/algeria_detailed.mbtiles';
      final dio = Dio();

      await dio.download(
        _algeriaTilesUrl,
        savePath,
        onReceiveProgress: (received, total) {
          if (total > 0) {
            setState(() => _progress = received / total);
          }
        },
      );

      await _configBox.put('algeria_map_path', savePath);
      await _initLocalMap();
    } catch (e) {
      setState(() {
        _statusText = 'فشل التحميل المباشر — استخدم أيقونة المجلد لاستيراد ملف .mbtiles';
      });
    } finally {
      setState(() => _isDownloading = false);
    }
  }

  Future<void> _pickMapFromPhone() async {
    final result = await FilePicker.platform.pickFiles(type: FileType.any);
    if (result != null && result.files.single.path != null) {
      final filePath = result.files.single.path!;
      if (!filePath.toLowerCase().endsWith('.mbtiles')) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('الرجاء اختيار ملف خريطة بصيغة .mbtiles')),
          );
        }
        return;
      }
      await _configBox.put('algeria_map_path', filePath);
      await _initLocalMap();
    }
  }

  Future<void> _initGnssHardware() async {
    LocationPermission perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
    }
    if (perm == LocationPermission.deniedForever) return;

    const locationSettings = LocationSettings(
      accuracy: LocationAccuracy.bestForNavigation,
      distanceFilter: 1,
    );

    _posStream = Geolocator.getPositionStream(locationSettings: locationSettings)
        .listen((Position position) {
      setState(() {
        _pos = position;
        if (_isRecordingTrack) {
          _recordedTrack.add(LatLng(position.latitude, position.longitude));
        }
      });
    });

    _compassStream = FlutterCompass.events?.listen((CompassEvent event) {
      if (event.heading != null) {
        setState(() => _heading = event.heading!);
      }
    });
  }

  @override
  void dispose() {
    _posStream?.cancel();
    _compassStream?.cancel();
    _algeriaMap?.dispose();
    super.dispose();
  }

  String _toGarminDMS(double value, bool isLat) {
    final hemisphere = isLat ? (value >= 0 ? 'N' : 'S') : (value >= 0 ? 'E' : 'W');
    final absVal = value.abs();
    final degrees = absVal.floor();
    final minRem = (absVal - degrees) * 60;
    final minutes = minRem.floor();
    final seconds = ((minRem - minutes) * 60).toStringAsFixed(1);
    return '$degrees°$minutes\'$seconds"$hemisphere';
  }

  void _saveNewWaypoint() {
    if (_pos == null) return;
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF141B24),
        title: const Text('حفظ نقطة إحداثيات (Waypoint)', textDirection: TextDirection.rtl),
        content: TextField(
          controller: controller,
          textDirection: TextDirection.rtl,
          decoration: const InputDecoration(hintText: 'اسم الموقع أو النقطة...'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('إلغاء')),
          ElevatedButton(
            onPressed: () {
              final label = controller.text.trim().isEmpty
                  ? 'WPT-${_waypointsBox.length + 1}'
                  : controller.text.trim();
              _waypointsBox.add({
                'name': label,
                'lat': _pos!.latitude,
                'lng': _pos!.longitude,
                'alt': _pos!.altitude,
              });
              Navigator.pop(ctx);
              setState(() {});
            },
            child: const Text('حفظ'),
          ),
        ],
      ),
    );
  }

  void _showWaypointsModal() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF10161F),
      builder: (ctx) => ListView.builder(
        itemCount: _waypointsBox.length,
        itemBuilder: (context, idx) {
          final item = Map<String, dynamic>.from(_waypointsBox.getAt(idx));
          return ListTile(
            leading: const Icon(Icons.flag, color: Color(0xFFFF9100)),
            title: Text(item['name'], textDirection: TextDirection.rtl),
            subtitle: Text('${_toGarminDMS(item['lat'], true)}  ${_toGarminDMS(item['lng'], false)}'),
            trailing: IconButton(
              icon: const Icon(Icons.navigation, color: Color(0xFF00E676)),
              onPressed: () {
                setState(() => _targetPoint = item);
                Navigator.pop(ctx);
              },
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final LatLng currentCoords = _pos != null
        ? LatLng(_pos!.latitude, _pos!.longitude)
        : const LatLng(33.8000, 2.8651);

    double? distanceMeters;
    double? bearingDegrees;
    if (_pos != null && _targetPoint != null) {
      distanceMeters = Geolocator.distanceBetween(
        currentCoords.latitude,
        currentCoords.longitude,
        _targetPoint!['lat'],
        _targetPoint!['lng'],
      );
      bearingDegrees = Geolocator.bearingBetween(
        currentCoords.latitude,
        currentCoords.longitude,
        _targetPoint!['lat'],
        _targetPoint!['lng'],
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('ATLAS GO • GARMIN DZ', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        actions: [
          IconButton(
            icon: const Icon(Icons.folder_open, color: Color(0xFFFF9100)),
            tooltip: 'استيراد خريطة .mbtiles من الهاتف',
            onPressed: _pickMapFromPhone,
          ),
          IconButton(
            icon: const Icon(Icons.bookmarks_outlined),
            onPressed: _showWaypointsModal,
          ),
        ],
      ),
      body: Column(
        children: [
          // شريط تحميل خريطة الجزائر التفصيلية
          if (_algeriaMap == null)
            Container(
              padding: const EdgeInsets.all(10),
              color: const Color(0xFF18202B),
              child: Column(
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          _statusText,
                          textDirection: TextDirection.rtl,
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                      if (!_isDownloading)
                        ElevatedButton.icon(
                          onPressed: _downloadAlgeriaMap,
                          icon: const Icon(Icons.download, size: 16),
                          label: const Text('تحميل الجزائر كاملة', style: TextStyle(fontSize: 12)),
                        ),
                    ],
                  ),
                  if (_isDownloading) ...[
                    const SizedBox(height: 8),
                    LinearProgressIndicator(value: _progress, color: const Color(0xFF00E676)),
                    const SizedBox(height: 4),
                    Text('${(_progress * 100).toStringAsFixed(1)}%', style: const TextStyle(fontSize: 11)),
                  ],
                ],
              ),
            ),

          // شاشة بيانات Garmin الميدانية (HUD)
          Container(
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 10),
            color: const Color(0xFF10161F),
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      _pos != null
                          ? '${_toGarminDMS(_pos!.latitude, true)} | ${_toGarminDMS(_pos!.longitude, false)}'
                          : 'جاري البحث عن الأقمار الصناعية...',
                      style: const TextStyle(
                        color: Color(0xFF00E676),
                        fontWeight: FontWeight.bold,
                        fontSize: 13,
                      ),
                    ),
                    Text(
                      'HDG ${_heading.toStringAsFixed(0)}°',
                      style: const TextStyle(color: Color(0xFFFF9100), fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
                const Divider(height: 10, color: Colors.white12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    _hudItem('الارتفاع', _pos != null ? '${_pos!.altitude.toStringAsFixed(0)} م' : '--'),
                    _hudItem('السرعة', _pos != null ? '${(_pos!.speed * 3.6).toStringAsFixed(1)} كم/س' : '--'),
                    _hudItem('دقة القمر', _pos != null ? '±${_pos!.accuracy.toStringAsFixed(1)} م' : '--'),
                  ],
                ),
              ],
            ),
          ),

          // رادار التوجيه نحو الهدف
          if (_targetPoint != null && distanceMeters != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              color: const Color(0xFFFF9100).withOpacity(0.2),
              child: Row(
                children: [
                  Transform.rotate(
                    angle: ((bearingDegrees! - _heading) * (math.pi / 180)),
                    child: const Icon(Icons.navigation, color: Color(0xFFFF9100), size: 32),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'الهدف: ${_targetPoint!['name']} • المسافة: ${distanceMeters > 1000 ? '${(distanceMeters / 1000).toStringAsFixed(2)} كم' : '${distanceMeters.toStringAsFixed(0)} م'}',
                      textDirection: TextDirection.rtl,
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    onPressed: () => setState(() => _targetPoint = null),
                  ),
                ],
              ),
            ),

          // الخريطة المتجهة
          Expanded(
            child: FlutterMap(
              mapController: _mapController,
              options: MapOptions(
                initialCenter: currentCoords,
                initialZoom: 14.0,
                maxZoom: 19.0,
              ),
              children: [
                if (_algeriaMap != null)
                  VectorTileLayer(
                    tileProviders: TileProviders({
                      'openmaptiles': MbTilesVectorTileProvider(mbtiles: _algeriaMap!),
                    }),
                    theme: ProvidedThemes.darkTheme(),
                  )
                else
                  TileLayer(
                    urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                    userAgentPackageName: 'com.zrg.atlasgo',
                  ),
                if (_recordedTrack.isNotEmpty)
                  PolylineLayer(
                    polylines: [
                      Polyline(
                        points: _recordedTrack,
                        color: const Color(0xFF00E676),
                        strokeWidth: 4.5,
                      ),
                    ],
                  ),
                MarkerLayer(
                  markers: [
                    if (_pos != null)
                      Marker(
                        point: currentCoords,
                        width: 44,
                        height: 44,
                        child: Transform.rotate(
                          angle: _heading * (math.pi / 180),
                          child: const Icon(Icons.navigation, color: Color(0xFF00E676), size: 36),
                        ),
                      ),
                    if (_targetPoint != null)
                      Marker(
                        point: LatLng(_targetPoint!['lat'], _targetPoint!['lng']),
                        width: 40,
                        height: 40,
                        child: const Icon(Icons.flag, color: Color(0xFFFF9100), size: 36),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
      floatingActionButton: Column(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          FloatingActionButton.small(
            heroTag: 'center',
            onPressed: () {
              if (_pos != null) _mapController.move(currentCoords, 16.0);
            },
            child: const Icon(Icons.my_location),
          ),
          const SizedBox(height: 10),
          FloatingActionButton.small(
            heroTag: 'track',
            backgroundColor: _isRecordingTrack ? Colors.red : const Color(0xFF00E676),
            onPressed: () {
              setState(() {
                _isRecordingTrack = !_isRecordingTrack;
                if (_isRecordingTrack && _pos != null) {
                  _recordedTrack.clear();
                  _recordedTrack.add(currentCoords);
                }
              });
            },
            child: Icon(_isRecordingTrack ? Icons.stop : Icons.route),
          ),
          const SizedBox(height: 10),
          FloatingActionButton(
            heroTag: 'wpt',
            onPressed: _saveNewWaypoint,
            child: const Icon(Icons.add_location_alt),
          ),
        ],
      ),
    );
  }

  Widget _hudItem(String title, String value) {
    return Column(
      children: [
        Text(title, style: const TextStyle(fontSize: 10, color: Colors.grey)),
        Text(value, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
      ],
    );
  }
}
