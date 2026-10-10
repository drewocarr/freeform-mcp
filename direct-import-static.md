# Direct board import: static tracing, 2026-10-09

Inspected the shipped `/System/Applications/Freeform.app/Contents/MacOS/Freeform`, version 5.0 (656.1.2), arm64e slice, without launching, modifying, or attaching to the original process. All addresses below are unslid virtual addresses (image base 0x100000000).

## Result

The hidden `CRLUtilitiesIntent` cannot import/export boards on this shipped Mac build: both operations dispatch directly to an unimplemented error. The misleading operation names and descriptions are real metadata, but do not establish functionality. `manipulate` explicitly reports that it is not implemented for macOS.

There **is** a separate implemented QA file import route, accessible from a QA menu. However, the app only installs that menu on an internal OS installation, and its file import/export entries have an additional `Freeform/FileImportExport` feature gate. The traced menu gate is an internal-OS check, not a simple user-default switch.

Neither finding proves that every other receiver path is absent. In particular, URL handling and file document registration require separate analysis. Do not broaden this result into “Freeform has no import implementation.”

## Hidden utility dispatch: exact proof

1. The intent implementation reads its operation's wrapped byte at `0x100f69ea8..0x100f69eb4`, then arguments at `0x100f69eb8..0x100f69ec4`.
2. At `0x100f69ee8..0x100f69ef8`, it loads async function descriptor `0x1015a2b90`. The signed relative pointer there is `-5695332`, which resolves to `0x10103442c`.
3. That function stores the operation byte and argument array, hops to the main executor, and checks array count at `0x1010344f4..0x1010344fc`. Empty arguments return `Error: No arguments provided.` at `0x101034564`.
4. With nonempty arguments, it takes the first argument and forms the remaining argument array, then dispatches the operation at `0x101034520..0x101034540` through table `0x1010346c4` relative to `0x101034538`.
5. The enum raw-value converter starts at `0x100718528`, with its own table `0x10071865c` relative to `0x100718558`. Decoding the short Swift string immediates and literal references produces:

| Index | Operation | Utility branch |
|---|---|---|
| 0 | boardID | 0x101034610 |
| 1 | downloadStatus | 0x101034544 |
| 2 | importBoard | 0x101034544 |
| 3 | exportBoard | 0x101034544 |
| 4 | shareBoard | 0x101034544 |
| 5 | acceptSharedBoard | 0x101034544 |
| 6 | stopSharingBoard | 0x101034544 |
| 7 | downloadBoard | 0x101034544 |
| 8 | resetBoard | 0x101034544 |
| 9 | manipulate | 0x1010345ec |

`0x101034544` releases the remaining argument array and constructs the error string `Error: Utility not implemented` (literal reference `0x101034558`). `0x1010345ec` constructs `Error: Utility not implemented for macOS` (literal reference `0x1010345f8`). Both flow into a Swift error allocation/throw sequence at `0x101034580..0x1010345e8`.

Consequently, **there is no import/export argument grammar to unlock in this utility implementation**. No feature check precedes those error branches.

`boardID` is the only active operation: it rejects remaining arguments with `Error: Operation doesn't support multiple boards` (`0x101034624`), then delegates the first string to async lookup `0x100c80b24`. Its exact name/UUID matching contract has not been traced here.

## Separate implemented QA import

`qa_importFile(_:)` belongs to `CRLMacWindowViewController.swift` (source diagnostic at `0x1009bacb8..0x1009bacc0`). It creates `NSOpenPanel` at `0x1009bab80`, disables directory selection at `0x1009bab98`, and presents a sheet at `0x1009bac54` (stub `0x1013d8240` resolves to `beginSheetModalForWindow:completionHandler:`).

An actual async reader operation starts at `0x1009bb5b0`. It logs `QA Import file %{public}@` at `0x1009bb930`, then `QA Import read board from file %{public}@, attempting to save.` at `0x1009bbda8`. A separate database helper includes `addImportedBoard(board:in:)` at `0x1004eda60`, with failure `boardIdentifierMustBeOwnerForCreation` at `0x1004ed4ac`. This is materially stronger evidence of a real file-reader/save implementation than the hidden utility's names.

The menu builder at `0x100e29d6c` creates the QA menu and, conditional on a feature flag, creates:

- `Export to File…` -> `qa_exportToFile:` (`0x100e29e20..0x100e29e2c`).
- `Import File…` -> `qa_importFile:` (`0x100e29e98..0x100e29ef0`).
- `Import/Export Options…` -> `qa_importExportOptions:` (`0x100e29f18..0x100e29f24`).

