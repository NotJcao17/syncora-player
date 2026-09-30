/// ¿[value] es una ruta de archivo local y no una URL, un degradado o un color?
///
/// Las portadas propias en modo local se guardan como ruta absoluta del
/// dispositivo: `/data/user/0/…` en Android y `C:\Users\…` en Windows. Antes
/// solo se reconocía el formato de Android, así que en Windows la ruta se
/// trataba como URL y la imagen no cargaba.
bool isLocalImagePath(String value) {
  if (value.isEmpty) return false;
  return value.startsWith('/') ||
      value.startsWith('file://') ||
      value.startsWith(r'\\') ||
      RegExp(r'^[A-Za-z]:[\\/]').hasMatch(value);
}

/// Ruta sin el prefijo `file://`, lista para `File(...)`.
String localImageFilePath(String value) =>
    value.startsWith('file://') ? Uri.parse(value).toFilePath() : value;
