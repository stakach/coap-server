require "spec"
require "../src/coap-server"

::Log.setup("*", :trace)

Spec.before_suite do
  ::Log.builder.bind("*", backend: ::Log::IOBackend.new(STDOUT), level: ::Log::Severity::Trace)
end
