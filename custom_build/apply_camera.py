"""Apply the Android-only camera item to LocalSend's existing file picker.

The patch uses the image_picker dependency already present in LocalSend.
Only Android lists this option; desktop keeps its normal file picker.
"""
from pathlib import Path

path = Path('app/lib/util/native/file_picker.dart')
s = path.read_text(encoding='utf-8')

def change(before: str, after: str):
    global s
    if s.count(before) != 1:
        raise RuntimeError(f'Upstream picker changed, expected one match: {before[:80]}')
    s = s.replace(before, after, 1)

change("import 'package:flutter/services.dart';",
       "import 'package:flutter/services.dart';\nimport 'package:image_picker/image_picker.dart';")
change("  media(Icons.image),", "  media(Icons.image),\n  camera(Icons.photo_camera),")
change("      case FilePickerOption.media:\n        return t.sendTab.picker.media;",
       "      case FilePickerOption.media:\n        return t.sendTab.picker.media;\n      case FilePickerOption.camera:\n        return t.assetPicker.sActionUseCameraHint;")
change("        FilePickerOption.media,\n        FilePickerOption.clipboard,",
       "        FilePickerOption.media,\n        FilePickerOption.camera,\n        FilePickerOption.clipboard,")
change("      case FilePickerOption.media:\n        // ignore: use_build_context_synchronously\n        await _pickMedia(context, ref);\n        break;",
       "      case FilePickerOption.media:\n        // ignore: use_build_context_synchronously\n        await _pickMedia(context, ref);\n        break;\n      case FilePickerOption.camera:\n        // ignore: use_build_context_synchronously\n        await _pickCamera(context, ref);\n        break;")
change("Future<void> _pickMedia(BuildContext context, Ref ref) async {",
       """Future<void> _pickCamera(BuildContext context, Ref ref) async {
  if (!checkPlatform([TargetPlatform.android])) return;
  try {
    final photo = await ImagePicker().pickImage(source: ImageSource.camera);
    if (photo == null) return;

    await ref.redux(selectedSendingFilesProvider).dispatchAsync(
      AddFilesAction(
        files: [photo],
        converter: CrossFileConverters.convertXFile,
      ),
    );
  } catch (e, stackTrace) {
    _logger.warning('Failed to capture photo', e, stackTrace);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(t.general.error)),
      );
    }
  }
}

Future<void> _pickMedia(BuildContext context, Ref ref) async {""")
path.write_text(s, encoding='utf-8')
print('Android camera option added to LocalSend file picker.')
