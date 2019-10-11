require "http/server"
lib C
  fun geteuid() : UInt32
end

euid = C.geteuid
port = euid == 0 ? {http: 80, https: 443} : {http: 8080, https: 8443}
host = System.hostname.match(/^([^.]+)/).not_nil![0]

server = HTTP::Server.new do |context|
  context.response.content_type = "text/plain"
  context.response.print "Hello world!"
end

address = server.bind_tcp "0.0.0.0", port[:http]
context = OpenSSL::SSL::Context::Server.new
context.certificate_chain = "CA/#{host}-www.crt"
context.private_key = "CA/private/#{host}-www.key"
addressl = server.bind_tls "0.0.0.0", port[:https], context
puts "Listening on http://#{address} and https://#{addressl}"
server.listen
