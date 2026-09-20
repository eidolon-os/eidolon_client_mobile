import 'dart:math' as math;
import 'dart:ui' show FontFeature, PointMode;

import 'package:flutter/material.dart';

/// The one visual language for every Mobile surface.
///
/// Three rules hold the system together:
///
/// 1. **Accent is ink, not paint.** The cyan is spent on hairlines, glyphs,
///    glows and a single gradient call-to-action per screen. Large flat fills
///    of a saturated hue are what made the app look unfinished.
/// 2. **Technical values are monospaced.** Addresses, identifiers, counts and
///    timestamps are instrument readouts, so they get tabular figures and a
///    dimmer ink than prose. It is the cheapest way to read as engineering.
/// 3. **One spacing and type scale.** Sizes step 11 / 12.5 / 14 / 15.5 / 18 /
///    21 / 26, spacing steps by 4. Nothing in between.
class Neon {
  const Neon._();

  // ---- Ground -------------------------------------------------------------
  /// Deep blue-black. Slightly blue rather than violet so the violet aurora
  /// above it reads as light rather than as the base colour.
  static const void_ = Color(0xFF060912);
  static const surface = Color(0xFF0C111F);
  static const surfaceHigh = Color(0xFF131A2C);

  /// Panel fill for cards floating over the backdrop.
  static const surfaceGlass = Color(0xE60D1324);

  // ---- Accents ------------------------------------------------------------
  /// Softer and richer than a pure neon cyan, which turns acid at large sizes.
  static const cyan = Color(0xFF3AD9F0);
  static const cyanSoft = Color(0xFF7FE9F8);
  static const indigo = Color(0xFF6E7BF2);
  static const purple = Color(0xFFA78BFA);
  static const magenta = Color(0xFFF472B6);

  // ---- Semantic -----------------------------------------------------------
  static const ok = Color(0xFF34D399);
  static const warn = Color(0xFFFBBF24);
  static const bad = Color(0xFFFB7185);

  // ---- Ink ----------------------------------------------------------------
  static const ink = Color(0xFFE9EEFC);
  static const inkDim = Color(0xFF94A1C6);
  static const inkFaint = Color(0xFF5E688C);
  static const onCyan = Color(0xFF05101C);

  // ---- Lines --------------------------------------------------------------
  static const hair = Color(0x14FFFFFF);
  static const hairStrong = Color(0x5C3AD9F0);

  // ---- Scale --------------------------------------------------------------
  static const s1 = 4.0;
  static const s2 = 8.0;
  static const s3 = 12.0;
  static const s4 = 16.0;
  static const s5 = 20.0;
  static const s6 = 24.0;
  static const s7 = 32.0;

  static const radiusS = 12.0;
  static const radiusM = 16.0;
  static const radiusL = 22.0;

  /// The single gradient every primary action wears.
  static const accentGradient = [cyan, indigo];
  static const dangerGradient = [Color(0xFFF87186), Color(0xFFB4456F)];

  /// Panel fill: lit from the top-left, so a stack of cards has depth without
  /// a drop shadow smearing the backdrop behind it.
  static const panelGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xF2141C31), Color(0xF20A0F1D)],
  );

  static List<BoxShadow> glow(Color color,
          {double blur = 18, double alpha = .35}) =>
      [BoxShadow(color: color.withValues(alpha: alpha), blurRadius: blur)];

  static const List<String> _monoFallback = <String>[
    'monospace',
    'Menlo',
    'Roboto Mono',
    'Courier New',
  ];

  /// Instrument type: tabular figures, so a value that ticks does not shove
  /// its neighbours sideways.
  static TextStyle mono({
    double size = 12,
    FontWeight weight = FontWeight.w600,
    Color color = inkDim,
    double tracking = .2,
    double height = 1.5,
  }) =>
      TextStyle(
        fontFamily: 'monospace',
        fontFamilyFallback: _monoFallback,
        fontSize: size,
        fontWeight: weight,
        color: color,
        letterSpacing: tracking,
        height: height,
        fontFeatures: const [FontFeature.tabularFigures()],
      );

  /// Small tracked uppercase label that sits above a title.
  static TextStyle eyebrow({Color color = cyan}) => TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w700,
        color: color,
        letterSpacing: 1.6,
        height: 1.2,
      );
}

