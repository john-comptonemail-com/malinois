# ADR 0024: Record original camera coverage failures without discarding evidence

- **Status:** accepted. Amended for 1.6 (65) (BACKLOG 108, CE-02): the revision counts each camera's
  evidence.
- **Date:** 2026-10-07

## Context

The Both-camera pipeline reported a failure only when neither lens returned evidence. A secondary
file-save failure was also unreported. Owners could therefore receive one capture without knowing
why the other was missing. A primary save failure with a surviving rear capture used the global
failure field, whose UI language could incorrectly imply that original rear footage was a retry.
The owner approved fixing these gaps and the shared clip-audio setting race before 1.4 ships.

## Decision

Keep every capture that reaches storage. An optional `Event.captureFailuresByCamera` dictionary
records original missing coverage using only `front`/`rear` keys and existing `CaptureFailureReason`
values. It includes unavailable rear coverage during front-only fallback. Record storage results
for both slots before deciding whether the whole capture failed. `captureFailure` and its existing
interruption retry policy apply only when no original media was saved. Retry also requires both
slots still empty when it begins.

Per-camera history is not cleared by retries, downloads or subsequent coalesced trips. Event detail
shows it in front/rear order, separately from the whole-capture retry explanation. Only an interruption
reason can describe saved evidence as a recovery photo; legacy storage failures use neutral wording.
Storage notices use the existing active-session reporting path, so interruption recovery cannot erase
a later storage warning and a save finishing after disarm does not put a warning on Home. The optional field
is stored locally and inside the existing encrypted metadata JSON; no CloudKit schema field or new
record type is required. Cloud decoding permits only the two keys and known reason values.

The shared clip-audio preference uses a dedicated lock for every read/write. The engine needs an
immediate read for microphone coordination, while session configuration reads it on the camera queue.
The lock is held only while copying the Boolean, never across capture work or an asynchronous wait.

## Consequences

Old saved events decode without the new field, and old receiving apps ignore it. Existing cloud
revision rules are unchanged: this field does not pretend failure metadata is successful evidence.
The known equal-revision mirror-enrichment gap remains, particularly for all-failed or already
owner-attributed records; that separate fix is planned after 1.4. Captures already missing their
explanation cannot be retroactively diagnosed.

Amended for 1.6 (65): the revision rule now counts each camera slot's evidence on its own
(`CloudExfiltrator.metaRevision`: one camera 2, both 3, an owner attribution one more). It
counted any evidence once, so a device holding the copy with the front camera refused the copy
that added the rear, an equal revision, and the rear often arrives later as late evidence. The
second slot counts by its file or its camera's name, which survives the media byte cap's
eviction, so eviction cannot lower a revision already sent. The failure-metadata gap above is
unchanged.

There is no automatic retry of just one missing lens. Successful evidence remains usable and the
owner sees what the original attempt could not obtain. A disarm during capture remains an intentional
end, not a reason to raise a camera-fault notice. This decision extends capture reporting without
superseding the existing capture, evidence-ordering or retry rules.
