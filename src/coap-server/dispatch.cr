require "../coap-server"

# Dispatch handles the low level communication layer
#
# it performs the following functions
# * buffers requests (io buffering + block-wise transfers)
# * buffers responses (block-wise transfers)
# * handles confirmations and acknowledgements
# * handles retransmission
class CoAP::Server::Dispatch
  # This will be tracked as IP + token_id.hexstring
  alias TokenID = String

  class RequestResponse
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

  struct RequestBuffer
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

  # this stores any incoming requests if we don't have the full request data
  @request_buffers = {} of Socket::IPAddress => RequestBuffer

  # this stores incoming block-wise transfers
  @requests = {} of TokenID => RequestResponse
  @request_timeouts = Deque(RequestResponse).new

  # this stores outgoing block-wise transfers
  @responses = {} of TokenID => RequestResponse
  @response_timeouts = Deque(RequestResponse).new

  # new requests are sent down this channel once fully received
  getter request = Channel(RequestResponse).new(1)

  # responses are sent via this channel
  getter response = Channel(Tuple(Socket::IPAddress, CoAP::Message)).new(1)

  @message_id : UInt16 = rand(UInt16::MAX).to_u16

  # ensure the message id is not strictly guessable
  private def next_message_id
    @message_id += rand(10).to_u16
  rescue OverflowError
    @message_id = rand(10).to_u16
  end

  # buffer incoming data from an endpoint and process any
  # messages received
  def buffer(ip_address : Socket::IPAddress, bytes : Bytes)
    buffer = if buff = @request_buffers.delete(ip_address)
                buff.pos = buff.size
                buff.write bytes
                buff.rewind
                buff
              else
                RequestBuffer.new(ip_address, bytes)
              end

    pos = 0

    begin
      loop do
        io = buffer.io
        header = io.read_bytes(CoAP::Header)
        if header.version != 1_u8
          raise "unknown CoAP version #{header.version}"
        end
        io.pos = pos

        # extract a message from the buffer
        process_request(ip_address, io.read_bytes(CoAP::Message))

        pos = io.pos
        break if buffer.eof?
      end
    rescue error
      # we'll buffer as we expect more data (possible ip fragmentation)
      if IO::EOFError.in?({error.class, error.cause.class})
        Log.trace { "buffering message: #{error.message}" }
        bytes = buffer.to_slice[pos..-1]
        @request_buffers[ip_address] = RequestBuffer.new(ip_address, bytes)
      else
        # we'll throw away the rest of this buffer
        @request_buffers.delete ip_address
        Log.warn(exception: error) { "while processing request from #{ip_address}" }
      end
    end
  end

  protected def process_request(ip_address, message) : Nil
    options = message.options

    block2 = options.find(&.type.block2?).try &.block
    block1 = options.find(&.type.block1?).try &.block

    # MUST lead to a 4.00 Bad Request response code upon reception in a request.
    if block2.try(&.szx.==(7)) || block1.try(&.szx.==(7))
      respond ip_address, request_error(message, reason: "invalid block size 7")
      return
    end

    # is this a request for a part of the response we have buffered
    if block2
      token_id = RequestResponse.token_id(ip_address, message)
      if response = @responses[token_id]?
        if payload = response.message[block2.number]?
          cleanup = !block2.more?
          respond(ip_address, payload)
        else
          respond ip_address, request_error(message, ResponseCode::BadOption, reason: "block2 out of bounds")
          cleanup = true
        end

        if cleanup
          @responses.delete(token_id)
          @response_timeouts.delete(token_id)
        end
      else
        respond ip_address, request_error(message, ResponseCode::NotFound, reason: "response timeout")
      end

    # is the request made up of multiple blocks?
    elsif block1 && !(block1.number.zero? && !block1.more?)
      token_id = RequestResponse.token_id(ip_address, message)

      if block1.number.zero?
        request = RequestResponse.new(ip_address, message, token_id)
        @requests[token_id] = request
        @request_timeouts << request
      elsif request = @requests[token_id]?
        request.insert(message, block1)
      end

      if request
        if block1.more?
          # respond with acknowledgement
          if message.type.confirmable?
            ack = CoAP::Message.new
            ack.type = :acknowledgement
            ack.message_id = message.message_id
            ack.status = CoAP::ResponseCode::Continue
            ack.options = [block1.to_option(:block1)]
            respond ip_address, ack
          end
        else
          # TODO:: check we have all the parts of the request
          # respond with RequestEntityIncomplete if not

          # cleanup and perform the request
          @requests.delete token_id
          @request_timeouts.delete request
          perform_request request
        end
      else
        respond ip_address, request_error(message, reason: "request timeout")
      end
    else # a normal simple request
      perform_request RequestResponse.new(ip_address, message)
    end
  end

  # builds an error response for the request provided
  def request_error(
    message : CoAP::Message,
    status_code : ResponseCode = ResponseCode::BadRequest,
    reason : String? = nil,
  )
    msg = CoAP::Message.new
    msg.type = :non_confirmable
    msg.message_id = next_message_id
    msg.status_code = status_code
    msg.token = message.token
    if reason && reason.presence
      msg.payload_data = reason.to_slice
    end
    msg
  end

  # TODO:: check if an ack is required for the response and retransmit as required
  def respond(ip_address : Socket::IPAddress, message : CoAP::Message)
    @response.send({ip_address, message})
  end

  def respond(response : RequestResponse)
    if response.message.size > 0
      @responses[response.token_id] = response
      @response_timeouts << response
    end
    respond(response.ip_address, response.message.first)
  end

  # TODO:: Track the message ids in-flight so we can ignore
  # any retransmits from the client
  def perform_request(request : RequestResponse)
    @request.send request
  end
end
