# Read-only Freeform App Intent fixture

`freeform-read-board-id.shortcut` is signed for import into Shortcuts. It has not been imported or executed by the fixture generator.

The sole action is `is.workflow.actions.appintentexecution`, using bundle `com.apple.freeform`, exact App Intent metadata identifier `CRLUtilitiesIntent`, operation `boardID`, and an empty `arguments` array. The advertised return type is String. Whether an empty arguments array is sufficient, and whether this hidden action is externally executable, remain runtime questions.

The logical scoped identifier is com.apple.freeform / CRLUtilitiesIntent; the descriptor must use the short type name, not concatenate the bundle identifier into AppIntentIdentifier.

`freeform-read-board-id.unsigned.shortcut` contains the inspectable binary plist. The action UUID is uppercase and the workflow name is `Freeform Read Board ID Probe`.

Signing command:

```sh
shortcuts sign --mode anyone --input freeform-read-board-id.unsigned.shortcut --output freeform-read-board-id.shortcut
```

The sandboxed command reported an invalid format for both XML and binary input; the identical binary input signed successfully when the normal Shortcuts signing service was accessible. Signing confirms fixture packaging, not runtime availability of the hidden action.
