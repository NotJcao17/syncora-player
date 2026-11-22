/// Lógica pura del actualizador de la app (sin red ni disco, para tests).
///
/// La app consulta `releases/latest` del repo en GitHub, el mismo lugar del que
/// descarga la web. Detalle en `docs/fases/actualizador.md`.
library;

/// Plataformas que se pueden actualizar desde la app.
enum UpdatePlatform { android, windows }

/// Nombre del archivo del release para cada plataforma. Son los mismos que
/// enlaza la web (`releases/latest/download/...`): no cambiarlos.
const updateAssetNames = {
  UpdatePlatform.android: 'Syncora.apk',
  UpdatePlatform.windows: 'SyncoraSetup.exe',
};

/// `1.2.3` comparable. Ignora el número de build (`+6`): las etiquetas de
/// GitHub solo llevan las tres partes.
class AppVersion implements Comparable<AppVersion> {
  const AppVersion(this.major, this.minor, this.patch);

  final int major;
  final int minor;
  final int patch;

  static final _pattern = RegExp(r'^v?(\d+)\.(\d+)\.(\d+)(?:\+\d+)?$');

  /// `null` si no es una versión (p. ej. la etiqueta `engine-channel`).
  static AppVersion? tryParse(String raw) {
    final m = _pattern.firstMatch(raw.trim());
    if (m == null) return null;
    return AppVersion(int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!));
  }

  @override
  int compareTo(AppVersion other) {
    if (major != other.major) return major.compareTo(other.major);
    if (minor != other.minor) return minor.compareTo(other.minor);
    return patch.compareTo(other.patch);
  }

  bool operator >(AppVersion other) => compareTo(other) > 0;

  @override
  bool operator ==(Object other) => other is AppVersion && compareTo(other) == 0;

  @override
  int get hashCode => Object.hash(major, minor, patch);

  @override
  String toString() => '$major.$minor.$patch';
}

/// Una versión más nueva que la instalada, con el archivo de esta plataforma.
class AvailableUpdate {
  const AvailableUpdate({
    required this.version,
    required this.downloadUrl,
    required this.fileName,
    required this.size,
    required this.sha256,
    required this.pageUrl,
    required this.notes,
  });

  final AppVersion version;
  final String downloadUrl;
  final String fileName;

  /// Bytes del archivo.
  final int size;

  /// Hash que publica GitHub (`digest` del asset), en hex minúsculas. `null` si
  /// el release no lo trae: la descarga se acepta igual (va por HTTPS desde
  /// GitHub, y en Android el sistema además exige la misma firma).
  final String? sha256;

  /// Página del release en GitHub.
  final String pageUrl;

  /// Novedades escritas a mano en el release (vacío si solo trae el enlace
  /// automático de "Full Changelog").
  final String notes;
}

/// Lee la respuesta de `GET /repos/{owner}/{repo}/releases/latest`.
///
/// Devuelve `null` si no hay nada que instalar: la versión no es más nueva que
/// [current], es un borrador o pre-release, o no trae el archivo de
/// [platform] (mejor no avisar que avisar algo que no se puede descargar).
AvailableUpdate? parseLatestRelease(
  Map<String, dynamic> json, {
  required UpdatePlatform platform,
  required AppVersion current,
}) {
  if (json['draft'] == true || json['prerelease'] == true) return null;
  final tag = json['tag_name'];
  if (tag is! String) return null;
  final version = AppVersion.tryParse(tag);
  if (version == null || !(version > current)) return null;

  final wanted = updateAssetNames[platform]!;
  final assets = json['assets'];
  if (assets is! List) return null;
  for (final asset in assets) {
    if (asset is! Map || asset['name'] != wanted) continue;
    final url = asset['browser_download_url'];
    final size = asset['size'];
    if (url is! String || !url.startsWith('https://') || size is! int || size <= 0) return null;
    return AvailableUpdate(
      version: version,
      downloadUrl: url,
      fileName: wanted,
      size: size,
      sha256: _sha256From(asset['digest']),
      pageUrl: json['html_url'] is String ? json['html_url'] as String : '',
      notes: cleanReleaseNotes(json['body'] is String ? json['body'] as String : ''),
    );
  }
  return null;
}

String? _sha256From(Object? digest) {
  if (digest is! String || !digest.startsWith('sha256:')) return null;
  final hex = digest.substring('sha256:'.length).toLowerCase();
  return RegExp(r'^[0-9a-f]{64}$').hasMatch(hex) ? hex : null;
}

/// Quita lo que agrega `--generate-notes` (enlace de "Full Changelog",
/// encabezado "What's Changed", lista de PRs con su autor) y deja solo lo que
/// se escribió a mano para el usuario.
String cleanReleaseNotes(String body) {
  final lines = body.replaceAll('\r\n', '\n').split('\n').where((line) {
    final t = line.trim();
    if (t.contains('**Full Changelog**')) return false;
    if (t == "## What's Changed" || t == '## New Contributors') return false;
    if (RegExp(r'^\* .+ by @\S+ in https://').hasMatch(t)) return false;
    if (RegExp(r'^\* @\S+ made their first contribution').hasMatch(t)) return false;
    return true;
  });
  return lines.join('\n').trim();
}

/// ¿Toca consultar GitHub? Como mucho una vez cada [interval] al abrir la app
/// (el límite de la API sin cuenta es 60 consultas por hora por IP).
bool shouldCheckForUpdate({
  required DateTime now,
  required DateTime? lastCheck,
  Duration interval = const Duration(hours: 12),
}) {
  if (lastCheck == null) return true;
  // Reloj movido hacia atrás: se consulta igual.
  if (lastCheck.isAfter(now)) return true;
  return now.difference(lastCheck) >= interval;
}

/// `83.2 MB`.
String formatUpdateSize(int bytes) {
  final mb = bytes / (1024 * 1024);
  return '${mb.toStringAsFixed(mb >= 10 ? 0 : 1)} MB';
}
