struct CoAP::Server::Dispatch::IOBuffer
  property io : IO::Memory
  getter initiated : Time::Span
  getter ip_address : Socket::IPAddress

  PROCESSING_DELAY = 2.seconds

  def initialize(@ip_address, bytes : Bytes)
    @io = IO::Memory.new(bytes.size)
    @io.write bytes
    @io.rewind
    @initiated = Time.monotonic
  end

  forward_missing_to @io

  def eof?
    @io.pos == @io.size
  end

  def timed_out?(now = Time.monotonic) : Bool
    (now - @initiated) >= PROCESSING_DELAY
  end
end
