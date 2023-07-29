require "http"
require "coap"

# a variation on HTTP::Server for handling CoAP protocol
class CoAP::Server < HTTP::Server
  {% begin %}
    VERSION = {{ `shards version "#{__DIR__}"`.chomp.stringify.downcase }}
  {% end %}

  Log = ::Log.for("coap.server")

  # Creates a new CoAP server with the given *handler*.
  def initialize(handler : HTTP::Handler | HTTP::Handler::HandlerProc)
    # love how simple crystal lang makes this
    @processor = ::CoAP::Server::RequestProcessor.new(handler)
  end

  def listen : Nil
    raise "Can't re-start closed server" if closed?
    raise "Can't start server with no sockets to listen to, use HTTP::Server#bind first" if @sockets.empty?
    raise "Can't start running server" if listening?

    @listening = true
    done = Channel(Nil).new

    @sockets.each do |socket|
      spawn { listen_socket(socket, done) }
    end
    @sockets.size.times { done.receive }
  end

  protected def listen_socket(socket : Socket::Server, done : Channel(Nil))
    loop do
      io = begin
        socket.accept?
      rescue e
        handle_exception(e)
        next
      end

      if io
        dispatch(io)
      else
        break
      end
    end
  ensure
    done.send nil
  end

  protected def listen_socket(socket : UDPSocket, done : Channel(Nil))
    loop do
      message, client_addr = socket.receive
    end
  ensure
    done.send nil
  end
end

require "./coap-server/*"
