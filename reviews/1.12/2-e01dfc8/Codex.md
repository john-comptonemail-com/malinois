# Malinois 1.12 (87): guarantee review

Reviewed by Codex, 11 November 2026.

## For the owner

**The clearest broken guarantee is that biometric access is only for viewing.** If you enable Face ID or Touch ID for the Event Log, that same access also lets someone delete an entire set-aside log and the photos and clips that only it references. They never need your Malinois PIN. These are logs the app preserved after it could not read them normally; they can contain your only remaining evidence. I verified the complete authorization and deletion path in the source. I did not run this interaction on a device or simulator.

**Two sharing problems remain suspected.** First, a particular signing-storage failure can make Share wait for a signature before the share sheet—and its one-minute fallback—exists. If that signature stalls, even the ordinary photos and text cannot be shared through that action. Second, the code can omit the signed ZIP without displaying its promised warning when the system completes a share without the ZIP provider ever making a bundle. The missing guards are visible, but I have not reproduced the required runtime conditions. They are not presented as observed iOS failures.

I did not establish a way for an unauthenticated person to disarm a running watch, bypass its PIN, or make the evidence verifier falsely accept altered signed evidence.

## What the app promises, and what I counted

The snapshot's project settings identify the iPhone app as **1.12, build 87** (`Malinois.xcodeproj/project.pbxproj:1826–1836`). Its README, SECURITY document, public listing, UI and architecture decisions establish these practical commitments:

- With the stated setup, enabled tripwires attempt to record handling and capture evidence. Detection has explicit sensor, camera and operating-system limits.
- The Malinois PIN protects disarming and changes to protection. Optional biometrics grant access to the Event Log and Test Sensors as **read** surfaces.
- Local evidence is retained subject to documented limits. Set-aside logs preserve records the app could not read normally; their records and exclusive media are deleted only through the owner's confirmed action.
- Pro attempts account-bound cloud backup. Evidence survives loss of the phone only if upload actually succeeded; delivery before shutdown is expressly not guaranteed.
- Signed evidence can be exported and checked within the verifier's stated limits. A completed share of a signed event that omits its ZIP is supposed to say so. Bundle preparation after destination selection has a one-minute fallback.

I treated those qualifications as part of the contract. Documented limitations—such as force-restart ending the watch, unavailable cameras, cloud delivery delays, and the verifier's stated trust limits—are not findings here.

**Evidence labels:** VERIFIED means the supplied source establishes the entire relevant path and result without an unresolved platform-behavior assumption. SUSPECTED means a concrete source path exists but a runtime prerequisite or end-to-end result still needs reproduction. No runtime tests were executed in this review; existing tests below are cited as code, not as newly observed passing results.

## 1. VERIFIED — Biometric viewing also authorizes irreversible evidence deletion

**Impact:** A person who can satisfy the opted-in biometric gate, but does not know the Malinois PIN, can delete a preserved log and its exclusive local media. If no other copy exists, the evidence is lost. This is a destructive extension of viewing authority, not an unauthenticated bypass. It does not delete current-log records or cloud copies.

### The guarantee

`SECURITY.md:868–885` explicitly calls the Event Log and Test Sensors the two “READ surfaces” that may accept biometrics. It explains why a presented face must not authorize write operations. `Malinois/Views/HomeView.swift:65–74` states the same boundary in the implementation. `Malinois/Views/SetAsideLogView.swift:9` assumes that the Event Log, and therefore this screen, is behind the PIN.

The new delete action violates that assumption. ADR 0078 authorizes an owner to confirm deletion; it does not expressly expand biometric viewing into deletion authority.

### Exact reproduction path

Use a disposable installation, with a set-aside log containing a photo or clip that neither the current log nor another set-aside log references.

1. Enable biometric viewing in Settings. Keep the enrolled biometric unchanged.
2. Leave the app disarmed, with Guided Access off and no PIN lockout. These conditions permit the biometric offer.
3. Open **Event Log** using Face ID or Touch ID. Do not enter the Malinois PIN during this visit.
4. Open **Set-aside log** at the top of the Event Log.
5. Tap **Delete**, then confirm **Delete**.
6. The preserved log and its exclusive media are removed without a Malinois PIN challenge.

The set-aside log need not have been created by the person deleting it. The app creates one when `events.json` cannot decode (`EventStore.swift:2872–2874`). For a controlled fixture in a private copy, encode two otherwise valid events, give one an unknown `cloudSyncState` string, and give the other a valid UUID-named JPEG in the store's `Media` directory. Launch with no journal or other record referencing that JPEG. The whole log is set aside; its good record remains readable there. `Item122SetAsideLogTests.testARecordABuildCannotReadCostsThatRecordOnly` already describes that unknown-enum case.

