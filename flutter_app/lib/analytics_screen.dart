import 'dart:async';
import 'dart:convert';

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'theme.dart';

// ---------------------------------------------------------------------------
// Benchmark response models (mirror the backend Pydantic schemas)
// ---------------------------------------------------------------------------

class BenchmarkRun {
  const BenchmarkRun({
    required this.prompt,
    this.reply,
    this.error,
    this.latencyMs,
    this.outputTokens,
    this.sentimentLabel,
    this.expectedSentiment,
    this.quality,
    this.qualityJudge,
  });

  final String prompt;
  final String? reply;
  final String? error;
  final double? latencyMs;
  final int? outputTokens;
  final String? sentimentLabel;
  final String? expectedSentiment;
  final double? quality;
  final String? qualityJudge;

  factory BenchmarkRun.fromJson(Map<String, dynamic> json) {
    return BenchmarkRun(
      prompt: json['prompt']?.toString() ?? '',
      reply: json['reply']?.toString(),
      error: json['error']?.toString(),
      latencyMs: (json['latency_ms'] as num?)?.toDouble(),
      outputTokens: (json['output_tokens'] as num?)?.toInt(),
      sentimentLabel: json['sentiment_label']?.toString(),
      expectedSentiment: json['expected_sentiment']?.toString(),
      quality: (json['quality'] as num?)?.toDouble(),
      qualityJudge: json['quality_judge']?.toString(),
    );
  }
}

class BenchmarkResult {
  const BenchmarkResult({
    required this.provider,
    required this.model,
    required this.runsCompleted,
    required this.errors,
    required this.avgLatencyMs,
    required this.p95LatencyMs,
    required this.inputTokens,
    required this.outputTokens,
    required this.sentimentAccuracy,
    required this.avgQuality,
    required this.estimatedCostUsd,
    required this.overallScore,
    required this.runs,
  });

  final String provider;
  final String model;
  final int runsCompleted;
  final int errors;
  final double avgLatencyMs;
  final double p95LatencyMs;
  final int inputTokens;
  final int outputTokens;
  final double? sentimentAccuracy;
  final double avgQuality;
  final double estimatedCostUsd;
  final double overallScore;
  final List<BenchmarkRun> runs;

  factory BenchmarkResult.fromJson(Map<String, dynamic> json) {
    final rawRuns = json['runs'];
    return BenchmarkResult(
      provider: json['provider']?.toString() ?? 'unknown',
      model: json['model']?.toString() ?? 'unknown',
      runsCompleted: (json['runs_completed'] as num?)?.toInt() ?? 0,
      errors: (json['errors'] as num?)?.toInt() ?? 0,
      avgLatencyMs: (json['avg_latency_ms'] as num?)?.toDouble() ?? 0,
      p95LatencyMs: (json['p95_latency_ms'] as num?)?.toDouble() ?? 0,
      inputTokens: (json['input_tokens'] as num?)?.toInt() ?? 0,
      outputTokens: (json['output_tokens'] as num?)?.toInt() ?? 0,
      sentimentAccuracy: (json['sentiment_accuracy'] as num?)?.toDouble(),
      avgQuality: (json['avg_quality'] as num?)?.toDouble() ?? 0,
      estimatedCostUsd: (json['estimated_cost_usd'] as num?)?.toDouble() ?? 0,
      overallScore: (json['overall_score'] as num?)?.toDouble() ?? 0,
      runs: rawRuns is List
          ? rawRuns
              .whereType<Map>()
              .map((entry) =>
                  BenchmarkRun.fromJson(Map<String, dynamic>.from(entry)))
              .toList(growable: false)
          : const <BenchmarkRun>[],
    );
  }
}

class BenchmarkRanking {
  const BenchmarkRanking({
    required this.rank,
    required this.provider,
    required this.model,
    required this.overallScore,
  });

  final int rank;
  final String provider;
  final String model;
  final double overallScore;

  factory BenchmarkRanking.fromJson(Map<String, dynamic> json) {
    return BenchmarkRanking(
      rank: (json['rank'] as num?)?.toInt() ?? 0,
      provider: json['provider']?.toString() ?? 'unknown',
      model: json['model']?.toString() ?? 'unknown',
      overallScore: (json['overall_score'] as num?)?.toDouble() ?? 0,
    );
  }
}

class BenchmarkResponse {
  const BenchmarkResponse({
    required this.timestamp,
    required this.prompts,
    required this.results,
    required this.ranking,
    required this.recommendation,
  });

