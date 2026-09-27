import 'dart:async';

import 'package:flutter/material.dart';

import 'amount_words.dart';
import 'zt_theme.dart';

/// Uses the verified absolute deadline, so delayed rendering or app suspension
/// never restarts the validity window. Server-side expiry remains authoritative.
class PoiaExpiryCountdown extends StatefulWidget {
  const PoiaExpiryCountdown({
    super.key,
    required this.expiresAt,
    this.now = DateTime.now,
  });

  final int expiresAt;
  final DateTime Function() now;

  @override
  State<PoiaExpiryCountdown> createState() => _PoiaExpiryCountdownState();
}

class _PoiaExpiryCountdownState extends State<PoiaExpiryCountdown>
    with WidgetsBindingObserver {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && mounted) setState(() {});
  }

  @override
  void dispose() {
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final remaining =
        ((widget.expiresAt * 1000 - widget.now().millisecondsSinceEpoch) / 1000)
            .ceil();
    return Text(
      remaining > 0 ? 'Expires in: ${remaining}s' : 'Expired',
      style: const TextStyle(
        color: ZtIamColors.textPrimary,
        fontSize: 13,
        fontWeight: FontWeight.w600,
      ),
    );
  }
}

/// SECURITY NOTE: everything in this file is presentation-only. It never
/// fetches, resolves, or invents a field value on its own -- every widget
/// here only reformats, groups, and re-orders the (label, value) pairs it
/// is given by [PoiaIntentSummary.displayFields], which the caller must
/// derive from the hash-verified intent object via
/// `verifiedDisplayFields(intentRaw)` (see main.dart). No value shown here
/// can therefore diverge from the exact intent object that is signed.
/// Canonicalization, hashing, signing, nonce handling and verification all
/// live in main.dart and are untouched by this file.
class PoiaFieldGroups {
  const PoiaFieldGroups({
    this.actionField,
    this.recipientField,
    this.amountField,
    this.currencyField,
    this.accountFields = const [],
    this.purposeFields = const [],
    this.otherFields = const [],
  });

  final MapEntry<String, String>? actionField;
  final MapEntry<String, String>? recipientField;
  final MapEntry<String, String>? amountField;
  final MapEntry<String, String>? currencyField;
  final List<MapEntry<String, String>> accountFields;
  final List<MapEntry<String, String>> purposeFields;
  final List<MapEntry<String, String>> otherFields;
}

const Set<String> _recipientPrimaryKeys = {
  'recipient',
  'beneficiary name',
  'external account',
  'target user',
  'patient id',
};
// Only used as a recipient identity when no name-bearing field (above) is
// present on the signed intent -- otherwise it's still shown in full, just
// under Account / resource instead of the headline recipient slot.
const String _recipientFallbackKey = 'beneficiary id';
const Set<String> _accountKeys = {
  'from account',
  'to account',
  'account',
  'account id',
  'target object',
  'new daily limit',
};
const Set<String> _purposeKeys = {'purpose'};

/// Buckets an already-verified, flattened field list (as produced by
/// `verifiedDisplayFields` in main.dart) into presentation groups purely for
/// layout and ordering. Every input field ends up in exactly one output
/// bucket, unchanged -- nothing is dropped, resolved, or replaced.
PoiaFieldGroups classifyPoiaFields(List<MapEntry<String, String>> fields) {
  MapEntry<String, String>? actionField;
  MapEntry<String, String>? recipientField;
  MapEntry<String, String>? recipientFallback;
  MapEntry<String, String>? amountField;
  MapEntry<String, String>? currencyField;
  final accountFields = <MapEntry<String, String>>[];
  final purposeFields = <MapEntry<String, String>>[];
  final otherFields = <MapEntry<String, String>>[];

  for (final field in fields) {
    final key = field.key.trim().toLowerCase();
    if (actionField == null && key == 'action') {
      actionField = field;
    } else if (amountField == null && key == 'amount') {
      amountField = field;
    } else if (currencyField == null && key == 'currency') {
      currencyField = field;
    } else if (recipientField == null && _recipientPrimaryKeys.contains(key)) {
      recipientField = field;
    } else if (recipientFallback == null && key == _recipientFallbackKey) {
      recipientFallback = field;
    } else if (_accountKeys.contains(key) ||
        key.startsWith('committed resource')) {
      accountFields.add(field);
    } else if (_purposeKeys.contains(key)) {
      purposeFields.add(field);
    } else {
      otherFields.add(field);
    }
  }

  if (recipientFallback != null) {
    if (recipientField == null) {
      recipientField = recipientFallback;
    } else {
      accountFields.add(recipientFallback);
    }
  }

  return PoiaFieldGroups(
    actionField: actionField,
    recipientField: recipientField,
    amountField: amountField,
    currencyField: currencyField,
    accountFields: accountFields,
    purposeFields: purposeFields,
    otherFields: otherFields,
  );
}

