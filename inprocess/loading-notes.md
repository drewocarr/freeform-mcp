# Freeform in-process loading feasibility

Read-only inspection, 2026-10-09. No app was launched or changed by this research worker. Main experiment is owned by the parent agent.

## Local facts

- Installed executable: `/System/Applications/Freeform.app/Contents/MacOS/Freeform`.
- Host: macOS 27.0 build 26A428; compiler Apple clang 21.0.0 (clang-2100.3.34.2).
- Universal binary has **arm64e and arm64e.x1 only**. No arm64 or x86_64 slice exists, so Rosetta is not an available fallback for this copy.
- Parsed fat entries: CPU 0x0100000c, subtype 0x80000002, offset 16384, size 28881840; second subtype 0x8000000c, offset 28901376, size 28355488.
- SDK `mach/machine.h` confirms CPU_SUBTYPE_PTRAUTH_ABI = 0x80000000, ARM64E = 2, ARM64E_X1 = 12. These are pointer-authenticated code slices, not a plain arm64 binary that can be relabeled safely.
- Both slices have 155 load commands. Neither has LC_ENCRYPTION_INFO nor LC_ENCRYPTION_INFO_64. A `fairplay-client` entitlement exists, but it does not establish that these Mach-O bytes are encrypted.
- LC_BUILD_VERSION: macOS platform 1, minimum 27.0, SDK 27.0.
- `codesign -dvvv`: signature by macOS Software Signing / Apple Code Signing Certification Authority / Apple Root CA; flags 0x2000 (library-validation); platform identifier 26; no TeamIdentifier. This flag set does **not** show hardened-runtime 0x10000.
- Entitlements include platform-application, app sandbox, Apple private CloudKit/account APIs, iCloud production containers, restricted Freeform group, creatorstudio group, and Apple keychain groups. Neither get-task-allow nor disable-library-validation is present.
- LC_RPATH is `@executable_path/../Frameworks`. Eleven bundle frameworks are present: AppContentHub, AppImageGenerationModel, AppImageGenerationUI, AppsGen, AppsGenUI, TSAccessibility, TSContentLanguage, TSFeatureFlags, TSFundamentals, TSGeometry, TSUtility. A full bundle copy preserves this layout.
- Main executable also depends on many system private frameworks including Coherence, CloudKitCode, CloudSharing, CoreCDPUI, AuthKit, AppleAccount, and AppSubscriptions. Finding their symbols does not establish permission to use their services after re-signing.

## Live result: loading succeeded

The parent agent subsequently ran the controlled launch experiment. I inspected `logs/launch-results-v2.json` and `logs/freeform-adhoc-v2.jsonl`: arm64 fixture, arm64e fixture, and the actual re-signed Freeform copy all exited zero with constructor markers. Freeform produced 282 probe records including live Objective-C class/method metadata. The copy has identifier `local.freeform.bridge.lab`, ad-hoc flags 0x2, and empty entitlements. Thus **an arm64e dylib demonstrably loads inside this re-signed Freeform copy on this workstation without a security-policy change**.

The constructor exits before normal app startup. This proves loading and runtime introspection, not a working UI, active board, storage, or undoable editing. The initial default-deny sandbox had prevented even control launches; the revised controlled sandbox passes.

## Superseded predicted blocker

Apple's open-source XNU `bsd/kern/kern_exec.c` checks arm64e subtype, pointer-auth ABI version zero, and whether the binary is platform signed. When a version-zero binary is no longer platform signed, its normal path rejects execution unless a special developer boot policy is enabled. An ad-hoc re-sign loses Apple platform trust. The installed baseline slice is the version-zero subtype.

Source: https://github.com/apple-oss-distributions/xnu/blob/main/bsd/kern/kern_exec.c#L1596-L1624

This was a **source-backed prediction that the live test disproved for this workstation**. GitHub main is not necessarily the source of host build 26A428. We have not established why this host allows the code. Do not present arm64e as impossible, infer an enabled boot setting, or modify settings to explain a test that already passes.

## Additional loading constraints

Local `man dyld` explicitly says DYLD environment variables are ignored for binaries protected by System Integrity Protection. It documents DYLD_INSERT_LIBRARIES as libraries loaded before normal dependencies. Consequently, an unchanged system app plus an environment variable is not a verified loading mechanism.

Apple documents library validation as requiring Apple code or code signed by the same team; its documented opt-out is an entitlement on the host executable. That entitlement does not restore Apple's platform status or private-service privileges to a re-signed copy.

Source: https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.cs.disable-library-validation

Pointer authentication also matters after loading. The runtime should receive correctly typed function pointers through supported Objective-C runtime APIs. Do not raw-patch method table pointers or assume arm64/arm64e ABI compatibility. Apple states arm64e.x1 adds return-address protection but not a new calling ABI; both are still pointer-authenticated code.

Source: https://developer.apple.com/documentation/security/preparing-your-app-to-work-with-pointer-authentication

## Minimal experiment interpretation

