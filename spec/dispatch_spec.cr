require "./spec_helper"

describe CoAP::Server do
  ip_address = Socket::IPAddress.new("127.0.0.1", 5683)
  dispatch = CoAP::Server::Dispatch.new
  before_each { dispatch = CoAP::Server::Dispatch.new }

  get_request = Proc(CoAP::Server::Dispatch::RequestResponse?).new do
    select
    when req = dispatch.request.receive
      req
    else
      nil
    end
  end

  get_reponse = Proc(Tuple(Socket::IPAddress, CoAP::Message)?).new do
    select
    when req = dispatch.response.receive
      req
    else
      nil
    end
  end

  it "buffers a fragmented request" do
    bytes = "7000aa0f".hexbytes
    dispatch.buffer ip_address, bytes[0..1]

    new_request = !!get_request.call
    new_request.should be_false

    dispatch.buffer ip_address, bytes[2..-1]

    new_request = !!get_request.call
    new_request.should be_true
  end

  # testing https://datatracker.ietf.org/doc/html/rfc7959#section-3.2
  it "buffers a block-wise request" do
    token = "ABCD".hexbytes
    message = CoAP::Message.new
    message.message_id = 1_u16
    message.token = token
    message.method = :post

    # TODO:: Options should be set after payload_data as it changes format
    # need to rethink this aspect of the server
    message.uri = URI.parse("coap://127.0.0.1/path/method?payload")
    message.options << CoAP::Option::Block.new(0, true).to_option(:block1)
    message.options = message.options
    dispatch.buffer ip_address, message.to_slice

    (!!get_request.call).should be_false
    ip, response = get_reponse.call.not_nil!
    ip.should eq ip_address
    response.type.acknowledgement?.should be_true
    response.status.continue?.should be_true

    message = CoAP::Message.new
    message.message_id = 2_u16
    message.token = token
    message.method = :post
    message.uri = URI.parse("coap://127.0.0.1/path/method?payload")
    message.options << CoAP::Option::Block.new(1, true).to_option(:block1)
    message.options = message.options
    dispatch.buffer ip_address, message.to_slice

    ip, response = get_reponse.call.not_nil!
    ip.should eq ip_address
    response.type.acknowledgement?.should be_true
    response.status.continue?.should be_true

    message = CoAP::Message.new
    message.message_id = 3_u16
    message.token = token
    message.method = :post
    message.uri = URI.parse("coap://127.0.0.1/path/method?payload")
    message.options << CoAP::Option::Block.new(2, false).to_option(:block1)
    message.options = message.options
    dispatch.buffer ip_address, message.to_slice

    get_reponse.call.should be_nil
    request = get_request.call.not_nil!
    request.message.size.should eq 3
  end
end
