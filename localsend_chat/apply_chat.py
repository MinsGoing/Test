from pathlib import Path

page = Path('app/lib/pages/tabs/send_tab_vm.dart')
src = page.read_text(encoding='utf-8')
src = src.replace(
    "import 'package:localsend_app/pages/progress_page.dart';",
    "import 'package:localsend_app/pages/chat_send_page.dart';\nimport 'package:localsend_app/pages/progress_page.dart';",
    1,
)

def replace_between(data, start, end, replacement):
    assert data.count(start) == 1, f"Expected exactly one start marker: {start}"
    assert data.count(end) == 1, f"Expected exactly one end marker: {end}"
    first = data.index(start)
    last = data.index(end, first)
    return data[:first] + replacement + data[last:]

src = replace_between(
    src,
    '    onTapAddress: (context) async {',
    '    onTapFavorite: (context) async {',
    """    onTapAddress: (context) async {
      final device = await showDialog<Device?>(
        context: context,
        builder: (_) => const AddressInputDialog(),
      );
      if (device != null && context.mounted) {
        final files = ref.read(selectedSendingFilesProvider);
        await context.push(() => ChatSendPage(target: device, initialFiles: files));
      }
    },
""",
)
src = replace_between(
    src,
    '    onTapFavorite: (context) async {',
    '    onTapSendMode: (context, mode) async {',
    """    onTapFavorite: (context) async {
      final device = await showDialog<Device?>(
        context: context,
        builder: (_) => const FavoritesDialog(),
      );
      if (device != null && context.mounted) {
        final files = ref.read(selectedSendingFilesProvider);
        await context.push(() => ChatSendPage(target: device, initialFiles: files));
      }
    },
""",
)
src = replace_between(
    src,
    '    onTapDevice: (context, device) async {',
    '    onTapDeviceMultiSend: (context, device) async {',
    """    onTapDevice: (context, device) async {
      final files = ref.read(selectedSendingFilesProvider);
      await context.push(() => ChatSendPage(target: device, initialFiles: files));
    },
""",
)
page.write_text(src, encoding='utf-8')

send = Path('app/lib/provider/network/send_provider.dart')
src = send.read_text(encoding='utf-8')
old = """    required List<CrossFile> files,
    required bool background,
  }) async {"""
new = """    required List<CrossFile> files,
    required bool background,
    void Function(String sessionId)? onCreated,
  }) async {"""
assert src.count(old) == 1
src = src.replace(old, new, 1)
old = """    ref
        .notifier(fileTransferProvider)
        .setStatuses(
          sessionId: sessionId,"""
new = """    onCreated?.call(sessionId);

    ref
        .notifier(fileTransferProvider)
        .setStatuses(
          sessionId: sessionId,"""
assert src.count(old) == 1
src = src.replace(old, new, 1)
send.write_text(src, encoding='utf-8')

chat = Path('app/lib/pages/chat_send_page.dart')
chat.parent.mkdir(parents=True, exist_ok=True)
text = Path('chat_send_page.dart').read_text(encoding='utf-8')
# No conversion needed: flow analysis promotes non-null image paths.
chat.write_text(text, encoding='utf-8')
print('Chat-style sending integrated into app.')

# Integrate incoming messages/files as part of the cross-platform chat patch.
from pathlib import Path

def edit(path, changes):
    file = Path(path)
    source = file.read_text(encoding='utf-8')
    for before, after in changes:
        if 'timestamp: DateTime.now().toUtc()' in before:
            # Normalize indentation in generated multiline Dart hunks.
            before = '\n'.join(line[1:] if line.startswith(' ') else line for line in before.split('\n'))
            after = '\n'.join(line[1:] if line.startswith(' ') else line for line in after.split('\n'))
        count = source.count(before)
        assert count == 1, f'{path}: expected 1 match, found {count}: {before[:100]!r}'
        source = source.replace(before, after, 1)
    file.write_text(source, encoding='utf-8')

controller = 'app/lib/provider/network/server/controller/receive_controller.dart'
if 'recordIncomingChat(' in Path(controller).read_text(encoding='utf-8'):
    print('Receive chat patch is already applied.')
    raise SystemExit(0)