  final DateTime? timestamp;
  final int prompts;
  final List<BenchmarkResult> results;
  final List<BenchmarkRanking> ranking;
  final String? recommendation;

  factory BenchmarkResponse.fromJson(Map<String, dynamic> json) {
    final rawResults = json['results'];
    final rawRanking = json['ranking'];
    return BenchmarkResponse(
      timestamp: DateTime.tryParse(json['timestamp']?.toString() ?? ''),
      prompts: (json['prompts'] as num?)?.toInt() ?? 0,
      results: rawResults is List
          ? rawResults
              .whereType<Map>()
              .map((entry) =>
                  BenchmarkResult.fromJson(Map<String, dynamic>.from(entry)))
              .toList(growable: false)
          : const <BenchmarkResult>[],
      ranking: rawRanking is List
          ? rawRanking
              .whereType<Map>()
              .map((entry) =>
                  BenchmarkRanking.fromJson(Map<String, dynamic>.from(entry)))
              .toList(growable: false)
          : const <BenchmarkRanking>[],
      recommendation: json['recommendation']?.toString(),
    );
  }
}

// ---------------------------------------------------------------------------
// Formatting helpers
// ---------------------------------------------------------------------------

const List<String> _monthNames = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

String _formatTimestamp(DateTime? timestamp) {
  if (timestamp == null) return 'n/a';
  final local = timestamp.toLocal();
  final hour = local.hour.toString().padLeft(2, '0');
  final minute = local.minute.toString().padLeft(2, '0');
  return '${local.day} ${_monthNames[local.month - 1]} ${local.year}, $hour:$minute';
}

/// Shows milliseconds, and adds the equivalent in seconds once the value
/// reaches one second so long waits stay readable.
String _formatLatency(double? milliseconds) {
  if (milliseconds == null) return 'n/a';
  if (milliseconds >= 1000) {
    return '${milliseconds.toStringAsFixed(0)} ms '
        '(${(milliseconds / 1000).toStringAsFixed(2)} s)';
  }
  if (milliseconds == milliseconds.roundToDouble()) {
    return '${milliseconds.toStringAsFixed(0)} ms';
  }
  return '${milliseconds.toStringAsFixed(1)} ms';
}

String _formatAccuracy(double? accuracy) {
  if (accuracy == null) return 'n/a';
  return '${(accuracy * 100).toStringAsFixed(1)}%';
}

String _formatCost(double costUsd) => '\$${costUsd.toStringAsFixed(6)}';

String _truncate(String text, int maxLength) {
  if (maxLength <= 0) return '';
  final collapsed = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (collapsed.length <= maxLength) return collapsed;
  return '${collapsed.substring(0, maxLength)}…';
}

String _shortLabel(String value) {
  if (value.length <= 9) return value;
  return '${value.substring(0, 8)}…';
}

// ---------------------------------------------------------------------------
// Screen
// ---------------------------------------------------------------------------

class AnalyticsScreen extends StatefulWidget {
  final String? baseUrl;
  final String? authToken;

  const AnalyticsScreen({super.key, this.baseUrl, this.authToken});

  @override
  State<AnalyticsScreen> createState() => _AnalyticsScreenState();
}

class _AnalyticsScreenState extends State<AnalyticsScreen> {
  static const String _fallbackBaseUrl = 'http://10.0.2.2:8000';
  static const Duration _requestTimeout = Duration(minutes: 10);

  bool _useJudgeLlm = true;
  bool _loading = false;
  bool _connectionError = false;
  String? _error;
  BenchmarkResponse? _response;

  String get _baseUrl {
    final raw = widget.baseUrl?.trim() ?? '';
    final url = raw.isEmpty ? _fallbackBaseUrl : raw;
    return url.endsWith('/') ? url.substring(0, url.length - 1) : url;
  }

  bool get _hasToken {
    final token = widget.authToken;
    return token != null && token.isNotEmpty;
  }

