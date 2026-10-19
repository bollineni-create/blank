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

1. In Xcode, select the **Loom-iOS** or **Loom-macOS** target, go to **Signing & Capabilities**, and choose your Team. A free Apple ID works for personal use.
2. Press ⌘R.
3. On first launch, Loom offers to download the recommended model. Use Wi-Fi.

Notes for iPhone:
- The iOS target requests the `increased-memory-limit` entitlement so 1–4B models fit in memory. If your signing team can't use it, remove that entitlement from `Loom/Resources/Loom-iOS.entitlements` and stick to models of 1.7B or smaller.
- With a free Apple ID, apps you sideload expire after 7 days. Re-run from Xcode to refresh. A paid developer account lasts a year.

## Save from any app (Share → Loom)

Loom adds a **Loom** option to the system Share menu on iPhone, iPad and Mac. Share a web page, text, photos, videos, PDFs or files to it, add an optional note, and tap **Save**. The Share extension drops everything into a shared inbox (App Group `group.com.personal.loom`), and Loom imports and summarizes it the next time it's open, or right away if it's already running.

If Loom doesn't appear in the Share menu on iPhone, scroll the app row to the end, tap **More**, and turn on Loom. On Mac, open **System Settings → General → Login Items & Extensions → Sharing** and enable Loom.

## iCloud sync

The library (items, files, tags, spaces and chats) syncs through your private iCloud database (`iCloud.com.personal.loom`). This needs the paid Apple Developer Program. In Xcode, under **Signing & Capabilities** for each app target, make sure the iCloud container is ticked. Settings in Loom shows whether sync is on. If iCloud can't start, Loom keeps working on that device and Settings says why.

## TestFlight (install on iPhone without a cable)

Do this once:
1. At [App Store Connect](https://appstoreconnect.apple.com) choose **Apps → + → New App**. Platform **iOS**, name **Loom** (add something like "Loom Brain" if the name is taken), bundle ID **com.personal.loom.ios**, and any SKU, e.g. `loom-ios`.
2. Open the app, go to the **TestFlight** tab → **Internal Testing → +**, create a group, and add yourself.
3. Install the **TestFlight** app on your iPhone from the App Store.

Then for each version:
1. In Xcode, choose the **Loom-iOS** scheme and **Any iOS Device (arm64)**, then **Product → Archive**.
2. In the Organizer window, click **Distribute App → TestFlight & App Store → Distribute**. Leave "Manage version and build number" on so each upload gets a new build number.
3. After processing (usually 5–15 minutes), the build appears in TestFlight on your iPhone. Tap **Install**. TestFlight builds last 90 days; upload a new one any time.

The Mac app can go through TestFlight the same way: add a **macOS** platform to the same app record, then archive **Loom-macOS**.

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
  Views/                       Root (sidebar), Library grid, Item detail, Ask chat, Settings
LlamaKit/                      small Swift wrapper around the prebuilt llama.cpp XCFramework
project.yml                    XcodeGen spec (iOS + macOS targets)
```

Data is stored in the app's sandbox (and synced through iCloud when available): the SwiftData store, `Application Support/Attachments`, and models in `Application Support/Models` (excluded from iCloud backup).

## Ideas for next steps

- Voice notes with on-device transcription (Speech framework)
- A vision-language model to describe photos that have no text
