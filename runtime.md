# Freeform native runtime and bridge feasibility

Inspected read-only on 2026-10-09: `/System/Applications/Freeform.app`, version **5.0 (656.1.2)**; Mach-O architectures **arm64e, arm64e.x1**. No attachment, injection, app changes, or user document access performed.

## Conclusion

A JavaScript MCP adapter running **outside** Freeform remains feasible through whatever external automation/clipboard/URL facilities can be verified. This inspection finds **no existing in-process JavaScript board API or generic board-edit XPC service**. Directly injecting a custom JS bridge into the installed system app is not a normal supported integration: platform signing and library validation stand in the way, and the useful board types live inside the native executable.

## Evidence

- `otool -L Contents/MacOS/Freeform` shows AppKit, SwiftUI, Metal, PencilKit/PaperKit, Coherence, `_Coherence_CloudKit_Private`, CloudKit and sqlite3. This is a native canvas/model, not an Electron/web application.
- Main executable strings name `CRLCanvasView`, `CRLCanvasLayer`, `CRLCanvasLayoutController`, `Freeform.CRLBoardItem`, and source paths ending in `CRLMacCanvasView.m`, `CRLBoardItem+CanvasPositioning.m`, and `CRLCommands/CRLCanvasCommandSelectionBehavior.m`.
- `nm -u` shows extensive Coherence `CRDT`, `CRRegister`, `CRStruct`, `CRContext`, `CRCKMergeable` imports. Board writes likely require native model changes and merge/undo bookkeeping, rather than treating a saved database as a simple row store. This is an architectural inference, not a tested write operation.
- Main executable links WebKit **but not JavaScriptCore**. Its WebKit class imports are `WKPDFConfiguration`, `WKWebView`, and `WKWebViewConfiguration`; `evaluateJavaScript:completionHandler:` exists.
- The relevant JavaScript is `Contents/Resources/SVGSize.js`, which computes SVG viewport/viewBox geometry and returns `size`/`roundedSize`. Adjacent binary strings explicitly say `SVG rendering with WebKit needs to be done on the main thead.`, name `CRLSVGRenderer`, load `SVGSize`, and reference `commitRoundedGeometry();`. The `http://localhost/` nearby is associated with SVG rendering; it is **not evidence of a local HTTP control server**.
- All bundled framework direct dependencies were checked. Only AppContentHub adds another direct WebKit dependency. No bundled framework directly links JavaScriptCore. This does not exclude indirect dependencies or dynamically loaded code.
- `codesign -dvvv --entitlements :-` reports **flags=0x2000(library-validation)**, `platform-application=true`, and `com.apple.security.app-sandbox=true`. There is no `get-task-allow`, `disable-library-validation`, or unsigned-executable-memory entitlement in the displayed set. Do not describe this as the generic hardened-runtime flag: the observed flag is specifically library validation.
- App has private Apple entitlements for CloudKit, application group `group.com.apple.freeform`, account services, and `com.apple.freeform.USD-renderer-remote-UI-entitlement`. A separately signed helper cannot assume it inherits these privileges.
- Bundle contains `Extensions/USDRendererExtension.appex` and `PlugIns/FreeformSharingExtension.appex`, no standalone XPC services discovered. Renderer declares `EXExtensionPointIdentifier=com.apple.freeform.USD-renderer-remote-UI`. Share extension declares the ordinary `com.apple.share-services` extension point.
- Main executable XPC protocols found: `CRLUSDRenderingExtensionAPIEndpointProtocol`, `RealitySnapshotExtensionXPCProtocol`, `_CRLUSDAsyncRenderingXPC`, `_CRLUSDAsyncRenderingDelegateXPC`. Imports include `NSXPCConnection` and `NSXPCInterface`, not `NSXPCListener`. These are evidence for client-side rendering IPC, not a generic public board API. Absence here is bounded to static symbols/strings, not a runtime proof.
- Share extension accepts URL, active webpage, file URL, image, plain text, rich text, movie, and map-item UTIs with count limits. This may provide an import route mediated by normal UI; it does not expose arbitrary object manipulation.

## Practical design implication

Start an external JS process for MCP, use verified OS automation/import operations, and return capability-specific errors for unsupported object edits. If deeper access is required, prioritize mapping external import/clipboard serialization before attempting native runtime instrumentation. Native method names are useful reverse-engineering clues, but they are not callable cross-process APIs simply because JXA can bridge Objective-C in its own process.

## Reproduction

```
otool -L /System/Applications/Freeform.app/Contents/MacOS/Freeform
codesign -dvvv --entitlements :- /System/Applications/Freeform.app
nm -u /System/Applications/Freeform.app/Contents/MacOS/Freeform
strings /System/Applications/Freeform.app/Contents/MacOS/Freeform
cat /System/Applications/Freeform.app/Contents/Resources/SVGSize.js
```

Raw executable strings are saved beside this note in `freeform-strings.txt`; they contain bundled program strings only, not user document contents.
