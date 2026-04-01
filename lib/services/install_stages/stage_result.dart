/// Her kurulum aşamasının döndürdüğü sonuç nesnesi.
///
/// [success] aşamanın başarıyla tamamlanıp tamamlanmadığını belirtir.
/// [message] aşama hakkında kısa açıklama veya hata mesajı içerir.
class StageResult {
  const StageResult({
    required this.success,
    this.message = '',
  });

  final bool success;
  final String message;

  /// Başarılı sonuç oluşturur.
  factory StageResult.ok([String message = '']) =>
      StageResult(success: true, message: message);

  /// Başarısız sonuç oluşturur.
  factory StageResult.fail(String message) =>
      StageResult(success: false, message: message);
}