String titleCaseField(String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty) {
    return value;
  }
  return trimmed
      .split(' ')
      .map((word) =>
          word.isEmpty ? word : '${word[0].toUpperCase()}${word.substring(1)}')
      .join(' ');
}

/// Compact caption for an avatar: the local part of an email (before "@"),
/// or the first word of a plain name/id, e.g. "dolly@bank.test" -> "dolly",
/// "Kanani Doe" -> "Kanani". The avatar caption is only ever a shortened
/// form for the visual -- the full, untruncated signed value is always
/// shown in the detail line beneath it too.
String shortDisplayName(String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty) {
    return trimmed;
  }
  final base = trimmed.contains('@') ? trimmed.split('@').first : trimmed;
  final words =
      base.split(RegExp(r'[\s._-]+')).where((word) => word.isNotEmpty);
  return words.isEmpty ? base : words.first;
}

/// Readable, prioritized, once-only-animated presentation of a signed PoIA
/// intent, shown inside the approval dialog in main.dart.
///
/// Visual priority follows: 1) action, 2) recipient (with a sender/recipient
/// direction row for transfer-like intents), 3) amount, 4) account/resource,
/// 5) purpose, 6) everything else (validity constraints and similar).
///
/// [displayVariant] is Dataset 2 of the PoIA human-subjects study: a
/// between-subjects comparison of this redesigned, classified/grouped layout
/// ('redesigned', the default) against the plain, one-field-per-row layout
/// that existed before the redesign ('legacy'). Both arms render the
/// identical verified field set from the identical signed intent -- only the
/// layout differs -- so the comparison isn't confounded by a difference in
/// what information is shown. Every real (non-study) caller omits this
/// parameter and always gets the current 'redesigned' behavior, unchanged.
class PoiaIntentSummary extends StatefulWidget {
  const PoiaIntentSummary({
    super.key,
    required this.displayFields,
    this.youLabel = 'You',
    this.displayVariant = 'redesigned',
  });

  final List<MapEntry<String, String>> displayFields;
  final String youLabel;

  /// 'redesigned' (default) or 'legacy'. See the class doc comment above.
  final String displayVariant;

  @override
  State<PoiaIntentSummary> createState() => _PoiaIntentSummaryState();
}

