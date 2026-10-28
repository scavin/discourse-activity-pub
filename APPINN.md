# Appinn maintenance notes

This fork keeps the original plugin identity and database schema. It carries two targeted fixes on top of upstream commit `d89d1b0131bbce4dc4102b1409f797be39b41961`.

## Fixes

- Serialize stored `Service` actors using the existing actor serializer. Preserve their ActivityStreams type and ID, including when they appear in followers or accepted Follow activities in an outbox.
- Give foreground remote GET reads a five-second network budget shared across a JSON-LD redirect chain. Bound connection and DNS/security resolution waits to at most two seconds each, within that remaining budget. Background GETs and all POST deliveries retain their original timeouts.

The original destination validation, SSRF filtering, request signing, Host header, and TLS hostname checks remain in use. This is not a limit on total page execution time, JSON-LD parsing, or a page that performs several separate remote reads.

## Installation

In a standard Discourse installation, replace the official ActivityPub clone entry with:

```yaml
- git clone https://github.com/scavin/discourse-activity-pub.git
```

Install one copy only, under the original `discourse-activity-pub` directory. Preserve the existing site domain, database, plugin identity, actor IDs, and signing keys. No new database migration is added by these fixes.

If migrating from the standalone temporary patch tool, roll it back with the matching tool version before changing the source repository. Then rebuild from this fork. Future rebuilds obtain the fixes as regular Git commits; do not run the standalone patch tool over this fork.

## Validation

The focused suite includes the existing Request, OutboxesController, and FollowersController specs plus Service actor regressions and a real stalled local HTTP peer. On 2026-10-28, all 27 examples passed with Discourse core source `7f1302a2974a046b1ec29a16880ee7f84917e267` and Ruby 3.4.6. A separate read-only process also checked serialization, destination safety, foreground timeouts, and unchanged background timeouts with Ruby 4.0.9.

Run from a Discourse checkout with this plugin installed, using an isolated test database and Redis:

```sh
LOAD_PLUGINS=1 bin/rspec \
  plugins/discourse-activity-pub/spec/lib/discourse_activity_pub/request_spec.rb \
  plugins/discourse-activity-pub/spec/requests/discourse_activity_pub/ap/outboxes_controller_spec.rb \
  plugins/discourse-activity-pub/spec/requests/discourse_activity_pub/ap/followers_controller_spec.rb \
  plugins/discourse-activity-pub/spec/requests/discourse_activity_pub/ap/service_actor_regression_spec.rb \
  plugins/discourse-activity-pub/spec/lib/discourse_activity_pub/foreground_network_budget_spec.rb
```

Focused regressions do not establish full federation interoperability or capacity under production load. Validate those separately when changing related behavior.

## Upstream updates

- Keep fixes committed on this fork's `main`; do not modify installed container files manually.
- Fetch and review official upstream updates, merge them into this fork in development, and resolve conflicts there.
- Run relevant tests before deploying the resulting revision. Do not automatically deploy upstream synchronization.
- When upstream provides equivalent fixes, remove the duplicate changes and rerun the tests. Continuing with this fork or switching the clone URL back to the official repository are both possible; preserve plugin identity and existing data in either case.
- Core upgrades still require compatibility testing. The existing upstream compatibility file and CI workflow are retained.
