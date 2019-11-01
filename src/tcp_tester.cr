require "socket"
require "json"
require "http/server"
require "option_parser"

module TcpTester
  VERSION        = "0.1.0"
  DFLT_CONF_FILE = "conf/config.json"
  DFLT_WORK_MODE = "server"
  DFLT_BIND_HOST = "0.0.0.0"
  DFLT_RMT_HOST  = "localhost"
  DFLT_APP_NAME  = "tcp_tester"

  lib C
    fun geteuid : UInt32
  end
  
  def self.get_app_name : String
    appName = Process.executable_path || DFLT_APP_NAME
    appName[((appName.rindex("/") || -1) + 1)..-1].gsub(/(?:^crystal-run-|\.tmp$)/,"")
  end

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
	
	class Discovery # Trek, AMD, Discovery Channel!
		@ports_d : Hash(String, Array(Hash(String, Int32 | String)))
		def initialize(@conf : Config)
			@ports_d = {"data" => @conf.ports.map {|p| {"{#TCP_T_PORT}" => p.port, "{#TCP_T_CHECK_TYPE}" => p.type + (p.use_ssl ? "s" : "")}}}
		end
		
    def ports(io : IO)
      @ports_d.to_json(io)
    end
    
    def ports
      @ports_d.to_json
    end	
	end
	
	config_file = DFLT_CONF_FILE
	work_mode 	= DFLT_WORK_MODE
  OptionParser.parse do |parser|
    parser.banner = "Usage: #{get_app_name} [arguments]"
    parser.on("-с CONFIG_FILE_PATH.json", "--config=CONFIG_FILE_PATH.json", "Path to configuration file in JSON format") {|c| config_file = c }
    parser.on("-m WORK_MODE", "--mode=WORK_MODE", "Specifies this script working mode. Acceptable values: server [default], client, discovery") { |w| work_mode = w }
    parser.on("-h", "--help", "Show this help") { puts parser; exit 0 }
    parser.invalid_option do |flag|
      STDERR.puts "ERROR: #{flag} is not a valid option."
      STDERR.puts parser
      exit 1
    end
  end	

  euid = C.geteuid
  host = System.hostname.match(/^([^.]+)/).not_nil![0]

  descr = Config.from_json(File.open(config_file).gets_to_end)
  tcp_ports = descr.ports
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
            ctx.response.content_type = "application/json"
            Discovery.new(descr).ports(ctx.response) #.print "PONG"
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
  when "discovery"
  	h = {"data" => tcp_ports.map {|p| {"{#TCP_T_PORT}" => p.port, "{#TCP_T_CHECK_TYPE}" => p.type + (p.use_ssl ? "s" : "")}}}
  	puts h.to_json
  else
    raise "Unknown work mode: #{work_mode}"
  end
end
