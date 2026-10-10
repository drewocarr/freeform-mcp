# Offline startup seams (read-only investigation)

Inspected installed Freeform 5.0 executable and existing strings on 2026-10-09. No app launches or changes made by this worker.

## The apparent disable switch is only a dialog switch

`CRLDisableCloudKitSync` has one directly materialized string address in the baseline arm64e slice, at VM `0x101531470`. Its caller is function `0x100ff65d8`.

- `0x100ff6618` loads the string.
- `0x100ff6640` invokes a boolean lookup.
- `0x100ff6658` branches on the boolean.
- True logs **Skipping iCloud dialog due to user default** at `0x100ff6690` and returns via `0x100ff679c`.
- False reads `CRLConnectICloudDialogShown`, checks system version, obtains a window, and continues toward dialog presentation.

Evidence: [offline-default-disassembly.txt](logs/offline-default-disassembly.txt). There is no evidence this default avoids the unconditional shared CKContainer creation observed in the prior crash. It can still be useful to suppress onboarding in an offline lab.

## App-level candidates for runtime inventory

- `Freeform.CRLiCloudStatusObserver`: source string explicitly names Sync/CRLiCloudStatusObserver.swift. Associated status notifications include CRLiCloudStatusChanged, CRLiCloudUserRecordIDChanged, and CRLiCloudDeviceToDeviceEncryptionAvailabilityChanged. Selectors include iCloudStatus, iCloudConnectionStatus, iCloudStatusDidChangeWithNotification:.
- `Freeform.CRLSyncDriver` and `Freeform.CRLSyncController`: strings show normal code can tolerate absent syncEngine: “Can't fetch records for zoneID. There is no syncEngine set”. These seams are downstream of the global CKContainer creation; no complete no-cloud startup mode was established.
- `Freeform.CRLBoardLibrary`, `Freeform.CRLBoardLibraryHeadlessController`: board lifecycle and persistence integration candidates. The latter is explicitly supported by a headless controller dependency protocol, useful for eventual non-UI model testing.
- `Freeform.CRLMacAppDelegate`: nib initialization currently triggers the CKContainer global. Its later applicationDidFinishLaunching path logs “CloudKit syncing is enabled”.

## Storage may already have a transient fallback

Strings from Persistence/CRLBoardDataStoreProvider.swift:

- “Failed to open the main store with error ... Falling back to a transient store”
- `com.apple.freeform.store.transient`
- `newMainDataStore() ensureOwnershiopOfData=%d didMigrate=%d`
- `migrateAndCreateIfNeeded(newURL:legacyURL:)`
- “Using production path Boards” / “Using sandbox path Development/Boards”

Inventory `Freeform.CRLBoardDataStoreProvider` before considering a replacement. A transient store might support a visible model edit but would not prove persistence across launch. The Development/Boards path is not sufficient isolation by itself: it could still reside in the real app group. Real user storage must remain denied and any redirected writable path must stay under the dedicated experiment directory.

No genuine startup flag that disables all cloud dependency construction has been confirmed. ObjC `isLaunchedForTesting` and `setUpForTesting` selectors exist, as do PPT performance-test classes, but their presence alone does not establish an offline mode.

## Follow-up: offline5 storage assertion and offline7 progression

Offline static analysis of the parent-owned `offline5` crash pinpoints `setupBoardLibrary()` in CRLMacAppDelegate.swift, source line 374. VM `0x10049c65c` invokes fatal assertion with **Failed to initialize the data store. error=%@**. The generic CRLAssertHelper.swift line 369 visible in stderr is the fatal helper, not the originating failure condition.

The setup calls `0x100e0cf20`, which tries main-store creation (`0x100e0b9e0`) and, on thrown error, attempts transient creation (`0x100e0ccc8`). The transient path calls `-[TSUTemporaryDirectory initWithSignature:error:]` using signature `CRLBoardDataStore.transientStore`. A nil result becomes a thrown Swift error. This provides a precise ObjC diagnostic seam for failures caused by an unwritable temporary directory. Evidence: `logs/offline5-disassembly.txt`, `offline5-setup-store.txt`, `offline5-store-provider.txt`, `offline5-store-paths.txt`, `offline5-store-creation.txt`, and `offline5-storage-url.txt`.

Parent subsequently reported that lab storage redirection succeeded and `lab/data/groups/group.com.apple.freeform/Boards/boards.db` exists. The `offline7` attempt reached an intentionally unsupported `registerSystemSharingUIObserver` call in the offline CloudKit stand-in. The parent owns launch evidence and the sharing-observer adaptation. These results move the immediate blocker beyond storage initialization; they do not yet establish a live board edit or persistence verification.
