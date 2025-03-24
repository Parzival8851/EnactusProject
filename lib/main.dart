import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:http/http.dart' as http;
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart'; // Import necessario
import 'package:flutter_map_cancellable_tile_provider/flutter_map_cancellable_tile_provider.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'OSM Routing App',
      theme: ThemeData(
        primarySwatch: Colors.blue,
      ),
      home: const MapScreen(),
    );
  }
}

class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  final MapController _mapController = MapController();
  double currentZoom = 13.0;
  LatLng currentCenter = LatLng(45.4642, 9.1900);
  List<LatLng> routePoints = [];
  LatLng? startPoint;
  LatLng? endPoint;
  // Variabile per la posizione attuale dell'utente
  LatLng? currentUserLocation;
  TextEditingController startController = TextEditingController();
  TextEditingController endController = TextEditingController();
  List<Map<String, dynamic>> startSuggestions = [];
  List<Map<String, dynamic>> endSuggestions = [];
  List<LatLng> obstacles = []; // Lista per segnalare ostacoli

  @override
  void initState() {
    super.initState();
    _loadObstacles(); // Carica ostacoli salvati all'avvio
  }

  // Salva un ostacolo con una key progressiva unica
  Future<void> _saveObstacle(LatLng point) async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    // Leggo il contatore corrente, se non esiste lo inizializzo a 0
    int counter = prefs.getInt('obstacle_counter') ?? 0;
    String key = 'obstacle_$counter';
    // Salvo l'ostacolo come JSON
    await prefs.setString(key, jsonEncode({'lat': point.latitude, 'lng': point.longitude}));
    // Aggiorno il contatore per il prossimo ostacolo
    await prefs.setInt('obstacle_counter', counter + 1);
  }

  // Carico tutti gli ostacoli salvati con le key che iniziano con "obstacle_"
  Future<void> _loadObstacles() async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    Set<String> keys = prefs.getKeys();
    // Seleziono tutte le chiavi che corrispondono al pattern desiderato
    List<String> obstacleKeys = keys.where((key) => key.startsWith('obstacle_')).toList();
    // Ordino le chiavi in base al numero progressivo
    obstacleKeys.sort((a, b) {
      int aNum = int.parse(a.split('_')[1]);
      int bNum = int.parse(b.split('_')[1]);
      return aNum.compareTo(bNum);
    });
    List<LatLng> loadedObstacles = [];
    for (String key in obstacleKeys) {
      String? value = prefs.getString(key);
      if (value != null) {
        Map<String, dynamic> map = jsonDecode(value);
        loadedObstacles.add(LatLng(map['lat'], map['lng']));
      }
    }
    setState(() {
      obstacles = loadedObstacles;
    });
  }

  // Funzione per cercare una località tramite Nominatim
  Future<void> _searchLocation(String query, bool isStart) async {
    if (query.isEmpty) return;
    final url = Uri.parse(
        'https://nominatim.openstreetmap.org/search?format=json&q=$query');
    final response = await http.get(url);
    if (response.statusCode == 200) {
      final List<dynamic> results = json.decode(response.body);
      setState(() {
        if (isStart) {
          startSuggestions =
              results.map((e) => e as Map<String, dynamic>).toList();
        } else {
          endSuggestions =
              results.map((e) => e as Map<String, dynamic>).toList();
        }
      });
    }
  }

  // Selezione della località dalla lista dei risultati
  void _selectLocation(Map<String, dynamic> location, bool isStart) {
    double lat = double.parse(location['lat']);
    double lon = double.parse(location['lon']);
    setState(() {
      if (isStart) {
        startPoint = LatLng(lat, lon);
        startController.text = location['display_name'];
        startSuggestions = [];
      } else {
        endPoint = LatLng(lat, lon);
        endController.text = location['display_name'];
        endSuggestions = [];
      }
    });
  }

  // Calcolo del percorso tramite OSRM
  Future<void> _calculateRoute() async {
    if (startPoint == null || endPoint == null) return;
    final url = Uri.parse(
      'https://router.project-osrm.org/route/v1/walking/'
          '${startPoint!.longitude},${startPoint!.latitude};'
          '${endPoint!.longitude},${endPoint!.latitude}'
          '?overview=full&geometries=geojson',
    );
    try {
      print("Fetching route from: $url");
      final response = await http.get(url);
      if (!mounted) return;
      if (response.statusCode == 200) {
        final data = json.decode(response.body) as Map<String, dynamic>;
        final routes = data['routes'] as List<dynamic>;
        if (routes.isNotEmpty) {
          final coords = routes[0]['geometry']['coordinates'] as List<dynamic>;
          setState(() {
            routePoints =
                coords.map((coord) => LatLng(coord[1], coord[0])).toList();
            _mapController.move(startPoint!, 13);
          });
        }
      } else {
        print("Error fetching route: ${response.body}");
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Exception: $e')),
        );
      }
    }
  }

  // Aggiunge un ostacolo e lo salva come entry separata
  void _addObstacle(LatLng point) {
    setState(() {
      obstacles.add(point);
    });
    _saveObstacle(point);
  }

  // Funzioni per lo zoom
  void _zoomIn() {
    setState(() {
      currentZoom += 1;
      _mapController.move(currentCenter, currentZoom);
    });
  }

  void _zoomOut() {
    setState(() {
      currentZoom -= 1;
      _mapController.move(currentCenter, currentZoom);
    });
  }

  // Ottieni la posizione attuale e aggiorna il marker
  Future<void> _getCurrentLocation() async {
    bool serviceEnabled;
    LocationPermission permission;

    serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      return;
    }

    permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.deniedForever) {
        return;
      }
    }

    Position position = await Geolocator.getCurrentPosition(
      desiredAccuracy: LocationAccuracy.best,
    );

    setState(() {
      currentUserLocation = LatLng(position.latitude, position.longitude);
    });
    _mapController.move(currentUserLocation!, 15);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('OSM Routing App')),
      body: Column(
        children: [
          // Sezione per la ricerca delle località
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: Column(
              children: [
                TextField(
                  controller: startController,
                  decoration:
                  const InputDecoration(labelText: 'Punto di partenza'),
                  onChanged: (value) => _searchLocation(value, true),
                ),
                ...startSuggestions.map((s) => ListTile(
                  title: Text(s['display_name']),
                  onTap: () => _selectLocation(s, true),
                )),
                TextField(
                  controller: endController,
                  decoration:
                  const InputDecoration(labelText: 'Punto di arrivo'),
                  onChanged: (value) => _searchLocation(value, false),
                ),
                ...endSuggestions.map((s) => ListTile(
                  title: Text(s['display_name']),
                  onTap: () => _selectLocation(s, false),
                )),
                ElevatedButton(
                  onPressed: _calculateRoute,
                  child: const Text("Calcola Percorso"),
                ),
              ],
            ),
          ),
          Expanded(
            child: Stack(
              children: [
                FlutterMap(
                  mapController: _mapController,
                  options: MapOptions(
                    initialCenter: LatLng(45.4642, 9.1900),
                    initialZoom: 13.0,
                    onTap: (tapPosition, point) => _addObstacle(point),
                  ),
                  children: [
                    TileLayer(
                      urlTemplate:
                      'https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png',
                      subdomains: ['a', 'b', 'c'],
                    ),
                    // Marker per la posizione attuale dell'utente
                    if (currentUserLocation != null)
                      MarkerLayer(
                        markers: [
                          Marker(
                            point: currentUserLocation!,
                            width: 40,
                            height: 40,
                            child: const Icon(Icons.person_pin_circle,
                                color: Colors.blue, size: 40),
                          ),
                        ],
                      ),
                    // Marker per il punto di partenza
                    if (startPoint != null)
                      MarkerLayer(
                        markers: [
                          Marker(
                            point: startPoint!,
                            width: 40,
                            height: 40,
                            child: const Icon(Icons.location_on,
                                color: Colors.green, size: 40),
                          ),
                        ],
                      ),
                    // Marker per il punto di arrivo
                    if (endPoint != null)
                      MarkerLayer(
                        markers: [
                          Marker(
                            point: endPoint!,
                            width: 40,
                            height: 40,
                            child: const Icon(Icons.location_on,
                                color: Colors.red, size: 40),
                          ),
                        ],
                      ),
                    // Layer per il percorso
                    if (routePoints.isNotEmpty)
                      PolylineLayer(
                        polylines: [
                          Polyline(
                            points: routePoints,
                            strokeWidth: 4,
                            color: Colors.blue,
                          ),
                        ],
                      ),
                    // Layer per gli ostacoli
                    MarkerLayer(
                      markers: obstacles
                          .map((point) => Marker(
                        point: point,
                        width: 40,
                        height: 40,
                        child: const Icon(Icons.warning,
                            color: Colors.orange, size: 40),
                      ))
                          .toList(),
                    ),
                  ],
                ),
                // Pulsanti per lo zoom
                Positioned(
                  left: 10,
                  bottom: 100,
                  child: Column(
                    children: [
                      FloatingActionButton(
                        heroTag: "zoom_in",
                        mini: true,
                        onPressed: _zoomIn,
                        child: const Icon(Icons.add),
                      ),
                      const SizedBox(height: 10),
                      FloatingActionButton(
                        heroTag: "zoom_out",
                        mini: true,
                        onPressed: _zoomOut,
                        child: const Icon(Icons.remove),
                      ),
                    ],
                  ),
                ),
                // Pulsante per la geolocalizzazione
                Positioned(
                  right: 10,
                  bottom: 100,
                  child: FloatingActionButton(
                    heroTag: "geolocate",
                    mini: true,
                    onPressed: _getCurrentLocation,
                    child: const Icon(Icons.my_location),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