  Future<void> _runBenchmark() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
      _connectionError = false;
    });

    final uri = Uri.parse('$_baseUrl/benchmark');
    final headers = <String, String>{
      'Content-Type': 'application/json',
      if (_hasToken) 'Authorization': 'Bearer ${widget.authToken}',
    };

    try {
      final response = await http
          .post(
            uri,
            headers: headers,
            body: jsonEncode(<String, dynamic>{'use_judge_llm': _useJudgeLlm}),
          )
          .timeout(_requestTimeout);

      if (response.statusCode < 200 || response.statusCode >= 300) {
        _fail(
          'Server error ${response.statusCode}: ${_extractDetail(response.body)}',
          connectionError: false,
        );
        return;
      }

      final decoded = jsonDecode(response.body);
      if (decoded is! Map) {
        _fail(
          'Unexpected response format from the benchmark endpoint.',
          connectionError: false,
        );
        return;
      }

      final parsed =
          BenchmarkResponse.fromJson(Map<String, dynamic>.from(decoded));
      if (!mounted) return;
      setState(() {
        _loading = false;
        _response = parsed;
      });
    } on TimeoutException {
      _fail(
        'The benchmark timed out after 10 minutes. Try again, or run it with '
        'the judge LLM disabled to speed it up.',
        connectionError: true,
      );
    } on http.ClientException catch (e) {
      _fail('Could not reach the backend at $_baseUrl.\n$e',
          connectionError: true);
    } catch (e) {
      _fail('Unexpected error: $e', connectionError: true);
    }
  }

  void _fail(String message, {required bool connectionError}) {
    if (!mounted) return;
    setState(() {
      _loading = false;
      _error = message;
      _connectionError = connectionError;
    });
  }

  String _extractDetail(String body) {
    final trimmed = body.trim();
    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is Map && decoded['detail'] != null) {
        return decoded['detail'].toString();
      }
    } on FormatException {
      return trimmed.isEmpty ? 'The benchmark request failed.' : trimmed;
    }
    return trimmed.isEmpty ? 'The benchmark request failed.' : trimmed;
  }

  void _setJudgeLlm(bool value) {
    if (_loading) return;
    setState(() => _useJudgeLlm = value);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: Semantics(
          button: true,
          label: 'Go back',
          child: IconButton(
            icon: const Icon(Icons.arrow_back),
            tooltip: 'Back',
            onPressed: () => Navigator.of(context).pop(),
          ),
        ),
        title: const Text('Model Analytics'),
        actions: [
          Semantics(
            button: true,
            label: 'Re-run the model benchmark',
            child: IconButton(
              tooltip: 'Re-run benchmark',
              icon: const Icon(Icons.refresh),
              onPressed: _loading ? null : _runBenchmark,
            ),
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return _LoadingView(
        prompts: _response?.prompts,
        models: _response?.results.length,
      );
    }

    final error = _error;
    if (error != null) {
      return _ErrorView(
        message: error,
        connectionError: _connectionError,
        baseUrl: _baseUrl,
        onRetry: _runBenchmark,
      );
    }

    final response = _response;
    if (response == null) {
      return _EmptyView(
        useJudgeLlm: _useJudgeLlm,
        onJudgeChanged: _setJudgeLlm,
        onRun: _runBenchmark,
      );
    }

    return _ResultsView(
      response: response,
      useJudgeLlm: _useJudgeLlm,
      onJudgeChanged: _setJudgeLlm,
      onRun: _runBenchmark,
    );
  }
}

// ---------------------------------------------------------------------------
// Screen states
// ---------------------------------------------------------------------------

class _EmptyView extends StatelessWidget {
  final bool useJudgeLlm;
  final ValueChanged<bool> onJudgeChanged;
  final Future<void> Function() onRun;

