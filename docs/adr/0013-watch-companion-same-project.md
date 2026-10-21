# ADR 0013: The Apple Watch companion is a second target in the Malinois project

- **Status:** accepted; decisions 4 and 5 amended by ADR 0042 (1.6: alerts only, version lockstep by test)
- **Date:** 2026-09-07

## Context

Item 57 (2026-09-01) found the wrist unreachable in the app's main scenario: the armed iPhone
sits unlocked and in the foreground under Guided Access, iOS mirrors notifications to a paired
watch only from a locked iPhone, and the CloudKit alert goes to the owner's other devices, whose
notifications do not mirror to a watch either. A watch-wearing single-iPhone owner gets no tap.
The alert push is already a visible notification with a title and a body
(`CloudExfiltrator.makeSubscription`), so a watch app that registers for its own remote
notifications and shares the CloudKit container receives it over the watch's own connection,
with the phone nowhere near.

On 2026-09-07 the owner started the work and ruled on the project structure ("go, approach 1")
from three options: (1) the existing Xcode project with a watch app target embedded in the
iPhone app and shared source by target membership; (2) the same, with the shared core moved into
a local Swift package now; (3) a separate project and App Store listing, an independent watch app
talking to the phone only through iCloud.

Constraints: the watch must never become a write path into the phone's session (owner ruling
2026-09-01, item 57: no disarm, v1 or v2; remote arm is physically impossible, since arming needs
the app in the foreground on an unlocked phone plus the Guided Access triple-click). Apple
requires an embedded watch app's version and build number to equal the containing app's. The
public mirror exports a fixed path list and strips the team ID from a known number of
project-file lines (item 46). The owner runs the test suite as one command.

## Decision

1. **One Xcode project.** The watch app is a target in `Malinois.xcodeproj`, embedded in the
   iPhone app, bundle identifier `com.johncompton.Malinois.watchkitapp`. It ships inside the
   iPhone binary: one archive, one upload, one listing, one review.
2. **Shared source by target membership, not a package.** A file the watch needs is a member of
   both targets. A Swift package is deferred until a third consumer exists (a widget, a Mac app);
   a separate project is rejected.
3. **A shared file compiles for both platforms.** An iPhone-only call in a shared file goes
   behind `#if os(iOS)` with an inert or equivalent watch body; the iOS body stays
   byte-identical. Nothing that imports WatchKit enters the iPhone target. The first instance is
   the cloud sender's background-task assertion.
4. **The watch receives and reads.** It carries no tamper engine, no sensors and no local tamper
   log (the phone's event store stays on the phone). It never writes a CloudKit record that
   changes a session: no disarm signal and no arm from the wrist. Pro-gated as filed in item 57
   (moot while Early Access runs, ADR 0009).
5. **Version and build number are one setting.** Both targets read `MARKETING_VERSION` and
   `CURRENT_PROJECT_VERSION` from one committed build-settings file, so the Build match commit
   stays one line and a mismatch cannot be uploaded. Done at the target-add step.
6. **The floor is watchOS 10**, the release paired with the app's iOS 17 floor.

## Consequences

- Milestone 1 is the alert on the wrist plus a status screen; the read-only event list follows
  through the cloud sender's read side (`fetchRecentEvents`), which is why that file was made
  watch-compilable first. In Bluetooth range the watch could also ride the phone's live
  connection (WatchConnectivity) for status; that is a later milestone's question.
- Pure logic the watch needs (rendering a push payload, deriving status) lives in shared files
  and is tested in the existing iPhone suite; a watch test target on a paired watch simulator is
  added only when the watch has logic of its own. The suite stays one command.
- The mirror export changes before the first mirror of a watch build: the team-ID line count
  (two today, four with the watch target) and the archive path list gain the watch folder; the
  mirror README's roadmap line ("Exploring — Apple Watch alerts") becomes a shipped line.
- App Store Connect requires Apple Watch screenshots from the first submission that carries the
  watch app; the store listing document gains that line. The watch app installs on paired watches
  automatically for users with automatic app installation on; What's New says so.
- Paths not taken: the package (deferred, not rejected: a public-API pass over every shared type
  and re-pointed tests, for no consumer yet); the separate project and listing (no direct phone
  link, a second review and version train, a drifting copy of the models); independence from the
  iOS app ("Supports Running Without iOS App Installation") is off in v1, since the watch has
  nothing to show without an armed phone or iPad on the account, and can be turned on later
  without a structure change.
- The hard prerequisite from item 57 stands: a physical Apple Watch on the personal iCloud,
  paired to the personal-iCloud iPhone; the watch simulator's pairing is too flaky to carry the
  verification alone.
