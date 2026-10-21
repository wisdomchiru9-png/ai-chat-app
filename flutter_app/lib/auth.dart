import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'theme.dart';

// ---------------------------------------------------------------------------
// Auth — JWT bearer tokens issued by the FastAPI backend
// ---------------------------------------------------------------------------
// The backend exposes:
//   POST /auth/register  {email, password, display_name?} -> token + user
//   POST /auth/login     {email, password}                -> token + user
//   GET  /auth/me                                         -> the signed-in user
//
// Sessions and persisted chat belong to the signed-in user, so every protected
// request needs `Authorization: Bearer <token>`.
// ---------------------------------------------------------------------------

class AuthUser {
  final int id;
  final String? email;
  final String displayName;

  AuthUser({required this.id, this.email, required this.displayName});

  factory AuthUser.fromJson(Map<String, dynamic> json) {
    return AuthUser(
      id: (json['id'] as num?)?.toInt() ?? 0,
      email: json['email'] as String?,
      displayName: json['display_name'] as String? ?? 'User',
    );
  }
}

class AuthResult {
  final String token;
  final AuthUser user;
  final int expiresIn;

  AuthResult({required this.token, required this.user, required this.expiresIn});

  factory AuthResult.fromJson(Map<String, dynamic> json) {
    return AuthResult(
      token: json['access_token'] as String? ?? '',
      user: AuthUser.fromJson(
        (json['user'] as Map?)?.cast<String, dynamic>() ?? const {},
      ),
      expiresIn: (json['expires_in'] as num?)?.toInt() ?? 0,
    );
  }
}

/// Thrown for anything the user can act on; [message] is safe to display.
class AuthException implements Exception {
  final String message;
  AuthException(this.message);

  @override
  String toString() => message;
}

class AuthApi {
  static const Duration _timeout = Duration(seconds: 20);

  static Map<String, String> _headers({String? token}) => {
        "Content-Type": "application/json",
        if (token != null && token.isNotEmpty) "Authorization": "Bearer $token",
      };

  /// Turns a non-2xx response into an [AuthException] using the `detail` field.
  static AuthException _errorFor(http.Response response) {
    String detail = "Request failed (${response.statusCode})";
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map && decoded['detail'] != null) {
        final raw = decoded['detail'];
        // FastAPI validation errors arrive as a list of objects.
        if (raw is String) {
          detail = raw;
        } else if (raw is List && raw.isNotEmpty) {
          final first = raw.first;
          detail = first is Map && first['msg'] != null
              ? first['msg'].toString()
              : raw.toString();
        }
      }
    } catch (_) {
      // Body was not JSON; keep the generic message.
    }
    return AuthException(detail);
  }

  static Future<AuthResult> _post(String baseUrl, String path, Map<String, dynamic> body) async {
    final http.Response response;
    try {
      response = await http
          .post(
            Uri.parse('$baseUrl$path'),
            headers: _headers(),
            body: jsonEncode(body),
          )
          .timeout(_timeout);
    } catch (e) {
      throw AuthException("Couldn't reach the backend at $baseUrl");
    }

    if (response.statusCode != 200 && response.statusCode != 201) {
      throw _errorFor(response);
    }
    return AuthResult.fromJson(jsonDecode(response.body) as Map<String, dynamic>);
  }

  static Future<AuthResult> register(
    String baseUrl, {
    required String email,
    required String password,
    String? displayName,
  }) {
    return _post(baseUrl, '/auth/register', {
      'email': email,
      'password': password,
      if (displayName != null && displayName.isNotEmpty) 'display_name': displayName,
    });
  }

  static Future<AuthResult> login(
    String baseUrl, {
    required String email,
    required String password,
  }) {
    return _post(baseUrl, '/auth/login', {'email': email, 'password': password});
  }

  /// Validates a stored token on startup. Throws [AuthException] when it is stale.
  static Future<AuthUser> me(String baseUrl, String token) async {
    final http.Response response;
    try {
      response = await http
          .get(Uri.parse('$baseUrl/auth/me'), headers: _headers(token: token))
          .timeout(_timeout);
    } catch (e) {
      throw AuthException("Couldn't reach the backend at $baseUrl");
    }
    if (response.statusCode != 200) throw _errorFor(response);
    return AuthUser.fromJson(jsonDecode(response.body) as Map<String, dynamic>);
  }
}

/// Persists the bearer token so a signed-in user survives an app restart.
class AuthStore {
  static const String _tokenKey = 'auth_token';
  static const String _emailKey = 'auth_email';

  static Future<({String? token, String? email})> read() async {
    final prefs = await SharedPreferences.getInstance();
    return (token: prefs.getString(_tokenKey), email: prefs.getString(_emailKey));
  }

  static Future<void> save(String token, String? email) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_tokenKey, token);
    if (email != null) await prefs.setString(_emailKey, email);
  }

  static Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_tokenKey);
    await prefs.remove(_emailKey);
  }
}

// ---------------------------------------------------------------------------
// Login / Register screen
// ---------------------------------------------------------------------------
class LoginScreen extends StatefulWidget {
  final String baseUrl;
  final ValueChanged<AuthResult> onAuthenticated;
  final VoidCallback? onConfigureBackend;

