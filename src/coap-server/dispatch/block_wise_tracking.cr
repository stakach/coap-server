require "./request_response"

# handles timeouts of block-wise transfers
class CoAP::Server::Dispatch::BlockWiseTracking
  def initialize
    @buffer = {} of String => RequestResponse
    @access_lock = Mutex.new
    @running = true
    spawn { timeout_loop }
  end

  def finalize
    stop
  end

  def buffer_request(ip_address : Socket::IPAddress, message : CoAP::Message) : RequestResponse
    request = RequestResponse.new(ip_address, message)
    token_id = request.token_id
    @access_lock.synchronize { @buffer[token_id] = request }
    request
  end

  def buffer_request(message : RequestResponse) : RequestResponse
    token_id = message.token_id
    @access_lock.synchronize { @buffer[token_id] = message }
    message
  end

  def lookup(ip_address : Socket::IPAddress, message : CoAP::Message) : RequestResponse?
    token_id = RequestResponse.token_id(ip_address, message)
    @access_lock.synchronize { @buffer[token_id]? }
  end

  def cleanup(message : RequestResponse) : Nil
    token_id = message.token_id
    @access_lock.synchronize { @buffer.delete token_id }
  end

  def reset(ip_address : Socket::IPAddress) : Nil
    @access_lock.synchronize do
      @buffer.reject! do |_lookup, msg|
        msg.ip_address == ip_address
      end
    end
  end

  protected def timeout_loop : Nil
    loop do
      break unless @running
      sleep 0.5

      now = Time.monotonic
      @access_lock.synchronize do
        @buffer.reject! do |_lookup, msg|
          if msg.timed_out?(now)
            Log.trace { "block-wise message timeout from #{msg.ip_address} id:#{msg.message.first.message_id}" }
            true
          end
        end
      end
    end
  end

  def stop
    @running = false
  end
end
