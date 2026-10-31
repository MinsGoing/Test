import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:localsend_app/model/cross_file.dart';
import 'package:localsend_app/provider/network/send_provider.dart';
import 'package:localsend_app/provider/network/server/server_provider.dart';
import 'package:localsend_app/provider/selection/selected_sending_files_provider.dart';
import 'package:localsend_app/util/native/channel/android_channel.dart' as android_channel;
import 'package:localsend_app/util/native/cross_file_converters.dart';
import 'package:localsend_isolates/model/device.dart';
import 'package:localsend_isolates/model/file_type.dart';
import 'package:localsend_isolates/model/session_status.dart';
import 'package:path_provider/path_provider.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Route inbound requests inline only for the matching, visible conversation.
final ValueNotifier<String?> activeChatFingerprint = ValueNotifier<String?>(null);

/// Notify open chat screens whenever local received history changes.
final ValueNotifier<int> chatReceiveRevision = ValueNotifier<int>(0);

/// Serialize writes so concurrent received images cannot erase each other.
Future<void> _lastIncomingWrite = Future<void>.value();

/// Locally persisted send and receive history, not remote synchronization.
class _ChatRecord {
  final String id;
  final String name;
  final String? text;
  final String type;
  final String direction;
  String? path;
  final int timestamp;
  String status;

  _ChatRecord({
    required this.id,
    required this.name,
    required this.text,
    required this.type,
    required this.direction,
    required this.path,
    required this.timestamp,
    required this.status,
  });

  factory _ChatRecord.fromJson(Map<String, dynamic> json) => _ChatRecord(
        id: json['id'] as String,
        name: json['name'] as String,
        text: json['text'] as String?,
        type: json['type'] as String? ?? 'other',
        direction: json['direction'] as String? ?? 'out',
        path: json['path'] as String?,
        timestamp: json['timestamp'] as int,
        status: json['status'] as String? ?? 'failed',
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'text': text,
        'type': type,
        'direction': direction,
        'path': path,
        'timestamp': timestamp,
        'status': status,
      };
}


String _incomingHistoryKey(String fingerprint) => 'localsend_camera_chat_received_v1_$fingerprint';

/// Persist an accepted incoming file/message under its verified sender ID.
/// This history is local to the receiving device; no protocol changes.
Future<void> recordIncomingChat({
  required String fingerprint,
  required String entryId,
  required String name,
  required FileType fileType,
  required String? path,
  required String? message,
}) async {
  final next = _lastIncomingWrite.catchError((Object _) {}).then(
    (_) => _writeIncomingChat(
      fingerprint: fingerprint,
      entryId: entryId,
      name: name,
      fileType: fileType,
      path: path,
      message: message,
    ),
  );
  _lastIncomingWrite = next;
  await next;
}

Future<void> _writeIncomingChat({
  required String fingerprint,
  required String entryId,
  required String name,
  required FileType fileType,
  required String? path,
  required String? message,
}) async {
  if (fingerprint.isEmpty) return;
  final prefs = await SharedPreferences.getInstance();
  final key = _incomingHistoryKey(fingerprint);
  final raw = prefs.getString(key);
  final records = <_ChatRecord>[];
  if (raw != null) {
    try {
      final existing = jsonDecode(raw) as List<dynamic>;
      records.addAll(existing.map((item) => _ChatRecord.fromJson(Map<String, dynamic>.from(item as Map))));
    } catch (_) {
      // Damaged history must not interrupt the actual file receive.
    }
  }
  if (records.any((entry) => entry.id == entryId)) return;
  String? savedPreview;
  if (fileType == FileType.image && path != null && !path.startsWith('content://')) {
    savedPreview = await _buildChatPreview(path, 'received_$entryId');
  }
  records.add(
    _ChatRecord(
      id: entryId,
      name: name,
      text: message,
      type: fileType.name,
      direction: 'in',
      path: savedPreview,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      status: 'received',
    ),
  );
  if (records.length > 200) records.removeRange(0, records.length - 200);
  await prefs.setString(key, jsonEncode(records.map((e) => e.toJson()).toList()));
  chatReceiveRevision.value++;
}

