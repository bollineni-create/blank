# Loom — a private, on-device second brain

A personal take on [Fabric](https://apps.apple.com/us/app/fabric-your-second-brain/id6449003046) for **iPhone, iPad and Mac**. All the AI runs **on your device** with [llama.cpp](https://github.com/ggml-org/llama.cpp) on the GPU. After a one-time model download, nothing you save leaves the device. There are no accounts, no servers and no API keys.

## What it does

| | |
|---|---|
| **Save anything** | Notes, links (the page text is fetched), photos and screenshots (on-device OCR), PDFs (text plus OCR for scans) and any other file. You can add things with the + menu, paste (⌘V on Mac), or drag and drop. |
| **Auto-organize** | The local model writes a title, a 1–3 sentence summary and topic tags for each item. It reuses your existing tags so they stay consistent. |
| **Semantic search** | Search matches meaning as well as keywords. It uses Apple's built-in sentence embeddings, so it works offline even with no LLM loaded. |
| **Ask your library** | Chat with your stuff. Answers are grounded in your saved items and cite them as `[1]`, `[2]`, and each source is a tappable link. Chats are saved. |
| **Spaces and tags** | Folders ("Spaces"), auto tags, favorites, and filters by type. |
| **Model manager** | Download, switch and delete models (GGUF from Hugging Face): Qwen3 (0.6B–8B), Gemma 3 1B, Llama 3.2 (1B / 3B). |

Recommended models: **Qwen3 1.7B** on iPhone (about 1.1 GB) and **Qwen3 4B** on Mac (about 2.5 GB). Use **Qwen3 8B** on a Mac with 16 GB of RAM or more.

## Requirements

- Xcode 26 or newer, on an Apple silicon Mac
- A real iPhone/iPad or Mac to run downloaded models. The app also runs in the iOS Simulator, but there only Apple Intelligence works: llama.cpp has no simulator build, so `LlamaKit/fetch-llama.sh` adds a stub simulator slice.
- No extra Xcode downloads: llama.cpp ships precompiled, so the Metal toolchain is **not** needed.
- iOS 17+ / macOS 14+

## Build and run

```bash
brew install xcodegen      # one-time
xcodegen generate          # downloads llama.cpp (about 65 MB, once), then creates Loom.xcodeproj
open Loom.xcodeproj
```

1. In Xcode, select the **Loom-iOS** or **Loom-macOS** target, go to **Signing & Capabilities**, and choose your Team. A free Apple ID works. iCloud sync is off by default because it needs a paid Apple Developer Program team (see below).
2. Press ⌘R.
3. On first launch, Loom offers to download the recommended model. Use Wi-Fi.

Notes for iPhone:
- The iOS target requests the `increased-memory-limit` entitlement so 1–4B models fit in memory. If your signing team can't use it, remove that entitlement from `Loom/Resources/Loom-iOS.entitlements` and stick to models of 1.7B or smaller.
- With a free Apple ID, apps you sideload expire after 7 days. Re-run from Xcode to refresh. A paid developer account lasts a year.

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
    LLMService.swift           model catalog (GGUF files), download/load/delete, streaming generation
    Librarian.swift            saving items + the background AI organizing queue
    ContentExtractor.swift     link fetching, HTML→text, Vision OCR, PDF text, thumbnails
    SearchIndex.swift          NLEmbedding vectors + keyword hybrid ranking
    AttachmentStore.swift      copies of imported files
    SyncMonitor.swift          reports whether iCloud sync is running, and why not
  Views/                       Root (sidebar), Library grid, Item detail, Ask chat, Settings
LlamaKit/                      small Swift wrapper around the prebuilt llama.cpp XCFramework
project.yml                    XcodeGen spec (iOS + macOS targets)
```

Data is stored in the app's sandbox and synced through iCloud when it's set up: the SwiftData store, `Application Support/Attachments`, and models in `Application Support/Models` (excluded from iCloud backup).

## Ideas for next steps

- A share extension, so you can save straight from Safari or any app (needs an App Group to share the database)
- Voice notes with on-device transcription (Speech framework)
- A vision-language model to describe photos that have no text
