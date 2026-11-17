# Huddle

A native, lightweight Matrix client for macOS. It is built with SwiftUI on the [Matrix Rust SDK](https://github.com/matrix-org/matrix-rust-sdk), the same engine as Element X, so it uses native sliding sync and end-to-end encryption. Several accounts can be signed in at once, all syncing side by side.

- **Native:** SwiftUI, no Electron or web view. The app is about 50 MB and idles around 65 MB of memory.
- **Sliding sync:** the room list loads instantly whatever the account's size. Homeservers without native sliding sync (MSC4186) are not supported.
- **Multiple accounts:** an avatar rail switches accounts (⌘1–9); each has its own unread badge and its own encrypted local store.
- **Sign-in:** username and password in the app wherever the homeserver accepts them, with OAuth in your browser as the alternative (needed for single sign-on, passkeys and two-step verification) or where it is the only way.
- **Chat:** searchable room list with previews and unread badges, invites, a timeline with history paging, images, reactions with a searchable emoji picker, formatted messages with mention pills, and a markdown composer that suggests people as you type "@". Settings (⌘,) switches between the modern message layout and a compact IRC-style one.
- **Audio:** voice messages and audio files play in the timeline, with a waveform or track to scrub through, 1×/1.5×/2× speed, and Save As. Ogg Opus, which macOS can't play by itself, is decoded in the app.
- **Threads:** Slack-style. Replies stay out of the room; the root message shows a reply count that opens the thread in a side panel with its own composer. A toolbar button lists all of a room's threads.
- **Read receipts:** in direct chats, ticks on your messages (one grey tick while sending, two grey once sent, two coloured once read); in group rooms, small avatars beside the last message each person has read, with the full list on click.
- **Notifications:** macOS alerts for new messages, mentions and invitations, following your account's notification rules (muted rooms stay silent; direct messages and mentions play a sound). Clicking one opens that account, room and thread, and reading a room clears its alerts. Settings (⌘,) turns alerts or their sound off; they start off in the Dev build.
- **Encryption:** end-to-end encrypted rooms work, and a new session is verified with your recovery key.

Not built yet: sending attachments, inline replies, edits, spaces, and emoji verification.

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
dev/synapse/seed.py audio     # voice messages and audio files in General
dev/synapse/seed.py reply bob General "team lunch" "hi"   # reply in the thread containing that text
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

The Dev build reads a few environment variables at launch (see `Sources/Huddle/Core/DevHooks.swift`): `HUDDLE_DEV_ACCOUNTS`, `HUDDLE_DEV_SELECT`, `HUDDLE_DEV_THREAD`, `HUDDLE_DEV_SIGN_OUT`, `HUDDLE_DEV_HOVER`, `HUDDLE_DEV_MUTE_AUDIO` (set by `run-dev.sh`, so test runs make no sound), and `HUDDLE_DEV_NO_BROWSER`, which prints the OAuth sign-in URL instead of opening the browser. The release app ignores them.

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
