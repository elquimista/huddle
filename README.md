# Huddle

A native, lightweight Matrix client for macOS. It is built with SwiftUI on the [Matrix Rust SDK](https://github.com/matrix-org/matrix-rust-sdk), the same engine as Element X, so it uses native sliding sync and end-to-end encryption. Several accounts can be signed in at once, all syncing side by side.

- **Native:** SwiftUI, no Electron or web view. The app is about 50 MB and idles around 65 MB of memory.
- **Sliding sync:** the room list loads instantly whatever the account's size. The rooms on screen in the list are kept subscribed, so their previews (reactions included) stay current and opening one shows its latest messages at once; rooms further down get only their newest event until they scroll into view. Homeservers without native sliding sync (MSC4186) are not supported.
- **Multiple accounts:** small avatars in the title bar above the sidebar switch accounts (⌘1–9), with any that don't fit in a +N menu; each has its own unread badge and its own encrypted local store. Settings ▸ Accounts lists them with whether this Mac is verified for each, and has Verify, Copy User ID, Sign Out and Add Account.
- **Spaces:** an account's spaces sit in a rail down the left of the sidebar (shown once it has a space or an invitation to one), each with a badge for its rooms that need attention. Choosing one narrows the room list to its rooms, including those in the spaces within it; All Rooms shows everything. Browsing a space lists every room and space in it, joined or not, to join or go into, and an invitation to a space shows who sent it and what is inside before you accept. Make a space, or a room (File ▸ New Room…, ⌥⌘N) that its members, only people invited, or anyone can join; add rooms you're in to a space or take them out; and leave a space along with any of its rooms.
- **Sections:** the room list is in sections that fold away by clicking their header (a folded one shows a badge for what needs attention): Invitations and Favourites, then People, your own sections and Rooms in the order you set, and Low Priority last. They are Element's sections (2026), shared both ways with Element on any device. A room's menu adds it to Favourites, or moves it with Move To to any section, a new one included; rooms can also be dragged onto a section. File ▸ New Section… or a section header's menu makes a section (just above Rooms, as Element does). Headers move People, Rooms and your sections up or down, and your own sections' headers rename or delete them (their rooms go back to People and Rooms). Stored as Element stores them: Favourites and Low Priority are the standard Matrix tags, a room in one of your sections carries its `element.io.section.<id>` tag (one section per room), and the sections' names and order are Element's `RoomList.CustomSectionData` and `RoomList.OrderedCustomSections` settings in your account (`im.vector.web.settings`, whose other settings are left alone). Huddle reads every room's tags with a sliding sync connection of its own that asks only for account data, then checks for changes every 30 seconds; sections made in Huddle before it matched Element are moved over once. Within a space, the sections hold that space's rooms; searching unfolds them all.
- **Devices:** Devices… (in an account's ⋯ menu in Settings ▸ Accounts, or its avatar's menu in the title bar) lists every device signed in to the account: this Mac first, then the others, most recently active first, each with when and from where it was last active, whether it's verified (signed by your cross-signing key, or without encryption at all), and devices unused for 90 days marked inactive. Devices can be renamed, and signed out one at a time or all at once, confirmed with your password. Where the server hands sign-in to its own service (Matrix Authentication Service), signing out opens that service's page for the device instead.
- **Settings (⌘,):** tabs for Notifications, Appearance (message layout and emoji size, with a live preview of a short conversation), Privacy, Accounts and Updates.
- **Your profile and password:** Edit Profile… (in an account's ⋯ menu in Settings ▸ Accounts, or its avatar's menu in the title bar) changes your display name and picture, cropped square, shown first and saved with Save. Change Password… asks for the current password and the new one twice, and can sign out your other devices (this Mac stays signed in). Accounts whose server hands sign-in to its own service (Matrix Authentication Service) change their password on that service's account page: Manage Account… opens it, as does Change Password… where the server doesn't let apps change passwords.
- **Updates:** Huddle ▸ Check for Updates…, or Check Now in Settings ▸ Updates, looks for a newer release; it also checks once a day by itself unless that's turned off. A new version shows what changed, then downloads, is checked against Huddle's signing key, installs and relaunches ([Sparkle](https://sparkle-project.org)). Settings can also have updates installed without asking (when Huddle quits) and offer beta versions. The Dev build never updates itself.
- **Sign-in:** username and password in the app wherever the homeserver accepts them, with OAuth in your browser as the alternative (needed for single sign-on, passkeys and two-step verification) or where it is the only way.
- **Chat:** searchable room list with previews and unread badges, invites, a timeline with history paging, images, reactions with a searchable emoji picker, formatted messages with mention pills, and a markdown composer that suggests people as you type "@". Settings (⌘,) switches between the modern message layout and a compact IRC-style one. In the IRC layout, drag the edge between the names and the messages to resize the names column, or double-click it to fit the longest name; each room remembers its own width.
- **Images:** pictures show at their own size up to a sensible limit, with the sender's blurred preview while they load; GIFs play in place. Clicking one opens it full size over the window, where it can be zoomed, rotated, moved, copied and saved; a click outside it, or Escape, closes it. Send images with the + button, by pasting, or by dragging them in: they wait in the composer with a caption, upload one at a time in order with progress, and can be cancelled or retried. HEIC and TIFF are converted so every client can show them.
- **Replies:** reply to any message from its hover actions or context menu. A reply shows the message it answers above it, and clicking that jumps to the original, loading older history if needed. Works inside threads too.
- **Editing and deleting:** edit your messages, or a picture's caption, from the ⋯ button in a message's hover actions or its context menu; the message goes into the composer with its mentions intact, and whatever you were writing is set aside until you save (Return) or cancel (Escape). Up arrow in an empty composer edits your last message. Delete asks first; room moderators can remove other people's messages.
- **Pinning:** pin messages for everyone in the room (where the room allows it). A banner at the top of the room shows the pinned messages one at a time; clicking it goes to that message and then the one pinned before it, and View All lists them in the side panel. A message from far back (a pin, or the original of a reply) opens in a view of its own around it, without loading the whole room's history up to it; Jump to Latest goes back.
- **Forwarding:** send any message, picture or file on to other rooms from the ⋯ menu: search for a room and press Send beside each one it should go to.
- **Direct and group chats:** File ▸ New Message… (⌘N), or the compose button above the room list, opens a To field. Find people by name or Matrix ID (the people already chatted with first, then your server's directory) and add them with a click or Return; Backspace takes the last one off. Going (the button, or Return in the empty field) takes you to the chat you already have with them: the direct chat with one person, or a group of exactly those people (with a way to start a new one anyway). Otherwise it starts one, unencrypted unless you tick End-to-end encryption; a group can be given a name. A full Matrix ID can always be added; one the server says nobody has is shown as such rather than invited.
- **Room info:** the ⓘ button on a room (Room ▸ Room Info, ⌘I) opens its details beside the conversation: picture, name and topic, whether it's encrypted, and who is in it, with their roles and who is only invited. Where your power level allows, click the picture to choose a new one (cropped square) or remove it, edit the name and topic, and turn encryption on (after a warning that it can't be turned off). Invite… beside the member count opens the same To field as New Message, with those already in the room shown but not choosable. The ⋯ button that appears on hover (or the right-click menu) has a Role submenu, for Admin, Moderator or Member, where your power level lets you change roles: anyone below you can be given any role up to your own, and you can lower your own. The two changes you can't take back (giving someone your own level, or lowering yourself) ask first; an owner's role can't be changed. Role changes show in the conversation for everyone, as "Alice made Bob a moderator" or "Bob stepped down as admin". Admins and moderators can also take someone below them out of the room, or withdraw an invitation, after a confirmation. Leave the room from there too.
- **Search:** Edit ▸ Find (⌘F), or the magnifying glass on a room, opens a search beside the conversation, in this room or all of them (⇧⌘F). Results show who wrote what and when, with the words found highlighted (other forms of them too); clicking one goes to the message, in its own room if need be (an edit to the message it changed, a reply in a thread to the thread), and the arrow keys, ⌘G and ⇧⌘G go through them in turn. Two searches run together and are merged, newest first: the homeserver's own, which covers the whole history of unencrypted rooms with nothing downloaded, and an index on this Mac, kept by the Matrix SDK and encrypted with the account's store key, which covers encrypted rooms. New messages go into it as they arrive; a pass in the background then goes through every encrypted room back to its first message (and through unencrypted rooms too, on a server that can't search), remembering which rooms are done. A room you have open (or had open recently) waits until it isn't, and one in view in the room list has its reactions check paused meanwhile: the SDK shares a room's loaded history with every timeline on it, so neither would otherwise grow to the room's whole history, redrawing all the way. The search panel and Settings ▸ Privacy show its progress, and Settings can turn it off. Old encrypted messages are found once their keys are available, which needs this Mac verified with the recovery key.
- **Read and unread:** mark a room read or unread from its context menu, or the selected room with Room ▸ Mark as Read/Unread (⇧⌘U); Mark All as Read is in the same menus and on an account's avatar. A room marked unread gets a blue dot (other unread rooms a grey one) and stays unread, even the one that is open, until it is opened again or you write in it. While the open room is marked unread, a bar along its top says so (your read receipts are paused meanwhile) and has a Mark as Read button.
- **Large emoji:** a message of nothing but a few emoji (up to 12) is drawn large. Settings ▸ Appearance chooses Normal, Large or Extra Large.
- **Audio:** voice messages and audio files play in the timeline, with a waveform or track to scrub through, 1×/1.5×/2× speed, and Save As. Ogg Opus, which macOS can't play by itself, is decoded in the app.
- **Threads:** Slack-style. Replies stay out of the room; the root message shows a reply count that opens the thread in a side panel with its own composer, beside the conversation when the window has room and over it when it hasn't. The panel slides in from the window's edge, and moving between the thread list and a thread slides like a page turn; with Reduce Motion on, these become fades. Drag the panel's edge to resize it (double-click for the standard width). Threads always use the modern layout. A toolbar button lists all of a room's threads.
- **Presence:** direct chats show whether the other person is online (green) or away (amber) on their avatar, and "Online" or "Last seen 5 min ago" under the room's name. Huddle tells your server you're online while it's in front and away a couple of minutes after; Settings can turn sharing off. Servers that don't do presence simply show nothing.
- **Typing:** start typing anywhere in the window and it goes to the composer; the arrow keys still move through the room list.
- **Read receipts:** in direct chats, ticks on your messages (one grey tick while sending, two grey once sent, two coloured once read); in group rooms, small avatars beside the last message each person has read, with the full list on click.
- **Notifications:** macOS alerts for new messages, mentions and invitations, following your account's notification rules (muted rooms stay silent; direct messages and mentions play a sound). Clicking one opens that account, room and thread, with the room list on the room's space if the space showing doesn't hold it, and reading a room clears its alerts. Each room can notify for all messages, only for mentions and keywords, or not at all (muted), or follow your account's default: choose from Notifications in its right-click menu or in Room Info (⌘I). The choice is kept in your push rules, so Element and other apps share it; muted rooms show a crossed-out bell in the list, and their new messages don't mark them unread. Settings (⌘,) turns alerts or their sound off; they start off in the Dev build.
- **Encryption:** end-to-end encrypted rooms work, and a new session is verified with your recovery key.
- **Keyboard:** Room ▸ Next Room and Previous Room (⌃Tab, ⌃⇧Tab) go through the rooms as the list shows them; Next Unread Room and Previous Unread Room (⌥⌘↓, ⌥⌘↑) skip to the ones with something new, folded sections included. View ▸ Show/Hide Sidebar (⌃⌘S). Window ▸ Huddle (⌘0) brings the window back after it has been closed.
- **Picking up where you left off:** the window comes back as it was left, and each account reopens the room it last had open (in the space showing). The window is kept under a fixed name, so an update can't stop macOS finding it again; if no window comes back at launch all the same, Huddle opens one.
- **Safety:** links in messages open only web pages and email; any other kind is refused, saying what it was, and a link whose text is a different address from where it goes asks first. A mention pill always names the person it points to, whatever the sender wrote. Formatting nested to absurd depths, and images or voice messages that would unpack to gigabytes, are cut short rather than stall the app. Saved pictures and recordings are marked as downloaded, so macOS checks them before opening, and their names can't hide a different kind of file. The app is signed with the hardened runtime, so no other process can inject code into it.

Not built yet: sending files other than images, and emoji verification.

## Requirements

- An Apple Silicon Mac running macOS 14 or later.
- Xcode (or its command line tools) with Swift 5.10 or later.
- Rust, only to compile the Matrix SDK: `brew install rustup && rustup default stable`.

## Building

Element publishes the Matrix SDK prebuilt for iOS only, so the first step compiles it for macOS. This takes 10–20 minutes and is needed once, and again whenever the SDK commit pinned in `Scripts/build-sdk.sh` or a patch in `Scripts/sdk-patches` changes. Its output lands in `Vendor/MatrixRustSDK` and is not kept in git.

`Scripts/sdk-patches` holds fixes to the SDK's dependencies, applied as the SDK is built. `ruma-html-deep-nesting.patch` frees a message's parsed HTML one node at a time: freed recursively, as ruma does, HTML nested a few thousand levels deep (which fits in one message) overflows the stack and crashes the app, at every launch while that message is in a room. When the SDK commit is bumped, check whether ruma has fixed this itself, and drop the patch if so.

```bash
Scripts/build-sdk.sh
```

Then build the app:

```bash
Scripts/build-app.sh          # release → build/Huddle.app
Scripts/build-app.sh debug    # debug   → build/Huddle Dev.app
open build/Huddle.app
```

Add accounts from the sign-in screen, an account's right-click menu in the title bar, or **File → Add Account…** (⇧⌘N). To sign out, right-click an account's avatar.

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
dev/synapse/seed.py spaces    # Work (with a Mobile space inside), Open Source, and an invitation to Book Club
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

The Dev build reads a few environment variables at launch (see `Sources/Huddle/Core/DevHooks.swift`): `HUDDLE_DEV_ACCOUNTS`, `HUDDLE_DEV_SELECT`, `HUDDLE_DEV_THREAD`, `HUDDLE_DEV_SEARCH` (opens the search beside the selected room with that query; `HUDDLE_DEV_SEARCH_ALL=1` for every room), `HUDDLE_DEV_INDEX_PAUSE` (milliseconds between pages of the full-history pass, to watch its progress), `HUDDLE_DEV_SPACE` (a space to browse at launch) and `HUDDLE_DEV_SHEET` (`newRoom`, `newSpace`, `addRooms` or `leave`, to open that sheet for it), `HUDDLE_DEV_SIGN_OUT`, `HUDDLE_DEV_HOVER`, `HUDDLE_DEV_MUTE_AUDIO` (set by `run-dev.sh`, so test runs make no sound), `HUDDLE_DEV_SLOW_ANIMATIONS` (a factor such as `20`, to watch an animation frame by frame), `HUDDLE_DEV_PERF` (prints how long each room takes to appear), `HUDDLE_DEV_AX_ACTIONS` (gives messages their actions as accessibility actions even without VoiceOver, for scripted tests), `HUDDLE_DEV_UPDATE_FEED` (an appcast to check for updates at, for testing them; build with `HUDDLE_SPARKLE_PUBLIC_KEY` set to the test key its updates are signed with, and `HUDDLE_VERSION` and `HUDDLE_BUILD` to make the newer build), and `HUDDLE_DEV_NO_BROWSER`, which prints the OAuth sign-in URL instead of opening the browser. The release app ignores them.

Both builds write a few notes about scrolling a room's conversation to the system log (when a room opens, when its first messages arrive, and when it stops following the newest message, and why), with no message content or room names. To read them:

```bash
/usr/bin/log show --last 1h --predicate 'subsystem == "app.huddle.Huddle" && category == "timeline"'
```

(`app.huddle.Huddle.dev` for the Dev build. In zsh, `log` alone is a different command.)

## Releases

Pushing a tag builds the release app on GitHub Actions (`.github/workflows/release.yml`) and publishes it, zipped, as that tag's release: `v1.2.0` becomes version 1.2.0, and a tag with a hyphen (`v1.3.0-beta1`) a pre-release.

```bash
git tag v0.2.0 && git push origin v0.2.0
```

The workflow compiles the Matrix SDK and caches it, so the first run, and the first after the pinned SDK commit changes, takes much longer than the rest.

To sign releases with your Apple Development certificate, add two repository secrets: `MACOS_CERTIFICATE_P12`, the base64 of the certificate and its private key exported from Keychain Access as a .p12 (`base64 -i cert.p12 | pbcopy`), and `MACOS_CERTIFICATE_PASSWORD`, the export password. Without them releases are signed ad hoc.

### Updates

The app finds updates in an appcast, a feed listing each release with its EdDSA signature. Since this repository is private, the workflow also publishes every release, and the appcast, to a public repository, `huddle-releases` under the same owner (or the `UPDATES_REPO` repository variable, as `owner/name`). The app reads `appcast.xml` on that repository's `main` branch; `Scripts/build-app.sh` puts that address and the public key in the release app's Info.plist. Pre-releases go in the appcast's beta channel, offered only to those who turn on beta versions.

To set it up:

1. Create the public repository `huddle-releases` (it can be empty).
2. Add two secrets to this repository: `SPARKLE_PRIVATE_KEY`, the private signing key, and `RELEASES_TOKEN`, a fine-grained personal access token with read and write access to Contents on `huddle-releases` only.

Without them, releases are still built and published here, but not offered as updates.

The signing key is in the login Keychain under the account `huddle`. Sparkle's tools export it again (`.build/artifacts/sparkle/Sparkle/bin/generate_keys --account huddle -x key.txt`) or show its public half (`-p`). Updates signed with any other key are refused, so keep it safe: a lost key means people have to download the next release by hand.

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
