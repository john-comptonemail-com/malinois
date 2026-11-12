# Reviews

From 1.12, each release's full reviews are published here: the reports other AI models wrote, as they wrote them, and
a page for each release saying what was done about each finding.

**How a full review works.** Before a release is archived, a clean copy of its code and documents goes to reviewers
from several AI vendors: the app's source and tests, the public documents, the decision records and the release tools.
It has no development notes and no earlier reviews, and its prompt names only the work still planned for the release,
so each review starts fresh. Each reviewer gets one of three prompts: a structured one with a checklist; an open one
that sets out the threat model and leaves where to look to the reviewer; or a short message that asks only to work out
what Malinois guarantees and show how those guarantees fail. Every finding is then checked against the code. A
confirmed finding is fixed with a test that fails before the fix and passes after it, and the fixes are reviewed again
before the build is tested on devices.

**What is here.** The reports are as the reviewers wrote them, with only details of the Mac they ran on taken out: its
file paths, its time zone and its simulators' IDs. They are not corrected: a finding the check did not confirm is still
in its report, and the release's page says why nothing was done about it. A finding still open that someone could use
against a phone is left out of its report until its fix ships, and the release's page says where one was left out.

- [1.12](1.12/README.md): four full reviews, eleven reports.
