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
| **Themes** | Eleven looks in **Settings → Theme**: the original Loom and ten design languages from the Loom Design Languages system (Paper & Ink, Herbarium, Observatory, Blueprint, Terrazzo, Swiss Index, Kiln, Lamplight, Riso, Mist). Each is a whole language, in light and dark mode: colours, display, body and label type, corners, tile depth (soft light, shelf shadows, ruled and flat, hard offset prints, frosted glass), icon weight and motion, and its own map: underlined words on ruled paper, specimen labels, stars in a night sky, drafted boxes on grid paper, chunky chips on speckled stone, Swiss blocks, glazed pebbles on thrown rings, words in lamplight, misprinted tags over halftone, frosted pills in mist. Kiln is the default. |

## Requirements

- Xcode 26 or newer, on an Apple silicon Mac
- iOS 17+ / macOS 14+ to run the app. The AI features (organizing and Ask) need **iOS 26 / macOS 26 on a device with Apple Intelligence turned on**. Without it, saving, search and the map still work.

## Build and run

`Loom.xcodeproj` is checked in, so just open it:

```bash
open Loom.xcodeproj
```

If you change `project.yml`, regenerate the project with `brew install xcodegen` (one-time) and `xcodegen generate`.

1. In Xcode, select the **Loom-iOS** or **Loom-macOS** target, go to **Signing & Capabilities**, and check the Team. The project is set to the paid team `66BLLM3ERE` with iCloud sync on. To build with a free Apple ID instead, pick your own team and point `CODE_SIGN_ENTITLEMENTS` back at the plain `Loom-iOS.entitlements` / `Loom-macOS.entitlements` (a free team can't sign iCloud).
2. Press ⌘R.

Note for iPhone: with a free Apple ID, apps you sideload expire after 7 days. Re-run from Xcode to refresh. A paid developer account lasts a year.

## Install on your Mac

To get Loom into your Applications folder, double-click **Install Loom.command** in the repository folder in Finder. It gets the latest Loom from GitHub, builds it, installs it in /Applications with iCloud sync on, and opens it. After that you can open it from the Dock, Launchpad or Spotlight like any other app. To update, double-click it again.

It always installs the latest `main`. Edits made on the Mac are put aside in a git stash (`git stash pop` brings them back), and commits that aren't on GitHub are kept on a `loom-backup-…` branch. Offline, it installs the copy that's there. For updates to work, get the folder with `git clone https://github.com/bollineni-create/blank.git` rather than as a zip.

The same build from Terminal, without the update step:

```bash
./scripts/install-mac.sh               # builds, installs /Applications/Loom.app and opens it
./scripts/install-mac.sh --no-install  # builds only, into build/
```

It needs Xcode. It signs with the project's team (`66BLLM3ERE`) and turns on iCloud, so the installed app shares one library with the iPhone. Run it again after you pull changes to update the installed app. To build for a different team, use `LOOM_TEAM=<team id> ./scripts/install-mac.sh`. To build without any team (ad-hoc signed, no iCloud, its own library), use `LOOM_TEAM= ./scripts/install-mac.sh`.

## Sharing one library between Mac and iPhone (iCloud)

The library syncs through your private iCloud database (container `iCloud.com.bollineni.loom`). If it isn't set up, each device silently keeps its own library. **Settings → iCloud sync** on each device shows whether sync is on, and if not, why.

For sync to work:

1. **A paid Apple Developer Program team.** A free Apple ID can't sign apps with iCloud. The project is set up for team `66BLLM3ERE` with the `-iCloud` entitlements on both targets; with a free team, switch `CODE_SIGN_ENTITLEMENTS` in `project.yml` back to the plain files and run `xcodegen generate`, and each device keeps its own library.
2. **The same team on both targets.** In Xcode, open **Signing & Capabilities** for **Loom-iOS** and **Loom-macOS**, choose the same team, and check that the **iCloud** capability lists the `iCloud.com.bollineni.loom` container on both. Container names are unique across all developers. If Xcode says the name is taken, pick another one (for example `iCloud.com.yourname.loom`), and change it in both `-iCloud` entitlements files and in `SyncMonitor.containerID`.
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