class _PoiaIntentSummaryState extends State<PoiaIntentSummary>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _fade;
  late final Animation<double> _slide;
  late final Animation<double> _emphasis;

  @override
  void initState() {
    super.initState();
    // A single, non-repeating entrance animation: it plays once when the
    // dialog opens and then stops. It never loops and never flashes.
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 420),
    );
    _fade = CurvedAnimation(parent: _controller, curve: Curves.easeOut);
    _slide = Tween<double>(begin: 10, end: 0)
        .animate(CurvedAnimation(parent: _controller, curve: Curves.easeOut));
    _emphasis = CurvedAnimation(
      parent: _controller,
      curve: const Interval(0.0, 0.75, curve: Curves.easeOut),
    );
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    if (reduceMotion) _controller.value = 1;

    if (widget.displayVariant == 'legacy') {
      // Dataset 2 study arm: the plain, pre-redesign presentation -- no
      // field classification, no avatar row, no amount card. Every field
      // from the verified intent, in its original order, one per row.
      return AnimatedBuilder(
        animation: _controller,
        builder: (context, child) {
          return Opacity(
            opacity: _fade.value,
            child: Transform.translate(
              offset: Offset(0, _slide.value),
              child: child,
            ),
          );
        },
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            _ActionHeader(field: null, emphasis: _emphasis),
            const SizedBox(height: 14),
            _FieldSection(
              stacked: true,
              title: "What you're approving",
              icon: Icons.list_alt_outlined,
              fields: widget.displayFields,
              valueFontSize: 17,
            ),
          ],
        ),
      );
    }

    final groups = classifyPoiaFields(widget.displayFields);
    final showTransferRow =
        groups.recipientField != null && groups.amountField != null &&
        (groups.actionField?.value.toLowerCase().contains('transfer') ?? false);

    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return Opacity(
          opacity: _fade.value,
          child: Transform.translate(
            offset: Offset(0, _slide.value),
            child: child,
          ),
        );
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          _ActionHeader(field: groups.actionField, emphasis: _emphasis),
          if (showTransferRow) ...[
            const SizedBox(height: 14),
            _TransferDirectionRow(
              youLabel: widget.youLabel,
              recipientField: groups.recipientField!,
              controller: _controller,
              emphasis: _emphasis,
              reduceMotion: reduceMotion,
            ),
          ] else if (groups.recipientField != null) ...[
            const SizedBox(height: 14),
            _EmphasizedFieldRow(
              icon: Icons.person_outline,
              field: groups.recipientField!,
              emphasis: _emphasis,
            ),
          ],
          if (groups.amountField != null) ...[
            const SizedBox(height: 14),
            _AmountCard(
              amountField: groups.amountField!,
              currencyField: groups.currencyField,
              emphasis: _emphasis,
            ),
          ],
          if (groups.amountField == null && groups.currencyField != null)
            _FieldSection(title: 'Currency', icon: Icons.payments_outlined,
                fields: [groups.currencyField!], valueFontSize: 18),
          if (groups.accountFields.isNotEmpty) ...[
            const SizedBox(height: 14),
            _FieldSection(
              title: 'Account / resource',
              icon: Icons.account_balance_outlined,
              fields: groups.accountFields,
              valueFontSize: 18,
            ),
          ],
          if (groups.purposeFields.isNotEmpty) ...[
            const SizedBox(height: 12),
            _FieldSection(
              title: 'Purpose',
              icon: Icons.notes_outlined,
              fields: groups.purposeFields,
              valueFontSize: 18,
            ),
          ],
          if (groups.otherFields.isNotEmpty) ...[
            const SizedBox(height: 12),
            _FieldSection(
              title: 'Other validity constraints',
              icon: Icons.rule_outlined,
              fields: groups.otherFields,
              valueFontSize: 17,
            ),
          ],
        ],
      ),
    );
  }
}

class _ActionHeader extends StatelessWidget {
  const _ActionHeader({required this.field, required this.emphasis});

  final MapEntry<String, String>? field;
  final Animation<double> emphasis;