### Complete code evidence

| Step | Source | What establishes it |
|---|---|---|
| Biometric entry permitted | `Malinois/Views/HomeView.swift:70–74` | `.log` returns `true` from `allowsBiometrics`. |
| Same navigation authority after biometric success | `HomeView.swift:162–165`, `255–260`; `Malinois/Views/PINViews.swift:607–615` | Successful biometric authentication invokes the success callback and opens the log; the destination carries no PIN-versus-biometric distinction. |
| Destructive screen reachable | `Malinois/Views/EventLogView.swift:107–114` | A navigation link opens `SetAsideLogView` directly. |
| Confirmation is the only further gate | `Malinois/Views/SetAsideLogView.swift:82–91`, `128–135` | Delete calls `eventStore.deleteSetAsideLog(log)` with no PIN request. |
| Actual evidence removal | `Malinois/Services/EventStore.swift:2921–2937`, `2981–2982`, `3013–3017` | The store checks the path, removes the log, and removes exclusively referenced media. It performs no authentication. |

The relevant implementation is direct:

```swift
// HomeView.Gate
case .log, .test: true       // allowsBiometrics

// SetAsideLogView.delete()
Task {
    _ = await eventStore.deleteSetAsideLog(log)
    deleting = false
    dismiss()
}
```

Existing test code confirms both halves separately: `MonitoringEngineTests.testSettingsGateNeverAllowsBiometrics` permits biometrics for the log; `Item122SetAsideLogTests.testDeleteRemovesTheLogAndAtOnceTheMediaOnlyItNames` (`416–444`) asserts that deletion removes both the log and its exclusive photo. `testItsScreenDeletesBehindTheConfirmation` (`469–475`) checks the confirmation and direct store call. None composes biometric entry with the destructive action and requires a PIN.

**Smallest repair:** Require the Malinois PIN at the set-aside Delete action, regardless of how the Event Log was opened. Add a focused regression that enters through the biometric viewing path and verifies that confirmation alone cannot delete anything.

## 2. SUSPECTED — Share can wait indefinitely before its timeout starts

**Potential impact:** Tapping Share can remain stuck before displaying any destinations. The user cannot send even the ordinary text and media through this action. The one-minute bundle fallback cannot help because the code has not created the bundle item yet.

### Exact prerequisite

This requires a **retained signing pass**: an earlier log-write notification could not read signing storage, so the signer kept that work for later. Storage then becomes readable, Share resumes the retained work, and an App Attest assertion requested by that work does not finish. A busy signer by itself does not establish this bug.

### Code path

```text
EventDetailView.openShare
  openingShare = true
  await EvidenceBundleItem.offer
    await signer.exportReadiness
      await passWhatWasKept
        await passQueued
          await pass
            await sign
              await keys.generateAssertion   <-- no deadline here
  sharing = ShareRequest(...)                <-- not reached while waiting
```

- `Malinois/Services/EvidenceSigner.swift:955–963`: a signature-file or key-list read failure prevents loading.
- `EvidenceSigner.swift:527–530`: the failed pass is stored in `passKept`.
- `EvidenceSigner.swift:498–500`, `368–372`, `353–363`: export readiness resumes that pass and waits for it.
- `EvidenceSigner.swift:587`, `624`, `660–667`: the pass can await `generateAssertion` without a deadline.
- `Malinois/Views/EvidenceBundleItem.swift:93–99`: the item is constructed only after readiness returns.
- `Malinois/Views/EventDetailView.swift:144–151`: the share sheet is presented only after the offer returns; further Share taps are rejected while `openingShare` is true.
- `EvidenceBundleItem.swift:156–166`, `184–195`: the 60-second limit exists inside the later item-making operation, which this path has not reached.

The source comment at `EvidenceBundleItem.swift:5–9` says the sheet opens at once and bundle creation waits for destination selection. This readiness path can perform signing first. More narrowly, `SECURITY.md:331–333` starts its minute **after** destination selection: this finding does not claim that that timer itself runs too long. It identifies an unbounded wait before the user can reach the bounded flow.

### Focused reproduction to run in a private simulator copy

The folder supplies the necessary fakes; no real Apple request is needed:

1. Use `TestKeyList` and `FakeKeyService` to certify a signer and sign event A.
2. Relaunch the signer over the same signature file, key list and key service.
3. Set `list.failNextReads(1)`. Change A's `ownerAttributed` value, then call the relaunched signer's `logWritten(generation: 1, events: [updatedA])`. The changed write is retained because the key-list read failed.
4. Call `await keys.holdNextAssertion()`.
5. Start `EvidenceBundleItem.offer(of: updatedA, log: [updatedA], exporter: exporterForRelaunchedSigner)` in a task. Wait until the fake reports that the assertion was requested.
6. Keep it held past 60 seconds and check that the offer has not returned and no share sheet can have been created.
7. Release it with `await keys.releaseHeldAssertion()`; check that the offer can now finish.

