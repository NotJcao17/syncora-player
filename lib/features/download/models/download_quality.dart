/// Calidad de audio para descargas locales en Syncora Player.
enum DownloadQuality {
  high(
    label: 'Alta',
    bitrateDescription: '~128-160 kbps',
    detail: 'La mejor que ofrece la fuente',
  ),
  medium(
    label: 'Normal',
    bitrateDescription: '~128 kbps',
    detail: 'Equilibrio óptimo de audio y espacio',
  ),
  low(
    label: 'Baja (Ahorro)',
    bitrateDescription: '~48-70 kbps',
    detail: 'Ahorro de datos y menor almacenamiento',
  );

  final String label;
  final String bitrateDescription;
  final String detail;

  const DownloadQuality({
    required this.label,
    required this.bitrateDescription,
    required this.detail,
  });

  static DownloadQuality fromString(String? val) {
    if (val == null) return DownloadQuality.high;
    return DownloadQuality.values.firstWhere(
      (e) => e.name.toLowerCase() == val.toLowerCase(),
      orElse: () => DownloadQuality.high,
    );
  }
}
