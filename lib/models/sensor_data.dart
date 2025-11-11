class SensorData {
  final double lat;
  final double lon;
  final double speed;
  final double roll;
  final double pitch;
  final double yaw;
  final double ax;
  final double ay;
  final double az;
  final double gx;
  final double gy;
  final double gz;
  final String alert;
  final String activity;
  final String source; // "ESP32" or "Phone"

  SensorData({
    required this.lat,
    required this.lon,
    required this.speed,
    required this.roll,
    required this.pitch,
    required this.yaw,
    required this.ax,
    required this.ay,
    required this.az,
    required this.gx,
    required this.gy,
    required this.gz,
    required this.alert,
    required this.activity,
    this.source = "ESP32",
  });

  factory SensorData.fromJson(Map<String, dynamic> json) {
    double parseNum(dynamic val) {
      if (val == null) return 0.0;
      if (val is num) return val.toDouble();
      if (val is String) return double.tryParse(val) ?? 0.0;
      return 0.0;
    }

    return SensorData(
      lat: parseNum(json['lat'] ?? json['latitude']),
      lon: parseNum(json['lon'] ?? json['longitude']),
      speed: parseNum(json['speed']),
      roll: parseNum(json['roll']),
      pitch: parseNum(json['pitch']),
      yaw: parseNum(json['yaw']),
      ax: parseNum(json['ax']),
      ay: parseNum(json['ay']),
      az: parseNum(json['az']),
      gx: parseNum(json['gx']),
      gy: parseNum(json['gy']),
      gz: parseNum(json['gz']),
      alert: json['alert']?.toString() ?? "None",
      activity: json['activity']?.toString() ?? "Stationary",
      source: json['source']?.toString() ?? "ESP32",
    );
  }

  Map<String, dynamic> toJson() => {
        'lat': lat,
        'lon': lon,
        'speed': speed,
        'roll': roll,
        'pitch': pitch,
        'yaw': yaw,
        'ax': ax,
        'ay': ay,
        'az': az,
        'gx': gx,
        'gy': gy,
        'gz': gz,
        'alert': alert,
        'activity': activity,
        'source': source,
      };

  bool get hasValidLocation => lat != 0.0 && lon != 0.0;
}