class EidolonTheme {
  const EidolonTheme._();

  static ThemeData dark() {
    const scheme = ColorScheme(
      brightness: Brightness.dark,
      primary: Neon.cyan,
      onPrimary: Neon.onCyan,
      primaryContainer: Color(0xFF0E3440),
      onPrimaryContainer: Neon.cyanSoft,
      secondary: Neon.indigo,
      onSecondary: Colors.white,
      secondaryContainer: Color(0xFF1E2447),
      onSecondaryContainer: Color(0xFFC7CEFF),
      tertiary: Neon.purple,
      onTertiary: Colors.white,
      tertiaryContainer: Color(0xFF241B45),
      onTertiaryContainer: Color(0xFFE2D5FF),
      error: Neon.bad,
      onError: Color(0xFF2A0710),
      errorContainer: Color(0xFF3A1220),
      onErrorContainer: Color(0xFFFFC2CE),
      surface: Neon.surface,
      onSurface: Neon.ink,
      surfaceDim: Neon.void_,
      surfaceBright: Color(0xFF1A2138),
      surfaceContainerLowest: Neon.void_,
      surfaceContainerLow: Color(0xFF090D19),
      surfaceContainer: Neon.surface,
      surfaceContainerHigh: Neon.surfaceHigh,
      surfaceContainerHighest: Color(0xFF1A2138),
      onSurfaceVariant: Neon.inkDim,
      outline: Color(0xFF3A4260),
      outlineVariant: Color(0xFF232A42),
      shadow: Colors.black,
      scrim: Colors.black,
      inverseSurface: Neon.ink,
      onInverseSurface: Neon.void_,
      inversePrimary: Color(0xFF00707A),
      surfaceTint: Colors.transparent,
    );

    final base = ThemeData(
      colorScheme: scheme,
      useMaterial3: true,
      brightness: Brightness.dark,
    );

    // One scale, no in-between sizes. Chinese body copy gets a 1.6 line height
    // so dense paragraphs stop looking like a wall.
    final t = base.textTheme;
    final textTheme = t.copyWith(
      displayLarge: t.displayLarge?.copyWith(
          fontSize: 34,
          fontWeight: FontWeight.w800,
          letterSpacing: -1,
          color: Colors.white),
      displayMedium: t.displayMedium?.copyWith(
          fontSize: 30,
          fontWeight: FontWeight.w800,
          letterSpacing: -.8,
          color: Colors.white),
      displaySmall: t.displaySmall?.copyWith(
          fontSize: 26,
          fontWeight: FontWeight.w800,
          letterSpacing: -.6,
          color: Colors.white),
      headlineLarge: t.headlineLarge?.copyWith(
          fontSize: 26,
          fontWeight: FontWeight.w800,
          letterSpacing: -.6,
          height: 1.25,
          color: Colors.white),
      headlineMedium: t.headlineMedium?.copyWith(
          fontSize: 23,
          fontWeight: FontWeight.w800,
          letterSpacing: -.5,
          height: 1.3,
          color: Colors.white),
      headlineSmall: t.headlineSmall?.copyWith(
          fontSize: 19,
          fontWeight: FontWeight.w700,
          letterSpacing: -.3,
          height: 1.35,
          color: Colors.white),
      titleLarge: t.titleLarge?.copyWith(
          fontSize: 18,
          fontWeight: FontWeight.w700,
          letterSpacing: -.2,
          color: Colors.white),
      titleMedium: t.titleMedium?.copyWith(
          fontSize: 15.5,
          fontWeight: FontWeight.w700,
          letterSpacing: -.1,
          height: 1.35,
          color: Neon.ink),
      titleSmall: t.titleSmall?.copyWith(
          fontSize: 13.5,
          fontWeight: FontWeight.w700,
          height: 1.35,
          color: Neon.ink),
      bodyLarge:
          t.bodyLarge?.copyWith(fontSize: 15, height: 1.6, color: Neon.ink),
      bodyMedium:
          t.bodyMedium?.copyWith(fontSize: 14, height: 1.6, color: Neon.inkDim),
      bodySmall: t.bodySmall
          ?.copyWith(fontSize: 12.5, height: 1.55, color: Neon.inkFaint),
      labelLarge: t.labelLarge?.copyWith(
          fontSize: 15, fontWeight: FontWeight.w700, letterSpacing: .2),
      labelMedium: t.labelMedium?.copyWith(
          fontSize: 12,
          fontWeight: FontWeight.w700,
          letterSpacing: .3,
          color: Neon.inkDim),
      labelSmall: t.labelSmall?.copyWith(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.4,
          color: Neon.inkFaint),
    );

    final pill = RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Neon.radiusS + 2));

    return base.copyWith(
      textTheme: textTheme,
      // Transparent: [EidolonBackdrop] under the Navigator paints the ground,
      // so every route floats over one continuous field instead of each page
      // re-declaring its own black.
      scaffoldBackgroundColor: Colors.transparent,
      canvasColor: Neon.surface,
      splashFactory: InkSparkle.splashFactory,
      splashColor: Neon.cyan.withValues(alpha: .09),
      highlightColor: Neon.cyan.withValues(alpha: .05),
      hoverColor: Neon.cyan.withValues(alpha: .04),
      focusColor: Neon.cyan.withValues(alpha: .10),
      dividerColor: Neon.hair,
      iconTheme: const IconThemeData(color: Neon.inkDim, size: 21),
      primaryIconTheme: const IconThemeData(color: Neon.cyan),
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
        elevation: 0,
        centerTitle: false,
        titleSpacing: Neon.s5,
        foregroundColor: Colors.white,
        iconTheme: const IconThemeData(color: Neon.ink, size: 22),
        actionsIconTheme: const IconThemeData(color: Neon.inkDim, size: 22),
        titleTextStyle: textTheme.titleLarge,
        toolbarHeight: 60,
      ),
      cardTheme: CardThemeData(
        color: const Color(0xF20E1425),
        surfaceTintColor: Colors.transparent,
        shadowColor: Colors.transparent,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Neon.radiusL),
          side: const BorderSide(color: Neon.hair),
        ),
        clipBehavior: Clip.antiAlias,
      ),
      listTileTheme: ListTileThemeData(
        iconColor: Neon.cyan,
        textColor: Neon.ink,
        titleTextStyle: textTheme.titleMedium,
        subtitleTextStyle: textTheme.bodySmall,
        leadingAndTrailingTextStyle: textTheme.labelMedium,
        minVerticalPadding: Neon.s3,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(Neon.radiusM)),
      ),
      expansionTileTheme: const ExpansionTileThemeData(
        iconColor: Neon.cyan,
        collapsedIconColor: Neon.inkFaint,
        textColor: Colors.white,
        collapsedTextColor: Neon.ink,
        shape: Border(),
        collapsedShape: Border(),
        tilePadding: EdgeInsets.symmetric(horizontal: Neon.s1),
      ),
      filledButtonTheme: FilledButtonThemeData(style: primaryButton()),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: Neon.cyanSoft,
          disabledForegroundColor: Neon.inkFaint,
          backgroundColor: Colors.white.withValues(alpha: .04),
          side: const BorderSide(color: Neon.hairStrong),
          shape: pill,
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
          minimumSize: const Size(0, 52),
          textStyle: textTheme.labelLarge,
          iconSize: 19,
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: Neon.cyanSoft,
          disabledForegroundColor: Neon.inkFaint,
          shape: pill,
          padding: const EdgeInsets.symmetric(
              horizontal: Neon.s3, vertical: Neon.s2),
          textStyle: textTheme.labelLarge?.copyWith(fontSize: 14),
          iconSize: 18,
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: Neon.surfaceHigh,
          foregroundColor: Neon.cyanSoft,
          shape: pill,
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
          minimumSize: const Size(0, 52),
          elevation: 0,
          textStyle: textTheme.labelLarge,
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          foregroundColor: Neon.inkDim,
          highlightColor: Neon.cyan.withValues(alpha: .10),
          minimumSize: const Size(44, 44),
        ),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: SegmentedButton.styleFrom(
          selectedBackgroundColor: Neon.cyan.withValues(alpha: .14),
          selectedForegroundColor: Neon.cyanSoft,
          foregroundColor: Neon.inkDim,
          side: const BorderSide(color: Neon.hair),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.white.withValues(alpha: .035),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: Neon.s4, vertical: Neon.s4),
        labelStyle: const TextStyle(color: Neon.inkDim, fontSize: 14),
        floatingLabelStyle: const TextStyle(
            color: Neon.cyan, fontWeight: FontWeight.w700, fontSize: 13),
        hintStyle: const TextStyle(color: Neon.inkFaint, fontSize: 14),
        helperStyle: textTheme.bodySmall,
        prefixIconColor: Neon.inkFaint,
        suffixIconColor: Neon.inkFaint,
        border: _field(Neon.hair),
        enabledBorder: _field(Neon.hair),
        focusedBorder: _field(Neon.cyan, 1.5),
        errorBorder: _field(Neon.bad),
        focusedErrorBorder: _field(Neon.bad, 1.5),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: Colors.white.withValues(alpha: .04),
        selectedColor: Neon.cyan.withValues(alpha: .16),
        secondarySelectedColor: Neon.cyan.withValues(alpha: .16),
        disabledColor: Colors.white.withValues(alpha: .02),
        side: const BorderSide(color: Neon.hair),
        shape: const StadiumBorder(),
        labelStyle:
            textTheme.labelLarge?.copyWith(fontSize: 13.5, color: Neon.inkDim),
        secondaryLabelStyle: textTheme.labelLarge
            ?.copyWith(fontSize: 13.5, color: Neon.cyanSoft),
        iconTheme: const IconThemeData(color: Neon.cyan, size: 16),
        checkmarkColor: Neon.cyanSoft,
        showCheckmark: false,
        labelPadding: const EdgeInsets.symmetric(horizontal: Neon.s2),
        padding:
            const EdgeInsets.symmetric(horizontal: Neon.s3, vertical: Neon.s3),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: Neon.surfaceHigh,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Neon.radiusL),
          side: const BorderSide(color: Neon.hairStrong),
        ),
        titleTextStyle: textTheme.headlineSmall,
        contentTextStyle: textTheme.bodyMedium,
        insetPadding:
            const EdgeInsets.symmetric(horizontal: Neon.s6, vertical: Neon.s6),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: Neon.surfaceHigh,
        surfaceTintColor: Colors.transparent,
        modalBackgroundColor: Neon.surfaceHigh,
        elevation: 0,
        modalElevation: 0,
        showDragHandle: true,
        dragHandleColor: Neon.inkFaint,
        dragHandleSize: Size(40, 4),
        shape: RoundedRectangleBorder(
          borderRadius:
              BorderRadius.vertical(top: Radius.circular(Neon.radiusL + 6)),
          side: BorderSide(color: Neon.hairStrong),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: const Color(0xFF161D33),
        contentTextStyle:
            textTheme.bodyMedium?.copyWith(color: Neon.ink, fontSize: 13.5),
        actionTextColor: Neon.cyanSoft,
        behavior: SnackBarBehavior.floating,
        elevation: 0,
        insetPadding: const EdgeInsets.all(Neon.s4),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Neon.radiusS),
          side: const BorderSide(color: Neon.hairStrong),
        ),
      ),
      dividerTheme:
          const DividerThemeData(color: Neon.hair, thickness: 1, space: 1),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: Neon.cyan,
        linearTrackColor: Colors.white.withValues(alpha: .07),
        circularTrackColor: Colors.white.withValues(alpha: .06),
        linearMinHeight: 3,
        strokeWidth: 2.5,
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((s) =>
            s.contains(WidgetState.selected) ? Neon.onCyan : Neon.inkFaint),
        trackColor: WidgetStateProperty.resolveWith((s) =>
            s.contains(WidgetState.selected)
                ? Neon.cyan
                : Colors.white.withValues(alpha: .05)),
        trackOutlineColor: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.selected) ? Neon.cyan : Neon.hair),
      ),
      checkboxTheme: CheckboxThemeData(
        fillColor: WidgetStateProperty.resolveWith((s) =>
            s.contains(WidgetState.selected) ? Neon.cyan : Colors.transparent),
        checkColor: const WidgetStatePropertyAll(Neon.onCyan),
        side: const BorderSide(color: Neon.hairStrong, width: 1.4),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
      ),
      radioTheme: RadioThemeData(
        fillColor: WidgetStateProperty.resolveWith((s) =>
            s.contains(WidgetState.selected) ? Neon.cyan : Neon.inkFaint),
      ),
      sliderTheme: SliderThemeData(
        activeTrackColor: Neon.cyan,
        inactiveTrackColor: Colors.white.withValues(alpha: .08),
        thumbColor: Neon.cyan,
        overlayColor: Neon.cyan.withValues(alpha: .12),
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: Neon.surfaceHigh,
          borderRadius: BorderRadius.circular(Neon.radiusS),
          border:
              const Border.fromBorderSide(BorderSide(color: Neon.hairStrong)),
        ),
        textStyle: textTheme.bodySmall?.copyWith(color: Neon.ink),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: Neon.surfaceHigh,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Neon.radiusM),
          side: const BorderSide(color: Neon.hairStrong),
        ),
        textStyle: textTheme.bodyMedium?.copyWith(color: Neon.ink),
      ),
      dropdownMenuTheme: DropdownMenuThemeData(
        menuStyle: MenuStyle(
          backgroundColor: const WidgetStatePropertyAll(Neon.surfaceHigh),
          surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
          shape: WidgetStatePropertyAll(RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(Neon.radiusM),
            side: const BorderSide(color: Neon.hairStrong),
          )),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: Neon.surface,
        indicatorColor: Neon.cyan.withValues(alpha: .14),
        iconTheme: WidgetStateProperty.resolveWith((s) => IconThemeData(
            color:
                s.contains(WidgetState.selected) ? Neon.cyan : Neon.inkFaint)),
        labelTextStyle: WidgetStatePropertyAll(textTheme.labelMedium),
      ),
      tabBarTheme: TabBarThemeData(
        labelColor: Neon.cyanSoft,
        unselectedLabelColor: Neon.inkFaint,
        indicatorColor: Neon.cyan,
        dividerColor: Neon.hair,
        labelStyle: textTheme.labelLarge?.copyWith(fontSize: 14),
      ),
      badgeTheme: const BadgeThemeData(
          backgroundColor: Neon.magenta, textColor: Colors.white),
      pageTransitionsTheme: const PageTransitionsTheme(builders: {
        TargetPlatform.android: FadeForwardsPageTransitionsBuilder(),
        TargetPlatform.iOS: FadeForwardsPageTransitionsBuilder(),
        TargetPlatform.macOS: FadeForwardsPageTransitionsBuilder(),
        TargetPlatform.linux: FadeForwardsPageTransitionsBuilder(),
        TargetPlatform.windows: FadeForwardsPageTransitionsBuilder(),
      }),
    );
  }

  static OutlineInputBorder _field(Color color, [double width = 1]) =>
      OutlineInputBorder(
        borderRadius: BorderRadius.circular(Neon.radiusS),
        borderSide: BorderSide(color: color, width: width),
      );

  /// Every primary action wears the same gradient lozenge.
  ///
  /// Painted through [ButtonStyle.backgroundBuilder] rather than a flat
  /// `backgroundColor`, so the fill has a direction and the button stops
  /// reading as a highlighter stripe across the screen.
  static ButtonStyle primaryButton({
    List<Color> colors = Neon.accentGradient,
    Color foreground = Neon.onCyan,
  }) =>
      FilledButton.styleFrom(
        backgroundColor: Colors.transparent,
        disabledBackgroundColor: Colors.transparent,
        foregroundColor: foreground,
        disabledForegroundColor: Neon.inkFaint,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(Neon.radiusS + 2)),
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
        minimumSize: const Size(0, 52),
        elevation: 0,
        iconSize: 19,
        textStyle: const TextStyle(
            fontSize: 15, fontWeight: FontWeight.w700, letterSpacing: .2),
      ).copyWith(backgroundBuilder: _gradientBackground(colors));

  static Widget Function(BuildContext, Set<WidgetState>, Widget?)
      _gradientBackground(List<Color> colors) => (context, states, child) {
            final off = states.contains(WidgetState.disabled);
            return DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(Neon.radiusS + 2),
                color: off ? Colors.white.withValues(alpha: .05) : null,
                gradient: off
                    ? null
                    : LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: colors,
                      ),
                border: Border.all(
                  color: off ? Neon.hair : Colors.white.withValues(alpha: .22),
                ),
              ),
              child: child,
            );
          };
}

