# Objective-C probe and isolated editing experiment

The default probe records runtime metadata; `FF_PROBE_SELFTEST=1` tests a synthetic getter. The opt-in `FF_OFFLINE_MODE=stub` additionally redirects cloud/storage dependencies, captures live scratch-board objects, and enables local native move requests. See [LIVE-EDIT.md](LIVE-EDIT.md) for the successful live test and its limits. That mode refuses hosts whose bundle identifier is not `local.freeform.bridge.lab`.

- `FF_PROBE_LOG`: absolute JSONL output file; created with mode 0600, append only, final symlink rejected.
- `FF_PROBE_EXIT=1`: exit immediately after constructor inventory and optional hook installation, before app main. Framework constructors and Objective-C `+load` may already have executed; this is not a universal guarantee that no startup code ran.
- `FF_PROBE_HOOK=1`: replace `NSApplication.finishLaunching` after checking that its runtime signature is exactly `void(id, SEL)`. Record invocation then call the original implementation with identical arguments. This flag alone does not enable the Freeform-specific hook.
- `FF_PROBE_FREEFORM_HOOK=1`: independently enable a metadata-only passthrough for `CRLPasteboardController.init`, accepting only the exact observed `@16@0:8` encoding. The wrapper preserves init's consumed receiver and retained return ARC conventions. It records entry/return without inspecting the object. Both lifecycle hooks now record `hook_return` after the original returns normally.
- `FF_PROBE_SELFTEST=1`: run the actual `CRLPasteboardController.delegate` getter on zeroed synthetic instance storage via Objective-C message dispatch, with a passthrough wrapper and nil-result assertion. Restore the method and exit before app main; no normal initializer or destructor is run. This mode exits regardless of `FF_PROBE_EXIT`.

Compile:

```sh
make
xcrun clang -arch arm64 -fobjc-arc -Wall -Wextra -framework Foundation -framework AppKit fixture.m -o fixture
xcrun clang -arch arm64e -fobjc-arc -Wall -Wextra -framework Foundation -framework AppKit fixture.m -o fixture-arm64e
```

## Independent fixture verification

The fixture links AppKit but does not launch an application or open any document. It replaces `finishLaunching` with an inert counter, installs the probe hook over that counter using exported `FFProbeInstallHook`, then invokes the method implementation once. This isolates ABI and original-call forwarding from AppKit startup effects.

Verified on this machine:

1. Inserted dylib constructor logs `loaded` and four absent Freeform class records inside the standalone fixture.
2. `FF_PROBE_EXIT=1` returns exit code 0 with no fixture main output (`fixture-exit-verified.jsonl`).
3. Constructor installs hook with encoding `v16@0:8`; fixture reinstalls over inert implementation, logs `hook_called`, prints `fixture_original_calls=1`, and returns 0 (`fixture-hook-final.jsonl`).
4. Both source files compile with `-Wall -Wextra` without warnings.

The fixture results alone demonstrate library loading and swizzling in our own process. The subsequent real Freeform selftest below provides stronger evidence in a disposable re-signed copy. Neither establishes loading into the installed Apple-signed app, successful normal app startup, or live board access. Runtime inventory at constructor time also may miss classes loaded later.

The arm64e variants compiled successfully without warnings and the arm64e probe subsequently ran inside the disposable Freeform copy. `fixture-arm64e` also provides a separate host-policy check, distinguishing pre-main host-policy failures from Freeform-specific startup requirements.

The earlier `fixture-hook.jsonl` was an incomplete first fixture experiment: its `+load` reset the method after constructor installation and therefore recorded no hook invocation. The final fixture installs explicitly after setting its inert original and verifies both hook entry and original forwarding.

## Follow-up app-specific hook

The root agent's `logs/freeform-adhoc-v2.jsonl` contains live Freeform runtime evidence: `CRLPasteboardController.init` has `@16@0:8`, and `Freeform.CRLBoardItem.crl_onBoard:moveItemToPosition:size:` has `v56@0:8@16{CGPoint=dd}24{CGSize=dd}40`. Only the initializer passthrough was implemented here; movement remains a candidate requiring live board/item references and validation of undo behavior.

Both architectures compiled warning-free after this extension. `fixture-hook-return.jsonl` verifies the AppKit hook still forwards once, emits its return marker, and rejects the absent Freeform class safely. Actual Freeform-specific hook invocation must be assessed from the root agent's isolated-app runs.

## Actual Freeform getter selftest: passed

`logs/selftest3-result.json` records successful execution of the real Freeform getter under an installed swizzle, through typed `objc_msgSend`, in the disposable re-signed Freeform executable. It records one hook call, one original call, the expected nil return, method restoration, and exit code 0. `original_image` resolves to the cloned Freeform main executable; no fake getter implementation was substituted for the original.

Offline metadata established that `_delegate` is a weak ivar at offset 64. Disassembly of the getter at unslid `0x10001b170` showed only the weak load and autoreleased return:

```asm
add x0, x0, #0x40
bl  _objc_loadWeakRetained
... frame and pointer-authentication return instructions ...
b   _objc_autoreleaseReturnValue
```

The selftest checks exact method encoding `@16@0:8`, NSObject superclass, ivar offset, and weak property metadata before `class_createInstance` creates zeroed storage. A static strong reference keeps that synthetic object alive until `_exit`; it is never attached to a board. The wrapper invokes the preserved original implementation and checks only whether the return is nil. The test reads no user object values.

Run with `python3 run-selftest.py <unique-alphanumeric-label>`. The script uses `sandbox-exec` with the existing lab profile, preventing network access, personal-file reads, and writes outside the evidence and isolated lab data directories, with an eight-second timeout. Running the nested sandbox required execution outside the agent's enclosing sandbox. The initial restricted attempt (`selftest1`) failed at `sandbox_apply`; `selftest2` passed with a direct fetched IMP call, and final `selftest3` passed through normal Objective-C message dispatch.

This proves real Freeform method swizzling and original-call forwarding in a re-signed copy. It does not prove live board access, undoable editing, or a working normal application launch. The root agent's separate normal-startup experiment stopped at a CloudKit initialization trap; this selftest exits before that startup path.

The loading/selftest sections above describe earlier milestones. Live board editing and persistence were subsequently proven in the separate opt-in offline experiment; see [current results](RESULTS.md).
