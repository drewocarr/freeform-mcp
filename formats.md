# Freeform formats and semantic clipboard bridge

Inspected installed `/System/Applications/Freeform.app` 5.0 (656.1.2), read-only. No personal boards, databases, clipboard contents, or documents were read or changed. Evidence is static binary/resource inspection; it does not prove runtime import succeeds.

## Most promising route: versioned JSON on the clipboard

Freeform ships a **bidirectional structured JSON clipboard integration**, beyond plain text and images. This is the strongest lead for making a JavaScript object creation bridge without loading code into Freeform.

Concrete evidence in `freeform-strings.txt`:

- 4389–4390: `CRLItemProviderItemWriter addJSONRepresentationOfBoardItems:toPasteboardObject:withItemProvider:`.
- 6935–6939: `CRLPasteboardController+ContentLanguage.swift`, `Failed to initialize drawables Array model`, `Failed to create drawableJsonData`.
- 25310: `contentLanguageBoardItemProvidersForPasteboard:itemIndex:boardItemFactory:`.
- 12580–12629: actual shape, image, group, path, resource importers; path importer has `PathImporter.failedToParseSVGString`. Resource importer supports base64 data.
- 13890–13896: `Paste failed. Failed to import drawable...`, `CRLContentLanguageBoardItemProvider`, `SharedJsonDrawableContext`.
- 30005: `isContentLanguageCopyPasteEnabled`; 7078: `ContentLanguageCopyPaste`.
- Root investigation found `/System/Library/FeatureFlags/Domain/Freeform.plist` marks `ContentLanguageCopyPaste` as `FeatureComplete`. This is not proof of effective runtime enablement.

The embedded `TSContentLanguage.framework` provides the data model and encoders. Demangled exported symbols saved to `content-language-symbols.txt` prove:

- `TSCLModelType.from(jsonData:session:)` and `.jsonData(session:)` (15236–15237).
- `TSCLModels.Array.init(elements:)`, Codable conformance, `encode(to:)` and `init(from:)` (11394–11426).
- `TSCLDecodingSession(... substituteInvalidValues:ignoreVersionInfo:)` (15339–15341).
- `TSCLModels.Shape.init(identifier:comments:geometry:aspectRatioLocked:description:opacity:image:path:tail:head:fill:stroke:shadow:layoutProperties:text:presetIdentifier:customData:alternateRepresentation:)` (12451).
- `Geometry.init(position:size:angle:flipHorizontally:widthValid:heightValid:...)` (14233).
- `Position.init(x:y:...)`, `Size.width/height`, and `Path.BezierPath.init(path:space:...)`.

Exact strings recovered from framework (`content-language-strings.txt`):

| Role | Evidence |
|---|---|
| Clipboard type prefix | `com.apple.apps.content-language.canvas-object-` (279) |
| Canvas object type | `com.apple.apps.content-language.canvas-object` (523) |
| Array type | `com.apple.apps.content-language.array` (747) |
| Object types | `...shape`, `...connection-line`, `...group`, `...image`, `...textbox` (410, 464–477) |
| Geometry types | `...geometry`, `...position`, `...size`, `...rect` (496–499) |
| Envelope keys | `type_identifier`, `version`, `children` (743–745) |
| Styling/geometry keys | `aspect_ratio_locked`, `geometry`, `position`, `size`, `flip_horizontally`, `width_valid`, `height_valid`, `opacity`, `fill`, `stroke`, `text` |
| Resource representations | `base64_encoded`, `indirect`, `filename`, `asset_uuid`, `encoding_format`; separate pasteboard prefix `com.apple.apps.content-language.resource-` in Freeform (1771) |
| Version representation | `TSCLVersion.init(String)` and regex `major.minor` (696); also major/minor properties. Exact wire version representation not yet established. |

This is enough to define an external JS API such as `insertShapes([{x,y,width,height,svgPath,fill,text}])`, backed by a native clipboard helper and Paste. It is **not yet enough to claim a working wire payload**. Exact envelope nesting, enum representation, defaults, per-model version numbers, and full pasteboard UTI suffix must be captured from a synthetic copied object. No JSON schema file or Swift module interface ships in the framework resources; the schema is implemented in binary Codable models.

Do not present a guessed JSON skeleton as accepted input. A useful internal JS model can remain simple while its adapter emits the verified Apple format later.

Limitations visible already: `CanvasObjectImporter.temp_unsupportedTextbox` and `ShapeImporter.unsupportedTextType` occur in the binary. Supported model classes do not prove Freeform imports every member. The UI insertion path may offset/normalize coordinates. Copy/paste creates objects; no evidence yet that it updates an existing object by identifier.

## Native clipboard: alternative, more complex

The app names exact native pasteboard types (1767–1770):

- `com.apple.freeform.CRLNativeData`
- `com.apple.freeform.CRLNativeMetadata`
- `com.apple.freeform.CRLAsset.` (prefix)
- `com.apple.freeform.TSUDescription`

`CRLPasteboardObject` has Swift `encode(to:)` / `init(from:)`, board item UUIDs, style presets, board items, and text CRDT (13666–13677). Write and read assistants manage native bytes and separate asset channels. A native object round trip could preserve more fidelity, but the JSON compatibility path avoids much of this unknown binary representation and CRDT detail.

## Board files and persistence

Info.plist exports `com.apple.freeform.board` with `.board`, and `com.apple.freeform.folder` with `.folder`. Internal utility description independently says `Export a board to a local .freeform file` (7587). These names should not be conflated: their on-disk roles are not verified.

`CRLBoardFileReadAssistant` and `CRLBoardFileWriteAssistant` exist. Swift reflection fields include `zipArchive`, `objectsEntryName`, `metadataEntryName`, `store`, `context`, and `readAssistant` (54671–54680), strongly suggesting ZIP-based board interchange. Exact entries and serialized object payload remain unknown. Internal options include `CRLFileImportPreserveObjectUUIDs` and `CRLFileImportPreserveCRDTMetadata` (7579–7580).

Persistence/sync strings show board_items SQLite data, CRDT metadata, CloudKit merge values, UUID remapping, assets, and parent container relationships. Direct database editing would bypass the app's normal change handling; it is a poorer first bridge than clipboard or supported actions.

## Hidden utility lead

Binary includes `Internal Freeform Utilities`, description `Manipulate items on a board`, and enum-like operation names `importBoard`, `exportBoard`, `shareBoard`, `downloadBoard`, `resetBoard`, `manipulate` (7581–7600). This establishes internal tooling exists, not that arbitrary JSON commands are callable externally. No callable JS evaluation surface was established by this investigation.

## Next minimal proof

On an explicitly disposable test board, copy a rectangle and text-bearing shape, save only their structured clipboard types and JSON, then reproduce them with a native helper writing those exact types. Verify shape count, geometry, text, and undo in Freeform. Then change one JSON field at a time and repaste. This will resolve the format and feature gate with much less effort than reverse engineering the native board archive. MCP should wrap a Node/TypeScript API that delegates clipboard/Accessibility operations to a small native helper; the JSON adapter can remain pure JavaScript once schema is established.