  @override
  Widget build(BuildContext context) {
    final label = field?.value ?? 'Sign intent';
    return AnimatedBuilder(
      animation: emphasis,
      builder: (context, _) {
        final t = emphasis.value.clamp(0.0, 1.0);
        return Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
          decoration: BoxDecoration(
            color: Color.lerp(
              ZtIamColors.accentBlue.withValues(alpha: 0.20),
              Colors.transparent,
              t,
            ),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.verified_user_outlined,
                  color: ZtIamColors.accentSoft, size: 22),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Action',
                        style:
                            TextStyle(color: ZtIamColors.textSecondary, fontSize: 12)),
                    const SizedBox(height: 2),
                    Text(
                      label,
                      style: const TextStyle(
                        fontSize: 21,
                        fontWeight: FontWeight.w700,
                        color: ZtIamColors.textPrimary,
                        height: 1.2,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _PersonAvatar extends StatelessWidget {
  const _PersonAvatar({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    // FittedBox lets this shrink gracefully instead of overflowing when a
    // narrow screen gives it less than its natural size.
    return FittedBox(
      fit: BoxFit.scaleDown,
      child: CircleAvatar(
        radius: 26,
        backgroundColor: Color.lerp(color, Colors.white, 0.78),
        child: const Icon(Icons.person_rounded, color: Color(0xFF15232D), size: 38),
      ),
    );
  }
}

/// Sender -> recipient visual for transfer-like intents: two simple person
/// avatars, each captioned with a short name derived from the sender's
/// enrolled identity and the recipient field on the signed intent (e.g.
/// "dolly" -> "kanani"), joined by a brief directional cue. The recipient
/// caption appears only under its avatar to keep the display compact.
class _TransferDirectionRow extends StatefulWidget {
  const _TransferDirectionRow({
    required this.youLabel,
    required this.recipientField,
    required this.controller,
    required this.emphasis,
    required this.reduceMotion,
  });

  final String youLabel;
  final MapEntry<String, String> recipientField;
  final AnimationController controller;
  final Animation<double> emphasis;
  final bool reduceMotion;

  @override
  State<_TransferDirectionRow> createState() => _TransferDirectionRowState();
}

class _TransferDirectionRowState extends State<_TransferDirectionRow>
    with SingleTickerProviderStateMixin {
  late final AnimationController _flowController;

  @override
  void initState() {
    super.initState();
    // A single gentle entrance cue, with no repeating animation.
    _flowController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    );
    if (widget.reduceMotion) {
      _flowController.value = 0.5;
    } else {
      _flowController.forward();
    }
  }

  @override
  void dispose() {
    _flowController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final arrowAnim = CurvedAnimation(
      parent: widget.controller,
      curve: const Interval(0.25, 0.9, curve: Curves.easeOut),
    );
    final recipientCaption = shortDisplayName(widget.recipientField.value);
    return AnimatedBuilder(
      animation: widget.emphasis,
      builder: (context, _) {
        final t = widget.emphasis.value.clamp(0.0, 1.0);
        return Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          decoration: BoxDecoration(
            color: Color.lerp(
              ZtIamColors.accentBlue.withValues(alpha: 0.14),
              Colors.transparent,
              t,
            ),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(flex: 2, child: Column(
                    children: [
                      const _PersonAvatar(color: ZtIamColors.accentBlue),
                      const SizedBox(height: 6),
                      Text(
                        shortDisplayName(widget.youLabel),
                        textAlign: TextAlign.center,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: ZtIamColors.textPrimary, fontSize: 16,
                            fontWeight: FontWeight.w700, height: 1.15),
                      ),
                    ],
                  )),
                  Expanded(
                    child: SizedBox(
                      height: 26,
                      child: AnimatedBuilder(
                        animation: Listenable.merge(
                            [arrowAnim, _flowController]),
                        builder: (context, _) {
                          // Entrance fade (arrowAnim) gates the whole cue
                          // in once; within that, _flowController drives
                          // the continuous back-and-forth drift.
                          final entrance = arrowAnim.value.clamp(0.0, 1.0);
                          final flowT = _flowController.value;
                          final drift =
                              flowT < 0.5 ? flowT / 0.5 : (1 - flowT) / 0.5;
                          return LayoutBuilder(
                            builder: (context, constraints) {
                              final travel =
                                  (constraints.maxWidth - 18).clamp(0.0, 1000.0);
                              return Opacity(
                                opacity: entrance,
                                child: Stack(
                                  alignment: Alignment.centerLeft,
                                  children: [
                                    Container(
                                      height: 2,
                                      color: ZtIamColors.divider,
                                    ),
                                    Positioned(
                                      left: drift * travel,
                                      child: Opacity(
                                        opacity: (0.35 + 0.65 * drift)
                                            .clamp(0.0, 1.0),
                                        child: const Icon(
                                          Icons.arrow_forward,
                                          color: ZtIamColors.accentSoft,
                                          size: 18,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              );
                            },
                          );
                        },
                      ),
                    ),
                  ),
                  Expanded(flex: 2, child: Column(
                    children: [
                      const _PersonAvatar(color: ZtIamColors.accentGreen),
                      const SizedBox(height: 6),
                      // The recipient caption is the ONLY place the
                      // recipient value is rendered (no repeat further
                      // down) -- it stays wide enough and allows a second
                      // line so realistic values are fully readable, with
                      // ellipsis only as a last resort for pathological
                      // ones. The underlying value is unchanged either
                      // way: this is the exact recipientField from the
                      // signed intent, just laid out compactly.
                      SizedBox(
                        width: double.infinity,
                        child: Text(
                          recipientCaption.isEmpty
                              ? widget.recipientField.value
                              : recipientCaption,
                          textAlign: TextAlign.center,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: ZtIamColors.textPrimary, fontSize: 16,
                              fontWeight: FontWeight.w700, height: 1.15),
                        ),
                      ),
                    ],
                  )),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

class _EmphasizedFieldRow extends StatelessWidget {
  const _EmphasizedFieldRow({
    required this.icon,
    required this.field,
    required this.emphasis,
  });

  final IconData icon;
  final MapEntry<String, String> field;
  final Animation<double> emphasis;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: emphasis,
      builder: (context, _) {
        final t = emphasis.value.clamp(0.0, 1.0);
        return Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 10),
          decoration: BoxDecoration(
            color: Color.lerp(
              ZtIamColors.accentBlue.withValues(alpha: 0.16),
              Colors.transparent,
              t,
            ),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 20, color: ZtIamColors.accentSoft),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(titleCaseField(field.key),
                        style: const TextStyle(
                            color: ZtIamColors.textSecondary, fontSize: 12)),
                    const SizedBox(height: 2),
                    Text(
                      field.value,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        color: ZtIamColors.textPrimary,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Prominent numeric + words amount display. Both the numeral and the words
/// form are derived only from [amountField]/[currencyField], which the
/// caller sources from the verified intent -- no currency or amount is ever
/// guessed. If the amount cannot be parsed as a number, or no currency was
/// present on the signed intent, the raw signed value is shown as-is instead
/// of a reformatted/guessed one.
class _AmountCard extends StatelessWidget {
  const _AmountCard({
    required this.amountField,
    required this.currencyField,
    required this.emphasis,
  });

  final MapEntry<String, String> amountField;
  final MapEntry<String, String>? currencyField;
  final Animation<double> emphasis;

  @override
  Widget build(BuildContext context) {
    final currency = currencyField?.value.trim();
    final numeralText = '${amountField.value}${currency == null ? '' : ' $currency'}';
    final wordsText = currency == null ? null : exactAmountWords(amountField.value, currency);

    return AnimatedBuilder(
      animation: emphasis,
      builder: (context, _) {
        final t = emphasis.value.clamp(0.0, 1.0);
        return Container(
          width: double.infinity,
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: Color.lerp(
              ZtIamColors.accentGreen.withValues(alpha: 0.20),
              ZtIamColors.card,
              t,
            ),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: ZtIamColors.inputBorder),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Amount',
                  style: TextStyle(color: ZtIamColors.textSecondary, fontSize: 12)),
              const SizedBox(height: 4),
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(
                  numeralText,
                  style: const TextStyle(
                    fontSize: 32,
                    fontWeight: FontWeight.w800,
                    color: ZtIamColors.textPrimary,
                  ),
                ),
              ),
              if (wordsText != null) ...[
                const SizedBox(height: 6),
                Text(
                  wordsText,
                  style: const TextStyle(
                    fontSize: 17,
                    color: ZtIamColors.textPrimary,
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

class _FieldSection extends StatelessWidget {
  const _FieldSection({
    required this.title,
    required this.icon,
    required this.fields,
    this.valueFontSize = 15,
    this.stacked = false,
  });

  final String title;
  final IconData icon;
  final List<MapEntry<String, String>> fields;
  final double valueFontSize;

  // false (default): the compact, redesigned packing -- each field is a
  // single "Label: Value" line and Wrap packs as many of those onto each
  // row as fit. true: the plain, pre-redesign presentation (PoIA study
  // Dataset 2's 'legacy' arm) -- every field gets its own full-width row,
  // label above value, separated by a thin divider.
  final bool stacked;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, size: 15, color: ZtIamColors.textMuted),
            const SizedBox(width: 6),
            Expanded(child: Text(
              title.toUpperCase(),
              style: const TextStyle(
                color: ZtIamColors.textMuted,
                fontSize: 14,
                letterSpacing: 0,
                fontWeight: FontWeight.w600,
              ),
            )),
          ],
        ),
        const SizedBox(height: 6),
        if (stacked)
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var i = 0; i < fields.length; i++) ...[
                if (i > 0) ...[
                  const SizedBox(height: 8),
                  const Divider(height: 1, color: ZtIamColors.divider),
                  const SizedBox(height: 8),
                ],
                Text(
                  titleCaseField(fields[i].key).toUpperCase(),
                  style: const TextStyle(
                    color: ZtIamColors.textSecondary,
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  fields[i].value,
                  style: TextStyle(
                    color: ZtIamColors.textPrimary,
                    fontSize: valueFontSize,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ],
          )
        else
          // Each field renders as a single "Label: Value" line instead of a
          // label line stacked above a value line, and Wrap packs as many of
          // those single-line fields onto each row as fit (e.g. "From
          // Account: 37" next to "Bank: PoIA Bank") instead of giving every
          // field its own full-width row -- this is what keeps the intent
          // summary compact enough to fit on screen without scrolling.
          Wrap(
            spacing: 20,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: fields
                .map(
                  (field) => Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: '${titleCaseField(field.key)}: ',
                          style: const TextStyle(
                            color: ZtIamColors.textSecondary,
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        TextSpan(
                          text: field.value,
                          style: TextStyle(
                            color: ZtIamColors.textPrimary,
                            fontSize: valueFontSize,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                )
                .toList(growable: false),
          ),
      ],
    );
  }
}
