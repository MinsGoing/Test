from pathlib import Path

page = Path('app/lib/pages/tabs/send_tab_vm.dart')
src = page.read_text()
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
page.write_text(src)

send = Path('app/lib/provider/network/send_provider.dart')
src = send.read_text()
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
send.write_text(src)

chat = Path('app/lib/pages/chat_send_page.dart')
chat.parent.mkdir(parents=True, exist_ok=True)
text = Path('chat_send_page.dart').read_text()
# No conversion needed: flow analysis promotes non-null image paths.
chat.write_text(text)
print('Chat-style sending integrated into app.')
