# Soniox data-processing basis

_The ground truth behind the README's privacy section. Confirmed against
Soniox's own public terms and API docs on 2026-07-20; their Terms of Service
and Privacy Policy both show "Last updated: June 29, 2026". Short quotes below
are attributed to the page that owns them. Everything here describes the
self-serve terms that govern an ordinary API key — Tamlil users bring their own
Soniox account, so this is what applies unless you have negotiated something
separate with Soniox._

## Bottom line

The pipeline uploads raw meeting audio (containing named third parties) to
Soniox's async speech-to-text API using your self-serve API key against the
default endpoint `api.soniox.com`. Under that self-serve arrangement:

- **Training / secondary use — good.** Soniox commits, by default and with no
  opt-in, that it never trains on customer audio or transcripts. This lives in
  the binding Terms of Service, not just a marketing FAQ.
- **Retention — read carefully.** "Zero retention" is the default only for
  real-time streaming. The **async API Tamlil uses is Soniox's storage
  service**: the uploaded audio and the resulting transcript are stored
  server-side with **no automatic deletion** — retention is the caller's
  responsibility.
- **Tamlil's deletion.** The pipeline deletes the stored transcription after
  each run (which also removes the uploaded audio file), so neither the audio
  nor the transcript text persists on Soniox under normal operation. See
  "Client-side deletion" below.
- **Contract basis — self-serve only.** An API-key user is bound by
  click-through Terms of Service plus Privacy Policy. A DPA is available
  self-serve through the Soniox Console but is **not** auto-incorporated by the
  Terms; unless you accepted it in the Console, no DPA is in force for your
  account. A HIPAA BAA requires additional written terms.

## Legal basis and contract structure

A self-serve API-key user is bound by Soniox's Terms of Service and Privacy
Policy. Use of an API key is itself acceptance: per the Terms, "By creating an
account, accessing Soniox Console, using an API key, using the Services, or
otherwise indicating acceptance, you agree to these Terms."

A DPA is **not** folded into those Terms. The Terms only give precedence to a
separate agreement if one exists: "If you have a separate written agreement with
Soniox, such as a master services agreement, order form, data processing
agreement, business associate agreement, or enterprise agreement, that agreement
controls to the extent it conflicts with these Terms." A self-serve DPA can be
obtained through the Console's Security & Compliance section, but obtaining and
accepting it is a deliberate step; it is not automatic.

Practically: unless you have signed into the Soniox Console and accepted the
self-serve DPA for your account, the legal basis is the click-through Terms of
Service plus Privacy Policy only — no negotiated DPA, no BAA. Regulated data is
further gated: "Use involving protected health information, sensitive personal
information, biometric information, children's information, or similarly
regulated data may require additional written terms with Soniox before such use
is permitted" (Terms of Service).

## Training and secondary use — confirmed

Soniox does not train on customer content, stated verbatim and identically in
both the Terms of Service and Privacy Policy: "Soniox does not use Customer
Content to train, fine-tune, evaluate, benchmark, or improve Soniox models or
services." The security docs restate it: "your audio and transcripts are never
used to improve Soniox models or services." Soniox also states it does not sell
customer content. This is a blanket default; no opt-out toggle is needed, and it
holds under the self-serve terms.

## Server-side retention

The no-storage default has an explicit exception, and it is exactly the service
Tamlil uses. From the security-and-privacy docs: "Soniox does not store your
audio or transcript data unless explicitly requested through a service that
supports storage, i.e. async API." The Terms phrase it the same way: "Soniox
does not store Customer Content processed by the Services unless storage is
explicitly requested or configured by you, required to provide a requested
product feature, or otherwise agreed in writing."

Because the pipeline uses the async API, both the uploaded audio and the
resulting transcript are stored server-side, and Soniox does **not** delete them
for you. The async limits-and-quotas docs are explicit: "You must manually
delete files after obtaining transcription results. Files are not deleted
automatically." The stated limits are capacity-based, not time-based (10 GB of
files, 1,000 files, 300 minutes per file) — there is no default retention window
that eventually purges stored data.

Soniox separately retains content-free operational metadata (usage, technical
metadata, security logs) for billing, security, and compliance; per the Privacy
Policy those logs are stated to contain no customer content.

### Client-side deletion — reconciled

The uploaded audio file and the transcription result are two separate objects
with separate deletion endpoints:

- `DELETE /v1/files/{file_id}` — "Permanently deletes specified file." Its docs
  do not mention the transcription, i.e. it removes only the audio.