/// Save a display preview independently of the transfer's temporary file.
Future<String?> _buildChatPreview(String path, String recordId) async {
  try {
    final bytes = await File(path).readAsBytes();
    final preview = await Isolate.run(() {
      final decoded = img.decodeImage(bytes);
      if (decoded == null) return null;
      final resized = decoded.width > 1600 ? img.copyResize(decoded, width: 1600) : decoded;
      return img.encodeJpg(resized, quality: 82);
    });
    if (preview == null) return null;
    final support = await getApplicationSupportDirectory();
    final previews = Directory('${support.path}/chat_sent_thumbnails');
    await previews.create(recursive: true);
    final output = File('${previews.path}/$recordId.jpg');
    await output.writeAsBytes(preview, flush: true);
    return output.path;
  } catch (_) {
    return null;
  }
}

/// A device-specific conversation screen for repeated LocalSend transfers.
class ChatSendPage extends StatefulWidget {
  final Device target;
  final List<CrossFile> initialFiles;

  const ChatSendPage({super.key, required this.target, this.initialFiles = const []});

  @override
  State<ChatSendPage> createState() => _ChatSendPageState();
}

class _ChatSendPageState extends State<ChatSendPage> with Refena {
  static const _maxRecords = 200;

  final _textController = TextEditingController();
  final _queuedTexts = Queue<String>();
  final _records = <_ChatRecord>[];
  bool _loading = true;
  bool _sending = false;
  String? _activeSessionId;

  String get _historyKey {
    final id = widget.target.fingerprint.isNotEmpty ? widget.target.fingerprint : (widget.target.ip ?? widget.target.alias);
    return 'localsend_camera_chat_v1_$id';
  }

  @override
  void initState() {
    super.initState();
    activeChatFingerprint.value = widget.target.fingerprint.isEmpty ? null : widget.target.fingerprint;
    chatReceiveRevision.addListener(_onIncomingUpdate);
    unawaited(_restore());
  }

  @override
  void dispose() {
    chatReceiveRevision.removeListener(_onIncomingUpdate);
    if (activeChatFingerprint.value == widget.target.fingerprint) {
      activeChatFingerprint.value = null;
    }
    _textController.dispose();
    super.dispose();
  }