  const LoginScreen({
    super.key,
    required this.baseUrl,
    required this.onAuthenticated,
    this.onConfigureBackend,
  });

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _nameController = TextEditingController();

  bool _isRegisterMode = false;
  bool _isSubmitting = false;
  bool _obscurePassword = true;
  String? _error;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;

    setState(() {
      _isSubmitting = true;
      _error = null;
    });

    try {
      final result = _isRegisterMode
          ? await AuthApi.register(
              widget.baseUrl,
              email: _emailController.text.trim(),
              password: _passwordController.text,
              displayName: _nameController.text.trim(),
            )
          : await AuthApi.login(
              widget.baseUrl,
              email: _emailController.text.trim(),
              password: _passwordController.text,
            );
      if (!mounted) return;
      widget.onAuthenticated(result);
    } on AuthException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = "Something went wrong: $e");
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.xl,
              vertical: AppSpacing.xl,
            ),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Form(
                key: _formKey,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Icon(Icons.forum_rounded, size: 56, color: scheme.primary),
                    const SizedBox(height: AppSpacing.lg),
                    Text(
                      _isRegisterMode ? "Create your account" : "Welcome back",
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    Text(
                      "Sign in to save and revisit your conversations.",
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                    ),
                    const SizedBox(height: AppSpacing.xl),

                    if (_isRegisterMode) ...[
                      TextFormField(
                        controller: _nameController,
                        textInputAction: TextInputAction.next,
                        decoration: const InputDecoration(
                          labelText: "Display name (optional)",
                          prefixIcon: Icon(Icons.person_outline),
                        ),
                      ),
                      const SizedBox(height: AppSpacing.md),
                    ],

                    TextFormField(
                      controller: _emailController,
                      keyboardType: TextInputType.emailAddress,
                      autofillHints: const [AutofillHints.email],
                      textInputAction: TextInputAction.next,
                      decoration: const InputDecoration(
                        labelText: "Email",
                        prefixIcon: Icon(Icons.mail_outline),
                      ),
                      validator: (value) {
                        final v = (value ?? '').trim();
                        if (v.isEmpty) return "Enter your email";
                        if (!v.contains('@') || !v.contains('.')) {
                          return "Enter a valid email address";
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: AppSpacing.md),

                    TextFormField(
                      controller: _passwordController,
                      obscureText: _obscurePassword,
                      autofillHints: const [AutofillHints.password],
                      textInputAction: TextInputAction.done,
                      onFieldSubmitted: (_) => _isSubmitting ? null : _submit(),
                      decoration: InputDecoration(
                        labelText: "Password",
                        prefixIcon: const Icon(Icons.lock_outline),
                        suffixIcon: IconButton(
                          icon: Icon(_obscurePassword
                              ? Icons.visibility_outlined
                              : Icons.visibility_off_outlined),
                          tooltip: _obscurePassword ? "Show password" : "Hide password",
                          onPressed: () =>
                              setState(() => _obscurePassword = !_obscurePassword),
                        ),
                      ),
                      validator: (value) {
                        final v = value ?? '';
                        if (v.isEmpty) return "Enter your password";
                        if (_isRegisterMode && v.length < 8) {
                          return "Use at least 8 characters";
                        }
                        return null;
                      },
                    ),

                    if (_error != null) ...[
                      const SizedBox(height: AppSpacing.lg),
                      Container(
                        padding: const EdgeInsets.all(AppSpacing.md),
                        decoration: BoxDecoration(
                          color: scheme.errorContainer,
                          borderRadius: BorderRadius.circular(AppRadius.small),
                        ),
                        child: Row(
                          children: [
                            Icon(Icons.error_outline,
                                size: 18, color: scheme.onErrorContainer),
                            const SizedBox(width: AppSpacing.sm),
                            Expanded(
                              child: Text(
                                _error!,
                                style: TextStyle(color: scheme.onErrorContainer),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],

                    const SizedBox(height: AppSpacing.xl),
                    Semantics(
                      button: true,
                      label: _isRegisterMode ? "Create account" : "Sign in",
                      child: FilledButton(
                        onPressed: _isSubmitting ? null : _submit,
                        style: FilledButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: AppSpacing.lg),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(AppRadius.pill),
                          ),
                        ),
                        child: _isSubmitting
                            ? const SizedBox(
                                height: 18,
                                width: 18,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : Text(_isRegisterMode ? "Create account" : "Sign in"),
                      ),
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    TextButton(
                      onPressed: _isSubmitting
                          ? null
                          : () => setState(() {
                                _isRegisterMode = !_isRegisterMode;
                                _error = null;
                              }),
                      child: Text(_isRegisterMode
                          ? "Already have an account? Sign in"
                          : "New here? Create an account"),
                    ),
                    if (widget.onConfigureBackend != null)
                      TextButton.icon(
                        onPressed: widget.onConfigureBackend,
                        icon: const Icon(Icons.settings_outlined, size: 18),
                        label: Text(
                          "Backend: ${widget.baseUrl}",
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
