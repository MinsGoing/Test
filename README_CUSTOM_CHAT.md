# LocalSend — chat-style sending and receiving (custom build)

This branch contains the **complete LocalSend source tree** from
[localsend/localsend](https://github.com/localsend/localsend), with
the custom Windows and Android chat interface applied to actual source
files. It is not just a patch archive.

- Upstream base commit: `92e133aa43869e94d394fd04fa70c50a0f796a64`
- Upstream license: see LICENSE
- Modified app code includes
  `app/lib/pages/chat_send_page.dart`,
  `app/lib/pages/tabs/send_tab_vm.dart`,
  `app/lib/provider/network/send_provider.dart`,
  `app/lib/provider/network/server/controller/receive_controller.dart`,
  `app/lib/pages/receive_page.dart`,
  `app/lib/pages/progress_page.dart`, and
  `app/lib/util/native/file_picker.dart`.
- `custom_build/` contains the scripts used to reproduce these changes.

Features: device-specific conversation page, outgoing and incoming
message/file bubbles, stored local transfer history, photo capture on
Android, image selection and file sending on Windows, and click/tap to
zoom picture previews.

### Conversation-first receiving (2026-10-31 redesign)

- **While a chat is open for a verified sender**: received text messages
  are acknowledged and appended live without displaying the legacy
  ReceivePage dialog; pictures totaling at most 20 MiB are also received
  inline automatically. Larger pictures and non-image files show an
  in-chat **Accept / Decline** card instead of navigating away.
- **Outside that chat**: original LocalSend receive confirmation,
  security handling, and progress screens remain available.
- Incoming items are shown on the left, outgoing items on the right.
  Newly received content immediately refreshes the conversation.
- Sent messages entered during an ongoing transfer are queued locally
  and sent sequentially. The text composer stays enabled.
- Received files can be reopened from chat bubbles when their original
  saved file still exists. Pictures prefer original resolution and
  retain a compressed local preview as a fallback.
- A canceled or failed inline transfer no longer navigates away from
  the chat; the cancellation card is removed or errors can be dismissed.
- LocalSend continues to use transfer sessions, **not an always-on
  messaging channel**. Conversation history is local to each device.
  There is no cloud or cross-device history synchronization.

**Build requirements:** Flutter 3.41.9, Rust 1.97.1,
Windows x64 MSVC toolchain for Windows, or Android SDK + JDK 17 +
Rust Android arm64 target for Android.

Typical build commands (after platform prerequisites and Flutter setup):

```sh
cd app
flutter pub get
dart format lib/pages/chat_send_page.dart lib/pages/receive_page.dart lib/pages/progress_page.dart lib/pages/tabs/send_tab_vm.dart lib/provider/network/send_provider.dart lib/provider/network/server/controller/receive_controller.dart lib/util/native/file_picker.dart
flutter analyze
flutter build windows --release
# Or on Android:
flutter build apk --release --split-per-abi --target-platform android-arm64
```

Android release signing must be configured with your own key.
Windows unsigned EXEs may trigger Microsoft SmartScreen warnings.
No private signing keys or credentials are stored here.
Upstream GitHub Actions workflow examples have been preserved under
`custom_build/upstream_workflows/` instead of `.github/workflows/`
because this branch is published using an automation token.

This remains a LocalSend-based file transfer client: messages use the
existing file transfer protocol, and history is stored locally rather
than synchronized between devices.