Support already exists in `MalinoisTests/EvidenceTestSupport.swift:437–447`. `Item90SignerTests.testAWriteAPassCouldNotCompareIsComparedWhenShareAsks` (`3287–3296`) covers readiness resuming retained work, without a stalled assertion. The missing composition is retained work plus the held assertion plus Share.

**Why SUSPECTED:** I traced the path but did not run this fault-injection reproduction or observe a real App Attest stall. ADR 0080 already acknowledges that an unfinished App Attest request can hold the signer; the distinct issue here is that retained work is awaited before the share sheet and its timeout exist.

**Smallest repair direction:** Bound the pre-sheet readiness operation, or return a temporary-not-ready offer while deferred signing proceeds separately. Preserve the signer's existing rules for assertions that complete late.

## 3. SUSPECTED — A missing ZIP can fall through the “sent without ZIP” warning

**Potential impact:** A user may finish sharing a signed event and receive no warning even though the recipient received only ordinary text/media, with no independently checkable evidence ZIP.

### Guarantee and exact conditional counterexample

`SECURITY.md:332–333` and ADR 0080 decision 1 promise a notice after a completed share of a signed event that went without the ZIP. The implementation treats an unknown making outcome as no reason to warn:

```swift
// EvidenceBundleItem.swift:216–223
case .ready: return made == false ? notMade : nil
```

For these exact inputs, `ShareNote.line` returns `nil`:

```swift
readiness: .ready
completed: true
destination: .airDrop
made: nil
mirrored: false
```

`MalinoisTests/Item200ShareNoteTests.swift:64` expressly expects no warning for `.ready, made:nil`, describing it as “not known to have failed.” That is weaker than confirming that the ZIP was included.

There is a corresponding no-ZIP state: `EvidenceBundleItem.activityViewController(_:itemForActivityType:)` (`118–120`) calls `keptBundle` (`138–143`), which returns nil before the provider operation makes anything. `madeForTheDestination` also remains nil until `madeBundle` runs (`62`, `105`, `166`). `EventDetailView.swift:100–105` passes that nil outcome into the completed-share warning calculation.

### Reproduction and the unresolved step

1. Create a ready `EvidenceBundleItem`, without running its item-making operation.
2. Ask its item-source callback for `.airDrop` or `.mail`. It returns nil. Existing `Item90ShareTests.testTheSheetsOwnAskMakesNoBundle` exercises these early callbacks.
3. Complete a file-capable share containing the ordinary sentence/media while the provider's outcome is still nil.
4. The warning calculation above returns nil, so the event screen displays no omission notice.

**Step 3 is not established on stock iOS.** The source proves the conditional result, not that UIKit normally completes this way. Apple permits an item-source callback to return nil when another registered item supplies a value. Apple's completion Boolean describes whether the activity was performed, rather than enumerating which attachments it consumed. These contracts leave the inference plausible but do not prove the provider scheduling needed for this reproduction. See Apple's [item-source return contract](https://developer.apple.com/documentation/uikit/uiactivityitemsource/activityviewcontroller%28_%3Aitemforactivitytype%3A%29) and [completion-handler contract](https://developer.apple.com/documentation/uikit/uiactivityviewcontroller/completionwithitemshandler-swift.typealias).

**Why SUSPECTED:** Neither the selected-destination callback order nor an actual completed share missing its ZIP was reproduced. A direct unit test of `ShareNote` alone would not establish normal UIKit reachability.

**Smallest repair direction:** For completed file-capable shares of an eligible signed event, distinguish a confirmed bundle from an unconfirmed outcome. If the app cannot establish inclusion, say that it could not confirm the ZIP was included rather than silently treating the unknown state as success.

## Review boundaries

All substantive evidence came from (the review folder) and the two Apple documentation pages cited above. I did not read excluded `_REVIEW_PROMPT`, `_REVIEW_REPORT` or `_REVIEW_NOTES` files, or use earlier review memory. Independent source-review passes covered protection controls, cloud/watch delivery and evidence signing/export; the deletion path and retained-pass sharing path were cross-checked independently.

I inspected a private copy, and checked all **449 copied files** against the supplied folder by SHA-256 before writing this report: they matched. I ran no Git commands, no builds, no app code and no tests, including no full test suite. I created or used no simulator. Nothing was sent or published. The only file added to the supplied folder is this report.

This is a source review with one established authorization failure and two explicitly unresolved runtime hypotheses. It is not a claim that every app guarantee or hardware behavior was exhaustively tested.
