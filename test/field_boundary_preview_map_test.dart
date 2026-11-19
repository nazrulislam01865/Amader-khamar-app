import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:bashir_agro_app_2/models/field_boundary_model.dart';
import 'package:bashir_agro_app_2/presentation/widgets/field_boundary_map_widget.dart';

void main() {
  final boundary = FieldBoundaryModel.fromCenterAndRadius(23.7806, 90.4160, 40);

  testWidgets('task-card preview uses a tile-friendly compact camera', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: FieldBoundaryMapWidget(
        boundary: boundary,
        height: 195,
        isInteractive: false,
      )),
    ));

    final map = tester.widget<FlutterMap>(find.byType(FlutterMap));
    final tiles = tester.widget<TileLayer>(find.byType(TileLayer));
    expect(map.options.initialZoom, 15.0);
    expect(tiles.maxNativeZoom, 14);
  });

  testWidgets('full-screen map keeps its original camera and tile zoom', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: FieldBoundaryMapWidget(
        boundary: boundary,
        height: 600,
        isInteractive: true,
      )),
    ));

    final map = tester.widget<FlutterMap>(find.byType(FlutterMap));
    final tiles = tester.widget<TileLayer>(find.byType(TileLayer));
    expect(map.options.initialZoom, 16.8);
    expect(tiles.maxNativeZoom, 20);
  });
}
