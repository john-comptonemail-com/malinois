# Malinois decision records

These are the project's architecture decision records: one file per decision, written when the decision was
made and amended in place when it changed, as the source cites them ("ADR 0039"). A record that was later
superseded, suspended or rejected stays here with its status, because the code and later records refer to it.
The records cite a private findings ledger by item number; those entries are not published, and
the numbers are kept so the records read as written. Taken from the private repository at commit 6c484fa;
published with each release from 1.8 on, as the source is.

◆ marks the records the security model rests on: the record comes before any response (ADR 0005), only the size limits remove records (ADR 0035), a sealed or surviving PIN is never taken for none (ADR 0040) and the covert response goes loud only on evidence of interference (ADR 0001). The PIN's rate limit, which fails closed, has no record of its own: SECURITY.md's PIN reference states it.

| Record | Status |
|---|---|
| [ADR 0001: Go loud only on evidence of interference](0001-escalate-only-on-interference.md) ◆ | accepted |
| [ADR 0002: Full-media retrieval by deterministic record ID](0002-full-media-retrieval-by-record-id.md) | superseded or suspended |
| [ADR 0003: Per-event upload serialization and single capture ownership](0003-upload-chain-and-capture-ownership.md) | accepted |
| [ADR 0004: A record is synced only on its own reported confirmation](0004-per-record-save-confirmation.md) | accepted |
| [ADR 0005: A write-ahead journal makes detection durable before response](0005-write-ahead-journal.md) ◆ | accepted |
| [ADR 0006: Store writes preserve monotonic fields; mirrors are copies, not custody](0006-monotonic-store-writes.md) | accepted |
| [ADR 0007: Hardware-key disarm rides CryptoTokenKit PIV, not FIDO2](0007-hardware-key-piv-over-fido2.md) | accepted |
| [ADR 0008: A capture that produces nothing says why, and gets one bounded retry](0008-capture-failure-honesty.md) | accepted |
| [ADR 0009: Early-Access — Pro is free and permanent for every install made while the program is open](0009-early-access-pro-free-and-permanent.md) | accepted |
| [ADR 0010: The first arm on a fresh install auto-lifts the Guided Access requirement](0010-first-arm-guided-access-auto-lift.md) | accepted |
| [ADR 0011: Permissions are asked on first use, and clip audio is off by default](0011-permissions-on-first-use.md) | accepted |
| [ADR 0012: The camera captures from the front unless the Vision tripwire is on](0012-front-unless-vision.md) | accepted |
| [ADR 0013: The Apple Watch companion is a second target in the Malinois project](0013-watch-companion-same-project.md) | accepted |
| [ADR 0014: A wrong disarm PIN is a record; the right one is not](0014-wrong-disarm-pins-are-records.md) | accepted |
| [ADR 0015: The Touch tripwire is always on](0015-touch-always-on.md) | accepted |
| [ADR 0016: A launch-time "locked" answer only waits, until the unlock or the app becoming active](0016-launch-lock-checks-end-when-active.md) | accepted |
| [ADR 0017: Cross-device alerts are worded on the receiving iPhone](0017-alerts-worded-on-the-receiving-iphone.md) | superseded or suspended |
| [ADR 0018: Home's Event Log count is what is new since the owner last looked](0018-home-counts-what-is-new.md) | accepted |
| [ADR 0019: A change to the protection settings leaves a record](0019-protection-settings-changes-are-recorded.md) | accepted |
| [ADR 0020: The heartbeat: a beat every five minutes, a trail and a latest record](0020-the-heartbeat.md) | accepted |
| [ADR 0021: Disarmed under Guided Access, the screen stays on for ten minutes](0021-guided-access-screen-hold.md) | accepted |
| [ADR 0022: Old heartbeat trails follow the retention setting; each watch keeps its latest beat](0022-old-beat-trails-follow-retention.md) | accepted |
| [ADR 0023: Swift 6 language mode](0023-swift-6-language-mode.md) — Every target builds in Swift 6 mode with no warning, and the changes keep the app's behavior. | accepted |
| [ADR 0024: Record original camera coverage failures without discarding evidence](0024-partial-camera-capture-reporting.md) | accepted |
| [ADR 0025: Preserve the shared audio session when Sound pauses for a clip](0025-audio-handoff-preserves-capture-session.md) | accepted |
| [ADR 0035: Separate incident and status retention budgets](0035-separate-incident-and-status-retention.md) ◆ | accepted |
| [ADR 0036: Retention uses a conservative cloud time observation](0036-retention-uses-cloud-system-time.md) | accepted |
| [ADR 0037: Recover interrupted first-hand media attachments](0037-recoverable-media-attachments.md) | accepted |
| [ADR 0038: Bound the camera caller and preserve each movie's actual outcome](0038-camera-attempt-deadlines-and-clip-outcomes.md) | accepted |
| [ADR 0039: Device-owner verification before cloud enrollment](0039-installation-cloud-enrollment.md) | accepted |
| [ADR 0040: Preserve a surviving PIN across reinstall](0040-pin-continuity-after-reinstall.md) ◆ | accepted |
| [ADR 0041: The PIN pad submits at the PIN's confirmed length](0041-pin-pad-submits-at-the-confirmed-length.md) | accepted |
| [ADR 0042: The Apple Watch app receives alerts and reads no records](0042-apple-watch-alerts-without-record-reads.md) | accepted |
| [ADR 0043: The armed iPhone relays its own alerts to its paired watch](0043-iphone-relays-its-own-alerts-to-its-watch.md) | accepted |
| [ADR 0044: The tamper warning shows how to disarm until the owner's first disarm](0044-tamper-warning-shows-the-hold-until-the-first-disarm.md) | accepted |
| [ADR 0045: Tamper alerts are Time Sensitive again, on the iPhone and the watch](0045-tamper-alerts-time-sensitive-again.md) | accepted |
| [ADR 0046: A late iCloud alert names its event's time](0046-late-icloud-alerts-name-the-events-time.md) | rejected |
| [ADR 0047: An "iCloud backup" switch that needs device authentication to turn off](0047-an-icloud-backup-switch.md) | accepted |
| [ADR 0048: A set-aside event log and its media are kept](0048-a-set-aside-event-log-is-kept.md) | accepted |
| [ADR 0049: A settings reset keeps the owner's iCloud choices, or turns backup off](0049-a-settings-reset-keeps-or-closes-icloud-backup.md) | accepted |
| [ADR 0050: A one-time screen before the first arm explains disarming and ending Guided Access](0050-a-one-time-screen-before-the-first-arm.md) | accepted |
| [ADR 0051: The watch sums up old relayed alerts, and every relayed alert names its event's time](0051-the-watch-sums-up-old-relayed-alerts-and-names-every-alerts-time.md) | accepted |
| [ADR 0052: The watch pairs iCloud's copy of its iPhone's alert with the relay's](0052-the-watch-pairs-icloud-and-relayed-copies-of-an-alert.md) | accepted |
| [ADR 0053: The countdown warns when the siren would play away from the iPhone](0053-the-countdown-warns-when-the-siren-would-play-elsewhere.md) | superseded or suspended |
| [ADR 0054: The ARM tap asks for the PIN when it has not been entered correctly for 14 days](0054-the-arm-tap-asks-for-the-pin-after-14-days-without-one.md) | accepted |
| [ADR 0055: Settings that cannot be read yet are not the owner's choices](0055-settings-read-before-the-first-unlock-wait-for-it.md) | accepted |
| [ADR 0056: Face ID or Touch ID unlock is bound to the faces or fingers enrolled when it is turned on](0056-face-id-unlock-is-bound-to-the-enrolled-biometrics.md) | accepted |
| [ADR 0057: The log records a PIN change and Guided Access ending during a watch](0057-the-log-records-a-pin-change-and-guided-access-ending-during-a-watch.md) | accepted |
| [ADR 0058: Apple's rating request after the third calm disarm](0058-apples-rating-request-after-the-third-calm-disarm.md) | accepted |
| [ADR 0059: A clip's thumbnail chosen by what changed](0059-a-clips-thumbnail-chosen-by-what-changed.md) | accepted |
| [ADR 0060: A warning the PIN pad holds back is postponed, not dropped](0060-a-warning-the-pin-pad-holds-back-is-postponed-not-dropped.md) | accepted |
| [ADR 0061: A burst of tamper alerts arrives quietly after its first three](0061-a-burst-of-tamper-alerts-arrives-quietly-after-its-first-three.md) | accepted |
| [ADR 0062: In Siren mode the siren plays from this iPhone's speaker](0062-in-siren-mode-the-siren-plays-from-this-iphones-speaker.md) | accepted |
| [ADR 0063: 1.9 hardening and engine components, in separately verified stages](0063-hardening-and-engine-components-in-separately-verified-stages.md) — 1.9's cloud and recovery fixes, then the engine's split into a cloud coordinator, a trip responder and an arming flow, each stage tested, reviewed and verified before the next, with no change in behavior. | accepted |
| [ADR 0064: A covered proximity sensor may blank the screen while recording: kept, and said](0064-a-covered-proximity-sensor-may-blank-the-screen-while-recording.md) | accepted |
| [ADR 0065: Evidence signing's format and its shared core](0065-evidence-signings-format-and-its-shared-core.md) — The fixed form the phone signs, its statements and the verifier's rules live in one folder of shared code, `MalinoisEvidence/`, which the app and the Mac verifier both build from. | accepted |
| [ADR 0066: Evidence signing's signer](0066-evidence-signings-signer.md) — One Secure Enclave key per install, which Apple certifies at launch, signs each of this phone's records at each change once its write is on disk, the signatures kept in a file of their own beside the log. | accepted |
| [ADR 0067: Evidence signing's export bundle](0067-evidence-signings-export-bundle.md) — Sharing a signed record adds a ZIP of the record with its signatures, its keys' certifications and its attachments, closed by an export statement the phone signs last. | accepted |
| [ADR 0068: The Mac verifier](0068-the-mac-verifier.md) — A command-line verifier, built on a Mac from the public source, checks a bundle against Apple's certificates and Malinois's App ID and prints what it checked. | accepted |
| [ADR 0069: Evidence signing: records that leave the log](0069-evidence-signings-records-that-leave-the-log.md) — A signed record that leaves the log is named in a signed statement, retention for what the size limit removed and absence for any other way, so a vanished record shows in every later bundle. | accepted |
| [ADR 0070: Evidence signing's export bundle, its check and the Mac verifier, as they stand](0070-evidence-signings-export-bundle-check-and-verifier.md) — The bundle's layout, the check that accounts for every counter of every key, and the verifier's report, as ADRs 0067 and 0068 and their amendments built them. | accepted |
| [ADR 0071: Evidence signing: the keys this install certified, kept where an edited backup cannot change them](0071-evidence-signings-keys-kept-in-the-keychain.md) | accepted |
| [ADR 0072: The one-time screen before an arm, and its four parts](0072-the-one-time-screen-before-an-arm-and-its-four-parts.md) | accepted |
| [ADR 0073: Evidence signing: signatures made and not kept](0073-evidence-signing-signatures-made-and-not-kept.md) — A signature App Attest made and the file did not keep is named in a signed unkept statement, which a verifier counts as accounted for and reports as information. | accepted |
| [ADR 0074: Full-media retrieval by record name, checked against what the phone signed](0074-full-media-retrieval-checked-against-what-the-phone-signed.md) | accepted |
| [ADR 0075: Uploads: the chain per event, the pending sweep and their deadlines](0075-uploads-the-chain-per-event-the-pending-sweep-and-their-deadlines.md) — Each event's iCloud writes go one at a time, in the order they were asked for; every iCloud wait has a deadline; and the pending sweep retries what is left, waiting as long as iCloud asks, up to two minutes. | accepted |
| [ADR 0076: Cloud enrollment: the verified account, its leases and each record's binding](0076-cloud-enrollment-the-verified-account-its-leases-and-each-records-binding.md) — An installation uses iCloud only after the owner verifies it with Face ID, Touch ID or the passcode; each record uploads only to the account it was bound to when it was made, and a restored record is held. | accepted |
| [ADR 0077: Evidence signing: a count that goes back](0077-evidence-signing-a-count-that-goes-back.md) — App Attest's count can go back after a forced restart. The phone throws away a signature on a counter its file already accounts for, so it keeps no counter twice, and a verifier reports two genuine signatures on one counter as information. | accepted |
| [ADR 0078: A set-aside event log is read, shared and deleted at the owner's word](0078-a-set-aside-event-log-is-read-shared-and-deleted-at-the-owners-word.md) — A set-aside event log is read record by record and listed at the top of the Event Log, on a screen of its own that shows what could be read, read only. Nothing read from it goes back into the log. Share sends the file as the phone kept it, with the photos and clips it names that are still on the phone. Only the owner deletes one, behind the Malinois PIN, with the photos and clips only it names, and the Delete leaves a status entry in the Event Log. Home says so while any is kept. | accepted |
| [ADR 0079: The watch gives a link wake back at its deadline, and one run of alerts shares the list's two seconds](0079-the-watchs-link-wakes-and-its-reads-of-the-list-as-they-stand.md) | accepted |
| [ADR 0080: Share says when it went without the signed ZIP, and waits a minute at most for it](0080-share-says-when-it-went-without-the-signed-zip-and-waits-a-minute-for-it.md) | accepted |
