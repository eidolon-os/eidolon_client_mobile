class SetupTrustException implements Exception {
  const SetupTrustException(this.message);

  final String message;

  @override
  String toString() => message;
}
