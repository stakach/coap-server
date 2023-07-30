struct CoAP::Server::Dispatch::RequestBuffer
  property io : IO::Memory
  getter initiated : Time::Span
  getter ip_address : Socket::IPAddress

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
end
