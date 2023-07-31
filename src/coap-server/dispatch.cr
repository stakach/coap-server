require "../coap-server"

# Dispatch handles buffering and retransmission
#
# it performs the following functions
# * buffers requests (io buffering + block-wise transfers)
# * buffers responses (block-wise transfers)
# * handles confirmations and acknowledgements
# * handles retransmission
class CoAP::Server::Dispatch
  # the max time a message can take to be received or sent
  MAX_TRANSMIT_SPAN = 45.seconds

  # this stores any incoming requests if we don't have the full request data
  @io_buffers = {} of Socket::IPAddress => IOBuffer
  @io_mutex = Mutex.new

  # new requests are sent down this channel once fully received
  getter request = Channel(RequestResponse).new(1)

  # responses are sent via this channel
  getter response = Channel(Tuple(Socket::IPAddress, CoAP::Message)).new(1)

  # manage timeouts and retransmission of confirmable messages
  def initialize
    @confirmations = ConfirmationTracking.new(@response)
    @block_wise_requests = BlockWiseTracking.new
    @block_wise_response = BlockWiseTracking.new
  end

  def close
    @confirmations.close
    @block_wise_requests.close
    @block_wise_response.close
    @request.close
    @response.close
  end

  def closed?
    @request.closed?
  end

  def timeout_io_buffers
    loop do
      sleep 2
      break if @request.closed?

      now = Time.monotonic
      @io_mutex.synchronize do
        @io_buffers.reject! do |_lookup, io|
          io.timed_out?(now)
        end
      end
    end
  end

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
    if buff = @io_mutex.synchronize { @io_buffers.delete(ip_address) }
      io = buff.io
      io.pos = io.size
    else
      io = IO::Memory.new(bytes.size)
    end

    io.write bytes
    io.rewind
    pos = 0

    begin
      loop do
        header = io.read_bytes(CoAP::Header)
        if header.version != 1_u8
          raise "unknown CoAP version #{header.version}"
        end
        io.pos = pos

        # extract a message from the buffer
        process_request(ip_address, io.read_bytes(CoAP::Message))

        pos = io.pos
        break if pos == io.size
      end
    rescue error
      # we'll buffer as we expect more data (possible ip fragmentation)
      if IO::EOFError.in?({error.class, error.cause.class})
        Log.trace { "buffering message from #{ip_address}: #{error.message}" }
        bytes = io.to_slice[pos..-1]
        @io_mutex.synchronize { @io_buffers[ip_address] = IOBuffer.new(ip_address, bytes) }
      else
        # we'll throw away the rest of this buffer
        @io_mutex.synchronize { @io_buffers.delete ip_address }
        Log.warn(exception: error) { "while processing request from #{ip_address}" }
      end
    end
  end

  protected def process_request(ip_address, message) : Nil
    # check if client reset and clear any buffers
    if message.type.reset?
      @confirmations.reset ip_address
      @block_wise_requests.reset ip_address
      @block_wise_response.reset ip_address
      return
    end

    if message.type.acknowledgement?
      @confirmations.acknowledged(ip_address, message)
      return
    end

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
      if response = @block_wise_response.lookup(ip_address, message)
        if payload = response.message[block2.number]?
          cleanup = !payload.options.find!(&.type.block2?).block.more?
          respond(ip_address, payload)
        else
          @response.send({ip_address, request_error(message, ResponseCode::BadOption, reason: "block2 out of bounds")})
          cleanup = true
        end

        @block_wise_response.cleanup(response) if cleanup
      else
        @response.send({ip_address, request_error(message, ResponseCode::BadOption, reason: "block2 response timeout")})
      end

      # is the request made up of multiple blocks?
    elsif block1 && !(block1.number.zero? && !block1.more?)
      if block1.number.zero?
        request = @block_wise_requests.buffer_request(ip_address, message)
      elsif request = @block_wise_requests.lookup(ip_address, message)
        request.insert(message, block1)
      end

      if request
        if block1.more?
          # respond with acknowledgement
          ack = CoAP::Message.new
          if message.type.non_confirmable?
            ack.type = :non_confirmable
            ack.message_id = next_message_id
          else
            ack.type = :acknowledgement
            ack.message_id = message.message_id
          end
          ack.status = CoAP::ResponseCode::Continue
          ack.options = [block1.to_option(:block1)]
          @response.send({ip_address, ack})
        else
          # cleanup and perform the request
          @block_wise_requests.cleanup request

          # check we have all the parts of the request
          if block1.number > (request.message.size - 1)
            @response.send({
              ip_address,
              request_error(message, ResponseCode::RequestEntityIncomplete, reason: "block1 missing parts"),
            })
            return
          end

          perform_request request
        end
      else
        respond ip_address, request_error(message, reason: "request timeout")
      end
    else # a normal simple request
      if message.type.confirmable?
        ack = CoAP::Message.new
        ack.type = :acknowledgement
        ack.message_id = message.message_id
        ack.status = 0
        @response.send({ip_address, ack})
      end

      perform_request RequestResponse.new(ip_address, message)
    end
  end

  # builds an error response for the request provided
  def request_error(
    message : CoAP::Message,
    status_code : ResponseCode = ResponseCode::BadRequest,
    reason : String? = nil
  )
    msg = CoAP::Message.new
    if message.type.non_confirmable?
      msg.type = :non_confirmable
      msg.message_id = next_message_id
    else
      msg.type = :acknowledgement
      msg.message_id = message.message_id
    end
    msg.status_code = status_code
    msg.token = message.token
    if reason && reason.presence
      msg.payload_data = reason.to_slice
    end
    msg
  end

  # check if an ack is required for the response and retransmit as required
  def respond(ip_address : Socket::IPAddress, message : CoAP::Message)
    if message.type.confirmable?
      # buffer and ensure we get an ACK
      @confirmations.register(ip_address, message)
    end
    @response.send({ip_address, message})
  end

  # block-wise request response
  def respond(response : RequestResponse)
    @block_wise_response.buffer_request(response) if response.message.size > 1
    respond(response.ip_address, response.message.first)
  end

  # TODO:: Track the message ids in-flight so we can ignore
  # any retransmits from the client
  def perform_request(request : RequestResponse)
    @request.send request
  end
end

require "./dispatch/*"
