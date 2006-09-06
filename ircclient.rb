module IrcClient
    require 'timeout'
    require "socket"
    require 'thread'

    ERR_NOSUCHNICK = 401

    # The irc class, which talks to the server and holds the main event loop
    class IrcActor
        #=========================================================== 
        #events
        #=========================================================== 
        def initialize(client)
            @client = client
            @eventqueue = ConditionVariable.new
            @eventlock = Mutex.new
            @events = []
            @store = {
                :ping => 
                Proc.new {|server|
                    client.send_pong server
                },
                :servernotice=>
                [Proc.new {|msg|
                    puts "Server:#{msg}"
                }],
                :privmsg =>
                [Proc.new {|user,channel,msg|
                    #puts "message from #{user} on #{channel} : #{msg}"
                    #client.msg_channel channel,"message from #{user} on #{channel} : #{msg}"
                }],
                :connect =>
                [Proc.new {|server,port,nick,pass|
                    client.send_pass pass
                    client.send_nick nick
                    client.send_user nick,'0','*',"#{server} Net Bot"
                }],
                :numeric =>
                [Proc.new {|server,numeric,msg,detail|
                    #puts "on numeric #{server}:#{numeric}"
                }],
                :join=>
                [Proc.new {|nick,channel|
                    #puts "on join"
                }],
                :part=>
                [Proc.new {|nick,channel,msg|
                    #puts "on part"
                }],
                :unknown =>
                [Proc.new {|line|
                    puts "unknown message #{line}"
                }]
            }
        end
        
        #=========================================================== 
        #on_xxx appends to registered callbacks
        #use [] to reset callbacks
        #=========================================================== 
        def on_connect(&block)
            raise IrcError.new('wrong arity') if block.arity != 4
            self[:connect] << block
        end
        def on_ping(&block)
            raise IrcError.new('wrong arity') if block.arity != 1
            self[:ping] << block
        end
        def on_privmsg(&block)
            raise IrcError.new('wrong arity') if block.arity != 3
            self[:privmsg] << block
        end
        def on(method,&block)
            self[method] << block
        end
        #=========================================================== 
        def [](method)
            @store[method] = [] if @store[method].nil?
            return @store[method]
        end

        def push(method,*args)
            @eventlock.synchronize {
                @events << [method,args]
                @eventqueue.signal
            }
        end
        
        def send_names(channel)
            @client.send_names channel
        end

        def send_message(user,message)
            @client.msg_user user, message
        end
        
        def send(message)
            @client.send message
        end

        def run
            @eventlock.synchronize {
                while true
                    begin
                        @eventqueue.wait(@eventlock)
                        method,args = @events.shift
                        self[method].each {|block| block[*args] }
                    rescue SystemExit => e
                        exit 0
                    rescue Exception => e
                        carp e
                    end
                end
            }
        end
        def join(channel)
            @client.send_join channel
        end
        def part(channel)
            @client.send_part channel
        end
        def nick
            return @nick
        end

        def carp(arg)
            if $verbose
                case  true
                when arg.kind_of?(Exception)
                    puts "#{self.class.to_s.downcase}:" + arg.message 
                    puts arg.backtrace.collect{|s| "#{self.class.to_s.downcase}:" + s}.join("\n")
                else
                    puts "#{self.class.to_s.downcase}:" + arg
                end
            end
        end
        
        #=========================================================
        #If we need more than just names, this should go into another
        #class.
        #=========================================================
        
        def names(channel)
            if @client.class.to_s =~ /Proxy/
                return @client.names(channel)
            else
                return pnames(channel)
            end
        end 
        
        #remote 
        def pnames(channel)
            carp "invoke names for #{channel}"
            #will be invoked from a thread different from that of the
            #primary IrcConnector thread.
            @names = []
            @client.send_names channel
            @eventbuf = []
            while true
                @eventqueue.wait(@eventlock)
                #wait for numeric
                method,args = @events.shift
                carp "#{method}->#{args}"
                if method == :numeric
                    server, numeric, msg, detail = args
                    case numeric
                    when 401
                        #nosuch channel
                        if msg =~ / *([^ ]+) +([^ ]+) */
                            if $2 == channel
                                carp "401"
                                break
                            else
                                @eventbuf << [method,args]
                            end
                        else
                            carp "401 message Invalid : #{message}"
                        end
                    when 366
                        #end of /names list
                        if msg =~ / +([^ ]+) */
                            if $1 == channel
                                carp "366 #{@names}"
                                break
                            else
                                @eventbuf << [method,args]
                            end
                        else
                            carp "366 message Invalid : #{message}"
                        end
                    when 353
                        if msg =~ / *= +([^ ]+)*$/
                            if $1 == channel
                                nicks = detail.split(/ +/)
                                nicks.each {|n| @names << $1.strip if n =~ /^@?([^ ]+)/ }
                                carp "nicks #{nicks}"
                            else
                                carp "353 message Invalid : #{message}"
                            end
                        else
                            @eventbuf << [method,args]
                        end
                    else
                        @eventbuf << [method,args]
                    end
                else
                    @eventbuf << [method,args]
                end
            end
            @events = @eventbuf + @events
            carp "returning #{@names}"
            return @names
        end
    end

    class PrintActor < IrcActor
        def initialize(client)
            super(client)
            on(:connect) {|server,port,nick,pass|
                client.send_join '#db'
            }
            on(:numeric) {|server,numeric,msg,detail|
                #puts "-:#{numeric}"
            }
            on(:join) {|nick,channel|
                #puts "#{nick} join-:#{channel}"
                #client.msg_channel '#markee', "heee"
            }
            on(:part) {|nick,channel,msg|
                #puts "#{nick} part-:#{channel}"
            }
        end
    end
    class TestActor < IrcActor
        def initialize(client)
            super(client)
            on(:connect) {|server,port,nick,pass|
                client.send_join '#db'
            }
            on(:numeric) {|server,numeric,msg,detail|
                puts "-:#{numeric}"
            }
            on(:join) {|nick,channel|
                puts "#{nick} join-:#{channel}"
            }
            on(:part) {|nick,channel,msg|
                puts "#{nick} part-:#{channel}"
            }
            on(:privmsg) {|nick,channel,msg|
                puts "#{nick}:#{channel} -> #{msg}"
                case msg
                when /^ *!who +([^ ]+) *$/
                    begin
                    puts ">names"
                    names = names($1)
                    puts names
                    send_message channel, "names: #{names.join(',')}"
                    rescue Exception => e
                        puts e.message
                        puts e.backtrace.join("\n")
                    end
                end
            }
        end
    end

    class IrcConnector
        attr_reader :server, :port, :nick, :socket
        attr_writer :actor, :socket
        def initialize(server, port, nick, pass)
            @server = server
            @port = port
            @nick = nick
            @pass = pass
            @actor = IrcActor.new(self)
            @readlock = Mutex.new
            @writelock = Mutex.new
        end

        def carp(arg)
            IrcConnector.carp(arg)
        end
        def IrcConnector.carp(arg)
            if $verbose
                case  true
                when arg.kind_of?(Exception)
                    puts "#{self.class.to_s.downcase}:" + arg.message 
                    puts arg.backtrace.collect{|s| "#{self.class.to_s.downcase}:" + s}.join("\n")
                else
                    puts "#{self.class.to_s.downcase}:" + arg
                end
            end
        end

        def run
            connect()
            @eventloop = Thread.new { @actor.run }
            listen_loop
        end

        def connect()
            #allow socket to be handed over from elsewhere.
            @socket = @socket || TCPSocket.open(@server, @port)
            @actor[:connect].each{|c| c[ @server, @port, @nick, @pass]}
        end
       
        #=========================================================== 
        def process(s)
            s.untaint
            case s.strip
            when /^PING :(.+)$/i
                #dont bother about event loop here.
                @actor[:ping][$1]
            when /^NOTICE\s(.+)$/i, /:([^ ]+) +NOTICE\s(.+)$/i
                @actor.push :servernotice, $1
            when /^:([a-zA-Z0-9_.-]+)!.*PRIVMSG\s([0-9a-zA-Z_#-]+)\s:(.+)$/i
                @actor.push :privmsg, $1.strip,$2.strip,$3.strip
            when /^:([a-zA-Z0-9_.-]+)!.*JOIN\s:([0-9a-zA-Z_#-]+) *$/i
                @actor.push :join, $1.strip,$2.strip
            when /^:([a-zA-Z0-9_.-]+)!.*PART\s([0-9a-zA-Z_#-]+)\s(.+)$/i
                @actor.push :part, $1.strip,$2.strip,$3.strip
            when /^:([a-zA-Z0-9_.-]+) +([0-9]+) +([^:]+):(.+)$/i
                server,numeric,msg,detail =  $1.strip,$2.strip.to_i,$3.strip,$4.strip
                @actor.push :numeric, server,numeric,msg,detail
            when /^:([a-zA-Z0-9_.-]+) +([0-9]+) +([^:]+)$/i
                server,numeric,msg,detail =  $1.strip,$2.strip.to_i,$3.strip, ''
                @actor.push :numeric, server,numeric,msg,detail
            else
                @actor.push :unknown, s
            end
        end

        def listen_loop()
            process(gets) while !@socket.eof?
        end

        #=====================================================
        def lock_read
            @readlock.lock
        end
        def unlock_read
            @readlock.unlock
        end
        def lock_write
            @writelock.lock
        end
        def unlock_write
            @writelock.unlock
        end
        #=====================================================
        def send_pong(arg)
            send "PONG :#{arg}"
        end
        def send_pass(pass)
            send "PASS #{pass}"
        end
        def send_nick(nick)
            send "NICK #{nick}"
        end
        def send_user(user,mode,unused,real)
            send "USER #{user} #{mode} #{unused} :#{real}"
        end
        def send_names(channel)
            send "NAMES #{channel}"
        end
        def send(msg)
            send "#{msg}"
        end
        #=====================================================
        def send_join(channel)
            send "JOIN #{channel}"
        end
        def send_part(channel)
            send "PART #{channel} :"
        end

        def msg_user(user,data)
            msg_channel(user, data)
        end

        def msg_channel(channel, data)
            send "PRIVMSG #{channel} :#{data}"
        end

        def gets
            @readlock.synchronize { 
                s = @socket.gets
                carp "<#{s}"
                return s 
            }
        end
        
        def send(s)
            carp ">#{s}"
            @writelock.synchronize { @socket << "#{s}\n" }
        end
        #=====================================================
        def IrcConnector.start(opts={})
            server = opts[:server] or raise 'No server defined.'
            nick = opts[:nick] || '_' + Socket.gethostname.split(/\./).shift
            port = opts[:port] || 6667
            pass = opts[:pass] || 'netserver'
            irc = IrcConnector.new(server, port , nick, pass)
            #irc.actor = PrintActor.new(irc)
            irc.actor = TestActor.new(irc)
            begin
                irc.run
            rescue SystemExit => e
                puts "exiting..#{e.message()}"
                exit 0
            rescue Interrupt
                exit 0
            rescue Exception => e
                carp e
            end
        end
    end
#=====================================================
    class ProxyConnector
        attr_reader :server, :nick
        attr_writer :actor
        def initialize(nick, pass, server, actor)
            @server = 'service'
            @nick = nick
            @pass = pass
            @actor = actor.new(self)
            @ircserver = server
        end

        #=====================================================
        def invoke(method, *args)
            @actor[method].each{|c| c[*args]}
        end
        
        #called during connection.
        def connect
            @actor[:connect].each{|c| c[ @server, @port, @nick, @pass]}
        end

        def ping(arg)
            @actor[:ping].each{|c| c[arg]}
        end

        def privmsg(nick, channel, msg)
            @actor[:privmsg].each{|c| c[nick, channel, msg]}
        end
        def join(nick, channel)
            @actor[:join].each{|c| c[nick, channel]}
        end
        def part(nick, channel, msg)
            @actor[:part].each{|c| c[nick, channel, msg]}
        end
        def numeric(server,numeric,msg, detail)
            @actor[:numeric].each{|c| c[server,numeric,msg,detail]}
        end
        def unknown(arg)
            @actor[:unknown].each{|c| c[arg]}
        end
       
        #=====================================================
        def send_pong(arg)
            @ircserver.invoke :pong,arg
        end

        def send_pass(arg)
            @ircserver.invoke :pass,arg
        end
        def send_nick(arg)
            @ircserver.invoke :nick,arg
        end
        def send_user(user,mode,unused,real)
            @ircserver.invoke :user, user, mode, unused, real
        end
        def send_names(arg)
            @ircserver.invoke :names,arg
        end
        def send_join(arg)
            @ircserver.invoke :join,arg
        end
        def send_part(channel)
            @ircserver.invoke :part,arg
        end
        def msg_channel(channel, data)
            @ircserver.invoke :privmsg,channel, data
        end
        #=====================================================
        def names(channel)
            return @ircserver.names(channel)
        end

        def msg_user(user,data)
            msg_channel(user, data)
        end
    end
#=====================================================
    if __FILE__ == $0
        server = 'localhost'
        port = 6667
        nick = 'genericclient'
        while arg = ARGV.shift
            case arg
            when /-s/
                server = ARGV.shift
            when /-p/
                port = ARGV.shift
            when /-n/
                nick = ARGV.shift
            end
        end
        IrcConnector.start :server => server, 
            :port => port, 
            :nick => nick, 
            :pass => 'netserver'
    end
end
