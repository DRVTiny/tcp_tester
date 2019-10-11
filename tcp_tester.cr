require "socket"
require "json"
module TcpTester
  VERSION = "0.1.0"
  DFLT_WORK_MODE = "client"
  DFLT_BIND_HOST = "0.0.0.0"
  DFLT_RMT_HOST = "localhost"

  class PortRec
    JSON.mapping(
      port: {type: Int32, nilable: false},
      remote: {type: String, nilable: false, default: TcpTester::DFLT_RMT_HOST},
      listen: {type: String, nilable: false, default: TcpTester::DFLT_BIND_HOST}
    )
  end

  unless conf_file = ARGV[0]?
    raise "No config file specified, you will burn in Hell!"
  end

  descr = Array(PortRec).from_json(File.open(conf_file).gets_to_end)
  work_mode = ARGV[1]? || DFLT_WORK_MODE
  ch = Channel(Nil).new  
  case work_mode
  when "client"
    descr.each do |e|
      spawn do
        tcp_client = TCPSocket.new(e.remote, e.port)
        tcp_client << "message\n"
        response = tcp_client.gets
        puts "message=<<#{response}>>"
        tcp_client.close
        ch.send(nil)
      end
    end
  when "server"
        descr.each do |e|
          spawn do
            tcp_server = TCPServer.new(e.listen, e.port)
            puts "listen on #{e.listen}:#{e.port}"
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
              end
            end
            ch.send(nil)
          end
        end
  else
        raise "Unknown work mode: #{work_mode}"
  end
  
  descr.size.times { ch.receive }
end
