require "./confirmable"

# handles retransmission of confirmable messages
class CoAP::Server::Dispatch::ConfirmationTracking
  def initialize(@transmit : Channel(Tuple(Socket::IPAddress, CoAP::Message)))
    @waiting = {} of String => Confirmable
    @reset = Channel(Socket::IPAddress).new
    @register = Channel(Confirmable).new
    @acknowledged = Channel(String).new
    @timeout_tick = Channel(Time::Span).new

    spawn { management_loop }
    spawn { timeout_loop }
  end

  def finalize
    close
  end

  def register(ip_address : Socket::IPAddress, message : CoAP::Message) : Nil
    @register.send Confirmable.new(ip_address, message)
  end

  def acknowledged(ip_address : Socket::IPAddress, message : CoAP::Message) : Nil
    @acknowledged.send Confirmable.lookup(ip_address, message)
  end

  def reset(ip_address : Socket::IPAddress) : Nil
    @reset.send ip_address
  end

  protected def management_loop : Nil
    loop do
      break if @register.closed?

      select
      when new_con = @register.receive
        @waiting[new_con.lookup_key] = new_con
      when lookup = @acknowledged.receive
        @waiting.delete lookup
      when ip_address = @reset.receive
        @waiting.reject! do |_lookup, msg|
          msg.ip_address == ip_address
        end
      when now = @timeout_tick.receive
        @waiting.reject! do |_lookup, msg|
          if msg.send_failed?(now)
            Log.trace { "message send failed #{msg.ip_address} id:#{msg.message.message_id}" }
            next true
          end

          if msg.timed_out?(now)
            @transmit.send({msg.ip_address, msg.message})
            msg.increment_transmit_count
          end

          false
        end
      end
    end
  rescue Channel::ClosedError
  end

  protected def timeout_loop : Nil
    loop do
      sleep 0.5
      break if @timeout_tick.closed?
      @timeout_tick.send Time.monotonic
    end
  rescue Channel::ClosedError
  end

  def close
    @register.close
    @reset.close
    @acknowledged.close
    @timeout_tick.close
  end
end
