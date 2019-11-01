require "socket"
require "json"
require "http/server"

module TcpTester
  VERSION        = "0.1.0"
  DFLT_WORK_MODE = "server"
  DFLT_BIND_HOST = "0.0.0.0"
  DFLT_RMT_HOST  = "localhost"
  
  class SSLConf
  	JSON.mapping(
	  	crt_file: 	{type: String, nilable: true},
  		key_file:  	{type: String, nilable: true}
  	)
  end
  class PortRec
    JSON.mapping(
      port:			{type: Int32, nilable: false},
      remote: 	{type: String, nilable: false, default: TcpTester::DFLT_RMT_HOST},
      listen: 	{type: String, nilable: false, default: TcpTester::DFLT_BIND_HOST},
      type: 		{type: String, nilable: false, default: "ftp"},
      use_ssl: 	{type: Bool, nilable: false, default: false}
    )
  end  
	class Config
		JSON.mapping(
			ports: Array(PortRec),
			ssl: SSLConf
		)
	end


  unless conf_file = ARGV[0]?
    raise "No config file specified, you will burn in Hell!"
  end

  lib C
    fun geteuid : UInt32
  end

  euid = C.geteuid
  host = System.hostname.match(/^([^.]+)/).not_nil![0]

  descr = Config.from_json(File.open(conf_file).gets_to_end)
  tcp_ports = descr.ports
  work_mode = ARGV[1]? || DFLT_WORK_MODE
  case work_mode
  when "client"
    ch_client = Channel(Nil).new
    tcp_ports.each do |e|
      spawn do
        tcp_client = TCPSocket.new(e.remote, e.port)
        tcp_client << "message\n"
        response = tcp_client.gets
        puts "message=<<#{response}>>"
        tcp_client.close
        ch_client.send(nil)
      end
    end
    tcp_ports.size.times { ch_client.receive }
  when "server"
    raise "cant bind to privileged ports, insufficient privileges" if euid > 0 && tcp_ports.find { |e| e.port < 1024 }
    ch = {http: Channel(Nil).new, other: Channel(Nil).new}
    if flHasHTTP = tcp_ports.find { |e| e.type == "http" }
      begin
        ssl_conf = OpenSSL::SSL::Context::Server.new
        ssl_conf.certificate_chain = descr.ssl.crt_file || "conf/CA/#{host}-www.crt"
        ssl_conf.private_key = descr.ssl.key_file || "conf/CA/private/#{host}-www.key"

        spawn do
          http_server = HTTP::Server.new do |ctx|
            ctx.response.content_type = "text/plain"
            ctx.response.print "PONG"
          rescue ex
            puts "ERROR: Exception of type #{ex.class} catched: #{ex.message}"
          end

          tcp_ports.reject { |e| e.type != "http" }.each do |e|
            unless e.use_ssl
              http_server.bind_tcp "0.0.0.0", e.port
            else
              http_server.bind_tls "0.0.0.0", e.port, ssl_conf
            end
            puts "HTTPServer listens on http#{e.use_ssl ? "s" : ""}://0.0.0.0:#{e.port}"
          end
          http_server.listen
          ch[:http].send(nil)
        rescue ex
          puts "ERROR: Exception of type #{ex.class} catched: #{ex.message}"
        end # <- spawn HTTP::Server
      rescue ex
        puts "ERROR: Exception of type #{ex.class} catched: #{ex.message}"
      end
    end
    other_cnt = 0
    if flHasNoHTTP = tcp_ports.find { |e| e.type != "http" }
      tcp_ports.reject { |e| e.type == "http" }.each do |e|
        spawn do
          tcp_server = TCPServer.new(e.listen, e.port)
          other_cnt += 1
          puts "TCPServer listen on #{e.listen}:#{e.port}"
          while client = tcp_server.accept?
            spawn do
              if c = client.not_nil!
                puts "write FTP header"
                c.puts "220 OK"
                while ans = c.gets
                  if ans.match(/^QUIT/)
                    break
                  else
                    c.puts "OK"
                  end
                end
                c.close
              end
            end # <- spawn (client connection)
          end   # <- while tcp_server.accept
          ch.[:other].send(nil)
        end # spawn (server itself)
      end   # ports enumeration
    end     # if some ports is not http
    ch[:http].receive if flHasHTTP
    other_cnt.times { ch[:other].receive } if flHasNoHTTP
  else
    raise "Unknown work mode: #{work_mode}"
  end
end