1. Compile a tiny matching-architecture dylib whose constructor writes a unique marker. This only demonstrates that the toolchain can emit the probe.
2. Parent-owned isolated bundle copy: use a new research bundle identifier and no production CloudKit/app-group entitlements; maintain embedded frameworks and resources. A changed identifier is useful separation but not proof that hard-coded Freeform storage paths are isolated.
3. Ad-hoc sign the experimental host with development-specific entitlements as appropriate, then verify the resulting signature/entitlements. Removing all private entitlements may prevent Freeform functionality; preserving them cannot recreate Apple authorization.
4. Launch the copy once with the probe requested and capture PID, stdout/stderr, constructor marker, and crash report. A failure before marker does not implicate swizzling. A marker alone establishes loading, not access to an active board.
5. Only after constructor success should a read-only method hook be considered. It must call the original implementation and only record the known disposable board operation.

No system-wide security setting changes are part of this experiment. A requirement for such changes is a stopping condition for the practical backend on this workstation.

## Reproduction commands used for inspection

```sh
file /System/Applications/Freeform.app/Contents/MacOS/Freeform
codesign -dvvv --entitlements :- /System/Applications/Freeform.app
xcrun otool -hv /System/Applications/Freeform.app/Contents/MacOS/Freeform
xcrun otool -l /System/Applications/Freeform.app/Contents/MacOS/Freeform
xcrun otool -L /System/Applications/Freeform.app/Contents/MacOS/Freeform
sw_vers
xcrun clang --version
man dyld
```

The two-slice encryption result was checked by parsing each fat architecture's full load-command table, rather than assuming otool's default architecture represented both.

## Normal-startup storage isolation

The executable contains literal `group.com.apple.freeform` and selector `containerURLForSecurityApplicationGroupIdentifier:`. Therefore changing CFBundleIdentifier does not prove separation from the normal Freeform data store. Empty entitlements may cause that API to return nil instead of giving the copy a usable alternate store.

The current sandbox denies reads anywhere under `/Users` except the research directory, denies writes except logs and /dev/null, denies networking, and explicitly denies cloud/account/keychain Mach services. Those are useful direct-access boundaries. Because it otherwise allows Mach lookups, they are **not** proof of isolation from all user data exposed through XPC brokers; preferences, container manager, and account-related services may be separate paths. Denying network also does not guarantee that a contacted daemon cannot access its own network connection.

For normal launch, keep the real home and group data denied. A separate lab-only writable storage tree can hold scratch data when the app is made to select it. First observe requested app-group/storage URLs, then prove the effective paths refer only to the scratch tree. An environment-variable home change alone is insufficient because APIs can obtain the actual account home or group container independently. No production CloudKit/account entitlements should be restored merely to advance startup.

Safest incremental runtime proof: constructor and class enumeration (already done), then a read-only hook or isolated in-memory object method. Launching a complete board window is a separate integration milestone and may require test-specific storage adaptation.

## First normal-startup failure: CloudKit construction

Specific crash inspected: `Freeform-2026-10-09-122727.ips`, PID 59048, corresponding to `logs/startup1-crash-summary.json`. Main image UUID f65bad7d-30cd-3e6a-ba48-0c8c23c9c446 is the arm64e lab executable. Top two frames are in CloudKit (usedImages index 13), not Freeform or an app-group filesystem helper.

Offline LLDB analysis identifies main-image offset 14531944 as VM 0x100ddbd68. The preceding instruction at 0x100ddbd64 calls an Objective-C selector stub for `initWithContainerID:options:`. The receiver class import at 0x1018faaa0 binds to CKContainer. Earlier instructions allocate CKContainerID, passing the literal `com.apple.freeform` and a selected environment to `initWithContainerIdentifier:environment:`. Therefore the crash happens while constructing a CloudKit container during a Swift one-time global initialization, itself invoked while the app delegate is decoded from its main nib.

This is a materially stronger diagnosis than the initial app-group hypothesis. **Redirecting app-group storage alone cannot resolve this first crash.** Missing CloudKit entitlements and/or the intentionally denied CloudKit service are plausible causes; the specific CloudKit assertion was not recoverable from this crash report or stderr, so the exact entitlement/service check remains unproven.

Evidence saved in `logs/startup1-offline-disassembly.txt`. No live process was attached or launched for this analysis.

A safe next lab experiment should observe or replace the lab-only app's CloudKit initialization boundary with a deliberate offline test dependency; merely restoring production CloudKit entitlements or allowing cloud access would undermine isolation. Such a replacement needs handling of subsequent callers, not just returning nil to a nonoptional Swift global. There is no verified simple storage-redirection switch that makes the complete app function offline.

## Rebuilding the isolated copy

`prepare-lab.py` copies only from the fixed installed app path into `inprocess/lab`, refuses existing destinations, preserves file contents and relative bundle symlinks without copying source xattrs/flags, changes the display name and identifier, removes URL/activity registrations, and ad-hoc signs with empty entitlements and options=0. It does not launch anything or alter the original. `--help` and `--name FreeformLabDryRun.app --dry-run` plus Python syntax parsing passed. The copying/signing path was not rerun because the existing experimental copy is preserved.
