# Huddle

A native, lightweight Matrix client for macOS. It is built with SwiftUI on the [Matrix Rust SDK](https://github.com/matrix-org/matrix-rust-sdk), the same engine as Element X, so it uses native sliding sync and end-to-end encryption. Several accounts can be signed in at once, all syncing side by side.

- **Native:** SwiftUI, no Electron or web view. The app is about 50 MB and idles around 65 MB of memory.
- **Sliding sync:** the room list loads instantly whatever the account's size. The rooms on screen in the list are kept subscribed, so their previews (reactions included) stay current and opening one shows its latest messages at once; rooms further down get only their newest event until they scroll into view. Homeservers without native sliding sync (MSC4186) are not supported.
- **Multiple accounts:** an avatar rail switches accounts (⌘1–9); each has its own unread badge and its own encrypted local store. Settings ▸ Accounts lists them with whether this Mac is verified for each, and has Verify, Copy User ID, Sign Out and Add Account.
- **Settings (⌘,):** tabs for Notifications, Appearance (message layout and emoji size, with a live preview of a short conversation), Privacy and Accounts.
- **Sign-in:** username and password in the app wherever the homeserver accepts them, with OAuth in your browser as the alternative (needed for single sign-on, passkeys and two-step verification) or where it is the only way.
- **Chat:** searchable room list with previews and unread badges, invites, a timeline with history paging, images, reactions with a searchable emoji picker, formatted messages with mention pills, and a markdown composer that suggests people as you type "@". Settings (⌘,) switches between the modern message layout and a compact IRC-style one.
- **Images:** pictures show at their own size up to a sensible limit, with the sender's blurred preview while they load; GIFs play in place. Clicking one opens it full size over the window, where it can be zoomed, rotated, moved, copied and saved; a click outside it, or Escape, closes it. Send images with the + button, by pasting, or by dragging them in: they wait in the composer with a caption, upload one at a time in order with progress, and can be cancelled or retried. HEIC and TIFF are converted so every client can show them.
- **Replies:** reply to any message from its hover actions or context menu. A reply shows the message it answers above it, and clicking that jumps to the original, loading older history if needed. Works inside threads too.
- **Editing and deleting:** edit your messages, or a picture's caption, from the ⋯ button in a message's hover actions or its context menu; the message goes into the composer with its mentions intact, and whatever you were writing is set aside until you save (Return) or cancel (Escape). Up arrow in an empty composer edits your last message. Delete asks first; room moderators can remove other people's messages.
- **Pinning:** pin messages for everyone in the room (where the room allows it). A banner at the top of the room shows the pinned messages one at a time; clicking it goes to that message and then the one pinned before it, and View All lists them in the side panel. A message from far back (a pin, or the original of a reply) opens in a view of its own around it, without loading the whole room's history up to it; Jump to Latest goes back.
- **Forwarding:** send any message, picture or file on to other rooms from the ⋯ menu: search for a room and press Send beside each one it should go to.
- **Read and unread:** mark a room read or unread from its context menu, or the selected room with Room ▸ Mark as Read/Unread (⇧⌘U); Mark All as Read is in the same menus and on an account's avatar. A room marked unread gets a blue dot (other unread rooms a grey one) and stays unread, even the one that is open, until it is opened again or you write in it. While the open room is marked unread, a bar along its top says so (your read receipts are paused meanwhile) and has a Mark as Read button.
- **Large emoji:** a message of nothing but a few emoji (up to 12) is drawn large. Settings ▸ Appearance chooses Normal, Large or Extra Large.
- **Audio:** voice messages and audio files play in the timeline, with a waveform or track to scrub through, 1×/1.5×/2× speed, and Save As. Ogg Opus, which macOS can't play by itself, is decoded in the app.
- **Threads:** Slack-style. Replies stay out of the room; the root message shows a reply count that opens the thread in a side panel with its own composer, beside the conversation when the window has room and over it when it hasn't. The panel slides in from the window's edge, and moving between the thread list and a thread slides like a page turn; with Reduce Motion on, these become fades. Drag the panel's edge to resize it (double-click for the standard width). Threads always use the modern layout. A toolbar button lists all of a room's threads.
- **Presence:** direct chats show whether the other person is online (green) or away (amber) on their avatar, and "Online" or "Last seen 5 min ago" under the room's name. Huddle tells your server you're online while it's in front and away a couple of minutes after; Settings can turn sharing off. Servers that don't do presence simply show nothing.
- **Typing:** start typing anywhere in the window and it goes to the composer; the arrow keys still move through the room list.
- **Read receipts:** in direct chats, ticks on your messages (one grey tick while sending, two grey once sent, two coloured once read); in group rooms, small avatars beside the last message each person has read, with the full list on click.
- **Notifications:** macOS alerts for new messages, mentions and invitations, following your account's notification rules (muted rooms stay silent; direct messages and mentions play a sound). Clicking one opens that account, room and thread, and reading a room clears its alerts. Settings (⌘,) turns alerts or their sound off; they start off in the Dev build.
- **Encryption:** end-to-end encrypted rooms work, and a new session is verified with your recovery key.

Not built yet: sending files other than images, edits, spaces, and emoji verification.

## Requirements

- An Apple Silicon Mac running macOS 14 or later.
- Xcode (or its command line tools) with Swift 5.10 or later.
- Rust, only to compile the Matrix SDK: `brew install rustup && rustup default stable`.

## Building

Element publishes the Matrix SDK prebuilt for iOS only, so the first step compiles it for macOS. This takes 10–20 minutes and is needed once, and again whenever the SDK commit pinned in `Scripts/build-sdk.sh` changes. Its output lands in `Vendor/MatrixRustSDK` and is not kept in git.

```bash
Scripts/build-sdk.sh
```

Then build the app:

```bash
Scripts/build-app.sh          # release → build/Huddle.app
Scripts/build-app.sh debug    # debug   → build/Huddle Dev.app
open build/Huddle.app
```

Add accounts from the sign-in screen, the **+** button on the account rail, or **File → Add Account…** (⇧⌘N). To sign out, right-click an account's avatar.

### Release and Dev builds

The two builds are separate apps, so test accounts never mix with real ones:

| | Release | Dev |
|---|---|---|
| App | `build/Huddle.app` | `build/Huddle Dev.app` |
| Bundle ID | `app.huddle.Huddle` | `app.huddle.Huddle.dev` |
| Data | `~/Library/Application Support/Huddle` | `~/Library/Application Support/Huddle Dev` |
| Keychain item | `app.huddle.sessions` | `app.huddle.sessions.dev` |
| Icon | green | orange, marked DEV |

### Keychain prompts after rebuilding

Sessions are stored in the Keychain, and macOS ties Keychain access to an app's Team ID. `Scripts/build-app.sh` signs with an **Apple Development** certificate if one is in your keychain (a free Apple ID in Xcode → Settings → Accounts → Manage Certificates is enough), so rebuilds don't prompt. Without one it signs ad hoc, and the Keychain asks for your password once per build. `HUDDLE_SIGN_IDENTITY` overrides the choice.

### Icons

`Scripts/make-icons.sh` redraws `Resources/AppIcon.icns` and `Resources/AppIcon-Dev.icns` from `Scripts/make-icon.swift`.

## Local test servers

Two Docker setups give Huddle Dev something to talk to. Their credentials are in each folder's `dev.env` and work nowhere else.

**Password sign-in** (Synapse on `http://localhost:8008`):

```bash
dev/synapse/setup.sh          # start Synapse, create alice, bob, carol, dave, erin
dev/synapse/seed.py           # rooms, history, images, a DM, an encrypted room, an invite
dev/synapse/seed.py say bob General "hello"   # send one live message
dev/synapse/seed.py read bob General           # Bob reads General up to its newest message
dev/synapse/seed.py threads   # three threads in General, one with 40 replies
dev/synapse/seed.py pin alice General "History message 3"   # pin messages, however far back
dev/synapse/seed.py audio     # voice messages and audio files in General
dev/synapse/seed.py images    # pictures of every shape in Design, an animation, and a missing one
dev/synapse/seed.py reply bob General "team lunch" "hi"   # reply in the thread containing that text
dev/synapse/seed.py respond bob General "hello" "hi back"  # inline reply to the message containing that text
```

**OAuth sign-in** (Synapse on `http://localhost:8009` with Matrix Authentication Service on `http://localhost:8081`):

```bash
dev/synapse-oauth/setup.sh    # start Synapse, MAS and Postgres, create olivia
```

`http://localhost:8009` offers OAuth only. `http://localhost:8010` is the same server behind a proxy that also accepts passwords, for testing the "password, or browser instead" sign-in.

To wipe either one, run `docker compose down && rm -rf data` in its folder.

`Scripts/run-dev.sh` builds both apps and launches Huddle Dev signed in to the password server as alice, bob and carol. An argument opens an account and room:

```bash
Scripts/run-dev.sh alice/General
```

The Dev build reads a few environment variables at launch (see `Sources/Huddle/Core/DevHooks.swift`): `HUDDLE_DEV_ACCOUNTS`, `HUDDLE_DEV_SELECT`, `HUDDLE_DEV_THREAD`, `HUDDLE_DEV_SIGN_OUT`, `HUDDLE_DEV_HOVER`, `HUDDLE_DEV_MUTE_AUDIO` (set by `run-dev.sh`, so test runs make no sound), `HUDDLE_DEV_SLOW_ANIMATIONS` (a factor such as `20`, to watch an animation frame by frame), `HUDDLE_DEV_PERF` (prints how long each room takes to appear), `HUDDLE_DEV_AX_ACTIONS` (gives messages their actions as accessibility actions even without VoiceOver, for scripted tests), and `HUDDLE_DEV_NO_BROWSER`, which prints the OAuth sign-in URL instead of opening the browser. The release app ignores them.

## Releases

Pushing a tag builds the release app on GitHub Actions (`.github/workflows/release.yml`) and publishes it, zipped, as that tag's release: `v1.2.0` becomes version 1.2.0, and a tag with a hyphen (`v1.3.0-beta1`) a pre-release.

```bash
git tag v0.2.0 && git push origin v0.2.0
```

The workflow compiles the Matrix SDK and caches it, so the first run, and the first after the pinned SDK commit changes, takes much longer than the rest.

To sign releases with your Apple Development certificate, add two repository secrets: `MACOS_CERTIFICATE_P12`, the base64 of the certificate and its private key exported from Keychain Access as a .p12 (`base64 -i cert.p12 | pbcopy`), and `MACOS_CERTIFICATE_PASSWORD`, the export password. Without them releases are signed ad hoc.

## Before distributing

- `AppInfo.clientURI` in `Sources/Huddle/Core/LoginFlow.swift` is the website Huddle reports when registering as an OAuth client. It is a placeholder (`https://huddle.invalid`); replace it with a real site.
- Releases are not notarized, so other Macs will block the app until it is allowed in System Settings → Privacy & Security.

## Layout

```
Sources/Huddle/App      app entry point and window
Sources/Huddle/Core     accounts, sign-in, sync, room list and timeline logic
Sources/Huddle/Views    SwiftUI views
Vendor/MatrixRustSDK    local Swift package wrapping the compiled SDK
Scripts                 SDK build, app bundling, icons, Dev launcher
dev                     Docker test servers and seed data
```