edit(controller, [
    (
        "import 'package:localsend_app/pages/home_page.dart';",
        "import 'package:localsend_app/pages/chat_send_page.dart';\nimport 'package:localsend_app/pages/home_page.dart';"
    ),
    (
        """               timestamp: DateTime.now().toUtc(),
             ),
           );
     }

     final receiveProvider""",
        """               timestamp: DateTime.now().toUtc(),
             ),
           );
       try {
         await recordIncomingChat(
           fingerprint: senderFingerprint,
           entryId: const Uuid().v4(),
           name: message,
           fileType: FileType.text,
           path: null,
           message: message,
         );
       } catch (e) {
         _logger.warning('Unable to store received chat message', e);
       }
     }

     final receiveProvider"""
    ),
    (
        """               senderAlias: receiveState.senderAlias,
               timestamp: DateTime.now().toUtc(),
             ),
           );
     } else {""",
        """               senderAlias: receiveState.senderAlias,
               timestamp: DateTime.now().toUtc(),
             ),
           );
       try {
         await recordIncomingChat(
           fingerprint: receiveState.sender.fingerprint,
           entryId: fileId,
           name: receivingFile.desiredName!,
           fileType: fileType,
           path: filePath,
           message: null,
         );
       } catch (e) {
         _logger.warning('Unable to store incoming chat file', e);
       }
     } else {"""
    ),
])

receive = 'app/lib/pages/receive_page.dart'
file = Path(receive)
source = file.read_text(encoding='utf-8')
source = source.replace(
    "import 'package:localsend_app/pages/receive_options_page.dart';",
    "import 'package:localsend_app/pages/chat_send_page.dart';\nimport 'package:localsend_app/pages/home_page.dart';\nimport 'package:localsend_app/pages/receive_options_page.dart';",
    1,
)
start = "    if (vm.message != null) {\n      return Center("
end = "    if (vm.status == SessionStatus.canceledBySender) {"
assert source.count(start) == 1
assert source.count(end) == 1
a = source.index(start)
b = source.index(end, a)
source = source[:a] + """    if (vm.message != null) {
      return Center(
        child: Wrap(
          spacing: 12,
          runSpacing: 8,
          alignment: WrapAlignment.center,
          children: [
            TextButton.icon(
              onPressed: () {
                vm.onAccept();
                context.global.dispatch(NavigateAction.popUntil<WebSharePage>());
              },
              icon: const Icon(Icons.close),
              label: Text(t.general.close),
            ),
            if (vm.showSenderInfo)
              FilledButton.icon(
                onPressed: () {
                  final sender = vm.sender;
                  vm.onAccept();
                  unawaited(
                    context.pushAndRemoveUntil(
                      removeUntil: HomePage,
                      builder: () => ChatSendPage(target: sender),
                      transition: RouterinoTransition.fade(),
                    ),
                  );
                },
                icon: const Icon(Icons.chat_bubble_outline),
                label: const Text('进入聊天'),
              ),
          ],
        ),
      );
    }

""" + source[b:]
file.write_text(source, encoding='utf-8')

progress = 'app/lib/pages/progress_page.dart'
edit(progress, [
    (
        "import 'package:localsend_app/pages/web_share_page.dart';",
        "import 'package:localsend_app/pages/chat_send_page.dart';\nimport 'package:localsend_app/pages/home_page.dart';\nimport 'package:localsend_app/pages/web_share_page.dart';",
    ),
    (
        """    if (result && mounted) {
      if (ref.read(serverProvider)?.webUpload == true) {
        context.global.dispatch(NavigateAction.popUntil<WebSharePage>());
      } else {
        context.global.dispatch(NavigateAction.popUntilRoot());
      }
    }""",
        """    if (result && mounted) {
      // Once an incoming transfer is complete, open the same per-device chat
      // as outgoing sends instead of returning to the main screen.
      if (receiveSession != null &&
          receiveSession.status == SessionStatus.finished &&
          ref.read(serverProvider)?.webUpload != true) {
        unawaited(
          context.pushAndRemoveUntil(
            removeUntil: HomePage,
            builder: () => ChatSendPage(target: receiveSession.sender),
            transition: RouterinoTransition.fade(),
          ),
        );
      } else if (ref.read(serverProvider)?.webUpload == true) {
        context.global.dispatch(NavigateAction.popUntil<WebSharePage>());
      } else {
        context.global.dispatch(NavigateAction.popUntilRoot());
      }
    }""",
    ),
])
print('Receive-to-chat navigation and history integration applied.')