/// The ground every route floats on.
///
/// A dot matrix rather than a perspective grid: the grid read as synthwave
/// nostalgia, while an even field of points reads as instrumentation and stays
/// out of the way of the content sitting on it. Static on purpose — a backdrop
/// that animates is a backdrop that drains an idle phone.
class EidolonBackdrop extends StatelessWidget {
  const EidolonBackdrop({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Stack(
        fit: StackFit.expand,
        children: [
          const RepaintBoundary(
              child: CustomPaint(painter: _BackdropPainter())),
          child,
        ],
      );
}

class _BackdropPainter extends CustomPainter {
  const _BackdropPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRect(rect, Paint()..color = Neon.void_);

    void bloom(Offset centre, double radius, Color color, double alpha) {
      canvas.drawCircle(
        centre,
        radius,
        Paint()
          ..shader = RadialGradient(colors: [
            color.withValues(alpha: alpha),
            color.withValues(alpha: 0),
          ]).createShader(Rect.fromCircle(center: centre, radius: radius)),
      );
    }

    // An aurora across the top and a cool counterweight low-left. Two lights,
    // never more: a third turns the ground into mud.
    bloom(Offset(size.width * .82, -size.height * .06), size.width * 1.05,
        Neon.indigo, .30);
    bloom(Offset(size.width * .06, size.height * .78), size.width * .85,
        Neon.cyan, .10);
    bloom(Offset(size.width * .95, size.height * .52), size.width * .5,
        Neon.magenta, .05);

    // Dot matrix. One drawPoints call for the field, a handful of brighter
    // nodes scattered over it so the field has somewhere to look.
    const pitch = 26.0;
    final dots = <Offset>[];
    for (var y = pitch / 2; y < size.height; y += pitch) {
      for (var x = pitch / 2; x < size.width; x += pitch) {
        dots.add(Offset(x, y));
      }
    }
    canvas.drawPoints(
      PointMode.points,
      dots,
      Paint()
        ..color = Colors.white.withValues(alpha: .035)
        ..strokeWidth = 1.6
        ..strokeCap = StrokeCap.round,
    );

    final random = math.Random(7);
    final nodes = <Offset>[
      for (var i = 0; i < 22; i++)
        dots.isEmpty ? Offset.zero : dots[random.nextInt(dots.length)],
    ];
    canvas.drawPoints(
      PointMode.points,
      nodes,
      Paint()
        ..color = Neon.cyan.withValues(alpha: .20)
        ..strokeWidth = 2.6
        ..strokeCap = StrokeCap.round,
    );

    // Vignette, so content near the edges sits deeper than content at the
    // centre without any element having to carry its own shadow.
    canvas.drawRect(
      rect,
      Paint()
        ..shader = RadialGradient(
          radius: 1.0,
          colors: [Colors.transparent, Colors.black.withValues(alpha: .38)],
          stops: const [.5, 1],
        ).createShader(rect),
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// A small tracked uppercase label that sits above a title.
class NeonEyebrow extends StatelessWidget {
  const NeonEyebrow(this.text, {super.key, this.color = Neon.cyan});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) =>
      Text(text.toUpperCase(), style: Neon.eyebrow(color: color));
}
