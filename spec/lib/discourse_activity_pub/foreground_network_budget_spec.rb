# frozen_string_literal: true

require "socket"

RSpec.describe DiscourseActivityPub::Request do
  describe "#perform" do
    it "releases a foreground reader while a real HTTP peer is still stalled" do
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
            request_line = socket.gets
            break if request_line.nil? || request_line == "\r\n"
          end
          sleep 8
          socket.write("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}")
        end
      peer.report_on_exception = false
      request_class =
        Class.new(described_class) do
          # This test peer is deliberately local; production uses the original resolver.
          def safe_request_uri
            uri
          end

          def final_headers(_verb)
            headers
          end
        end
      request = request_class.new(uri: "http://127.0.0.1:#{server.addr[1]}/slow")
      WebMock.disable_net_connect!(allow_localhost: true)
      Thread.current["discourse.processing_request"] = true
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      result = request.perform(:get)
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      expect(result).to be_nil
      expect(elapsed).to be_between(4.0, 5.8)
    ensure
      Thread.current["discourse.processing_request"] = nil
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
