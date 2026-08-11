import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:http/http.dart' as http;
import 'package:markdown/markdown.dart' as md;

import 'theme.dart';

void main() {
  runApp(const AIChatApp());
}

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------
class BackendConfig {
  static const String kLocalhost = "http://localhost:8000";
  static const String kAndroidEmulator = "http://10.0.2.2:8000";
  static String baseUrl = kAndroidEmulator;

  static String get chatEndpoint => "$baseUrl/chat";
}

// ---------------------------------------------------------------------------
// App — uses AppTheme from theme.dart (design tokens + a11y labels)
// ---------------------------------------------------------------------------
class AIChatApp extends StatelessWidget {
  const AIChatApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AI Chat',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      home: Semantics(
        label: 'AI Chat conversation screen',
        child: const ChatScreen(),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Models
// ---------------------------------------------------------------------------
class ChatMessage {
  final String text;
  final bool isUser;
  final String? sentiment;
  final double? confidence;
  final String? provider;
  final String? model;
  final DateTime timestamp;

  ChatMessage({
    required this.text,
    required this.isUser,
    this.sentiment,
    this.confidence,
    this.provider,
    this.model,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();
}

// ---------------------------------------------------------------------------
// Chat Screen
// ---------------------------------------------------------------------------
class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final TextEditingController _controller = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final GlobalKey<AnimatedListState> _listKey = GlobalKey<AnimatedListState>();

  final List<ChatMessage> _messages = [];
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _insertMessage(ChatMessage(
        text:
            "Hi! I'm your AI assistant. Ask me anything — I analyze sentiment and reply using whatever LLM you've configured in the backend.\n\nTip: long-press any message to copy it.",
        isUser: false,
      ));
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollToBottom({bool force = false}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      final pos = _scrollController.position;
      final target = pos.maxScrollExtent;
      if (pos.pixels < target - 50 || force) {
        _scrollController.animateTo(
          target,
          duration: AppDurations.medium,
          curve: AppCurves.enter,
        );
      }
    });
  }

  void _insertMessage(ChatMessage msg) {
    _messages.add(msg);
    final idx = _messages.length - 1;
    _listKey.currentState?.insertItem(idx, duration: AppDurations.medium);
    _scrollToBottom();
  }

