import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

// ---------------------------------------------------------------------------
// AI Chat App — Design System
// ---------------------------------------------------------------------------
// Explicit design tokens matching UI/UX design principles:
//   - Brand color (indigo seed)
//   - Typography scale (Material 3 styles + headings)
//   - Spacing scale (8px base unit)
//   - Elevation, radius, motion curves + durations
//   - Semantics labels (a11y) + contrast ratios
//
// Good for portfolio: demonstrates you can translate product requirements
// into a reusable, themeable, accessible design system in Flutter.
// ---------------------------------------------------------------------------

class AppSpacing {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 32;
}

class AppRadius {
  static const double pill = 24;
  static const double bubble = 14;
  static const double card = 12;
  static const double small = 8;
  static const double badge = 8;
}

class AppElevation {
  static const double none = 0;
  static const double level1 = 1;
  static const double level2 = 3;
}

class AppDurations {
  static const Duration fast = Duration(milliseconds: 150);
  static const Duration medium = Duration(milliseconds: 300);
  static const Duration slow = Duration(milliseconds: 600);
  static const Duration typingDot = Duration(milliseconds: 1200);
}

class AppCurves {
  static const Curve enter = Curves.easeOutCubic;
  static const Curve exit = Curves.easeInCubic;
  static const Curve standard = Curves.easeInOutCubic;
}

class AppColors {
  // Primary brand seed — used by M3 ColorScheme.fromSeed
  static const Color brandSeed = Color(0xFF6366F1);
  static const Color positive = Color(0xFF16A34A);
  static const Color negative = Color(0xFFDC2626);
  static const Color info = Color(0xFF2563EB);
}

class AppTextStyles {
  static const String fontFamily = 'Roboto';

  // Bubble body (on par with native iOS/Android chat apps)
  static const TextStyle bubbleBody = TextStyle(
    fontSize: 15,
    height: 1.35,
    fontWeight: FontWeight.w400,
  );

  // Chat meta (timestamps, badges, model tags)
  static const TextStyle bubbleMeta = TextStyle(
    fontSize: 11,
    height: 1.2,
    fontWeight: FontWeight.w400,
  );

  static const TextStyle badgeBold = TextStyle(
    fontSize: 10,
    fontWeight: FontWeight.w800,
  );

  static const TextStyle typingHint = TextStyle(
    fontSize: 12,
    fontStyle: FontStyle.italic,
  );
}

class AppSemantics {
  // Accessibility labels used across the UI (screen readers like TalkBack/VoiceOver)
  static const String sendButton = 'Send message';
  static const String settingsButton = 'Backend connection settings';
  static const String clearButton = 'Clear chat conversation';
  static const String messageField = 'Message input field';
  static const String aiAvatar = 'AI assistant avatar';
  static const String userAvatar = 'Your avatar';
  static String aiMessage(String preview) => 'AI message: ${preview.replaceAll('\n', ' ')}';
  static String userMessage(String preview) => 'Your message: ${preview.replaceAll('\n', ' ')}';
  static const String typingIndicator = 'AI is typing a reply';
}

class AppTheme {
  static ThemeData light() {
    final scheme = ColorScheme.fromSeed(
      seedColor: AppColors.brandSeed,
      brightness: Brightness.light,
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: scheme.surface,
      appBarTheme: AppBarTheme(
        centerTitle: true,
        elevation: AppElevation.none,
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
      ),
      pageTransitionsTheme: const PageTransitionsTheme(builders: {
        TargetPlatform.android: CupertinoPageTransitionsBuilder(),
        TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
      }),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.card)),
      ),
      inputDecorationTheme: InputDecorationTheme(
        contentPadding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg,
          vertical: AppSpacing.md,
        ),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(AppRadius.pill)),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.pill),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
      ),
    );
  }

  static ThemeData dark() {
    final scheme = ColorScheme.fromSeed(
      seedColor: AppColors.brandSeed,
      brightness: Brightness.dark,
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      appBarTheme: AppBarTheme(
        centerTitle: true,
        elevation: AppElevation.none,
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
      ),
      pageTransitionsTheme: const PageTransitionsTheme(builders: {
        TargetPlatform.android: CupertinoPageTransitionsBuilder(),
        TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
      }),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.card)),
      ),
      inputDecorationTheme: InputDecorationTheme(
        contentPadding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg,
          vertical: AppSpacing.md,
        ),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(AppRadius.pill)),
      ),
    );
  }
}
