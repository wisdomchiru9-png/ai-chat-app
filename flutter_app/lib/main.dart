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
  static String get sessionsEndpoint => "$baseUrl/sessions";
}

// ---------------------------------------------------------------------------
// App with Navigation State
// ---------------------------------------------------------------------------
class AIChatApp extends StatefulWidget {
  const AIChatApp({super.key});

  @override
  State<AIChatApp> createState() => _AIChatAppState();
}

class _AIChatAppState extends State<AIChatApp> {
  String? _activeSessionId;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AI Chat',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      home: _activeSessionId == null
          ? SessionListScreen(
              onSelectSession: (sessionId) {
                setState(() => _activeSessionId = sessionId);
              },
            )
          : ChatScreen(
              sessionId: _activeSessionId,
              onBack: () {
                setState(() => _activeSessionId = null);
              },
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

class Session {
  final String sessionId;
  final String title;
  final DateTime createdAt;
  final int messageCount;

  Session({
    required this.sessionId,
    required this.title,
    required this.createdAt,
    this.messageCount = 0,
  });

  factory Session.fromJson(Map<String, dynamic> json) {
    return Session(
      sessionId: json['session_id'] ?? '',
      title: json['title'] ?? 'Chat',
      createdAt: DateTime.tryParse(json['created_at'] ?? '') ?? DateTime.now(),
      messageCount: json['message_count'] ?? 0,
    );
  }
}

// ---------------------------------------------------------------------------
// Session List Screen (with create new session)
// ---------------------------------------------------------------------------
class SessionListScreen extends StatefulWidget {
  final Function(String) onSelectSession;

  const SessionListScreen({
    super.key,
    required this.onSelectSession,
  });

  @override
  State<SessionListScreen> createState() => _SessionListScreenState();
}

class _SessionListScreenState extends State<SessionListScreen> {
  late Future<List<Session>> _sessionsFuture;

  @override
  void initState() {
    super.initState();
    _sessionsFuture = _fetchSessions();
  }

  Future<List<Session>> _fetchSessions() async {
    try {
      final response = await http.get(
        Uri.parse(BackendConfig.sessionsEndpoint),
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as List;
        return data.map((s) => Session.fromJson(s)).toList();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Failed to load sessions: $e")),
        );
      }
    }
    return [];
  }

  Future<void> _createNewSession() async {
    final titleController = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("New Chat Session"),
        content: TextField(
          controller: titleController,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: "Enter session title...",
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text("Cancel"),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(ctx, titleController.text.trim().isNotEmpty ? titleController.text.trim() : "New Chat"),
            child: const Text("Create"),
          ),
        ],
      ),
    );

    if (result != null) {
      try {
        final response = await http.post(
          Uri.parse(BackendConfig.sessionsEndpoint),
          headers: {"Content-Type": "application/json"},
          body: jsonEncode({"title": result}),
        ).timeout(const Duration(seconds: 10));

        if (response.statusCode == 201) {
          final data = jsonDecode(response.body);
          if (mounted) {
            widget.onSelectSession(data['session_id']);
          }
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text("Failed to create session: $e")),
          );
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("AI Chat Sessions"),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: "Backend settings",
            onPressed: _showSettings,
          ),
        ],
      ),
      body: FutureBuilder<List<Session>>(
        future: _sessionsFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }

          if (snapshot.hasError) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.error_outline, size: 48, color: Colors.red),
                  const SizedBox(height: 16),
                  Text("Error: ${snapshot.error}"),
                  const SizedBox(height: 16),
                  FilledButton.tonal(
                    onPressed: () {
                      setState(() {
                        _sessionsFuture = _fetchSessions();
                      });
                    },
                    child: const Text("Retry"),
                  ),
                ],
              ),
            );
          }

          final sessions = snapshot.data ?? [];

          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(16.0),
                child: FilledButton.icon(
                  onPressed: _createNewSession,
                  icon: const Icon(Icons.add),
                  label: const Text("New Chat"),
                ),
              ),
              if (sessions.isEmpty)
                const Expanded(
                  child: Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.chat_bubble_outline, size: 48, color: Colors.grey),
                        SizedBox(height: 16),
                        Text("No sessions yet. Create one to start!"),
                      ],
                    ),
                  ),
                )
              else
                Expanded(
                  child: ListView.builder(
                    itemCount: sessions.length,
                    itemBuilder: (context, index) {
                      final session = sessions[index];
                      return Card(
                        margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        child: ListTile(
                          title: Text(session.title),
                          subtitle: Text(
                            "${session.messageCount} messages • ${_formatDate(session.createdAt)}",
                          ),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () => widget.onSelectSession(session.sessionId),
                        ),
                      );
                    },
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  String _formatDate(DateTime date) {
    final now = DateTime.now();
    if (date.year == now.year &&
        date.month == now.month &&
        date.day == now.day) {
      return "Today ${date.hour}:${date.minute.toString().padLeft(2, '0')}";
    }
    return "${date.month}/${date.day}/${date.year}";
  }

  Future<void> _showSettings() async {
    final controller = TextEditingController(text: BackendConfig.baseUrl);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Backend URL"),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text("Enter the base URL of your FastAPI backend:"),
            const SizedBox(height: 16),
            TextField(
              controller: controller,
              autofocus: true,
              decoration: const InputDecoration(
                hintText: "http://localhost:8000",
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                ActionChip(
                  label: const Text("Android Emulator"),
                  onPressed: () => controller.text = BackendConfig.kAndroidEmulator,
                ),
                ActionChip(
                  label: const Text("Localhost"),
                  onPressed: () => controller.text = BackendConfig.kLocalhost,
                ),
              ],
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text("Cancel"),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text("Save"),
          ),
        ],
      ),
    );

    if (result != null && result.isNotEmpty) {
      BackendConfig.baseUrl = result.replaceFirst(RegExp(r'/$'), '');
      if (mounted) {
        setState(() {
          _sessionsFuture = _fetchSessions();
        });
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Chat Screen
// ---------------------------------------------------------------------------
class ChatScreen extends StatefulWidget {
  final String? sessionId;
  final VoidCallback? onBack;

  const ChatScreen({
    super.key,
    this.sessionId,
    this.onBack,
  });

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
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _insertMessage(ChatMessage msg) {
    _messages.add(msg);
    final idx = _messages.length - 1;
    _listKey.currentState?.insertItem(idx, duration: const Duration(milliseconds: 300));
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

      final body = {
        "message": text,
        "history": history,
        if (widget.sessionId != null) "session_id": widget.sessionId,
      };

      final response = await http
          .post(
            Uri.parse(BackendConfig.chatEndpoint),
            headers: {"Content-Type": "application/json"},
            body: jsonEncode(body),
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
      builder: (ctx) => AlertDialog(
        title: const Text("Backend URL"),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text("Enter the base URL of your FastAPI backend:"),
            const SizedBox(height: 16),
            TextField(
              controller: controller,
              autofocus: true,
              decoration: const InputDecoration(
                hintText: "http://localhost:8000",
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                ActionChip(
                  label: const Text("Android Emulator"),
                  onPressed: () => controller.text = BackendConfig.kAndroidEmulator,
                ),
                ActionChip(
                  label: const Text("Localhost"),
                  onPressed: () => controller.text = BackendConfig.kLocalhost,
                ),
              ],
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text("Cancel"),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text("Save"),
          ),
        ],
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

  Future<void> _clearChat() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Clear chat?"),
        content: const Text("All messages in this conversation will be removed."),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text("Cancel"),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text("Clear"),
          ),
        ],
      ),
    );
    if (ok != true) return;
    while (_messages.isNotEmpty) {
      final lastIdx = _messages.length - 1;
      _listKey.currentState?.removeItem(
        lastIdx,
        (context, animation) => const SizedBox.shrink(),
        duration: const Duration(milliseconds: 150),
      );
      _messages.removeAt(lastIdx);
    }
    await Future<void>.delayed(const Duration(milliseconds: 150));
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
        leading: widget.onBack != null
            ? IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: widget.onBack,
              )
            : null,
        title: const Text("AI Chat"),
        actions: [
          IconButton(
            tooltip: "Clear chat",
            icon: const Icon(Icons.delete_sweep_outlined),
            onPressed: _clearChat,
          ),
          IconButton(
            tooltip: "Backend settings",
            icon: const Icon(Icons.settings_outlined),
            onPressed: _showSettings,
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: _messages.isEmpty
                ? const Center(
                    child: Text("No messages yet", style: TextStyle(color: Colors.grey)),
                  )
                : AnimatedList(
                    key: _listKey,
                    controller: _scrollController,
                    padding: const EdgeInsets.all(16),
                    initialItemCount: _messages.length,
                    itemBuilder: (context, index, animation) =>
                        _AnimatedMessageBubble(
                      message: _messages[index],
                      animation: animation,
                    ),
                  ),
          ),
          if (_isLoading) const _TypingIndicator(),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 8, 24),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _controller,
                    textInputAction: TextInputAction.send,
                    minLines: 1,
                    maxLines: 4,
                    decoration: InputDecoration(
                      hintText: "Type a message…",
                      suffixIcon: IconButton(
                        tooltip: "Send",
                        icon: const Icon(Icons.send_rounded),
                        onPressed: _isLoading ? null : _sendMessage,
                      ),
                    ),
                    onSubmitted: (_) => _sendMessage(),
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
// Animated Message Bubble with Sentiment Badge
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
    ).chain(CurveTween(curve: Curves.easeOut));

    return SlideTransition(
      position: animation.drive(slide),
      child: FadeTransition(
        opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
        child: _MessageBubble(message: message),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Message Bubble with Sentiment and Metadata
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

    return Align(
      alignment: align,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            if (!isUser) const SizedBox(width: 8),
            Flexible(
              child: GestureDetector(
                onLongPress: () => _copy(context, message.text),
                child: Tooltip(
                  message: "Long-press to copy",
                  preferBelow: false,
                  child: Container(
                    constraints: BoxConstraints(
                      maxWidth: MediaQuery.of(context).size.width * 0.78,
                    ),
                    padding:
                        const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    decoration: BoxDecoration(
                      color: bg,
                      borderRadius: BorderRadius.only(
                        topLeft: const Radius.circular(16),
                        topRight: const Radius.circular(16),
                        bottomLeft: Radius.circular(isUser ? 16 : 4),
                        bottomRight: Radius.circular(isUser ? 4 : 16),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SelectableText(
                          message.text,
                          style: TextStyle(color: fg),
                        ),
                        const SizedBox(height: 8),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            // Sentiment Badge
                            if (!isUser && message.sentiment != null)
                              _SentimentBadge(
                                label: message.sentiment!,
                                confidence: message.confidence ?? 0.0,
                              ),
                            if (!isUser && message.sentiment != null)
                              const SizedBox(width: 6),
                            // Time
                            Text(
                              _formatTime(message.timestamp),
                              style: TextStyle(
                                fontSize: 11,
                                color: fg.withAlpha(180),
                              ),
                            ),
                          ],
                        ),
                        // Provider info
                        if (!isUser && message.provider != null) ...[
                          const SizedBox(height: 4),
                          Text(
                            "${message.provider} • ${message.model}",
                            style: TextStyle(
                              fontSize: 10,
                              color: fg.withAlpha(140),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
            if (isUser) const SizedBox(width: 8),
          ],
        ),
      ),
    );
  }

  String _formatTime(DateTime time) {
    return "${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}";
  }
}

// ---------------------------------------------------------------------------
// Sentiment Badge (Colored indicator)
// ---------------------------------------------------------------------------
class _SentimentBadge extends StatelessWidget {
  final String label;
  final double confidence;

  const _SentimentBadge({
    required this.label,
    required this.confidence,
  });

  @override
  Widget build(BuildContext context) {
    Color badgeColor;
    IconData icon;

    final upperLabel = label.toUpperCase();
    if (upperLabel.contains("POSITIVE")) {
      badgeColor = Colors.green;
      icon = Icons.thumb_up_rounded;
    } else if (upperLabel.contains("NEGATIVE")) {
      badgeColor = Colors.red;
      icon = Icons.thumb_down_rounded;
    } else {
      badgeColor = Colors.grey;
      icon = Icons.remove_circle_rounded;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: badgeColor.withAlpha(30),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: badgeColor.withAlpha(100), width: 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: badgeColor),
          const SizedBox(width: 4),
          Text(
            "${upperLabel.substring(0, 3)} ${(confidence * 100).toStringAsFixed(0)}%",
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w600,
              color: badgeColor,
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Typing Indicator (AI is typing...)
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
    _ctrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 600))
      ..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
      child: Row(
        children: [
          const SizedBox(width: 40),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(16),
                topRight: Radius.circular(16),
                bottomLeft: Radius.circular(4),
                bottomRight: Radius.circular(16),
              ),
            ),
            child: Row(
              children: List.generate(3, (i) {
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: ScaleTransition(
                    scale: Tween<double>(begin: 0.7, end: 1.0).chain(
                      CurveTween(curve: Curves.easeInOut),
                    ).animate(
                      CurvedAnimation(
                        parent: _ctrl,
                        curve: Interval(
                          i * 0.2,
                          0.6 + i * 0.2,
                          curve: Curves.easeInOut,
                        ),
                      ),
                    ),
                    child: Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primary,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
                );
              }),
            ),
          ),
        ],
      ),
    );
  }
}
