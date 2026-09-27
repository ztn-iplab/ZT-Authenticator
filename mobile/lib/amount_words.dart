/// Pure, dependency-free helpers for turning a numeric monetary amount into
/// a human-readable numeral string and an English words string.
///
/// These functions are presentation-only: they never read, fetch, or infer
/// a value beyond what the caller passes in. Callers must always source
/// [amount]/[currencyCode] from an already hash-verified value (see
/// `validatedPoiaIntent` / `verifiedDisplayFields` in main.dart) so that
/// anything rendered with these helpers still corresponds exactly to the
/// signed PoIA intent.
library amount_words;

/// Never round a signed value. Unsupported number syntax remains numeric-only.
String? exactAmountWords(String raw, String currency) {
  final match = RegExp(r'^(-?)(\d{1,15})(?:\.(\d{1,12}))?$').firstMatch(raw);
  final info = _currencies[currency.toUpperCase()];
  if (match == null || info == null) return null;
  final whole = int.parse(match[2]!);
  final fraction = match[3] ?? '';
  final fractional = fraction.isNotEmpty && RegExp(r'[1-9]').hasMatch(fraction);
  final sign = match[1] == '-' ? 'negative ' : '';
  final decimal = fractional
      ? ' point ${fraction.split('').map((digit) => _ones[int.parse(digit)]).join(' ')}'
      : '';
  final unit = whole == 1 && !fractional ? info.singular : info.plural;
  return _capitalize('$sign${integerToWords(whole)}$decimal $unit');
}

class _CurrencyInfo {
  const _CurrencyInfo({
    required this.singular,
    required this.plural,
    this.symbol,
    this.decimalDigits = 2,
  });

  final String singular;
  final String plural;
  final String? symbol;
  final int decimalDigits;

  // No currency below currently needs subunit names other than the
  // ordinary English "cent"/"cents", so these aren't constructor
  // parameters (an unused optional parameter is itself an analyzer
  // warning). Add real per-currency subunit names here if one is needed.
  String get subunitSingular => 'cent';
  String get subunitPlural => 'cents';
}

const Map<String, _CurrencyInfo> _currencies = {
  'USD': _CurrencyInfo(
      singular: 'US dollar', plural: 'US dollars', symbol: '\$'),
  'EUR': _CurrencyInfo(singular: 'euro', plural: 'euros', symbol: '€'),
  'GBP': _CurrencyInfo(
      singular: 'British pound', plural: 'British pounds', symbol: '£'),
  'JPY': _CurrencyInfo(
      singular: 'Japanese yen',
      plural: 'Japanese yen',
      symbol: '¥',
      decimalDigits: 0),
  'CNY': _CurrencyInfo(
      singular: 'Chinese yuan', plural: 'Chinese yuan', symbol: '¥'),
  'CHF': _CurrencyInfo(singular: 'Swiss franc', plural: 'Swiss francs'),
  'CAD': _CurrencyInfo(
      singular: 'Canadian dollar', plural: 'Canadian dollars', symbol: 'CA\$'),
  'AUD': _CurrencyInfo(
      singular: 'Australian dollar',
      plural: 'Australian dollars',
      symbol: 'A\$'),
  'INR': _CurrencyInfo(
      singular: 'Indian rupee', plural: 'Indian rupees', symbol: '₹'),
  'KRW': _CurrencyInfo(
      singular: 'South Korean won',
      plural: 'South Korean won',
      symbol: '₩',
      decimalDigits: 0),
};

const List<String> _ones = [
  'zero', 'one', 'two', 'three', 'four', 'five', 'six', 'seven', 'eight',
  'nine', 'ten', 'eleven', 'twelve', 'thirteen', 'fourteen', 'fifteen',
  'sixteen', 'seventeen', 'eighteen', 'nineteen',
];
const List<String> _tens = [
  '', '', 'twenty', 'thirty', 'forty', 'fifty', 'sixty', 'seventy',
  'eighty', 'ninety',
];
const List<String> _scales = ['', ' thousand', ' million', ' billion', ' trillion'];