  const _EmptyView({
    required this.useJudgeLlm,
    required this.onJudgeChanged,
    required this.onRun,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Icon(Icons.insights_outlined, size: 56, color: scheme.primary),
              const SizedBox(height: AppSpacing.lg),
              Text(
                'Model Analytics',
                textAlign: TextAlign.center,
                style: theme.textTheme.headlineSmall
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: AppSpacing.sm),
              Text(
                'The benchmark sends a fixed set of prompts to every configured '
                'model, scores each reply for quality and sentiment accuracy, '
                'measures latency and token usage, then ranks the models and '
                'picks a recommendation.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: AppSpacing.xl),
              _JudgeToggle(
                value: useJudgeLlm,
                enabled: true,
                onChanged: onJudgeChanged,
              ),
              const SizedBox(height: AppSpacing.xl),
              Semantics(
                button: true,
                label: 'Run the model benchmark',
                child: FilledButton.icon(
                  onPressed: onRun,
                  icon: const Icon(Icons.play_arrow_rounded),
                  label: const Text('Run benchmark'),
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              Text(
                'This runs every prompt through every provider, so it can take '
                'several minutes.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LoadingView extends StatelessWidget {
  final int? prompts;
  final int? models;

  const _LoadingView({this.prompts, this.models});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final headline = (prompts != null && models != null)
        ? 'Running $prompts prompts across $models models'
        : 'Running the benchmark across every configured model';
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 44,
              height: 44,
              child: CircularProgressIndicator(strokeWidth: 3),
            ),
            const SizedBox(height: AppSpacing.xl),
            Semantics(
              liveRegion: true,
              label: '$headline — this can take a while.',
              child: Text(
                '$headline — this can take a while…',
                textAlign: TextAlign.center,
                style: theme.textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.w600),
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              'Every prompt is sent to every provider and scored, so expect '
              'this to take up to 10 minutes.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  final String message;
  final bool connectionError;
  final String baseUrl;
  final Future<void> Function() onRetry;

  const _ErrorView({
    required this.message,
    required this.connectionError,
    required this.baseUrl,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Icon(Icons.error_outline, size: 48, color: scheme.error),
              const SizedBox(height: AppSpacing.lg),
              Text(
                'Benchmark failed',
                textAlign: TextAlign.center,
                style: theme.textTheme.titleLarge
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: AppSpacing.sm),
              Text(
                message,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
              if (connectionError) ...[
                const SizedBox(height: AppSpacing.md),
                Text(
                  'The backend may not be running. Verify it is reachable at '
                  '$baseUrl.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: scheme.error),
                ),
              ],
              const SizedBox(height: AppSpacing.xl),
              Semantics(
                button: true,
                label: 'Retry the model benchmark',
                child: FilledButton.tonalIcon(
                  onPressed: onRetry,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Retry'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ResultsView extends StatelessWidget {
  final BenchmarkResponse response;
  final bool useJudgeLlm;
  final ValueChanged<bool> onJudgeChanged;
  final Future<void> Function() onRun;

  const _ResultsView({
    required this.response,
    required this.useJudgeLlm,
    required this.onJudgeChanged,
    required this.onRun,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final results = response.results;
    final recommendation = response.recommendation;

    BenchmarkResult? recommended;
    if (recommendation != null) {
      for (final result in results) {
        if (result.provider == recommendation ||
            result.model == recommendation) {
          recommended = result;
          break;
        }
      }
    }

    return RefreshIndicator(
      onRefresh: onRun,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg,
          AppSpacing.lg,
          AppSpacing.lg,
          AppSpacing.xxl,
        ),
        children: [
          _JudgeToggle(
            value: useJudgeLlm,
            enabled: true,
            onChanged: onJudgeChanged,
          ),
          const SizedBox(height: AppSpacing.lg),
          if (recommendation != null)
            _RecommendationCard(
              recommendation: recommendation,
              result: recommended,
            )
          else
            const _NoRecommendationCard(),
          const SizedBox(height: AppSpacing.lg),
          _SummaryCard(
            prompts: response.prompts,
            models: results.length,
            timestamp: response.timestamp,
          ),
          if (results.isEmpty) ...[
            const SizedBox(height: AppSpacing.lg),
            Text(
              'The benchmark completed but returned no model results.',
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ] else ...[
            const SizedBox(height: AppSpacing.lg),
            _OverallScoreChart(results: results),
            const SizedBox(height: AppSpacing.lg),
            _QualityAccuracyChart(results: results),
            const SizedBox(height: AppSpacing.lg),
            for (final result in results) ...[
              _ModelCard(result: result),
              const SizedBox(height: AppSpacing.lg),
            ],
          ],
          if (response.ranking.isNotEmpty) _RankingCard(ranking: response.ranking),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Shared pieces
// ---------------------------------------------------------------------------

class _JudgeToggle extends StatelessWidget {
  final bool value;
  final bool enabled;
  final ValueChanged<bool> onChanged;

  const _JudgeToggle({
    required this.value,
    required this.enabled,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      elevation: AppElevation.none,
      margin: EdgeInsets.zero,
      color: scheme.surfaceContainerHighest,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.card),
      ),
      child: SwitchListTile(
        contentPadding:
            const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
        title: const Text('Use judge LLM'),
        subtitle: const Text(
          'Score reply quality with an LLM instead of the fast heuristic.',
        ),
        value: value,
        onChanged: enabled ? onChanged : null,
      ),
    );
  }
}

class _SummaryCard extends StatelessWidget {
  final int prompts;
  final int models;
  final DateTime? timestamp;

  const _SummaryCard({
    required this.prompts,
    required this.models,
    required this.timestamp,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      elevation: AppElevation.none,
      margin: EdgeInsets.zero,
      color: scheme.surfaceContainerHighest,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.card),
      ),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Wrap(
          spacing: AppSpacing.xl,
          runSpacing: AppSpacing.md,
          children: [
            _SummaryItem(
              icon: Icons.article_outlined,
              label: 'Prompts',
              value: prompts.toString(),
            ),
            _SummaryItem(
              icon: Icons.hub_outlined,
              label: 'Models',
              value: models.toString(),
            ),
            _SummaryItem(
              icon: Icons.schedule_outlined,
              label: 'Run at',
              value: _formatTimestamp(timestamp),
            ),
          ],
        ),
      ),
    );
  }
}

class _SummaryItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  const _SummaryItem({
    required this.icon,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 18, color: scheme.primary),
        const SizedBox(width: AppSpacing.sm),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: textTheme.labelSmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
            Text(
              value,
              style: textTheme.titleSmall
                  ?.copyWith(fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ],
    );
  }
}

class _RecommendationCard extends StatelessWidget {
  final String recommendation;
  final BenchmarkResult? result;

  const _RecommendationCard({
    required this.recommendation,
    this.result,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final match = result;
    final score = match?.overallScore;
    final spokenScore =
        score == null ? '' : ', overall score ${score.toStringAsFixed(1)} of 100';
    return Semantics(
      label: 'Recommended model: $recommendation$spokenScore.',
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(AppSpacing.lg),
        decoration: BoxDecoration(
          color: scheme.primaryContainer,
          borderRadius: BorderRadius.circular(AppRadius.card),
          border: Border.all(color: scheme.primary.withAlpha(80)),
        ),
        child: Row(
          children: [
            Icon(
              Icons.emoji_events_outlined,
              size: 28,
              color: scheme.onPrimaryContainer,
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'RECOMMENDED',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onPrimaryContainer.withAlpha(200),
                      letterSpacing: 0.8,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    recommendation,
                    style: theme.textTheme.titleLarge?.copyWith(
                      color: scheme.onPrimaryContainer,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  if (match != null)
                    Text(
                      match.model,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onPrimaryContainer.withAlpha(200),
                      ),
                    ),
                ],
              ),
            ),
            if (score != null)
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    score.toStringAsFixed(1),
                    style: theme.textTheme.headlineSmall?.copyWith(
                      color: scheme.onPrimaryContainer,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  Text(
                    'overall',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onPrimaryContainer.withAlpha(200),
                    ),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

class _NoRecommendationCard extends StatelessWidget {
  const _NoRecommendationCard();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpacing.lg),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(AppRadius.card),
      ),
      child: Row(
        children: [
          Icon(Icons.help_outline, color: scheme.onSurfaceVariant),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Text(
              'No recommendation — the benchmark produced no successful '
              'model results.',
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }
}

class _MetricTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  const _MetricTile({
    required this.icon,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return SizedBox(
      width: 152,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 16, color: scheme.primary),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: theme.textTheme.labelSmall
                        ?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    value,
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ScoreBadge extends StatelessWidget {
  final double score;

  const _ScoreBadge({required this.score});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: scheme.primaryContainer,
        borderRadius: BorderRadius.circular(AppRadius.badge),
      ),
      child: Column(
        children: [
          Text(
            score.toStringAsFixed(1),
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w700,
              color: scheme.onPrimaryContainer,
            ),
          ),
          Text(
            'score',
            style: TextStyle(
              fontSize: 10,
              color: scheme.onPrimaryContainer.withAlpha(200),
            ),
          ),
        ],
      ),
    );
  }
}

class _ModelCard extends StatelessWidget {
  final BenchmarkResult result;

  const _ModelCard({required this.result});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Card(
      elevation: AppElevation.level1,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.card),
      ),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        result.provider,
                        style: theme.textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      Text(
                        result.model,
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: AppSpacing.md),
                _ScoreBadge(score: result.overallScore),
              ],
            ),
            const SizedBox(height: AppSpacing.lg),
            Wrap(
              spacing: AppSpacing.md,
              runSpacing: AppSpacing.sm,
              children: [
                _MetricTile(
                  icon: Icons.timer_outlined,
                  label: 'Avg latency',
                  value: _formatLatency(result.avgLatencyMs),
                ),
                _MetricTile(
                  icon: Icons.speed_outlined,
                  label: 'p95 latency',
                  value: _formatLatency(result.p95LatencyMs),
                ),
                _MetricTile(
                  icon: Icons.sentiment_satisfied_outlined,
                  label: 'Sentiment accuracy',
                  value: _formatAccuracy(result.sentimentAccuracy),
                ),
                _MetricTile(
                  icon: Icons.star_outline,
                  label: 'Avg quality',
                  value: result.avgQuality.toStringAsFixed(2),
                ),
                _MetricTile(
                  icon: Icons.south_outlined,
                  label: 'Input tokens',
                  value: result.inputTokens.toString(),
                ),
                _MetricTile(
                  icon: Icons.north_outlined,
                  label: 'Output tokens',
                  value: result.outputTokens.toString(),
                ),
                _MetricTile(
                  icon: Icons.attach_money,
                  label: 'Est. cost',
                  value: _formatCost(result.estimatedCostUsd),
                ),
                _MetricTile(
                  icon: Icons.error_outline,
                  label: 'Errors',
                  value: result.errors.toString(),
                ),
                _MetricTile(
                  icon: Icons.check_circle_outline,
                  label: 'Runs completed',
                  value: result.runsCompleted.toString(),
                ),
              ],
            ),
            const Divider(height: AppSpacing.xl),
            if (result.runs.isEmpty)
              Text(
                'No per-prompt runs recorded.',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: scheme.onSurfaceVariant),
              )
            else
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                childrenPadding: const EdgeInsets.only(bottom: AppSpacing.sm),
                shape: const Border(),
                collapsedShape: const Border(),
                iconColor: scheme.primary,
                leading: Icon(Icons.list_alt_outlined, color: scheme.primary),
                title: Text(
                  'Per-prompt breakdown',
                  style: theme.textTheme.titleSmall
                      ?.copyWith(fontWeight: FontWeight.w600),
                ),
                subtitle: Text(
                  '${result.runs.length} run(s)',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: scheme.onSurfaceVariant),
                ),
                children: [
                  for (final run in result.runs) _RunTile(run: run),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

class _RunTile extends StatelessWidget {
  final BenchmarkRun run;

  const _RunTile({required this.run});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final error = run.error;
    final hasError = error != null && error.isNotEmpty;
    final reply = run.reply;

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: AppSpacing.sm),
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: hasError
            ? scheme.errorContainer.withAlpha(120)
            : scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(AppRadius.small),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _truncate(run.prompt, 140),
            style: theme.textTheme.bodySmall
                ?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: AppSpacing.sm),
          if (hasError)
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.error_outline, size: 16, color: scheme.error),
                const SizedBox(width: AppSpacing.xs),
                Expanded(
                  child: Text(
                    _truncate(error, 180),
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: scheme.error),
                  ),
                ),
              ],
            )
          else
            Text(
              _truncate(reply ?? '(no reply)', 200),
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          const SizedBox(height: AppSpacing.sm),
          Wrap(
            spacing: AppSpacing.md,
            runSpacing: AppSpacing.xs,
            children: [
              _RunStat(
                icon: Icons.timer_outlined,
                text: 'Latency: ${_formatLatency(run.latencyMs)}',
              ),
              _RunStat(
                icon: Icons.star_outline,
                text: 'Quality: '
                    '${run.quality == null ? 'n/a' : run.quality!.toStringAsFixed(2)}',
              ),
              if (run.outputTokens != null)
                _RunStat(
                  icon: Icons.north_outlined,
                  text: '${run.outputTokens} tokens',
                ),
              if (run.sentimentLabel != null)
                _RunStat(
                  icon: Icons.sentiment_neutral_outlined,
                  text: run.sentimentLabel!,
                ),
              if (run.qualityJudge != null)
                _RunStat(icon: Icons.gavel_outlined, text: run.qualityJudge!),
            ],
          ),
          if (run.expectedSentiment != null &&
              run.sentimentLabel != null &&
              run.expectedSentiment != run.sentimentLabel) ...[
            const SizedBox(height: AppSpacing.xs),
            Text(
              'Expected ${run.expectedSentiment} but got ${run.sentimentLabel}',
              style:
                  theme.textTheme.labelSmall?.copyWith(color: scheme.error),
            ),
          ],
        ],
      ),
    );
  }
}

class _RunStat extends StatelessWidget {
  final IconData icon;
  final String text;

