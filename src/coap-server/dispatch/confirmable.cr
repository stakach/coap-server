require "random/secure"

# tracks messages that must be confirmed
class CoAP::Server::Dispatch::Confirmable
  ACK_TIMEOUT       = 2.0
  ACK_RANDOM_FACTOR = 1.5
  MAX_RETRANSMIT    =   4

  def initialize(@ip_address : Socket::IPAddress, @message : CoAP::Message)
    @transmit_last = @transmit_start = Time.monotonic
    @timeout = (ACK_TIMEOUT * (1.0 + Random::Secure.rand * (ACK_RANDOM_FACTOR - 1.0))).seconds
  end

  getter ip_address : Socket::IPAddress
  getter message : CoAP::Message

  getter timeout : Time::Span
  getter transmit_start : Time::Span
  getter transmit_last : Time::Span
  getter transmit_count : Int32 = 0

  def timed_out?(now = Time.monotonic) : Bool
    (now - @transmit_last) >= @timeout
  end

  def send_failed?(now = Time.monotonic) : Bool
    @transmit_count >= MAX_RETRANSMIT || (now - @transmit_start) >= MAX_TRANSMIT_SPAN
  end

  def increment_transmit_count : Nil
    @transmit_count += 1
    @timeout *= 2 # double the timeout
    @transmit_last = Time.monotonic
  end

  def lookup_key
    self.class.lookup(@ip_address, @message)
  end

  def self.lookup(ip_address : Socket::IPAddress, message : CoAP::Message)
    "#{ip_address}~#{message.message_id}"
  end
end
