# frozen_string_literal: true

require "socket"

RSpec.describe DiscourseActivityPub::Request do
  describe ".with_network_budget" do
    it "bounds a real stalled background GET and marks it retryable" do
      webmock_config = WebMock::Config.instance
      previous_webmock_config =
        %i[allow_net_connect allow_localhost allow].to_h do |option|
          [option, webmock_config.public_send(option)]
        end
      server = TCPServer.new("127.0.0.1", 0)
      socket = nil
      peer =
        Thread.new do
          socket = server.accept
          loop do
            line = socket.gets
            break if line.nil? || line == "\r\n"
          end
          sleep 5
        end
      peer.report_on_exception = false
      request_class =
        Class.new(described_class) do
          # Only the test peer uses a private address; production keeps SSRF checks.
          def safe_request_uri
            uri
          end

          def final_headers(_verb)
            headers
          end
        end
      request = request_class.new(uri: "http://127.0.0.1:#{server.addr[1]}/slow")
      WebMock.disable_net_connect!(allow_localhost: true)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      described_class.with_network_budget(seconds: 0.5) do |budget|
        expect(request.perform(:get)).to be_nil
        expect(budget[:failed]).to eq(true)
      end

      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be_between(0.4, 1.5)
    ensure
      previous_webmock_config&.each do |option, value|
        webmock_config.public_send("#{option}=", value)
      end
      peer&.kill
      peer&.join
      socket&.close
      server&.close
    end
  end
end
