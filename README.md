# Malinois

A covert unattended-device tamper detector for iPhone.

**[Download on the App Store](https://apps.apple.com/us/app/malinois-device-anti-tampering/id6797636246)**

Malinois' singular objective is to guarantee, to the greatest extent possible, that you either:

- **A.** Return to an unattended device in the same state you left it, or
- **B.** Know that unauthorized access was attempted (or succeeded)

Once armed, if the device is moved, tilted, unplugged, handled, touched, or approached, Malinois logs a tripwire event, captures a photo or clip, and writes it to a PIN-gated Event Log. Arms, disarms, and all tripwire events are logged with no immediate delete mechanism for an adversary, and all paths to escape Malinois leave a trace.

With Guided Access on and iOS set to ask before new wired accessories connect, there is no viable scenario (short of an already compromised device) where a tamper can occur without an indication: The nearest misses are documented in [SECURITY.md](SECURITY.md).

## Try it out

1. **First run** - set a 4–6 digit PIN and allow the camera/microphone prompts so capture works.
2. Tap **ARM**, then **Start countdown**.
3. Walk away. The countdown ends, sensors calibrate, and the screen goes black.
4. **To disarm:** press and hold the black screen for 5 seconds, then enter your PIN. Evidence is in the **Event Log**.

**Enable Guided Access before you trust an armed phone unattended.** You can skip it while getting a feel for the app, but it's what stops someone from simply closing Malinois. One-time setup: Settings → Accessibility → Guided Access. Triple-click the side button before arming to enable GA, and triple-click again after disarming to end it. Using a PIN instead of Face ID for Guided Access is recommended due to the open "Guided Access is not available" iOS bug.

## AI Disclosure

**I am a guy who wanted an app that didn't exist, and am in no way an iOS developer.** Malinois was developed in its entirety using AI tools; primarily Fable/Opus 5/4.8. Several rounds of adversarial reviews were performed with multiple passes from different models (5.6 Sol, Kimi K3, GLM 5.2, Deepseek V4 Pro/Flash, etc.) until a release-ready consensus was reached, and tested on a couple of my personal devices: that is the extent of my abilities. The majority of the documentation is also AI-generated. As with most docs these days, I find it frustrating to read at times, but I also feel it would be deceptive on my part to try and conceal it by rewriting, so I've reviewed it for obvious errors and largely left it as-is.

This is ultimately a personal project, but it's a project I think others might find a use for, and it would not have happened without AI. As such, please poke holes in the code, the assumptions and decisions I made, threat model thinking, anything and everything: I'm relying on it too. I don't have the budget for a bounty program, but would be happy to offer Pro license codes for not-stupid defects, improvements, or threat model gaps.

## Pro

A Pro in-app purchase is available, but **Pro is not required to meet Malinois' objective**: Detection, on-device capture, the local log, everything needed to fulfill that promise, is and will always be free. Pro features are "nice-to-haves" or extend the app functionality beyond the primary objective, and I believe the defaults are sufficient for the vast majority of use cases. Pro features include cloud backup/restore (evidence survives even if the phone is destroyed seconds later), cross-device alerts, Vision/Audio tripwires, more capture options, and helping me further enrich Anthropic investors. New installs include a 30-day trial of everything Pro does — no card, nothing to cancel.

> ⚠️ Use this only on **your own device**. It is a personal anti-tampering / anti-snoop tool, not a surveillance tool for other people.

## Roadmap

Solo project, no dates, and everything here is subject to change — or to being talked out of. If one of these matters to you (or something missing does), support@comptonemail.com reaches me.

**Planned**

- **Hardware-key disarm** — disarm with a YubiKey-class security key, NFC or USB-C. The crypto path is already proven on-device; this is the next major feature.
- **Honest capture-interruption records** — when iOS takes the camera or microphone away mid-capture (a call, another app, system pressure), the log should say exactly that, as an event, rather than fail silently.

**Exploring**

- **Apple Watch alerts** — the tamper alert as a tap on your wrist. (An iOS quirk makes this need a real watch app: an armed phone that is unlocked and in the foreground never mirrors its notifications to its own paired watch.)
- **Heartbeat records** — periodic proof-of-life while armed, so that if a device goes silent, the silence itself becomes evidence.

---

## What this repository is

This is the **source of each shipped release**, published so the app's privacy
and security claims can be checked against the code rather than taken on
trust. Each commit here corresponds to one App Store release. The app source
is byte-identical to what was submitted, with exactly one change: the developer
team ID is removed from the project file. (This README, the licence files, and
light adaptations to SECURITY.md — internal-tracker citations reworded, a
reporting section added — exist only in this mirror.)

It is a **mirror, not a project**: development happens elsewhere, issues and
pull requests are not monitored, and the two histories never merge. New code
appears here when — and only when — a release ships.

One honest limitation: iOS offers no reproducible builds, so this repository
cannot *prove* that the binary on the App Store was compiled from exactly this
tree. What it can do is let you read what the app is designed to do — every
claim in the privacy policy and in [SECURITY.md](SECURITY.md) is checkable
against this source.

## Where to look

- **[SECURITY.md](SECURITY.md)** — the threat model, every defense mechanism,
  and the things the app explicitly does *not* protect against, including how
  to report a vulnerability. If you read one file, read this one.
- **`Malinois/`** — the app. No third-party dependencies, by design: what you
  see is everything that runs.
- **`MalinoisTests/`** — the unit tests. Most security rules in SECURITY.md
  are pinned by a test here.

Building requires Xcode and your own signing settings; the project file ships
with no development team set.

## License

GPL-3.0-or-later — see [LICENSE](LICENSE), with an App Store additional
permission and a name/artwork reservation in
[LICENSE-EXCEPTION.md](LICENSE-EXCEPTION.md).
