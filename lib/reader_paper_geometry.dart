import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Path, Size;

/// One shaded, texture-mapped surface of the turning sheet.
///
/// [positions] and [uv] store two floats per vertex; [normals] stores one
/// value per vertex. The painter turns normals into vertex colours, so the
/// three arrays must agree on the vertex count. [uv] is in logical page
/// pixels (0..width, 0..height), not normalized texture coordinates.
class ReaderPaperMesh {
  ReaderPaperMesh({
    required this.positions,
    required this.normals,
    required this.uv,
    required this.indices,
    required this.outline,
  });

  final Float32List positions;
  final Float32List normals;
  final Float32List uv;
  final Uint16List indices;
  final Path outline;

  /// Degenerate surface parked far outside the page.
  ///
  /// The painter always draws both faces of a snapshot, even when one face is
  /// hidden, so an invisible face still needs valid vertex arrays.
  static final ReaderPaperMesh hidden = ReaderPaperMesh(
    positions: Float32List.fromList(const <double>[
      -100000,
      -100000,
      -100000,
      -100000,
      -100000,
      -100000,
    ]),
    normals: Float32List.fromList(const <double>[1, 1, 1]),
    uv: Float32List.fromList(const <double>[0, 0, 0, 0, 0, 0]),
    indices: Uint16List.fromList(const <int>[0, 1, 2]),
    outline: Path(),
  );
}

/// Pure page-turn geometry for [ReaderSpineTurn].
///
/// The sheet is modelled in canonical page coordinates: the hinge is the
/// vertical line x = 0 and the page extends towards +x. A rigid page rotates
/// by pi * [progress], with a small constant-curvature curl while it is still
/// facing the reader. The caller mirrors and translates this canonical page
/// for the left/right half of a spread.
///
/// At progress 0 the sheet covers the page; at 0.5 it is edge-on; after that
/// its projected x is negative, so the back face moves behind the hinge and
/// the incoming page is no longer obstructed.
class ReaderPaperGeometry {
  ReaderPaperGeometry({
    required this.size,
    required this.gap,
    required double progress,
    required double touchY,
  }) : progress = _clampUnit(progress, 0),
       touchY = _clampUnit(touchY, 0.5) {
    final width = size.width;
    final height = size.height;
    if (!width.isFinite ||
        !height.isFinite ||
        width <= 0 ||
        height <= 0) {
      sheet = Path();
      front = ReaderPaperMesh.hidden;
      back = ReaderPaperMesh.hidden;
      frontInk = ReaderPaperMesh.hidden;
      backInk = ReaderPaperMesh.hidden;
      lift = 0;
      return;
    }

    final theta = math.pi * this.progress;
    final liftValue = math.sin(theta);
    final curl = 0.6 + 0.4 * math.sin(math.pi * touchY);
    final bendLimit = math.max(0.0, math.pi / 2 - theta);
    final bend = this.progress < 0.5
        ? math.min(bendLimit, curl * math.sin(theta) * 0.9)
        : 0.0;
    final kappa = bend / width;

    double xAt(double distance) {
      if (kappa.abs() < 1e-6) return distance * math.cos(theta);
      return (math.sin(theta + kappa * distance) - math.sin(theta)) / kappa;
    }

    final outline = _outline(width, height, xAt);
    final mesh = _mesh(width, height, xAt, theta, kappa, outline);
    if (this.progress < 0.5) {
      sheet = outline;
      front = mesh;
      frontInk = mesh;
      back = ReaderPaperMesh.hidden;
      backInk = ReaderPaperMesh.hidden;
    } else {
      sheet = Path();
      front = ReaderPaperMesh.hidden;
      frontInk = ReaderPaperMesh.hidden;
      back = mesh;
      backInk = mesh;
    }
    lift = liftValue;
  }

  /// Canonical page size; width is the sheet's distance from the hinge.
  final Size size;

  /// Gap between the two pages of a spread, supplied by the caller.
  final double gap;

  /// Normalized turn progress in 0..1.
  final double progress;

  /// Normalized touch height used to vary the curl, in 0..1.
  final double touchY;

  /// Area the incoming page must hide behind while the sheet still covers it.
  late final Path sheet;

  /// Front face of the turning sheet, visible before the half-turn.
  late final ReaderPaperMesh front;

  /// Back face of the turning sheet, visible after the half-turn.
  late final ReaderPaperMesh back;

  /// Texture surface matching [front].
  late final ReaderPaperMesh frontInk;

  /// Texture surface matching [back].
  late final ReaderPaperMesh backInk;

  /// Shadow strength in 0..1.
  late final double lift;

  static double _clampUnit(double value, double fallback) =>
      value.isFinite ? value.clamp(0.0, 1.0).toDouble() : fallback;

  static const int _columns = 24;
  static const int _rows = 12;

  static Path _outline(
    double width,
    double height,
    double Function(double) xAt,
  ) {
    final path = Path()..moveTo(xAt(0), 0);
    for (var column = 1; column <= _columns; column++) {
      final distance = width * column / _columns;
      path.lineTo(xAt(distance), 0);
    }
    path.lineTo(xAt(width), height);
    for (var column = _columns - 1; column >= 0; column--) {
      final distance = width * column / _columns;
      path.lineTo(xAt(distance), height);
    }
    path.close();
    return path;
  }

  static ReaderPaperMesh _mesh(
    double width,
    double height,
    double Function(double) xAt,
    double theta,
    double kappa,
    Path outline,
  ) {
    final vertexColumns = _columns + 1;
    final vertexRows = _rows + 1;
    final count = vertexColumns * vertexRows;
    final positions = Float32List(count * 2);
    final normals = Float32List(count);
    final uv = Float32List(count * 2);
    var vertex = 0;
    for (var row = 0; row < vertexRows; row++) {
      final y = height * row / _rows;
      for (var column = 0; column < vertexColumns; column++) {
        final distance = width * column / _columns;
        final index = vertex * 2;
        positions[index] = xAt(distance);
        positions[index + 1] = y;
        uv[index] = distance;
        uv[index + 1] = y;
        // The out-of-plane component of the surface normal. The painter only
        // needs its magnitude, so front and back can share one mesh.
        normals[vertex] = -math.sin(theta + kappa * distance);
        vertex++;
      }
    }

    final indices = Uint16List(_columns * _rows * 6);
    var cursor = 0;
    for (var row = 0; row < _rows; row++) {
      for (var column = 0; column < _columns; column++) {
        final topLeft = row * vertexColumns + column;
        final topRight = topLeft + 1;
        final bottomLeft = topLeft + vertexColumns;
        final bottomRight = bottomLeft + 1;
        indices[cursor++] = topLeft;
        indices[cursor++] = bottomLeft;
        indices[cursor++] = topRight;
        indices[cursor++] = topRight;
        indices[cursor++] = bottomLeft;
        indices[cursor++] = bottomRight;
      }
    }
    return ReaderPaperMesh(
      positions: positions,
      normals: normals,
      uv: uv,
      indices: indices,
      outline: outline,
    );
  }
}
