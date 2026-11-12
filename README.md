# Swipe to Unread Chats — pull up in any chat to preview and open the next unread one

Pulling up at the end of a channel already takes you to the next unread channel — but only to the one Telegram
picked, and only in channels. This concept makes the same gesture work in **any chat** and lets you **choose**:

* **Pull up** at the end of a chat — past the usual threshold a panel stays on screen: a row of your unread chats
  at the bottom and a live preview of the selected one above it.
* **Swipe the preview** left or right, or **drag the row** of avatars — the preview follows the finger.
* **Tap** the preview — it grows into the chat. No trip back to the chat list.
* The first item of the row turns the preview into the **list of all unread chats**.
* Pull back below the threshold or tap outside — nothing happens.

Telegram concept for **iOS** (UIKit / AsyncDisplayKit), built on top of the official sources.

| iOS |
|---|
| [Media/ios.mp4](Media/ios.mp4) |

## Repository

| Path | What |
|---|---|
| `ios/Feature/submodules/…` | The new iOS file, at the same path as in Telegram-iOS — copy the folder over a checkout. |
| `ios/Integration/telegram-ios.patch` | Hooks in existing Telegram-iOS files (`git apply`). |
| `Media/` | The recording of the concept (1920×1920, 60 fps). |

## iOS

| File | What |
|---|---|
| `TelegramUI/Sources/ConceptsTopicSwipe.swift` | The whole feature: the list of unread chats of the current folder, the panel (row of avatars, preview card, list of all unread chats), selection by swiping the card or dragging the row, haptics, and the transition of the preview into the real chat. |

Hooks in existing files (see the patch, 5 lines):

* `ChatController.swift` — the pull at the end of the chat is offered in any chat, not only in channels (one line).
* `ChatHistoryListNode.swift` — the overscroll progress is passed to the concept (two lines) and the release of the
  finger is handed to it before the stock "open next channel" (one line).

Base commit: `fb0e62ba8a147f0821da6aa63c09da7d79a10111` (TelegramMessenger/Telegram-iOS).

```sh
cd Telegram-iOS
git checkout fb0e62ba8a147f0821da6aa63c09da7d79a10111
cp -R /path/to/this-repo/ios/Feature/submodules/ submodules/
git apply /path/to/this-repo/ios/Integration/telegram-ios.patch
```

Build as usual (`build-system/Make/Make.py` or the generated Xcode project) and launch with the argument
`--concepts-topic-swipe`. Without it nothing changes: every new branch is behind `ConceptsTopicSwipe.isEnabled`,
which stays `false`.

## How it works

* **Threshold.** The first part is the stock pull at the end of a channel: the same rubber band, the same capsule
  with the arrow, the same haptic on the threshold.
* **Who is next.** All unread chats of the folder the chat was opened from, of any type; the freshest first,
  muted ones last. The stock code knows only one candidate — here it is a list.
* **Preview.** The card above the row is a real `ChatController` in previewing mode — the same one as on a long
  press in the chat list — so the chat looks exactly as it will after opening, with its own theme and wallpaper.
* **Row.** The row of avatars moves with the finger (fractional position, resistance at the edges); the avatar
  that passes the center grows and its chat becomes the preview.
* **Opening.** The preview card grows into the chat with the stock spring (stiffness 440, damping 42, no
  overshoot); the header and the input panel of the real chat appear under the card and replace it.
* **Motion.** Fades, dimming and blur — `cubic-bezier(0, 0.4, 0, 1)`, 300 ms; movement — the same curve, 450 ms.

## Notes and limits

* This is a prototype recorded on fictional data. Nothing is sent anywhere.
* The published file is the working file of the prototype with the recording script cut out; in this form it was
  **not** compiled against a clean checkout — only inside the private test bench it was written in.
* The offline-demo harness (fictional account and chats, chat themes) and the scripted run with real touch events
  used for the video belong to a larger private test bench and are not included.
* `ConceptsTopicSwipeTune` holds the tuning values of the recording; the numbers at the call sites are older defaults.
* Forum topics are not handled separately: the row shows chats.
* Code comments are partly in Russian.
* Telegram sources are GPLv2; these files are meant to be used on top of them.