At `0x100e29df4`, feature enum value 15 is checked through `FeatureFlags.isFeatureEnabled` (`0x100e29e04`), and false skips those entries (`0x100e29e18`). The feature key converter starts at `0x10060bde8`; its table at `0x10060c0d4` maps value15 to `0x10060bf20`, which loads the literal **FileImportExport**. The shipped `/System/Library/FeatureFlags/Domain/Freeform.plist` has no FileImportExport entry. Absence alone is not a runtime false proof.

## QA menu's independent internal-OS gate

App startup at `0x100499850..0x100499870` checks a cached byte at `0x101ae4d48` before obtaining and inserting the QA menu (`0x10049989c`). The cached byte is initialized by `0x100b471ec`, which calls `+[CRLInternalOSUtilities isInternalOSInstall]`:

- ObjC class metadata at `0x1019c67d8` identifies `CRLInternalOSUtilities`.
- Call stub `0x1013fb1c0` identifies selector `isInternalOSInstall`.
- Class method implementation is `0x10026f19c`, caching a result calculated at `0x10026f1d4`.
- The calculation obtains the main bundle identifier then calls `_os_variant_has_internal_content` at `0x10026f228`.

No preference-based override occurs in this traced method. Enabling a feature flag alone would not cause normal startup to add the QA menu.

## Other import-looking symbols can be stubs

A separate callback at `0x10106df2c..0x10106dfe8` only logs `We have not yet implemented import board.` and releases objects; selector `importBoardWithSender:` is also tested by menu validation at `0x1010644d8`. The exact metadata binding between that selector and this callback was not resolved here, so treat the relationship as a lead rather than verified attribution. An export placeholder message exists at `0x10108f378`.

## Concrete next experiment

The existing isolated lab copy could expose the QA menu locally, or call its QA import/export methods, to obtain a synthetic native archive and validate archive contents and preservation of editability. That experiment would avoid the original app, real boards, global flags, and global security changes. **It would prove the archive format, but would not yet provide an externally callable receiver in the normal Apple-signed Mac app.**

## Reproduction artifacts

`direct-import/disassembly.txt`: `xcrun llvm-objdump --macho --arch=arm64e --disassemble --no-show-raw-insn` output.

`direct-import/objc-metadata.txt`: `--objc-meta-data` output. `direct-import/objc-stubs.txt`: disassembly including `--section=__objc_stubs` to resolve modern objc_msgSend selector stubs.

`direct-import/Freeform.arm64e`: temporary unmodified thin arm64e slice used to read relative jump tables and async descriptors, generated by `xcrun lipo -thin arm64e`.

## Bounded URL-handler follow-up

The concrete Objective-C `application:openURLs:` method resolves via selector reference `0x1019b3400` and method metadata to IMP **0x10049f09c**. It bridges the NSArray of URLs and calls **0x1004b7fa8**. That function checks the array is nonempty, operates on its first URL, logs `Opening board from URL: %{public}@` (`0x1004b8100`), and either defers it until application readiness or calls **0x1004a07bc**.

The latter attempts board and folder/shared-item resolution (`0x1004c0c3c`, `0x1004c1ebc`), then additional existing board/share-link parsing. The visible fallback includes `https://www.icloud.com/freeform/` and `/freeform-folder/`; failure logs `Failed to open URL: %{public}@` at `0x1004a0f30`.

One resolver's verified contract includes:

- `URLComponents.scheme == "freeform"`, encoded as short Swift-string immediates at `0x1004c188c..0x1004c1898`.
- Host `board` or `folder`, conditional on requested object kind (`0x1004c1964..0x1004c1988`).
- Query item **sharingToken**, matched by short-string immediates at `0x1004c1b60..0x1004c1bb0`.

This is evidence for opening/resolving existing boards and shared objects, not submitting new shape data. No direct board-file reader or shape JSON import call was established in the traced handler. The previously found `freeform://board?id=` string is consistent with navigation; this follow-up did not fully decode the separate ID-parser function.

**`com.apple.apps.freeform-edit-in` remains unresolved.** It is declared in Info.plist, but no corresponding literal in the main executable's extracted strings established its handler. Its query parameters, payload transport, and external callability were not recovered in this bounded trace. In particular, do not call it clipboard-backed or file-backed on this evidence. It could be handled by a linked framework or a different platform path; those remain hypotheses.
