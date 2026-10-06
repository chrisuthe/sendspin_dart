// ABOUTME: Type-checked accessors for fields of decoded JSON payloads.
// ABOUTME: A field of the wrong type reads as absent instead of throwing.

/// [value] if it is a string, else null.
String? jsonString(Object? value) => value is String ? value : null;

/// [value] if it is a boolean, else null.
bool? jsonBool(Object? value) => value is bool ? value : null;

/// [value] as an integer, or null. A whole-number double such as `48000.0`
/// is accepted; fractions, infinities and NaN are not.
int? jsonInt(Object? value) {
  if (value is int) return value;
  if (value is double && value.isFinite && value == value.truncateToDouble()) {
    return value.toInt();
  }
  return null;
}

/// [value] if it is a JSON object, else null.
Map<String, dynamic>? jsonObject(Object? value) =>
    value is Map<String, dynamic> ? value : null;

/// [value] if it is a JSON array, else null.
List<dynamic>? jsonList(Object? value) => value is List ? value : null;