  const _RunStat({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 13, color: scheme.onSurfaceVariant),
        const SizedBox(width: AppSpacing.xs),
        Text(
          text,
          style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
        ),
      ],
    );
  }
}

class _RankingCard extends StatelessWidget {
  final List<BenchmarkRanking> ranking;

  const _RankingCard({required this.ranking});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Card(
      elevation: AppElevation.level1,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.card),
      ),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Ranking',
              style: theme.textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: AppSpacing.md),
            for (final entry in ranking)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
                child: Row(
                  children: [
                    Container(
                      width: 28,
                      height: 28,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: entry.rank == 1
                            ? scheme.primary
                            : scheme.surfaceContainerHighest,
                        shape: BoxShape.circle,
                      ),
                      child: Text(
                        entry.rank.toString(),
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: entry.rank == 1
                              ? scheme.onPrimary
                              : scheme.onSurfaceVariant,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    const SizedBox(width: AppSpacing.md),
                    Expanded(
                      child: Text(
                        '${entry.provider} · ${entry.model}',
                        style: theme.textTheme.bodyMedium,
                      ),
                    ),
                    Text(
                      entry.overallScore.toStringAsFixed(1),
                      style: theme.textTheme.titleSmall
                          ?.copyWith(fontWeight: FontWeight.w700),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Charts
// ---------------------------------------------------------------------------

class _ChartCard extends StatelessWidget {
  final String title;
  final String subtitle;
  final String semanticsLabel;
  final Widget child;

  const _ChartCard({
    required this.title,
    required this.subtitle,
    required this.semanticsLabel,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      elevation: AppElevation.level1,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.card),
      ),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: theme.textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              subtitle,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: AppSpacing.lg),
            Semantics(label: semanticsLabel, child: child),
          ],
        ),
      ),
    );
  }
}

