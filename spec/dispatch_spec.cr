require "./spec_helper"

describe CoAP::Server::Dispatch do
  ip_address = Socket::IPAddress.new("127.0.0.1", 5683)
  dispatch = CoAP::Server::Dispatch.new
  token = "ABCD".hexbytes

  before_each do
    dispatch.close
    dispatch = CoAP::Server::Dispatch.new
  end

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
    message = CoAP::Message.new
    message.message_id = 1_u16
    message.token = token
    message.method = :post
    message.uri = URI.parse("coap://127.0.0.1/path/method?payload")
    bytes = message.to_slice

    dispatch.buffer ip_address, bytes[0..1]

    new_request = !!get_request.call
    new_request.should be_false

    dispatch.buffer ip_address, bytes[2..-1]

    new_request = !!get_request.call
    new_request.should be_true
  end

  # testing https://datatracker.ietf.org/doc/html/rfc7959#section-3.2
  it "buffers a block-wise request" do
    message = CoAP::Message.new
    message.message_id = 1_u16
    message.token = token
    message.method = :post
    message.uri = URI.parse("coap://127.0.0.1/path/method?payload")
    message.options << CoAP::Option::Block.new(0, true).to_option(:block1)
    dispatch.buffer ip_address, message.to_slice

    (!!get_request.call).should be_false
    ip, response = get_reponse.call || raise "response expected"
    ip.should eq ip_address
    response.type.acknowledgement?.should be_true
    response.status.continue?.should be_true

    message = CoAP::Message.new
    message.message_id = 2_u16
    message.token = token
    message.method = :post
    message.uri = URI.parse("coap://127.0.0.1/path/method?payload")
    message.options << CoAP::Option::Block.new(1, true).to_option(:block1)
    dispatch.buffer ip_address, message.to_slice

    ip, response = get_reponse.call || raise "response expected"
    ip.should eq ip_address
    response.type.acknowledgement?.should be_true
    response.status.continue?.should be_true

    message = CoAP::Message.new
    message.message_id = 3_u16
    message.token = token
    message.method = :post
    message.uri = URI.parse("coap://127.0.0.1/path/method?payload")
    message.options << CoAP::Option::Block.new(2, false).to_option(:block1)
    dispatch.buffer ip_address, message.to_slice

    get_reponse.call.should be_nil
    request = get_request.call || raise "request expected"
    request.message.size.should eq 3
  end

  it "buffers and handles a block-wise response" do
    message = CoAP::Message.new
    message.message_id = 0_u16
    message.token = token
    message.status = :content
    message.options << CoAP::Option::Block.new(0, true).to_option(:block2)
    response = CoAP::Server::Dispatch::RequestResponse.new(ip_address, message)

    message = CoAP::Message.new
    message.message_id = 1_u16
    message.token = token
    message.status = :content
    message.options << CoAP::Option::Block.new(1, false).to_option(:block2)
    response.message << message

    # returns the first part of the response
    dispatch.respond response
    _ip, resp = get_reponse.call || raise "response expected"
    resp.should eq response.message.first?

    # request the next part of the response
    message = CoAP::Message.new
    message.message_id = 2_u16
    message.token = token
    message.method = :get
    message.uri = URI.parse("coap://127.0.0.1/path/method?payload")
    message.options << CoAP::Option::Block.new(1, false).to_option(:block2)
    dispatch.buffer ip_address, message.to_slice

    get_request.call.should be_nil
    _ip, resp = get_reponse.call || raise "response expected"
    resp.should eq response.message[-1]
  end

  it "times out buffered request / responses" do
    Timecop.scale(120) do
      message = CoAP::Message.new
      message.message_id = 0_u16
      message.token = token
      message.status = :content
      message.options << CoAP::Option::Block.new(0, true).to_option(:block2)
      response = CoAP::Server::Dispatch::RequestResponse.new(ip_address, message)

      message = CoAP::Message.new
      message.message_id = 1_u16
      message.token = token
      message.status = :content
      message.options << CoAP::Option::Block.new(1, false).to_option(:block2)
      response.message << message

      # returns the first part of the response
      dispatch.respond response
      _ip, resp = get_reponse.call || raise "response expected"
      resp.should eq response.message.first?

      sleep 0.6

      # request the next part of the response
      message = CoAP::Message.new
      message.message_id = 2_u16
      message.token = token
      message.method = :get
      message.uri = URI.parse("coap://127.0.0.1/path/method?payload")
      message.options << CoAP::Option::Block.new(1, false).to_option(:block2)
      dispatch.buffer ip_address, message.to_slice

      get_request.call.should be_nil
      _ip, resp = get_reponse.call || raise "response expected"
      puts resp.status.inspect
      resp.status.bad_option?.should eq true
      String.new(resp.payload_data).should eq "block2 response timeout"
    end
  end
end
