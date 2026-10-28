# Appinn maintenance notes

This fork keeps the original plugin identity and database schema. It carries targeted fixes on top of upstream commit `d89d1b0131bbce4dc4102b1409f797be39b41961`.

## Fixes

- Serialize stored `Service` actors using the existing actor serializer. Preserve their ActivityStreams type and ID, including when they appear in followers or accepted Follow activities in an outbox.
- Give foreground remote GET reads a five-second network budget shared across a JSON-LD redirect chain. Bound connection and DNS/security resolution waits to at most two seconds each, within that remaining budget. GETs made during background inbox signature verification share a ten-second budget, including separate actor/Webfinger lookups and key refreshes. Other background GETs and all POST deliveries retain their original timeouts.

The original destination validation, SSRF filtering, request signing, Host header, and TLS hostname checks remain in use. The foreground fallback is not a limit on total page execution time, JSON-LD parsing, or several separate remote reads. The default inbox path below avoids foreground remote reads entirely.

## Inbox timeout fix

`activity_pub_async_inbox_verification` defaults to `true`. Actor and shared inboxes validate the body digest, signature format/algorithm, required signed headers and receipt-time freshness before queueing a minimal canonical signature context with the activity JSON. They do not resolve remote signing actors in the web worker. HTTP 202 acknowledges receipt for verification; it does not mean the signature was accepted.

The low-priority `VerifyInbox` job uses the same RSA verification, origin restrictions, key ID/actor/public-key ownership checks, and SSRF filtering as synchronous verification. Only a valid signature dispatches `Process` with a signed actor ID. A failed cached key is refreshed with ownership checks and a fresh key object, so legitimate key rotation works. Invalid signed deliveries are rejected even when unsigned delivery is explicitly enabled. Truly unsigned deliveries retain that site's existing unsigned policy.

- Each inbox body is limited to 512 KiB (413 above that limit). Canonical signature fields are limited to 16 KiB each.
- At most 200 deliveries await verification per site. A full queue returns 503 with `Retry-After: 60`, rather than accepting and discarding the message.
- Identical payload, route and signature contexts share a reservation. A forged signature cannot reserve the identity of a differently signed delivery. Completed deliveries are deduplicated for ten minutes.
- Remote GETs during verification share ten seconds; connection and DNS waits remain within that budget. Transient network/408/429/5xx failures raise for up to five Sidekiq retries. Exhausted retries release the reservation and log a warning; abandoned reservations/jobs expire after 24 hours.
- Confirmed HTTP 410 responses with bodies no larger than 16 KiB are cached for ten minutes. Allowed-410 callers retain the response; other callers still receive failure. A 410 alone never deletes an actor or bypasses signature verification. Other responses are not negative-cached.

Setting `activity_pub_async_inbox_verification` to `false` restores synchronous inbox verification using the existing foreground timeout fallback. Both old and new verification code must remain available while queued jobs drain. Keep the standard `low` Sidekiq queue running; accepted deliveries depend on the background worker. Signature freshness is checked at receipt, so normal queue delay does not invalidate a valid delivery.

These limits reduce the identified worker-blocking problem; they do not guarantee capacity against arbitrary traffic or prevent unrelated worker timeouts. Monitor the low queue, retry/dead jobs and delivery logs after rollout. The patch does not add migrations or change federation IDs, keys, follows or historical content.

## Installation

In a standard Discourse installation, replace the official ActivityPub clone entry with:

```yaml
- git clone https://github.com/scavin/discourse-activity-pub.git
```

Install one copy only, under the original `discourse-activity-pub` directory. Preserve the existing site domain, database, plugin identity, actor IDs, and signing keys. No new database migration is added by these fixes.

If migrating from the standalone temporary patch tool, roll it back with the matching tool version before changing the source repository. Then rebuild from this fork. Future rebuilds obtain the fixes as regular Git commits; do not run the standalone patch tool over this fork.

## Validation

On 2026-10-28, the final focused native suite passed **122 examples, zero failures** on Discourse core source `7f1302a2974a046b1ec29a16880ee7f84917e267` and Ruby 3.4.6. It covers all ActivityPub API controller specs, Webfinger handle validation, legacy signatures, async signature/ownership/rotation failures, shared inboxes, queue capacity/deduplication/expiry, and real stalled foreground/background HTTP peers.

A broader candidate run executed 1,281 examples with 23 failures. Two empty mocked-response failures were corrected and the Request specs passed in the final suite. The other 21 failing examples also failed on unchanged fork baseline `e6bc4ba`: 19 browser examples lack usable browser-test infrastructure (baseline has no Playwright binary), and two multisite examples lack plugin tables in the second test database. This is not a claim that the entire plugin/system suite passes.

Run from a Discourse checkout with this plugin installed, using an isolated test database and Redis:

```sh
LOAD_PLUGINS=1 bin/rspec \
  plugins/discourse-activity-pub/spec/requests/discourse_activity_pub/ap \
  plugins/discourse-activity-pub/spec/requests/discourse_activity_pub/webfinger \
  plugins/discourse-activity-pub/spec/lib/discourse_activity_pub/request_spec.rb \
  plugins/discourse-activity-pub/spec/lib/discourse_activity_pub/foreground_network_budget_spec.rb \
  plugins/discourse-activity-pub/spec/lib/discourse_activity_pub/background_network_budget_spec.rb \
  plugins/discourse-activity-pub/spec/lib/discourse_activity_pub/network_budget_spec.rb \
  plugins/discourse-activity-pub/spec/lib/discourse_activity_pub/inbox_queue_spec.rb
```

Ruby formatting and RuboCop checks pass. The standard `bin/lint --fix` bootstrap could not finish installing its requested Bundler/frontend dependencies in this lab, so equivalent Ruby tools were run directly against all changed Ruby files. No frontend code was changed. Focused regressions do not establish full federation interoperability or production capacity; validate those separately during rollout.

## Upstream updates

- Keep fixes committed on this fork's `main`; do not modify installed container files manually.
- Fetch and review official upstream updates, merge them into this fork in development, and resolve conflicts there.
- Run relevant tests before deploying the resulting revision. Do not automatically deploy upstream synchronization.
- Before removing the async verifier or switching back to official upstream, stop new async admissions with the setting and drain its queued/retry jobs while this job class is still installed. Retain the verifier until those jobs finish; removing its class early can strand accepted deliveries.
- When upstream provides equivalent fixes, remove the duplicate changes and rerun the tests. Continuing with this fork or switching the clone URL back to the official repository are both possible; preserve plugin identity and existing data in either case.
- Core upgrades still require compatibility testing. The existing upstream compatibility file and CI workflow are retained.
