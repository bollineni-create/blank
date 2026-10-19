# Loom — a private, on-device second brain

A personal take on [Fabric](https://apps.apple.com/us/app/fabric-your-second-brain/id6449003046) for **iPhone, iPad and Mac**. All the AI runs **on your device** with Apple Intelligence (Apple's on-device Foundation Model). Nothing you save leaves the device. There are no accounts, no servers and no API keys.

## What it does

| | |
|---|---|
| **Save anything** | Notes, links (the page text is fetched), photos and screenshots (on-device OCR), PDFs (text plus OCR for scans) and any other file. You can add things with the + menu, paste (⌘V on Mac), or drag and drop. |
| **Auto-organize** | Apple Intelligence writes a title, a 1–3 sentence summary and topic tags for each item. It reuses your existing tags so they stay consistent. |
| **Semantic search** | Search matches meaning as well as keywords. It uses Apple's built-in sentence embeddings, so it works offline even without Apple Intelligence. |
| **Ask your library** | Chat with your stuff. Answers are grounded in your saved items and cite them as `[1]`, `[2]`, and each source is a tappable link. Chats are saved. |
| **Spaces and tags** | Folders ("Spaces"), auto tags, favorites, and filters by type. |

## Requirements

- Xcode 26 or newer, on an Apple silicon Mac
- iOS 17+ / macOS 14+ to run the app. The AI features (organizing and Ask) need **iOS 26 / macOS 26 on a device with Apple Intelligence turned on**. Without it, saving, search and the map still work.

## Build and run

`Loom.xcodeproj` is checked in, so just open it:

```bash
open Loom.xcodeproj
```

If you change `project.yml`, regenerate the project with `brew install xcodegen` (one-time) and `xcodegen generate`.

1. In Xcode, select the **Loom-iOS** or **Loom-macOS** target, go to **Signing & Capabilities**, and choose your Team. A free Apple ID works. iCloud sync is off by default because it needs a paid Apple Developer Program team (see below).
2. Press ⌘R.

Note for iPhone: with a free Apple ID, apps you sideload expire after 7 days. Re-run from Xcode to refresh. A paid developer account lasts a year.

## Install on your Mac

To get Loom into your Applications folder, run one command. After that you can open it from the Dock, Launchpad or Spotlight like any other app:

```bash
./scripts/install-mac.sh               # builds, installs /Applications/Loom.app and opens it
./scripts/install-mac.sh --no-install  # builds only, into build/
```

It needs Xcode but no Apple ID, because the build is ad-hoc signed. Run it again after you pull changes to update the installed app. On another Mac, right-click the app and choose **Open** the first time.

An ad-hoc signed app can't use iCloud, so it keeps its own library. To sync with your iPhone, pass your paid Apple Developer Program team ID (Xcode → Settings → Accounts, or developer.apple.com → Membership). The script then signs with that team and the iCloud entitlements:

```bash
LOOM_TEAM=ABCDE12345 ./scripts/install-mac.sh
```

The iPhone app must use the same team and the iOS iCloud entitlements (see below). Both builds use iCloud's development environment, so they see the same data.

## Sharing one library between Mac and iPhone (iCloud)

The library syncs through your private iCloud database (container `iCloud.com.personal.loom`). If it isn't set up, each device silently keeps its own library. **Settings → iCloud sync** on each device shows whether sync is on, and if not, why.

For sync to work:

1. **A paid Apple Developer Program team.** A free Apple ID can't sign apps with iCloud, so by default both targets are signed without it and each device keeps its own library. To turn sync on, change `CODE_SIGN_ENTITLEMENTS` in `project.yml` to `Loom/Resources/Loom-iOS-iCloud.entitlements` and `Loom/Resources/Loom-macOS-iCloud.entitlements`, then run `xcodegen generate` again.
2. **The same team on both targets.** In Xcode, open **Signing & Capabilities** for **Loom-iOS** and **Loom-macOS**, choose the same team, and check that the **iCloud** capability lists the `iCloud.com.personal.loom` container on both. Container names are unique across all developers. If Xcode says the name is taken, pick another one (for example `iCloud.com.yourname.loom`), and change it in both `-iCloud` entitlements files and in `SyncMonitor.containerID`.
3. **The same Apple Account** signed in to iCloud on the Mac and the iPhone.
4. **The same iCloud environment.** Builds you run from Xcode use the *development* environment. TestFlight and App Store builds use *production*. The two never see each other's data, so run both from Xcode (or ship both through TestFlight after deploying the schema in the CloudKit Console).

The first sync can take a few minutes, and large attachments take longer. The iOS Simulator only syncs when the app opens, because it gets no push notifications.

## Project layout

```
Loom/
  App/LoomApp.swift            app entry, SwiftData container, Mac menu commands
  Models/Item.swift            Item, Space, Conversation, ChatMessage (SwiftData)
  Services/
    LLMService.swift           Apple Intelligence availability and streaming generation
    AppleModelEngine.swift     Foundation Models calls (plain answers and guided organizing)
    Librarian.swift            saving items + the background AI organizing queue
    ContentExtractor.swift     link fetching, HTML→text, Vision OCR, PDF text, thumbnails
    SearchIndex.swift          NLEmbedding vectors + keyword hybrid ranking
    AttachmentStore.swift      copies of imported files
    SyncMonitor.swift          reports whether iCloud sync is running, and why not
  Views/                       Root (sidebar), Library grid, Item detail, Ask chat, Settings
project.yml                    XcodeGen spec (iOS + macOS targets)
```

Data is stored in the app's sandbox and synced through iCloud when it's set up: the SwiftData store and `Application Support/Attachments`.

## Ideas for next steps

- A share extension, so you can save straight from Safari or any app (needs an App Group to share the database)
- Voice notes with on-device transcription (Speech framework)
- A vision-language model to describe photos that have no text