  Future<void> _sendMessage() async {
    final text = _controller.text.trim();
    if (text.isEmpty || _isLoading) return;

    setState(() => _isLoading = true);
    _insertMessage(ChatMessage(text: text, isUser: true));
    _controller.clear();
    _scrollToBottom(force: true);

    try {
      final history = _messages
          .where((m) =>
              !m.text.startsWith("Couldn't reach the backend") &&
              !m.text.startsWith("Server error"))
          .map((m) => {
                "role": m.isUser ? "user" : "assistant",
                "content": m.text,
              })
          .toList(growable: false);

      final response = await http
          .post(
            Uri.parse(BackendConfig.chatEndpoint),
            headers: {"Content-Type": "application/json"},
            body: jsonEncode({"message": text, "history": history}),
          )
          .timeout(const Duration(seconds: 120));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        _insertMessage(ChatMessage(
          text: data["reply"] ?? "(empty reply)",
          isUser: false,
          sentiment: data["sentiment"],
          confidence: (data["confidence"] as num?)?.toDouble(),
          provider: data["provider"],
          model: data["model"],
        ));
      } else {
        String detail = response.body;
        try {
          detail = jsonDecode(response.body)["detail"] ?? detail;
        } catch (_) {}
        _insertMessage(ChatMessage(
          text: "Server error ${response.statusCode}: $detail",
          isUser: false,
        ));
      }
    } catch (e) {
      _insertMessage(ChatMessage(
        text: "Couldn't reach the backend.\n"
            "Make sure it's running at ${BackendConfig.baseUrl}\n"
            "Error: $e",
        isUser: false,
      ));
    } finally {
      if (mounted) setState(() => _isLoading = false);
      _scrollToBottom(force: true);
    }
  }

  Future<void> _showSettings() async {
    final controller = TextEditingController(text: BackendConfig.baseUrl);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => Semantics(
        label: 'Backend settings dialog',
        child: AlertDialog(
          title: const Text("Backend URL"),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text("Enter the base URL of your FastAPI backend:"),
              const SizedBox(height: AppSpacing.md),
              TextField(
                controller: controller,
                autofocus: true,
                decoration: const InputDecoration(
                  hintText: "http://localhost:8000",
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              Wrap(
                spacing: AppSpacing.sm,
                runSpacing: AppSpacing.sm,
                children: [
                  _presetChip("Android Emulator", BackendConfig.kAndroidEmulator, controller),
                  _presetChip("Localhost", BackendConfig.kLocalhost, controller),
                ],
              ),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text("Cancel")),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, controller.text.trim()),
                child: const Text("Save")),
          ],
        ),
      ),
    );
    if (result != null && result.isNotEmpty) {
      setState(() {
        BackendConfig.baseUrl = result.replaceFirst(RegExp(r'/$'), '');
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Backend set to ${BackendConfig.baseUrl}")),
        );
      }
    }
  }

  Widget _presetChip(
          String label, String value, TextEditingController target) =>
      ActionChip(
        label: Text(label),
        tooltip: "Set URL to $value",
        onPressed: () => target.text = value,
      );

  Future<void> _clearChat() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Clear chat?"),
        content: const Text("All messages in this conversation will be removed."),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text("Cancel")),
          FilledButton(
              style: FilledButton.styleFrom(
                  backgroundColor: Theme.of(ctx).colorScheme.error),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text("Clear")),
        ],
      ),
    );
    if (ok != true) return;
    while (_messages.isNotEmpty) {
      final lastIdx = _messages.length - 1;
      _listKey.currentState?.removeItem(
        lastIdx,
        (context, animation) => const SizedBox.shrink(),
        duration: AppDurations.fast,
      );
      _messages.removeAt(lastIdx);
    }
    await Future<void>.delayed(AppDurations.fast);
    if (mounted) {
      _insertMessage(ChatMessage(
        text: "Chat cleared. How can I help?",
        isUser: false,
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("AI Chat"),
        actions: [
          Semantics(
            label: AppSemantics.clearButton,
            button: true,
            child: IconButton(
              tooltip: "Clear chat",
              icon: const Icon(Icons.delete_sweep_outlined),
              onPressed: _clearChat,
            ),
          ),
          Semantics(
            label: AppSemantics.settingsButton,
            button: true,
            child: IconButton(
              tooltip: "Backend settings",
              icon: const Icon(Icons.settings_outlined),
              onPressed: _showSettings,
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: _messages.isEmpty
                ? Center(
                    child: Semantics(
                      label: 'No messages yet placeholder',
                      child: const Text("No messages yet",
                          style: TextStyle(color: Colors.grey)),
                    ),
                  )
                : AnimatedList(
                    key: _listKey,
                    controller: _scrollController,
                    padding: const EdgeInsets.all(AppSpacing.md),
                    initialItemCount: _messages.length,
                    itemBuilder: (context, index, animation) =>
                        _AnimatedMessageBubble(
                      message: _messages[index],
                      animation: animation,
                    ),
                  ),
          ),
          AnimatedSize(
            duration: AppDurations.fast,
            curve: AppCurves.standard,
            child: _isLoading ? const _TypingIndicator() : const SizedBox.shrink(),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.sm, AppSpacing.sm, AppSpacing.xl),
            child: Row(
              children: [
                Expanded(
                  child: Semantics(
                    label: AppSemantics.messageField,
                    textField: true,
                    child: TextField(
                      controller: _controller,
                      textInputAction: TextInputAction.send,
                      minLines: 1,
                      maxLines: 4,
                      decoration: InputDecoration(
                        hintText: "Type a message…",
                        suffixIcon: Semantics(
                          label: AppSemantics.sendButton,
                          button: true,
                          child: IconButton(
                            tooltip: "Send",
                            icon: const Icon(Icons.send_rounded),
                            onPressed: _isLoading ? null : _sendMessage,
                          ),
                        ),
                      ),
                      onSubmitted: (_) => _sendMessage(),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Animated message bubble (fade + slide in)
// ---------------------------------------------------------------------------
class _AnimatedMessageBubble extends StatelessWidget {
  final ChatMessage message;
  final Animation<double> animation;

  const _AnimatedMessageBubble({
    required this.message,
    required this.animation,
  });

  @override
  Widget build(BuildContext context) {
    final slide = Tween<Offset>(
      begin: Offset(message.isUser ? 0.25 : -0.25, 0.08),
      end: Offset.zero,
    ).chain(CurveTween(curve: AppCurves.enter));
    return SlideTransition(
      position: animation.drive(slide),
      child: FadeTransition(
        opacity: CurvedAnimation(parent: animation, curve: AppCurves.enter),
        child: _MessageBubble(message: message),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Message Bubble
// ---------------------------------------------------------------------------
class _MessageBubble extends StatelessWidget {
  final ChatMessage message;

  const _MessageBubble({required this.message});

  Future<void> _copy(BuildContext context, String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (context.mounted) {
      ScaffoldMessenger.of(context).removeCurrentSnackBar();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Copied to clipboard"),
          behavior: SnackBarBehavior.floating,
          duration: Duration(seconds: 1, milliseconds: 500),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isUser = message.isUser;
    final align = isUser ? Alignment.centerRight : Alignment.centerLeft;
    final bg = isUser
        ? theme.colorScheme.primaryContainer
        : theme.colorScheme.surfaceContainerHighest;
    final fg = isUser
        ? theme.colorScheme.onPrimaryContainer
        : theme.colorScheme.onSurfaceVariant;
    final preview = message.text.replaceAll('\n', ' ').length > 80
        ? message.text.replaceAll('\n', ' ').substring(0, 80)
        : message.text.replaceAll('\n', ' ');

    return Align(
      alignment: align,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Semantics(
          label: isUser
              ? AppSemantics.userMessage(preview)
              : AppSemantics.aiMessage(preview),
          onLongPressHint: 'Copy message',
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              if (!isUser) ...[
                _Avatar(isUser: false),
                const SizedBox(width: AppSpacing.sm),
              ],
              Flexible(
                child: InkWell(
                  borderRadius: BorderRadius.only(
                    topLeft: const Radius.circular(AppRadius.bubble),
                    topRight: const Radius.circular(AppRadius.bubble),
                    bottomLeft: Radius.circular(isUser ? AppRadius.bubble : AppRadius.small),
                    bottomRight: Radius.circular(isUser ? AppRadius.small : AppRadius.bubble),
                  ),
                  onLongPress: () => _copy(context, message.text),
                  child: Tooltip(
                    message: "Long-press to copy",
                    preferBelow: false,
                    child: Container(
                      constraints: BoxConstraints(
                        maxWidth: MediaQuery.of(context).size.width * 0.78,
                      ),
                      padding: const EdgeInsets.symmetric(
                          horizontal: AppSpacing.md, vertical: AppSpacing.sm + 2),
                      decoration: BoxDecoration(
                        color: bg,
                        borderRadius: BorderRadius.only(
                          topLeft: const Radius.circular(AppRadius.bubble),
                          topRight: const Radius.circular(AppRadius.bubble),
                          bottomLeft: Radius.circular(isUser ? AppRadius.bubble : AppRadius.small),
                          bottomRight: Radius.circular(isUser ? AppRadius.small : AppRadius.bubble),
                        ),
                      ),
                      child: DefaultTextStyle(
                        style: AppTextStyles.bubbleBody.copyWith(color: fg),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (isUser)
                              SelectableText(message.text)
                            else
                              _MarkdownBody(text: message.text, fg: fg),
                            const SizedBox(height: AppSpacing.sm - 2),
                            Wrap(
                              spacing: AppSpacing.sm,
                              runSpacing: AppSpacing.xs,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [
                                Text(
                                  _time(message.timestamp),
                                  style: AppTextStyles.bubbleMeta
                                      .copyWith(color: fg.withValues(alpha: 0.6)),
                                ),
                                if (message.sentiment != null)
                                  _SentimentChip(
                                    label: message.sentiment!,
                                    confidence: message.confidence,
                                  ),
                                if (message.provider != null)
                                  _Badge(
                                      text: message.provider!,
                                      fg: fg,
                                      fontWeight: FontWeight.w800,
                                      backgroundAlpha: 0.14),
                                if (message.model != null)
                                  _Badge(
                                      text: message.model!,
                                      fg: fg,
                                      backgroundAlpha: 0.08),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              if (isUser) ...[
                const SizedBox(width: AppSpacing.sm),
                _Avatar(isUser: true),
              ],
            ],
          ),
        ),
      ),
    );
  }

  String _time(DateTime t) {
    final h = t.hour.toString().padLeft(2, '0');
    final m = t.minute.toString().padLeft(2, '0');
    return "$h:$m";
  }
}

// ---------------------------------------------------------------------------
// Small widgets
// ---------------------------------------------------------------------------
class _Avatar extends StatelessWidget {
  final bool isUser;

  const _Avatar({required this.isUser});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = isUser ? theme.colorScheme.secondaryContainer : theme.colorScheme.primary;
    final onColor = isUser ? theme.colorScheme.onSecondaryContainer : theme.colorScheme.onPrimary;
    return Semantics(
      label: isUser ? AppSemantics.userAvatar : AppSemantics.aiAvatar,
      child: CircleAvatar(
        radius: 16,
        backgroundColor: color,
        child: Icon(
          isUser ? Icons.person_outline : Icons.smart_toy_outlined,
          color: onColor,
          size: 18,
        ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  final String text;
  final Color fg;
  final FontWeight fontWeight;
  final double backgroundAlpha;

  const _Badge({
    required this.text,
    required this.fg,
    this.fontWeight = FontWeight.w600,
    this.backgroundAlpha = 0.08,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.xs + 2, vertical: 2),
      decoration: BoxDecoration(
        color: fg.withValues(alpha: backgroundAlpha),
        borderRadius: BorderRadius.circular(AppRadius.badge),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 10,
          color: fg.withValues(alpha: 0.85),
          fontWeight: fontWeight,
        ),
      ),
    );
  }
}

class _SentimentChip extends StatelessWidget {
  final String label;
  final double? confidence;

  const _SentimentChip({required this.label, this.confidence});

  @override
  Widget build(BuildContext context) {
    final positive = label.toUpperCase().contains("POSITIVE");
    final color = positive ? AppColors.positive : AppColors.negative;
    final icon = positive
        ? Icons.sentiment_satisfied_alt
        : Icons.sentiment_dissatisfied;
    final pct = confidence == null
        ? ""
        : " ${(confidence! * 100).toStringAsFixed(0)}%";
    return Semantics(
      label: 'Sentiment: $label ${pct.trim()}',
      child: Container(
        padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.xs + 2, vertical: 2),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(AppRadius.badge),
          border: Border.all(color: color.withValues(alpha: 0.25)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 12, color: color),
            const SizedBox(width: 3),
            Text(
              "${label.toLowerCase()}$pct",
              style: TextStyle(
                  fontSize: 10, color: color, fontWeight: FontWeight.w700),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Markdown rendering (only for AI replies, users get plain text)
// ---------------------------------------------------------------------------
class _MarkdownBody extends StatelessWidget {
  final String text;
  final Color fg;

  const _MarkdownBody({required this.text, required this.fg});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return MarkdownBody(
      data: text,
      selectable: true,
      softLineBreak: true,
      extensionSet: md.ExtensionSet.gitHubFlavored,
      styleSheet: MarkdownStyleSheet(
        p: AppTextStyles.bubbleBody.copyWith(color: fg, height: 1.35),
        h1: TextStyle(
            color: fg, fontSize: 20, fontWeight: FontWeight.w800, height: 1.25),
        h2: TextStyle(
            color: fg, fontSize: 18, fontWeight: FontWeight.w700, height: 1.25),
        h3: TextStyle(
            color: fg, fontSize: 16, fontWeight: FontWeight.w700, height: 1.25),
        strong: TextStyle(fontWeight: FontWeight.w800, color: fg),
        em: TextStyle(fontStyle: FontStyle.italic, color: fg),
        code: TextStyle(
          fontFamily: 'monospace',
          fontSize: 13,
          color: fg,
          backgroundColor: fg.withValues(alpha: 0.1),
        ),
        codeblockDecoration: BoxDecoration(
          color: theme.colorScheme.surface,
          borderRadius: BorderRadius.circular(AppRadius.small),
          border: Border.all(color: fg.withValues(alpha: 0.15)),
        ),
        blockquoteDecoration: BoxDecoration(
          color: fg.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(AppRadius.xs),
          border: Border(
            left: BorderSide(width: 3, color: fg.withValues(alpha: 0.4)),
          ),
        ),
        listBullet: TextStyle(color: fg, fontSize: 15),
        horizontalRuleDecoration: BoxDecoration(
          border: Border.all(width: 1, color: fg.withValues(alpha: 0.2)),
        ),
        a: TextStyle(
          color: theme.colorScheme.primary,
          decoration: TextDecoration.underline,
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Animated typing indicator (bouncing dots)
// ---------------------------------------------------------------------------
class _TypingIndicator extends StatefulWidget {
  const _TypingIndicator();

  @override
  State<_TypingIndicator> createState() => _TypingIndicatorState();
}

class _TypingIndicatorState extends State<_TypingIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: AppDurations.typingDot)
      ..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final fg = Theme.of(context).colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.symmetric(
          vertical: AppSpacing.sm, horizontal: AppSpacing.md),
      child: Semantics(
        label: AppSemantics.typingIndicator,
        liveRegion: true,
        child: Row(
          children: [
            const SizedBox(width: AppSpacing.xl),
            Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.md, vertical: AppSpacing.sm + 2),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(AppRadius.bubble),
                  topRight: Radius.circular(AppRadius.bubble),
                  bottomLeft: Radius.circular(AppRadius.small),
                  bottomRight: Radius.circular(AppRadius.bubble),
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _dot(0, fg),
                  const SizedBox(width: 4),
                  _dot(1, fg),
                  const SizedBox(width: 4),
                  _dot(2, fg),
                  const SizedBox(width: 10),
                  Text(
                    "typing…",
                    style: AppTextStyles.typingHint.copyWith(
                      color: fg.withValues(alpha: 0.7),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _dot(int i, Color fg) {
    const delayPerDot = 0.16;
    final anim = TweenSequence<double>([
      TweenSequenceItem(
          tween: Tween(begin: 0, end: -6)
              .chain(CurveTween(curve: AppCurves.enter)),
          weight: 30),
      TweenSequenceItem(
          tween: Tween(begin: -6, end: 0)
              .chain(CurveTween(curve: AppCurves.exit)),
          weight: 30),
      TweenSequenceItem(tween: ConstantTween(0), weight: 40),
    ]).animate(CurvedAnimation(
      parent: _ctrl,
      curve: Interval(delayPerDot * i, delayPerDot * i + 0.6,
          curve: Curves.linear),
    ));
    return AnimatedBuilder(
      animation: anim,
      builder: (_, __) => Transform.translate(
        offset: Offset(0, anim.value),
        child: Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(
            color: fg.withValues(alpha: 0.7),
            shape: BoxShape.circle,
          ),
        ),
      ),
    );
  }
}
