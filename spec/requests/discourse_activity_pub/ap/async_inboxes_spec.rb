# frozen_string_literal: true

RSpec.describe "ActivityPub asynchronous inbox verification" do
  let!(:keypair) { OpenSSL::PKey::RSA.new(2048) }
  let!(:person) do
    Fabricate(:discourse_activity_pub_actor_person, public_key: keypair.public_key.to_pem)
  end
  let!(:group) { Fabricate(:discourse_activity_pub_actor_group) }
  let(:body) { build_activity_json(type: "Follow", actor: person, object: group) }

  before do
    SiteSetting.activity_pub_async_inbox_verification = true
    toggle_activity_pub(group.model)
  end

  def signed_headers(path: nil, **options)
    build_headers(
      object: group,
      actor: person,
      keypair: keypair,
      verb: "post",
      path: path || DiscourseActivityPub::URI.parse(group.inbox).path,
      headers: {
        "Digest" => "SHA-256=#{Digest::SHA256.base64digest(body.to_json)}",
      },
      **options,
    )
  end

  def verification_args
    Jobs::DiscourseActivityPub::VerifyInbox.jobs.last.fetch("args").first.with_indifferent_access
  end

  it "receives an unknown actor without network I/O and processes only after verification" do
    actor_json = build_actor_json(public_key: keypair.public_key.to_pem)
    actor_json[:id] = person.ap_id
    actor_json[:publicKey][:id] = "#{person.ap_id}#main-key"
    actor_json[:publicKey][:owner] = person.ap_id
    headers = signed_headers
    actor_id = person.ap_id
    person.destroy!
    remote = stub_request(:get, actor_id).to_return(status: 200, body: actor_json.to_json)

    post_to_inbox(group, body: body, headers: headers)

    expect(response.status).to eq(202)
    expect(remote).not_to have_been_requested
    expect(Jobs::DiscourseActivityPub::Process.jobs).to be_empty
    Jobs::DiscourseActivityPub::VerifyInbox.new.execute(verification_args)
    expect(remote).to have_been_requested.once
    expect(
      Jobs::DiscourseActivityPub::Process.jobs.last.dig("args", 0, "signed_actor_ap_id"),
    ).to eq(actor_id)
  end

  it "verifies a cached actor before dispatching the activity" do
    post_to_inbox(group, body: body, headers: signed_headers)
    expect(Jobs::DiscourseActivityPub::Process.jobs).to be_empty

    Jobs::DiscourseActivityPub::VerifyInbox.new.execute(verification_args)

    expect(
      Jobs::DiscourseActivityPub::Process.jobs.last.dig("args", 0, "signed_actor_ap_id"),
    ).to eq(person.ap_id)
  end

  it "rejects bad signatures even when the remote key refresh succeeds" do
    actor_json = build_actor_json(public_key: keypair.public_key.to_pem)
    actor_json[:id] = person.ap_id
    actor_json[:publicKey][:id] = "#{person.ap_id}#main-key"
    actor_json[:publicKey][:owner] = person.ap_id
    stub_request(:get, person.ap_id).to_return(status: 200, body: actor_json.to_json)
    post_to_inbox(group, body: body, headers: signed_headers(keypair: OpenSSL::PKey::RSA.new(2048)))

    Jobs::DiscourseActivityPub::VerifyInbox.new.execute(verification_args)

    expect(Jobs::DiscourseActivityPub::Process.jobs).to be_empty
  end

  it "keeps transient lookup failures for a background retry" do
    headers = signed_headers
    actor_id = person.ap_id
    person.destroy!
    stub_request(:get, actor_id).to_timeout
    post_to_inbox(group, body: body, headers: headers)
    args = verification_args

    expect { Jobs::DiscourseActivityPub::VerifyInbox.new.execute(args) }.to raise_error(
      Jobs::DiscourseActivityPub::VerifyInbox::NetworkFailure,
    )
    expect(Jobs::DiscourseActivityPub::Process.jobs).to be_empty
    expect(DiscourseActivityPub::InboxQueue.reserve(args[:token])).to eq(:duplicate)
  end

  it "deduplicates identical deliveries without allowing a forged signature to reserve a valid delivery" do
    valid_headers = signed_headers
    post_to_inbox(group, body: body, headers: valid_headers)
    post_to_inbox(group, body: body, headers: valid_headers)
    expect(Jobs::DiscourseActivityPub::VerifyInbox.jobs.size).to eq(1)

    post_to_inbox(group, body: body, headers: signed_headers(keypair: OpenSSL::PKey::RSA.new(2048)))
    expect(Jobs::DiscourseActivityPub::VerifyInbox.jobs.size).to eq(2)
  end

  it "rejects a digest mismatch before reserving a job" do
    headers = signed_headers
    altered_body = body.merge("id" => "https://remote.com/forged")

    post_to_inbox(group, body: altered_body, headers: headers)

    expect(response.status).to eq(401)
    expect(Jobs::DiscourseActivityPub::VerifyInbox.jobs).to be_empty
  end

  it "rejects stale signatures and missing signatures before reserving a job" do
    headers = signed_headers(params: { created: 2.days.ago.to_i, expires: 1.day.ago.to_i })
    post_to_inbox(group, body: body, headers: headers)
    expect(response.status).to eq(401)
    post_to_inbox(group, body: body)
    expect(response.status).to eq(401)
    expect(Jobs::DiscourseActivityPub::VerifyInbox.jobs).to be_empty
  end

  it "uses the same signature gate for the shared inbox" do
    path = DiscourseActivityPub.users_shared_inbox_path
    post_to_inbox(group, url: path, body: body, headers: signed_headers(path: path))
    expect(response.status).to eq(202)
    expect(Jobs::DiscourseActivityPub::Process.jobs).to be_empty

    Jobs::DiscourseActivityPub::VerifyInbox.new.execute(verification_args)

    expect(
      Jobs::DiscourseActivityPub::Process.jobs.last.dig("args", 0, "signed_actor_ap_id"),
    ).to eq(person.ap_id)
  end

  it "returns a retryable response when verification capacity is exhausted" do
    stub_const(DiscourseActivityPub::InboxQueue, :MAX_PENDING, 0) do
      post_to_inbox(group, body: body, headers: signed_headers)
      expect(response.status).to eq(503)
      expect(response.headers["Retry-After"]).to eq("60")
      expect(Jobs::DiscourseActivityPub::VerifyInbox.jobs).to be_empty
    end
  end

  it "bounds the inbox body before parsing or enqueueing it" do
    oversized = { "padding" => "x" * DiscourseActivityPub::InboxVerification::MAX_BODY_BYTES }
    post_to_inbox(group, body: oversized)
    expect(response.status).to eq(413)
    expect(Jobs::DiscourseActivityPub::VerifyInbox.jobs).to be_empty
  end

  it "accepts a rotated key only after validating the refreshed key owner" do
    rotated_key = OpenSSL::PKey::RSA.new(2048)
    actor_json = build_actor_json(public_key: rotated_key.public_key.to_pem)
    actor_json[:id] = person.ap_id
    actor_json[:publicKey][:id] = "#{person.ap_id}#main-key"
    actor_json[:publicKey][:owner] = person.ap_id
    stub_request(:get, person.ap_id).to_return(status: 200, body: actor_json.to_json)
    post_to_inbox(group, body: body, headers: signed_headers(keypair: rotated_key))

    Jobs::DiscourseActivityPub::VerifyInbox.new.execute(verification_args)

    expect(
      Jobs::DiscourseActivityPub::Process.jobs.last.dig("args", 0, "signed_actor_ap_id"),
    ).to eq(person.ap_id)
  end

  it "rejects a fetched key whose owner belongs to another actor" do
    actor_json = build_actor_json(public_key: keypair.public_key.to_pem)
    actor_json[:id] = person.ap_id
    actor_json[:publicKey][:id] = "#{person.ap_id}#main-key"
    actor_json[:publicKey][:owner] = "https://remote.com/someone-else"
    headers = signed_headers
    actor_id = person.ap_id
    person.destroy!
    stub_request(:get, actor_id).to_return(status: 200, body: actor_json.to_json)
    post_to_inbox(group, body: body, headers: headers)

    Jobs::DiscourseActivityPub::VerifyInbox.new.execute(verification_args)

    expect(DiscourseActivityPubActor.exists?(ap_id: actor_id)).to eq(false)
    expect(Jobs::DiscourseActivityPub::Process.jobs).to be_empty
  end

  it "rejects a blocked signing origin in the background" do
    post_to_inbox(group, body: body, headers: signed_headers)
    SiteSetting.activity_pub_blocked_request_origins =
      DiscourseActivityPub::URI.domain_from_uri(person.ap_id)

    Jobs::DiscourseActivityPub::VerifyInbox.new.execute(verification_args)

    expect(Jobs::DiscourseActivityPub::Process.jobs).to be_empty
  end

  it "rejects private key URLs even if they are configured as allowed internal hosts" do
    SiteSetting.allowed_internal_hosts = "127.0.0.1"
    actor_id = "http://127.0.0.1/private"
    remote = stub_request(:get, actor_id).to_return(status: 200, body: "{}")
    post_to_inbox(group, body: body, headers: signed_headers(key_id: "#{actor_id}#main-key"))

    Jobs::DiscourseActivityPub::VerifyInbox.new.execute(verification_args)

    expect(remote).not_to have_been_requested
    expect(Jobs::DiscourseActivityPub::Process.jobs).to be_empty
  end

  it "does not delete stored actors when a key refresh returns Gone" do
    remote = stub_request(:get, person.ap_id).to_return(status: 410, body: "")
    post_to_inbox(group, body: body, headers: signed_headers(keypair: OpenSSL::PKey::RSA.new(2048)))
    args = verification_args

    Jobs::DiscourseActivityPub::VerifyInbox.new.execute(args)
    Jobs::DiscourseActivityPub::VerifyInbox.new.execute(args)

    expect(person.reload.public_key).to eq(keypair.public_key.to_pem)
    expect(person.available?).to eq(true)
    expect(remote).to have_been_requested.once
    expect(Jobs::DiscourseActivityPub::Process.jobs).to be_empty
  end

  it "uses receipt time for signature freshness when a valid job was delayed" do
    post_to_inbox(group, body: body, headers: signed_headers)
    args = verification_args

    freeze_time(3.hours.from_now) { Jobs::DiscourseActivityPub::VerifyInbox.new.execute(args) }

    expect(
      Jobs::DiscourseActivityPub::Process.jobs.last.dig("args", 0, "signed_actor_ap_id"),
    ).to eq(person.ap_id)
  end

  it "expires abandoned jobs without processing their activities" do
    post_to_inbox(group, body: body, headers: signed_headers)
    args = verification_args

    freeze_time(25.hours.from_now) { Jobs::DiscourseActivityPub::VerifyInbox.new.execute(args) }

    expect(Jobs::DiscourseActivityPub::Process.jobs).to be_empty
    expect(Discourse.redis.zcard(DiscourseActivityPub::InboxQueue::PENDING_KEY)).to eq(0)
  end

  it "keeps unsigned delivery available only under the explicit unsigned policy" do
    SiteSetting.activity_pub_require_signed_requests = false
    post_to_inbox(group, body: body)
    expect(response.status).to eq(202)
    expect(Jobs::DiscourseActivityPub::VerifyInbox.jobs).to be_empty
    expect(
      Jobs::DiscourseActivityPub::Process.jobs.last.dig("args", 0, "signed_actor_ap_id"),
    ).to be_nil
  end

  it "cleans up the site's reservation when background retries are exhausted" do
    post_to_inbox(group, body: body, headers: signed_headers)
    args = verification_args
    job = { "args" => [args.to_h] }

    Jobs::DiscourseActivityPub::VerifyInbox.sidekiq_retries_exhausted_block.call(job)

    expect(DiscourseActivityPub::InboxQueue.reserve(args[:token])).to eq(:reserved)
    expect(Jobs::DiscourseActivityPub::Process.jobs).to be_empty
  end

  it "dispatches a verified job once when the queue redelivers it" do
    post_to_inbox(group, body: body, headers: signed_headers)
    args = verification_args

    Jobs::DiscourseActivityPub::VerifyInbox.new.execute(args)
    Jobs::DiscourseActivityPub::VerifyInbox.new.execute(args)

    expect(Jobs::DiscourseActivityPub::Process.jobs.size).to eq(1)
  end
end
