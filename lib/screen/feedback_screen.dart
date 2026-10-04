import 'package:bmsc/service/feedback_service.dart';
import 'package:bmsc/util/logger.dart';
import 'package:flutter/material.dart';

/// 应用内反馈表单：问题描述（必填）+ 联系方式（可选）+ 可附带应用日志，
/// 版本与系统信息自动随反馈提交（见 FeedbackService.buildPayload）。
class FeedbackScreen extends StatefulWidget {
  const FeedbackScreen({super.key});

  @override
  State<FeedbackScreen> createState() => _FeedbackScreenState();
}

class _FeedbackScreenState extends State<FeedbackScreen> {
  final TextEditingController _contentController = TextEditingController();
  final TextEditingController _contactController = TextEditingController();

  int get _logCount => LoggerUtils.logs.length;
  late bool _attachLogs = _logCount > 0;
  bool _submitting = false;

  @override
  void dispose() {
    _contentController.dispose();
    _contactController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final content = _contentController.text.trim();
    if (content.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请填写问题描述')),
      );
      return;
    }
    setState(() => _submitting = true);
    try {
      await FeedbackService.submit(
        content: content,
        contact: _contactController.text,
        logs: _attachLogs ? LoggerUtils.formatLogs() : '',
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('反馈已提交，感谢！')),
      );
      Navigator.pop(context);
    } on FeedbackSubmitException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('提交失败: ${e.message}')),
      );
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('问题反馈'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (!FeedbackService.isConfigured)
            Card(
              color: Theme.of(context).colorScheme.errorContainer,
              child: const Padding(
                padding: EdgeInsets.all(12),
                child: Text('应用内反馈尚未配置，请改用 GitHub Issues 反馈'),
              ),
            ),
          TextField(
            controller: _contentController,
            minLines: 5,
            maxLines: 10,
            maxLength: FeedbackService.maxContentLength,
            decoration: const InputDecoration(
              labelText: '问题描述',
              hintText: '请描述遇到的问题、复现步骤等',
              alignLabelWithHint: true,
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _contactController,
            decoration: const InputDecoration(
              labelText: '联系方式（可选）',
              hintText: '邮箱 / GitHub ID / B 站 UID，便于开发者回复',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 4),
          SwitchListTile(
            title: const Text('附带应用日志'),
            subtitle: Text(
              _logCount > 0
                  ? '共 $_logCount 条，脱敏后随反馈提交'
                  : '暂无日志（日志页可开启日志记录）',
            ),
            value: _attachLogs,
            onChanged: _logCount > 0
                ? (value) => setState(() => _attachLogs = value)
                : null,
          ),
          const ListTile(
            dense: true,
            leading: Icon(Icons.info_outline, size: 20),
            title: Text('将自动附带应用版本与系统信息'),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed:
                _submitting || !FeedbackService.isConfigured ? null : _submit,
            icon: _submitting
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.send),
            label: Text(_submitting ? '提交中…' : '提交'),
          ),
        ],
      ),
    );
  }
}
