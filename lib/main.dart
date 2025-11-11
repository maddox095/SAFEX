import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:geolocator/geolocator.dart';
import 'package:fl_chart/fl_chart.dart';
import 'providers/data_provider.dart';
import 'models/sensor_data.dart';
import 'dart:async';

void main() {
  runApp(
    ChangeNotifierProvider(
      create: (_) => DataProvider(),
      child: const MyApp(),
    ),
  );
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ESP32 BLE Tracker',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blueAccent),
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with TickerProviderStateMixin {
  GoogleMapController? _mapController;
  late TabController _tabController;

  static const LatLng _defaultLocation = LatLng(12.9344, 77.5348);

  Position? _currentPhonePosition;
  StreamSubscription<Position>? _positionStreamSub;
  bool _isMapReady = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    Future.microtask(() => _initializeApp());
  }

  @override
  void dispose() {
    _mapController?.dispose();
    _tabController.dispose();
    _positionStreamSub?.cancel();
    super.dispose();
  }

  Future<void> _initializeApp() async {
    await _initializePermissionsAndLocation();
    if (mounted) {
      context.read<DataProvider>().startPhoneGPS();
    }
  }

  Future<void> _initializePermissionsAndLocation() async {
    try {
      await [
        Permission.bluetoothScan,
        Permission.bluetoothConnect,
        Permission.locationWhenInUse,
        Permission.storage,
      ].request();

      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('⚠️ Enable location services')),
          );
        }
        return;
      }

      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }

      _startPhoneLocationListener();
    } catch (e) {
      debugPrint("❌ Permission error: $e");
    }
  }

  void _startPhoneLocationListener() {
    const locationSettings = LocationSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: 1,
    );

    _positionStreamSub = Geolocator.getPositionStream(
      locationSettings: locationSettings,
    ).listen((Position pos) {
      if (!mounted) return;

      _currentPhonePosition = pos;
      final provider = context.read<DataProvider>();

      debugPrint("📍 Phone: ${pos.latitude}, ${pos.longitude}, Speed: ${pos.speed}");

      if (!provider.isConnected || provider.latestData == null) {
        final phoneData = SensorData(
          lat: pos.latitude,
          lon: pos.longitude,
          speed: pos.speed,
          roll: 0,
          pitch: 0,
          yaw: 0,
          ax: 0,
          ay: 0,
          az: 0,
          gx: 0,
          gy: 0,
          gz: 0,
          alert: "Phone GPS",
          activity: "Phone Tracking",
          source: "Phone",
        );
        provider.updateWithPhoneGPS(phoneData);
      }
    });
  }

  Future<void> _downloadData(BuildContext context) async {
    try {
      final provider = context.read<DataProvider>();
      if (provider.dataHistory.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('⚠️ No data to download')),
          );
        }
        return;
      }

      final dir = Directory('/storage/emulated/0/Download');
      if (!await dir.exists()) await dir.create(recursive: true);

      final file = File(
        '${dir.path}/tracker_${DateTime.now().millisecondsSinceEpoch}.json',
      );
      await file.writeAsString(
        json.encode(provider.dataHistory.map((e) => e.toJson()).toList()),
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('✅ Saved: ${file.path}')),
        );
      }
    } catch (e) {
      debugPrint("❌ Download error: $e");
    }
  }

  void _onMapCreated(GoogleMapController controller) {
    if (!mounted) return;
    _mapController = controller;
    _isMapReady = true;
    debugPrint("🗺️ Map ready");

    Geolocator.getCurrentPosition(
      desiredAccuracy: LocationAccuracy.high,
      timeLimit: const Duration(seconds: 5),
    ).then((pos) {
      if (mounted && _mapController != null) {
        _mapController!.animateCamera(
          CameraUpdate.newLatLngZoom(
            LatLng(pos.latitude, pos.longitude),
            16.0,
          ),
        );
      }
    }).catchError((e) {
      debugPrint("❌ Position error: $e");
    });
  }

  void _showClearConfirmation(BuildContext context, DataProvider provider) {
    showDialog(
      context: context,
      builder: (BuildContext dialogContext) {
        return AlertDialog(
          title: const Text('Clear Tracking Data?'),
          content: const Text(
            'This will remove all tracked paths and sensor data from the map and graphs. '
            'This action cannot be undone.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red,
                foregroundColor: Colors.white,
              ),
              onPressed: () {
                provider.clearHistory();
                Navigator.of(dialogContext).pop();
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('🗑️ Tracking data cleared'),
                    duration: Duration(seconds: 2),
                  ),
                );
              },
              child: const Text('Clear'),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'ESP32 BLE Tracker',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(icon: Icon(Icons.map), text: "Map"),
            Tab(icon: Icon(Icons.show_chart), text: "Graphs"),
            Tab(icon: Icon(Icons.analytics), text: "Data"),
          ],
        ),
        actions: [
          Consumer<DataProvider>(
            builder: (context, provider, _) {
              return Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (provider.dataHistory.isNotEmpty)
                    IconButton(
                      icon: const Icon(Icons.clear_all),
                      tooltip: 'Clear Tracking',
                      onPressed: () => _showClearConfirmation(context, provider),
                    ),
                  IconButton(
                    icon: Icon(
                      provider.isConnected
                          ? Icons.bluetooth_connected
                          : Icons.bluetooth_disabled,
                      color: provider.isConnected ? Colors.green : Colors.red,
                    ),
                    onPressed: () => _handleBluetoothButton(provider),
                  ),
                ],
              );
            },
          ),
        ],
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _buildMapTab(),
          _buildGraphTab(),
          _buildDataTab(),
        ],
      ),
      floatingActionButton: Consumer<DataProvider>(
        builder: (context, provider, _) {
          if (provider.dataHistory.isEmpty) return const SizedBox.shrink();
          return Padding(
            padding: const EdgeInsets.only(bottom: 20),
            child: FloatingActionButton.extended(
              onPressed: () => _downloadData(context),
              label: const Text('Download'),
              icon: const Icon(Icons.download),
              backgroundColor: Colors.blue,
            ),
          );
        },
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
    );
  }

  Future<void> _handleBluetoothButton(DataProvider provider) async {
    if (provider.isConnected) {
      await provider.disconnect();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('🔌 Disconnected')),
        );
      }
    } else {
      try {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('🔍 Scanning...')),
          );
        }

        final results = await provider.scanForDevices(
          timeout: const Duration(seconds: 8),
        );

        if (results.isNotEmpty) {
          final device = results.first.device;
          await provider.connectToDevice(device);
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('✅ Connected to ${device.platformName}')),
            );
          }
        } else {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('❌ No devices found')),
            );
          }
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('❌ Error: $e')),
          );
        }
      }
    }
  }

  Widget _buildMapTab() {
    return Consumer<DataProvider>(
      builder: (context, provider, _) {
        LatLng? currentPos;
        if (provider.latestData != null && provider.latestData!.hasValidLocation) {
          currentPos = LatLng(provider.latestData!.lat, provider.latestData!.lon);
        } else if (_currentPhonePosition != null) {
          currentPos = LatLng(
            _currentPhonePosition!.latitude,
            _currentPhonePosition!.longitude,
          );
        }

        Set<Marker> markers = {};
        if (currentPos != null) {
          BitmapDescriptor icon;
          switch (provider.latestData?.activity) {
            case "Driving":
            case "Driving/Scooter":
              icon = BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueRed);
              break;
            case "Biking":
              icon = BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueMagenta);
              break;
            case "Walking":
              icon = BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueOrange);
              break;
            case "Phone Tracking":
              icon = BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueAzure);
              break;
            default:
              icon = BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueGreen);
          }

          markers.add(
            Marker(
              markerId: const MarkerId('current'),
              position: currentPos,
              icon: icon,
              infoWindow: InfoWindow(
                title: provider.latestData?.activity ?? "Tracking",
                snippet: provider.latestData?.alert ?? "Active",
              ),
            ),
          );
        }

        final allPoints = provider.dataHistory
            .where((d) => d.hasValidLocation)
            .map((d) => LatLng(d.lat, d.lon))
            .toList();

        Set<Polyline> polylines = {};
        
        if (allPoints.length >= 2) {
          polylines.add(
            Polyline(
              polylineId: const PolylineId('complete_path'),
              color: Colors.green,
              width: 4,
              points: allPoints,
              startCap: Cap.roundCap,
              endCap: Cap.roundCap,
              jointType: JointType.round,
            ),
          );
          debugPrint("🛤️ Complete path: ${allPoints.length} points");
        }

        final esp32Points = provider.dataHistory
            .where((d) => d.source == "ESP32" && d.hasValidLocation)
            .map((d) => LatLng(d.lat, d.lon))
            .toList();

        if (esp32Points.length >= 2) {
          polylines.add(
            Polyline(
              polylineId: const PolylineId('esp32_path'),
              color: Colors.blueAccent,
              width: 5,
              points: esp32Points,
              startCap: Cap.roundCap,
              endCap: Cap.roundCap,
              jointType: JointType.round,
            ),
          );
          debugPrint("🛤️ ESP32 path: ${esp32Points.length} points");
        }

        if (_isMapReady &&
            _mapController != null &&
            currentPos != null &&
            _tabController.index == 0) {
          Future.delayed(const Duration(milliseconds: 100), () {
            if (mounted && _mapController != null) {
              _mapController!.animateCamera(
                CameraUpdate.newLatLng(currentPos!),
              );
            }
          });
        }

        return Stack(
          children: [
            GoogleMap(
              onMapCreated: _onMapCreated,
              initialCameraPosition: CameraPosition(
                target: currentPos ?? _defaultLocation,
                zoom: 16.0,
              ),
              markers: markers,
              polylines: polylines,
              myLocationEnabled: true,
              myLocationButtonEnabled: false,
              zoomControlsEnabled: false,
              mapToolbarEnabled: false,
              compassEnabled: true,
              mapType: MapType.normal,
            ),
            if (!_isMapReady)
              Container(
                color: Colors.white,
                child: const Center(child: CircularProgressIndicator()),
              ),
            Positioned(
              top: 10,
              left: 10,
              child: Material(
                elevation: 4,
                borderRadius: BorderRadius.circular(20),
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.black87,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        provider.isConnected
                            ? Icons.bluetooth_connected
                            : Icons.gps_fixed,
                        color: Colors.white,
                        size: 16,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        provider.isConnected
                            ? 'ESP32'
                            : (_currentPhonePosition != null ? 'Phone GPS' : 'Searching...'),
                        style: const TextStyle(color: Colors.white, fontSize: 12),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            Positioned(
              bottom: 80,
              right: 16,
              child: Column(
                children: [
                  FloatingActionButton(
                    heroTag: 'recenter',
                    mini: true,
                    backgroundColor: Colors.white,
                    onPressed: () {
                      if (currentPos != null && _mapController != null) {
                        _mapController!.animateCamera(
                          CameraUpdate.newLatLngZoom(currentPos, 17.0),
                        );
                      }
                    },
                    child: const Icon(Icons.my_location, color: Colors.blue),
                  ),
                  const SizedBox(height: 8),
                  FloatingActionButton(
                    heroTag: 'zoom_in',
                    mini: true,
                    backgroundColor: Colors.white,
                    onPressed: () => _mapController?.animateCamera(CameraUpdate.zoomIn()),
                    child: const Icon(Icons.add, color: Colors.black87),
                  ),
                  const SizedBox(height: 8),
                  FloatingActionButton(
                    heroTag: 'zoom_out',
                    mini: true,
                    backgroundColor: Colors.white,
                    onPressed: () => _mapController?.animateCamera(CameraUpdate.zoomOut()),
                    child: const Icon(Icons.remove, color: Colors.black87),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  List<double> _smoothData(List<double> data, {int windowSize = 5}) {
    if (data.length < windowSize) return data;
    
    List<double> smoothed = [];
    for (int i = 0; i < data.length; i++) {
      int start = (i - windowSize ~/ 2).clamp(0, data.length - 1);
      int end = (i + windowSize ~/ 2 + 1).clamp(0, data.length);
      
      double sum = 0;
      int count = 0;
      for (int j = start; j < end; j++) {
        sum += data[j];
        count++;
      }
      smoothed.add(sum / count);
    }
    return smoothed;
  }

  Map<String, double> _calculateYAxisRange(List<double> values) {
    if (values.isEmpty) return {'min': 0.0, 'max': 10.0, 'interval': 2.0};

    final minVal = values.reduce((a, b) => a < b ? a : b);
    final maxVal = values.reduce((a, b) => a > b ? a : b);
    final range = (maxVal - minVal).abs();

    if (range < 0.5) {
      final center = (minVal + maxVal) / 2;
      return {
        'min': center - 2.5,
        'max': center + 2.5,
        'interval': 1.0,
      };
    }

    final padding = range * 0.3;
    final yMin = minVal - padding;
    final yMax = maxVal + padding;
    
    final totalRange = yMax - yMin;
    double interval;
    if (totalRange < 5) {
      interval = 1.0;
    } else if (totalRange < 10) {
      interval = 2.0;
    } else if (totalRange < 20) {
      interval = 5.0;
    } else {
      interval = 10.0;
    }

    return {
      'min': yMin,
      'max': yMax,
      'interval': interval,
    };
  }

  Widget _buildGraphTab() {
    return Consumer<DataProvider>(
      builder: (context, provider, _) {
        if (provider.dataHistory.isEmpty) {
          return const Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.show_chart, size: 64, color: Colors.grey),
                SizedBox(height: 16),
                Text("No data yet", style: TextStyle(fontSize: 16)),
              ],
            ),
          );
        }

        final recent = provider.dataHistory.length > 100
            ? provider.dataHistory.sublist(provider.dataHistory.length - 100)
            : provider.dataHistory;

        return ListView(
          padding: const EdgeInsets.all(12),
          children: [
            _lineChart(
              "Speed (m/s)", 
              recent.map((d) => d.speed).toList(), 
              Colors.blue,
              windowSize: 7,
            ),
            const SizedBox(height: 12),
            _lineChart(
              "Accel X (m/s²)", 
              recent.map((d) => d.ax).toList(), 
              Colors.orange,
              windowSize: 5,
            ),
            const SizedBox(height: 12),
            _lineChart(
              "Accel Y (m/s²)", 
              recent.map((d) => d.ay).toList(), 
              Colors.purple,
              windowSize: 5,
            ),
            const SizedBox(height: 12),
            _lineChart(
              "Accel Z (m/s²)", 
              recent.map((d) => d.az).toList(), 
              Colors.green,
              windowSize: 5,
            ),
          ],
        );
      },
    );
  }

  Widget _lineChart(String title, List<double> values, Color color, {int windowSize = 5}) {
    if (values.isEmpty) return const SizedBox.shrink();

    final smoothedValues = _smoothData(values, windowSize: windowSize);
    final yAxisRange = _calculateYAxisRange(smoothedValues);

    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  title, 
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: color.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: color.withOpacity(0.3)),
                  ),
                  child: Text(
                    'Smoothed',
                    style: TextStyle(
                      fontSize: 11,
                      color: color,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            SizedBox(
              height: 300,
              child: LineChart(
                LineChartData(
                  minY: yAxisRange['min'],
                  maxY: yAxisRange['max'],
                  gridData: FlGridData(
                    show: true,
                    drawVerticalLine: false,
                    horizontalInterval: yAxisRange['interval'],
                    getDrawingHorizontalLine: (value) => FlLine(
                      color: Colors.grey.withOpacity(0.2),
                      strokeWidth: 1,
                    ),
                  ),
                  titlesData: FlTitlesData(
                    show: true,
                    rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                    topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                    bottomTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        reservedSize: 35,
                        interval: smoothedValues.length > 20 ? 20 : 10,
                        getTitlesWidget: (value, meta) {
                          if (value.toInt() % (smoothedValues.length > 20 ? 20 : 10) != 0) {
                            return const SizedBox.shrink();
                          }
                          return Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Text(
                              value.toInt().toString(),
                              style: const TextStyle(fontSize: 11, color: Colors.grey),
                            ),
                          );
                        },
                      ),
                    ),
                    leftTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        reservedSize: 55,
                        interval: yAxisRange['interval'],
                        getTitlesWidget: (value, meta) => Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: Text(
                            value.toStringAsFixed(1),
                            style: const TextStyle(fontSize: 11, color: Colors.grey),
                          ),
                        ),
                      ),
                    ),
                  ),
                  borderData: FlBorderData(
                    show: true,
                    border: Border.all(color: Colors.grey.withOpacity(0.3)),
                  ),
                  lineBarsData: [
                    LineChartBarData(
                      spots: smoothedValues
                          .asMap()
                          .entries
                          .map((e) => FlSpot(e.key.toDouble(), e.value))
                          .toList(),
                      color: color,
                      barWidth: 3,
                      isCurved: true,
                      curveSmoothness: 0.35,
                      dotData: const FlDotData(show: false),
                      belowBarData: BarAreaData(
                        show: true,
                        color: color.withOpacity(0.15),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDataTab() {
    return Consumer<DataProvider>(
      builder: (context, provider, _) {
        if (provider.latestData == null) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const CircularProgressIndicator(),
                const SizedBox(height: 16),
                Text(
                  _currentPhonePosition != null ? 'Getting GPS...' : 'No data',
                  style: const TextStyle(fontSize: 16),
                ),
              ],
            ),
          );
        }

        final d = provider.latestData!;

        return ListView(
          padding: const EdgeInsets.all(10),
          children: [
            _infoCard('Source', d.source, color: Colors.indigo),
            _infoCard('Activity', d.activity, color: _getActivityColor(d.activity)),
            _infoCard('Speed', '${d.speed.toStringAsFixed(2)} m/s'),
            _infoCard('Latitude', d.lat.toStringAsFixed(6)),
            _infoCard('Longitude', d.lon.toStringAsFixed(6)),
            _infoCard('Alert', d.alert),
            if (d.source == "ESP32") ...[
              const Divider(height: 32),
              const Padding(
                padding: EdgeInsets.all(8),
                child: Text('IMU Data', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              ),
              _infoCard('Roll', d.roll.toStringAsFixed(2)),
              _infoCard('Pitch', d.pitch.toStringAsFixed(2)),
              _infoCard('Yaw', d.yaw.toStringAsFixed(2)),
              _infoCard('Accel X', d.ax.toStringAsFixed(2)),
              _infoCard('Accel Y', d.ay.toStringAsFixed(2)),
              _infoCard('Accel Z', d.az.toStringAsFixed(2)),
            ],
          ],
        );
      },
    );
  }

  Color _getActivityColor(String activity) {
    switch (activity) {
      case "Driving":
      case "Driving/Scooter":
        return Colors.redAccent;
      case "Biking":
        return Colors.pinkAccent;
      case "Walking":
        return Colors.orangeAccent;
      case "Phone Tracking":
        return Colors.blueAccent;
      default:
        return Colors.green;
    }
  }

  Widget _infoCard(String label, String value, {Color? color}) {
    return Card(
      child: ListTile(
        title: Text(label, style: const TextStyle(fontWeight: FontWeight.bold)),
        trailing: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: color ?? Colors.blueGrey.shade100,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(value, style: const TextStyle(fontWeight: FontWeight.w500)),
        ),
      ),
    );
  }
}