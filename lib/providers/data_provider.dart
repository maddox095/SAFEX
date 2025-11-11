import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import '../models/sensor_data.dart';

class DataProvider extends ChangeNotifier {
  SensorData? _latestData;
  final List<SensorData> _dataHistory = [];
  bool _isConnected = false;
  BluetoothDevice? _connectedDevice;
  StreamSubscription<List<int>>? _characteristicSubscription;
  
  // GPS tracking
  bool _isTrackingPhoneGPS = false;
  Timer? _gpsTimeout;

  SensorData? get latestData => _latestData;
  List<SensorData> get dataHistory => List.unmodifiable(_dataHistory);
  bool get isConnected => _isConnected;

  // Scan for BLE devices
  Future<List<ScanResult>> scanForDevices({Duration timeout = const Duration(seconds: 8)}) async {
    List<ScanResult> results = [];
    
    try {
      // Check if Bluetooth is available
      if (await FlutterBluePlus.isSupported == false) {
        debugPrint("❌ Bluetooth not supported");
        return results;
      }

      // Start scanning
      await FlutterBluePlus.startScan(
        timeout: timeout,
        androidUsesFineLocation: true,
      );

      // Listen to scan results
      final completer = Completer<List<ScanResult>>();
      final subscription = FlutterBluePlus.scanResults.listen((scanResults) {
        results = scanResults.where((r) => 
          r.device.platformName.isNotEmpty && 
          (r.device.platformName.contains('ESP32') || 
           r.device.platformName.contains('BLE'))
        ).toList();
        
        if (results.isNotEmpty && !completer.isCompleted) {
          completer.complete(results);
        }
      });

      // Wait for timeout or first result
      await Future.any([
        completer.future,
        Future.delayed(timeout),
      ]);

      await subscription.cancel();
      await FlutterBluePlus.stopScan();

      debugPrint("✅ Found ${results.length} devices");
      return results;
    } catch (e) {
      debugPrint("❌ Scan error: $e");
      return results;
    }
  }

  // Connect to a BLE device
  Future<void> connectToDevice(BluetoothDevice device) async {
    try {
      debugPrint("🔗 Connecting to ${device.platformName}...");
      
      // Disconnect any existing connection
      if (_connectedDevice != null) {
        await disconnect();
      }

      // Connect to device
      await device.connect(timeout: const Duration(seconds: 10));
      _connectedDevice = device;
      _isConnected = true;
      
      debugPrint("✅ Connected to ${device.platformName}");

      // Discover services
      List<BluetoothService> services = await device.discoverServices();
      debugPrint("📡 Discovered ${services.length} services");

      // Find the characteristic to subscribe to
      for (BluetoothService service in services) {
        for (BluetoothCharacteristic characteristic in service.characteristics) {
          debugPrint("📌 Characteristic: ${characteristic.uuid}");
          
          // Subscribe to notifications if available
          if (characteristic.properties.notify) {
            debugPrint("🔔 Subscribing to notifications on ${characteristic.uuid}");
            
            await characteristic.setNotifyValue(true);
            
            _characteristicSubscription = characteristic.lastValueStream.listen(
              _onDataReceived,
              onError: (error) {
                debugPrint("❌ Characteristic error: $error");
              },
            );
            
            break;
          }
        }
        if (_characteristicSubscription != null) break;
      }

      notifyListeners();
    } catch (e) {
      debugPrint("❌ Connection error: $e");
      _isConnected = false;
      _connectedDevice = null;
      notifyListeners();
      rethrow;
    }
  }

  // Handle incoming BLE data
  void _onDataReceived(List<int> value) {
    try {
      final jsonString = utf8.decode(value);
      debugPrint("📥 Received: $jsonString");

      final jsonData = json.decode(jsonString);
      
      // Parse the sensor data
      final sensorData = SensorData(
        lat: (jsonData['lat'] ?? 0.0).toDouble(),
        lon: (jsonData['lon'] ?? 0.0).toDouble(),
        speed: (jsonData['speed'] ?? 0.0).toDouble(),
        roll: (jsonData['roll'] ?? 0.0).toDouble(),
        pitch: (jsonData['pitch'] ?? 0.0).toDouble(),
        yaw: (jsonData['yaw'] ?? 0.0).toDouble(),
        ax: (jsonData['ax'] ?? 0.0).toDouble(),
        ay: (jsonData['ay'] ?? 0.0).toDouble(),
        az: (jsonData['az'] ?? 0.0).toDouble(),
        gx: (jsonData['gx'] ?? 0.0).toDouble(),
        gy: (jsonData['gy'] ?? 0.0).toDouble(),
        gz: (jsonData['gz'] ?? 0.0).toDouble(),
        alert: jsonData['alert'] ?? 'Normal',
        activity: jsonData['activity'] ?? 'Unknown',
        source: 'ESP32',
      );

      debugPrint("✅ Parsed data: ${sensorData.activity}, Speed: ${sensorData.speed}");

      // Update latest data
      _latestData = sensorData;
      
      // Add to history - THIS IS CRITICAL FOR GRAPHS
      _dataHistory.add(sensorData);
      
      // Limit history size to prevent memory issues (keep last 1000 points)
      if (_dataHistory.length > 1000) {
        _dataHistory.removeAt(0);
      }

      // Stop phone GPS tracking when ESP32 data arrives
      if (_isTrackingPhoneGPS) {
        _isTrackingPhoneGPS = false;
        _gpsTimeout?.cancel();
        debugPrint("🛑 Stopped phone GPS tracking - ESP32 data received");
      }

      // Notify listeners to update UI
      notifyListeners();
    } catch (e) {
      debugPrint("❌ Data parsing error: $e");
      debugPrint("Raw data: ${utf8.decode(value)}");
    }
  }

  // Update with phone GPS data
  void updateWithPhoneGPS(SensorData phoneData) {
    // Only use phone GPS if not connected or no valid ESP32 data
    if (!_isConnected || (_latestData == null || !_latestData!.hasValidLocation)) {
      _latestData = phoneData;
      _dataHistory.add(phoneData);
      
      // Limit history size
      if (_dataHistory.length > 1000) {
        _dataHistory.removeAt(0);
      }
      
      notifyListeners();
    }
  }

  // Start phone GPS tracking
  void startPhoneGPS() {
    _isTrackingPhoneGPS = true;
    
    // Set a timeout to stop tracking if ESP32 connects
    _gpsTimeout?.cancel();
    _gpsTimeout = Timer(const Duration(seconds: 30), () {
      if (!_isConnected) {
        debugPrint("⏰ Phone GPS timeout - continuing to track");
      }
    });
  }

  // Disconnect from BLE device
  Future<void> disconnect() async {
    try {
      debugPrint("🔌 Disconnecting...");
      
      await _characteristicSubscription?.cancel();
      _characteristicSubscription = null;
      
      if (_connectedDevice != null) {
        await _connectedDevice!.disconnect();
      }
      
      _connectedDevice = null;
      _isConnected = false;
      _gpsTimeout?.cancel();
      
      debugPrint("✅ Disconnected");
      notifyListeners();
    } catch (e) {
      debugPrint("❌ Disconnect error: $e");
    }
  }

  // Clear all data
  void clearHistory() {
    dataHistory.clear();
    notifyListeners();
  }

  @override
  void dispose() {
    _characteristicSubscription?.cancel();
    _gpsTimeout?.cancel();
    _connectedDevice?.disconnect();
    super.dispose();
  }
}