- `DELETE /v1/transcriptions/{transcription_id}` — "Permanently deletes a
  transcription and its associated files." Deleting the transcription also
  removes the file; deleting the file does not remove the transcription.

The pipeline (`src/tamlil/transcribe_soniox.py`) creates a transcription
(POST `/transcriptions`), fetches the transcript, then in its cleanup calls
`DELETE /transcriptions/{id}` — which per Soniox also removes the associated
file. So after a normal run **both the uploaded audio and the stored
transcription are removed** from Soniox; nothing persists on their servers.
(If a run fails before the transcription is created, only the uploaded file
exists, and that file is deleted instead.) `tamlil-transcribe --keep-remote`
skips this cleanup. Deletion is best-effort: a failed delete is logged but does
not fail the run.

The consequence for the README's wording: after each run neither the uploaded
audio nor the transcript text is retained by Soniox under normal operation.

## Subprocessors

There is no public subprocessor list. The Privacy Policy names only generic
categories — "infrastructure providers, hosting providers, payment processors,
analytics providers, email providers, support tools, security tools, and
business operations providers" — and identifies no specific vendor (no named
cloud host). The actual list is behind the Console: "For compliance documents
such as DPA, subprocessors, certificates, and security reports, sign in to
Soniox Console and open the Security & Compliance." Neither the identities of
the subprocessors, nor whether the (Console-gated) DPA promises advance notice
of new subprocessors, can be verified from public sources.

## Data residency

Soniox offers three regions — US, EU, and Japan — each with its own endpoints,
selected at project creation: for a regional project "all audio and transcript
data for that project stays in that region, for both processing and storage."
Regional (non-US) access is not fully self-serve: "To get access to regional
deployments send your inquiry to support@soniox.com," and the EU region "is
enabled by request." The EU option is Soniox-operated ("Soniox Sovereign Cloud
runs the same model in-region"), not a customer VPC or on-prem deployment; no
customer-hosted/on-prem option was found.

Because the pipeline calls the default `api.soniox.com`, audio and transcripts
are processed and stored in the **US** unless you explicitly requested and
configured a regional project. Residency also does not cover system data: per
the Privacy Policy it "may not apply to system data such as account
information, ... usage statistics, billing data, security logs, ... which may be
processed outside the selected region."

## Compliance posture

Soniox publicly claims SOC 2 Type 2, ISO/IEC 27001:2022, GDPR, and HIPAA. The
certificates, security reports, DPA, and BAA themselves live inside the
authenticated Console ("All compliance documentation can be obtained through
Soniox Console Security & compliance section"); there is no public trust portal
(`trust.soniox.com` does not resolve). This write-up verified the framework
*claims* on Soniox's public pages but not the underlying certificates or
contract text, which are Console-gated.

## What could not be verified from primary sources

Each of these is behind Console authentication and should be confirmed before
relying on it:

- The identities of Soniox's subprocessors (including the underlying cloud host).
- Whether the self-serve DPA commits to advance notice of new subprocessors.
- The actual SOC 2 / ISO 27001 / HIPAA certificates and the DPA/BAA contract text.
- Whether your account has accepted the self-serve DPA in the Console (an
  account-state check, not a public fact).

## Recommended setup for your Soniox account

1. **Accept the self-serve DPA in the Console** so a data-processing agreement
   is actually in force — the audio you send contains named third parties.
2. **Consider the EU region and/or a BAA** if the recorded parties or data
   warrant it; regional access and PHI handling both require contacting Soniox.

## Sources

All fetched 2026-07-20; Terms of Service and Privacy Policy last updated
2026-06-29.

- Terms of Service — <https://soniox.com/policies/terms-of-service>
- Privacy Policy — <https://soniox.com/policies/privacy-policy>
- Policies index (compliance docs are Console-gated) — <https://soniox.com/policies>
- Security and privacy (data handling) — <https://soniox.com/docs/security-and-privacy>
- Data residency — <https://soniox.com/docs/data-residency>
- EU / Sovereign Cloud — <https://soniox.com/europe>
- Async limits and quotas (manual deletion) — <https://soniox.com/docs/stt/async/limits-and-quotas>
- Delete file endpoint — <https://soniox.com/docs/api-reference/stt/files/delete_file>
- Delete transcription endpoint — <https://soniox.com/docs/api-reference/stt/transcriptions/delete_transcription>
