class CoAP::Server::Dispatch::RequestResponse
  getter message : Array(CoAP::Message) = [] of CoAP::Message
  getter initiated : Time::Span
  getter ip_address : Socket::IPAddress

  def initialize(@ip_address, @message, @token_id = nil)
    @initiated = Time.monotonic
  end

  def initialize(@ip_address, message : CoAP::Message, @token_id = nil)
    @message = [message]
    @initiated = Time.monotonic
  end

  def self.token_id(ip_address : Socket::IPAddress, message : CoAP::Message)
    "#{ip_address}~#{message.token.hexstring}"
  end

  getter token_id : String do
    self.class.token_id(@ip_address, @message.first)
  end

  def timed_out?(now = Time.monotonic) : Bool
    (now - @initiated) >= MAX_TRANSMIT_SPAN
  end

  def insert(message : CoAP::Message, block : Option::Block)
    messages = @message
    index = 0
    new_number = block.number
    replace = false

    messages.each do |msg|
      block_no = msg.options.find!(&.type.block1?).block.number

      if block_no == new_number
        replace = true
        break
      end

      break if block_no > new_number
      index += 1
    end

    if replace
      messages[index] = message
    else
      messages.insert(index, message)
    end
  end
end
