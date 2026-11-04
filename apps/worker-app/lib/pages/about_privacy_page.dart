import 'package:fish_core/fish_core.dart';
import 'package:flutter/material.dart';

/// 关于 祁连山电竞 / 隐私政策（内容来自管理端可编辑模块 GET /public/about|privacy，客户端零硬编码）
class AboutPrivacyPage extends StatefulWidget {
  const AboutPrivacyPage({super.key, required this.kind});

  final String kind; // about / privacy

  @override
  State<AboutPrivacyPage> createState() => _AboutPrivacyPageState();
}

class _AboutPrivacyPageState extends State<AboutPrivacyPage> {
  final ApiClient _api = ApiClient();
  String? _title;
  String? _content;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final resp = await _api.request('GET', '/public/${widget.kind}');
      final data = resp['data'] as Map<String, dynamic>? ?? {};
      setState(() {
        _title = '${data['title'] ?? (widget.kind == 'about' ? '关于 祁连山电竞' : '隐私政策')}';
        _content = '${data['content'] ?? ''}';
        _loading = false;
      });
    } on ApiException catch (e) {
      setState(() {
        _error = e.message;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(_title ?? (widget.kind == 'about' ? '关于 祁连山电竞' : '隐私政策'))),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(_error!, style: const TextStyle(color: AppColors.error)),
                      const SizedBox(height: AppSpacing.md),
                      FilledButton(onPressed: _load, child: const Text('重试')),
                    ],
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.all(AppSpacing.xl),
                  children: [
                    if (widget.kind == 'about') ...[
                      const SizedBox(height: AppSpacing.xl),
                      Center(
                        child: Container(
                          width: 72,
                          height: 72,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: AppColors.primary.withValues(alpha: 0.08),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: const Icon(Icons.sports_esports, size: 36, color: AppColors.primary),
                        ),
                      ),
                      const SizedBox(height: AppSpacing.lg),
                      Center(
                        child: Text(
                          _title ?? '',
                          style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
                        ),
                      ),
                      const SizedBox(height: AppSpacing.xl),
                    ],
                    Text(
                      _content ?? '',
                      style: const TextStyle(fontSize: 14, color: AppColors.textSecondary, height: 1.8),
                    ),
                  ],
                ),
    );
  }
}