String _threeDigitsToWords(int value) {
  var n = value;
  final parts = <String>[];
  if (n >= 100) {
    parts.add('${_ones[n ~/ 100]} hundred');
    n %= 100;
    if (n > 0) {
      parts.add('and');
    }
  }
  if (n >= 20) {
    final tens = _tens[n ~/ 10];
    final rem = n % 10;
    parts.add(rem > 0 ? '$tens-${_ones[rem]}' : tens);
  } else if (n > 0) {
    parts.add(_ones[n]);
  }
  return parts.join(' ');
}

/// Converts a non-negative (or negative) integer into English words, e.g.
/// `integerToWords(150000)` -> `"one hundred and fifty thousand"`.
String integerToWords(int value) {
  if (value == 0) {
    return 'zero';
  }
  if (value < 0) {
    return 'negative ${integerToWords(-value)}';
  }
  final groups = <int>[];
  var remaining = value;
  while (remaining > 0) {
    groups.add(remaining % 1000);
    remaining ~/= 1000;
  }
  final parts = <String>[];
  for (var i = groups.length - 1; i >= 0; i--) {
    if (groups[i] == 0) {
      continue;
    }
    final scale = i < _scales.length ? _scales[i] : ' (10^${i * 3})';
    parts.add('${_threeDigitsToWords(groups[i])}$scale');
  }
  return parts.join(' ');
}

String _capitalize(String value) {
  if (value.isEmpty) {
    return value;
  }
  return '${value[0].toUpperCase()}${value.substring(1)}';
}

String _digitsGrouped(int value) {
  final negative = value < 0;
  final digits = value.abs().toString();
  final buffer = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) {
      buffer.write(',');
    }
    buffer.write(digits[i]);
  }
  return negative ? '-$buffer' : buffer.toString();
}

_CurrencyInfo _infoFor(String currencyCode) {
  final code = currencyCode.trim().toUpperCase();
  return _currencies[code] ??
      _CurrencyInfo(singular: code, plural: code, decimalDigits: 2);
}

int _pow10(int exponent) {
  var result = 1;
  for (var i = 0; i < exponent; i++) {
    result *= 10;
  }
  return result;
}

/// Splits [amount] into whole and fractional currency-minor-unit parts
/// according to the currency's usual number of decimal digits, rounding
/// once to avoid floating point artifacts (e.g. 19.999999999999996).
class _SplitAmount {
  const _SplitAmount(this.whole, this.fraction);
  final int whole;
  final int fraction;
}

_SplitAmount _splitAmount(num amount, int decimalDigits) {
  final divisor = _pow10(decimalDigits);
  final totalMinorUnits = (amount * divisor).round();
  final whole = totalMinorUnits ~/ divisor;
  final fraction = (totalMinorUnits % divisor).abs();
  return _SplitAmount(whole, fraction);
}

/// Formats [amount] as a numeral string with the currency's usual symbol
/// (or code) and thousands separators, e.g.
/// `formatCurrencyAmount(150000, 'JPY')` -> `"¥150,000"`.
String formatCurrencyAmount(num amount, String currencyCode) {
  final info = _infoFor(currencyCode);
  final split = _splitAmount(amount, info.decimalDigits);
  final wholeText = _digitsGrouped(split.whole);
  final numeral = info.decimalDigits == 0
      ? wholeText
      : '$wholeText.${split.fraction.toString().padLeft(info.decimalDigits, '0')}';
  if (info.symbol != null) {
    return '${info.symbol}$numeral';
  }
  return '$numeral ${currencyCode.trim().toUpperCase()}';
}

/// Renders [amount] in English words with the currency name, e.g.
/// `amountToWords(150000, 'JPY')` ->
/// `"One hundred and fifty thousand Japanese yen"`.
String amountToWords(num amount, String currencyCode) {
  final info = _infoFor(currencyCode);
  final split = _splitAmount(amount, info.decimalDigits);
  final wholeWords = integerToWords(split.whole);
  final currencyName = split.whole == 1 ? info.singular : info.plural;
  var result = '${_capitalize(wholeWords)} $currencyName';
  if (info.decimalDigits > 0 && split.fraction > 0) {
    final fractionWords = integerToWords(split.fraction);
    final subunitName =
        split.fraction == 1 ? info.subunitSingular : info.subunitPlural;
    result += ' and $fractionWords $subunitName';
  }
  return result;
}