  Future<void> _restore() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_historyKey);
      if (raw != null) {
        final jsonList = jsonDecode(raw) as List<dynamic>;
        _records.addAll(jsonList.map((entry) => _ChatRecord.fromJson(Map<String, dynamic>.from(entry as Map))));
      }
      // Keep received history in its own key so receive callbacks cannot
      // overwrite outgoing messages written by an open chat screen.
      final incoming = prefs.getString(_incomingHistoryKey(widget.target.fingerprint));
      if (incoming != null) {
        final jsonList = jsonDecode(incoming) as List<dynamic>;
        _records.addAll(jsonList.map((entry) => _ChatRecord.fromJson(Map<String, dynamic>.from(entry as Map))));
      }
      _records.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    } catch (_) {
      // Broken or obsolete local history must not prevent file transfers.
      _records.clear();
    }
    if (!mounted) return;
    setState(() => _loading = false);
    unawaited(_refreshIncoming());
    if (widget.initialFiles.isNotEmpty) {
      await _sendFiles(widget.initialFiles, clearSelection: true);
    }
  }

  void _onIncomingUpdate() {
    if (!_loading) unawaited(_refreshIncoming());
  }

  Future<void> _refreshIncoming() async {
    if (!mounted || widget.target.fingerprint.isEmpty) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_incomingHistoryKey(widget.target.fingerprint));
      if (raw == null) return;
      final incoming = (jsonDecode(raw) as List<dynamic>)
          .map((entry) => _ChatRecord.fromJson(Map<String, dynamic>.from(entry as Map)))
          .toList();
      if (!mounted) return;
      setState(() {
        _records.removeWhere((record) => record.direction == 'in');
        _records.addAll(incoming);
        _records.sort((a, b) => a.timestamp.compareTo(b.timestamp));
      });
    } catch (_) {
      // Corrupt history must not stop a live conversation.
    }
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    final outgoing = _records.where((e) => e.direction != 'in').toList();
    final snapshot = outgoing.length > _maxRecords ? outgoing.sublist(outgoing.length - _maxRecords) : outgoing;
    await prefs.setString(_historyKey, jsonEncode(snapshot.map((e) => e.toJson()).toList()));
  }

  void _reportError() {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('无法发送，请检查连接或重试。')));
  }

  Future<void> _sendFiles(List<CrossFile> files, {bool clearSelection = false}) async {
    if (files.isEmpty || _sending || !mounted) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final entries = <_ChatRecord>[
      for (var i = 0; i < files.length; i++)
        _ChatRecord(
          id: '${now}_$i',
          name: files[i].name,
          text: files[i].fileType == FileType.text && files[i].bytes != null ? utf8.decode(files[i].bytes!, allowMalformed: true) : null,
          type: files[i].fileType.name,
          direction: 'out',
          path: null,
          timestamp: now,
          status: 'sending',
        ),
    ];

    setState(() {
      _sending = true;
      _records.addAll(entries);
    });
    try {
      // The normal transfer cache is deleted after a successful send.
      // Keep optimized previews under application support so chat history lasts.
      for (var i = 0; i < files.length; i++) {
        if (files[i].fileType == FileType.image) {
          entries[i].path = await _savePreview(files[i], entries[i].id);
        }
      }
      await _persist();
      String? sessionId;
      final sender = ref.notifier(sendProvider);
      bool success = false;
      try {
        await sender.startSession(
          target: widget.target,
          files: files,
          background: true,
          onCreated: (id) {
            sessionId = id;
            if (mounted) {
              setState(() => _activeSessionId = id);
            }
          },
        );
        // A successful background session is removed by SendNotifier.
        final session = sessionId == null ? null : ref.read(sendProvider)[sessionId];
        success = sessionId != null && (session == null || session.status == SessionStatus.finished);
      } finally {
        if (sessionId != null) sender.closeSession(sessionId!);
      }
      for (final entry in entries) {
        entry.status = success ? 'sent' : 'failed';
      }
      if (!success) _reportError();
    } catch (_) {
      for (final entry in entries) {
        entry.status = 'failed';
      }
      _reportError();
    } finally {
      if (mounted) {
        setState(() {
          _sending = false;
          _activeSessionId = null;
        });
      }
      try {
        await _persist();
      } catch (_) {
        _reportError();
      }
      if (clearSelection && mounted) {
        ref.redux(selectedSendingFilesProvider).dispatch(ClearSelectionAction());
      }
      if (mounted && _queuedTexts.isNotEmpty) {
        final next = _queuedTexts.removeFirst();
        unawaited(_sendTextValue(next));
      }
    }
  }

  Future<String?> _savePreview(CrossFile file, String recordId) async {
    final path = file.path;
    if (path == null || path.startsWith('content://')) return null;
    return _buildChatPreview(path, recordId);
  }

  Future<void> _sendText() async {
    final value = _textController.text.trim();
    if (value.isEmpty || _loading) return;
    _textController.clear();
    if (_sending) {
      setState(() => _queuedTexts.add(value));
      return;
    }
    await _sendTextValue(value);
  }

  Future<void> _sendTextValue(String value) async {
    final bytes = utf8.encode(value);
    final file = CrossFile(
      name: 'message_${DateTime.now().microsecondsSinceEpoch}.txt',
      fileType: FileType.text,
      size: bytes.length,
      thumbnail: null,
      asset: null,
      path: null,
      bytes: bytes,
      lastModified: null,
      lastAccessed: null,
    );
    await _sendFiles([file]);
  }

  Future<void> _takePhoto() async {
    if (!Platform.isAndroid) return;
    try {
      final photo = await ImagePicker().pickImage(source: ImageSource.camera);
      if (photo != null && mounted) {
        await _sendFiles([await CrossFileConverters.convertXFile(photo)]);
      }
    } catch (_) {
      _reportError();
    }
  }

  Future<void> _pickPhotos() async {
    try {
      // The native image picker is Android-only in this build.
      // file_selector uses the system's file dialog on Windows.
      final images = Platform.isAndroid
          ? await ImagePicker().pickMultiImage()
          : await openFiles(
              acceptedTypeGroups: [
                const XTypeGroup(label: 'Images', extensions: ['jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp']),
              ],
            );
      if (images.isEmpty || !mounted) return;
      final files = <CrossFile>[];
      for (final image in images) {
        files.add(await CrossFileConverters.convertXFile(image));
      }
      if (mounted) await _sendFiles(files);
    } catch (_) {
      _reportError();
    }
  }

  Future<void> _pickFiles() async {
    try {
      final files = <CrossFile>[];
      if (Platform.isAndroid) {
        final selected = await android_channel.pickFilesAndroid();
        if (selected == null) return;
        for (final item in selected) {
          files.add(await CrossFileConverters.convertFileInfo(item));
        }
      } else {
        final selected = await openFiles();
        for (final item in selected) {
          files.add(await CrossFileConverters.convertXFile(item));
        }
      }
      if (files.isNotEmpty && mounted) await _sendFiles(files);
    } on PlatformException catch (e) {
      if (e.code != 'CANCELED') _reportError();
    } catch (_) {
      _reportError();
    }
  }

  Future<void> _showAttachmentMenu() async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (Platform.isAndroid)
              ListTile(
                leading: const Icon(Icons.photo_camera),
                title: const Text('拍照发送'),
                onTap: () async {
                  Navigator.of(sheetContext).pop();
                  await _takePhoto();
                },
              ),
            ListTile(
              leading: const Icon(Icons.photo_library),
              title: Text(Platform.isAndroid ? '从相册选择' : '选择图片'),
              onTap: () async {
                Navigator.of(sheetContext).pop();
                await _pickPhotos();
              },
            ),
            ListTile(
              leading: const Icon(Icons.attach_file),
              title: const Text('发送文件'),
              onTap: () async {
                Navigator.of(sheetContext).pop();
                await _pickFiles();
              },
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final activeSession = ref.watch(sendProvider)[_activeSessionId];
    final waiting = activeSession?.status == SessionStatus.waiting;
    final sending = activeSession?.status == SessionStatus.sending;
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.target.alias, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
            Text(widget.target.ip ?? 'LocalSend', style: Theme.of(context).textTheme.labelSmall),
          ],
        ),
      ),
      body: SafeArea(
        child: Column(
          children: [
            if (_loading) const LinearProgressIndicator(),
            if (_sending && (waiting || sending))
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                child: Row(
                  children: [
                    const SizedBox(width: 15, height: 15, child: CircularProgressIndicator(strokeWidth: 2)),
                    const SizedBox(width: 12),
                    Text(waiting ? '等待对方接收…' : '正在发送…', style: Theme.of(context).textTheme.bodySmall),
                  ],
                ),
              ),
            Expanded(
              child: _records.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(32),
                        child: Text('开始向这台设备发送文字、照片或文件。\n发送记录仅保存在本机。', textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodyMedium),
                      ),
                    )
                  : ListView.builder(
                      reverse: true,
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 18),
                      itemCount: _records.length,
                      itemBuilder: (context, index) => _buildBubble(_records[_records.length - index - 1], scheme),
                    ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  IconButton(
                    tooltip: '照片和文件',
                    onPressed: _sending || _loading ? null : _showAttachmentMenu,
                    icon: const Icon(Icons.add_circle_outline, size: 28),
                  ),
                  Expanded(
                    child: TextField(
                      controller: _textController,
                      enabled: !_loading,
                      minLines: 1,
                      maxLines: 4,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) async => _sendText(),
                      decoration: InputDecoration(
                        hintText: '发送消息',
                        filled: true,
                        fillColor: scheme.surfaceContainerHighest.withValues(alpha: 0.55),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(22), borderSide: BorderSide.none),
                      ),
                    ),
                  ),
                  const SizedBox(width: 5),
                  IconButton.filled(
                    tooltip: '发送',
                    onPressed: _loading ? null : _sendText,
                    icon: const Icon(Icons.send, size: 19),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showImageViewer(String path) async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => Dialog.fullscreen(
        backgroundColor: Colors.black,
        child: Stack(
          children: [
            Positioned.fill(
              child: InteractiveViewer(
                minScale: 0.6,
                maxScale: 5,
                panEnabled: true,
                scaleEnabled: true,
                child: Center(
                  child: Image.file(
                    File(path),
                    fit: BoxFit.contain,
                    errorBuilder: (_, _, _) => const Text('图片已不可用', style: TextStyle(color: Colors.white)),
                  ),
                ),
              ),
            ),
            Positioned(
              top: 10,
              right: 14,
              child: SafeArea(
                child: IconButton.filledTonal(
                  tooltip: '关闭预览',
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  icon: const Icon(Icons.close),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBubble(_ChatRecord item, ColorScheme scheme) {
    final when = DateTime.fromMillisecondsSinceEpoch(item.timestamp);
    final time = TimeOfDay.fromDateTime(when).format(context);
    final isImage = item.type == FileType.image.name;
    final path = item.path;
    final canShowImage = isImage && path != null && !path.startsWith('content://');
    final title = item.text ?? item.name;
    final isIncoming = item.direction == 'in';
    final status = isIncoming ? '已接收' : switch (item.status) {
      'sent' => '已发送',
      'failed' => '未发送',
      _ => '发送中',
    };
    final statusIcon = isIncoming ? Icons.download_done : switch (item.status) {
      'sent' => Icons.done_all,
      'failed' => Icons.error_outline,
      _ => Icons.schedule,
    };

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Align(
        alignment: isIncoming ? Alignment.centerLeft : Alignment.centerRight,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.82),
          child: Column(
            crossAxisAlignment: isIncoming ? CrossAxisAlignment.start : CrossAxisAlignment.end,
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: isIncoming ? scheme.surfaceContainerHighest : scheme.primaryContainer,
                  borderRadius: BorderRadius.circular(16).copyWith(
                    bottomRight: Radius.circular(isIncoming ? 16 : 4),
                    bottomLeft: Radius.circular(isIncoming ? 4 : 16),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (canShowImage)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 7),
                        child: Tooltip(
                          message: '点击放大图片',
                          child: InkWell(
                            onTap: () => _showImageViewer(path),
                            borderRadius: BorderRadius.circular(10),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(10),
                              child: Image.file(
                                File(path),
                                width: 180,
                                height: 150,
                                fit: BoxFit.cover,
                                errorBuilder: (_, _, _) => const SizedBox(
                                  width: 180,
                                  height: 100,
                                  child: Center(child: Icon(Icons.image_not_supported_outlined)),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    if (item.text == null)
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(isImage ? Icons.image_outlined : Icons.insert_drive_file_outlined, size: 19),
                          const SizedBox(width: 7),
                          Flexible(child: Text(title, maxLines: 3, overflow: TextOverflow.ellipsis)),
                        ],
                      )
                    else
                      SelectableText(title),
                  ],
                ),
              ),
              const SizedBox(height: 4),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(time, style: Theme.of(context).textTheme.labelSmall),
                  const SizedBox(width: 8),
                  Icon(statusIcon, size: 13, color: item.status == 'failed' ? scheme.error : scheme.onSurfaceVariant),
                  const SizedBox(width: 3),
                  Text(status, style: Theme.of(context).textTheme.labelSmall?.copyWith(color: item.status == 'failed' ? scheme.error : null)),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