class _OverallScoreChart extends StatelessWidget {
  final List<BenchmarkResult> results;

  const _OverallScoreChart({required this.results});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final labelStyle = theme.textTheme.labelSmall
        ?.copyWith(color: scheme.onSurfaceVariant);
    final summary = results
        .map((r) => '${r.provider} scores ${r.overallScore.toStringAsFixed(1)}')
        .join('; ');

    return _ChartCard(
      title: 'Overall score by model',
      subtitle: 'Composite benchmark score from 0 to 100 — higher is better.',
      semanticsLabel: 'Bar chart of overall score per model. $summary.',
      child: LayoutBuilder(
        builder: (context, constraints) {
          final needed = results.length * 76.0;
          final width =
              needed < constraints.maxWidth ? constraints.maxWidth : needed;
          return SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SizedBox(
              width: width,
              height: 220,
              child: BarChart(
                BarChartData(
                  minY: 0,
                  maxY: 100,
                  alignment: BarChartAlignment.spaceAround,
                  barTouchData: BarTouchData(
                    enabled: true,
                    touchTooltipData: BarTouchTooltipData(
                      getTooltipColor: (group) => scheme.inverseSurface,
                      getTooltipItem: (group, groupIndex, rod, rodIndex) =>
                          BarTooltipItem(
                        rod.toY.toStringAsFixed(1),
                        TextStyle(
                          color: scheme.onInverseSurface,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                  gridData: FlGridData(
                    show: true,
                    drawVerticalLine: false,
                    horizontalInterval: 25,
                    getDrawingHorizontalLine: (value) => FlLine(
                      color: scheme.outlineVariant,
                      strokeWidth: 1,
                    ),
                  ),
                  borderData: FlBorderData(show: false),
                  titlesData: FlTitlesData(
                    topTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false),
                    ),
                    rightTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false),
                    ),
                    leftTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        reservedSize: 34,
                        interval: 25,
                        getTitlesWidget: (value, meta) => Text(
                          value.toInt().toString(),
                          style: labelStyle,
                        ),
                      ),
                    ),
                    bottomTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        reservedSize: 44,
                        getTitlesWidget: (value, meta) {
                          final index = value.toInt();
                          if (index < 0 || index >= results.length) {
                            return const SizedBox.shrink();
                          }
                          return Padding(
                            padding: const EdgeInsets.only(top: AppSpacing.sm),
                            child: Text(
                              _shortLabel(results[index].provider),
                              textAlign: TextAlign.center,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: labelStyle,
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                  barGroups: [
                    for (var i = 0; i < results.length; i++)
                      BarChartGroupData(
                        x: i,
                        barRods: [
                          BarChartRodData(
                            toY: results[i].overallScore.clamp(0, 100).toDouble(),
                            color: scheme.primary,
                            width: 22,
                            borderRadius: const BorderRadius.vertical(
                              top: Radius.circular(AppRadius.small),
                            ),
                          ),
                        ],
                      ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _QualityAccuracyChart extends StatelessWidget {
  final List<BenchmarkResult> results;

  const _QualityAccuracyChart({required this.results});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final labelStyle = theme.textTheme.labelSmall
        ?.copyWith(color: scheme.onSurfaceVariant);
    final qualityColor = scheme.tertiary;
    final accuracyColor = scheme.secondary;
    final summary = results
        .map((r) =>
            '${r.provider}: quality ${(r.avgQuality * 100).toStringAsFixed(0)} '
            'out of 100, sentiment accuracy ${_formatAccuracy(r.sentimentAccuracy)}')
        .join('; ');

    return _ChartCard(
      title: 'Quality vs sentiment accuracy',
      subtitle: 'Both scales run 0 to 100 so they can be compared per model.',
      semanticsLabel:
          'Grouped bar chart comparing reply quality against sentiment '
          'accuracy for each model. $summary.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _LegendDot(color: qualityColor, label: 'Avg quality'),
              const SizedBox(width: AppSpacing.lg),
              _LegendDot(color: accuracyColor, label: 'Sentiment accuracy'),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          LayoutBuilder(
            builder: (context, constraints) {
              final needed = results.length * 96.0;
              final width =
                  needed < constraints.maxWidth ? constraints.maxWidth : needed;
              return SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: SizedBox(
                  width: width,
                  height: 220,
                  child: BarChart(
                    BarChartData(
                      minY: 0,
                      maxY: 100,
                      alignment: BarChartAlignment.spaceAround,
                      barTouchData: BarTouchData(
                        enabled: true,
                        touchTooltipData: BarTouchTooltipData(
                          getTooltipColor: (group) => scheme.inverseSurface,
                          getTooltipItem: (group, groupIndex, rod, rodIndex) =>
                              BarTooltipItem(
                            '${rod.toY.toStringAsFixed(0)} / 100',
                            TextStyle(
                              color: scheme.onInverseSurface,
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                      gridData: FlGridData(
                        show: true,
                        drawVerticalLine: false,
                        horizontalInterval: 25,
                        getDrawingHorizontalLine: (value) => FlLine(
                          color: scheme.outlineVariant,
                          strokeWidth: 1,
                        ),
                      ),
                      borderData: FlBorderData(show: false),
                      titlesData: FlTitlesData(
                        topTitles: const AxisTitles(
                          sideTitles: SideTitles(showTitles: false),
                        ),
                        rightTitles: const AxisTitles(
                          sideTitles: SideTitles(showTitles: false),
                        ),
                        leftTitles: AxisTitles(
                          sideTitles: SideTitles(
                            showTitles: true,
                            reservedSize: 34,
                            interval: 25,
                            getTitlesWidget: (value, meta) => Text(
                              value.toInt().toString(),
                              style: labelStyle,
                            ),
                          ),
                        ),
                        bottomTitles: AxisTitles(
                          sideTitles: SideTitles(
                            showTitles: true,
                            reservedSize: 44,
                            getTitlesWidget: (value, meta) {
                              final index = value.toInt();
                              if (index < 0 || index >= results.length) {
                                return const SizedBox.shrink();
                              }
                              return Padding(
                                padding:
                                    const EdgeInsets.only(top: AppSpacing.sm),
                                child: Text(
                                  _shortLabel(results[index].provider),
                                  textAlign: TextAlign.center,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: labelStyle,
                                ),
                              );
                            },
                          ),
                        ),
                      ),
                      barGroups: [
                        for (var i = 0; i < results.length; i++)
                          BarChartGroupData(
                            x: i,
                            barsSpace: 6,
                            barRods: [
                              BarChartRodData(
                                toY: (results[i].avgQuality * 100)
                                    .clamp(0, 100)
                                    .toDouble(),
                                color: qualityColor,
                                width: 14,
                                borderRadius: const BorderRadius.vertical(
                                  top: Radius.circular(AppRadius.small),
                                ),
                              ),
                              BarChartRodData(
                                toY: ((results[i].sentimentAccuracy ?? 0) * 100)
                                    .clamp(0, 100)
                                    .toDouble(),
                                color: accuracyColor,
                                width: 14,
                                borderRadius: const BorderRadius.vertical(
                                  top: Radius.circular(AppRadius.small),
                                ),
                              ),
                            ],
                          ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}

class _LegendDot extends StatelessWidget {
  final Color color;
  final String label;

  const _LegendDot({required this.color, required this.label});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: AppSpacing.xs),
        Text(label, style: theme.textTheme.labelSmall),
      ],
    );
  }
}
