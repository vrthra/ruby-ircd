#!/usr/local/bin/ruby
require 'webrick'
require 'thread'
require 'ircreplies'
require 'netutils'

include IRCReplies

$config = {}
$config['version'] = '0.1'
$config['timeout'] = 10
$config['port'] = 6667
$config['hostname'] = Socket.gethostname.split(/\./).shift
$config['starttime'] = Time.now.to_s

$verbose = ARGV.shift || false
    
CHANNEL = /^[#\$&]+/
PREFIX  = /^:[^ ]+ +(.+)$/
class UserStore
    @@registered_users = {}
    @@mutex = Mutex.new

    def UserStore.<<(client)
        @@mutex.synchronize {
            @@registered_users[client.nick] = client
        }
    end

    def UserStore.[](nick)
        client = nil
        @@mutex.synchronize {
            client = @@registered_users[nick]
        }
        return client
    end

    def UserStore.delete(nick)
        @@mutex.synchronize {
            @@registered_users.delete(nick)
        }
    end

    def UserStore.each
        @@registered_users.values.each {|u|
            @@mutex.synchronize {
                yield u 
            }
        }
    end
end

class ChannelStore
    @@mutex = Mutex.new
    @@registered_channels = {}

    def ChannelStore.<<(client)
        @@mutex.synchronize {
            @@registered_channels[client.nick] = client
        }
    end

    def ChannelStore.[](c)
        @@mutex.synchronize {
            return @@registered_channels[c]
        }
    end

    def ChannelStore.add(c)
        channel = nil
        @@mutex.synchronize {
            if @@registered_channels[c].nil?
                channel = IRCChannel.new(c)
                @@registered_channels[c] = channel
            else
                channel = @@registered_channels[c]
            end
        }
        return channel
    end

    def ChannelStore.delete(c)
        carp "channel #{c} deleted.."
        @@mutex.synchronize {
            @@registered_channels.delete(c)
        }
    end

    def ChannelStore.each
        @@registered_channels.values.each do |c|
            #this will cause prob if some one using the 
            #value *and* calling to any of the above
            #how ever this should not happen.
            @@mutex.synchronize do
                yield c 
            end
        end
    end

    def ChannelStore.carp(arg)
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
end


class IRCChannel
    include NetUtils
    attr_reader :name, :topic
    @@mutex = Mutex.new

    def initialize(name)
        @clients = []
        @topic = "There is no topic"
        @name = name
        carp "create channel:#{@name}"
    end

    def join(client)
        @@mutex.synchronize {
            return false if @clients.include?(client)
            @clients << client 
        }
        #send join to each user in the channel
        eachuser {|user|
            user.reply :join, client.userprefix, @name
        }
        return true
    end

    def part(client, msg)
        @@mutex.synchronize {
            @clients.delete(client)
        }
        eachuser {|user|
            user.reply :part, client.userprefix, @name, msg
        }
        ChannelStore.delete(@name) if @clients.empty?
    end

    def quit(client, msg)
        @@mutex.synchronize {
            @clients.delete(client)
        }
        eachuser {|user|
            user.reply :quit, client.userprefix, @name, msg if user!= client
        }
        ChannelStore.delete(@name) if @clients.empty?
    end

    def privatemsg(msg, client)
        eachuser {|user|
            user.reply :privmsg, client.userprefix, @name, msg if user != client
        }
    end

    def notice(msg, client)
        eachuser {|user|
            user.reply :notice, client.userprefix, @name, msg if user != client
        }
    end

    def topic(msg=nil)
        return @topic if msg.nil?
        @topic = msg
        eachuser {|user|
            user.reply :topic, user.userprefix, @name, msg
        }
        return @topic
    end

    def clients
        return @clients
    end

    def names
        return @clients.collect{|c|c.nick}
    end

    def mode(u)
        return u == @clients[0] ? '@' : ''
    end

    def remove_nick(nick)
        @@mutex.synchronize {
            @clients.delete_if{|c| c.nick == nick}
        }
    end

    def eachuser
        @@mutex.synchronize {
            @clients.each {|c|
            @@mutex.unlock
                yield c 
            @@mutex.lock
            }
        }
    end
end

class IRCClient
    include NetUtils

    def initialize(sock, serv)
        @serv = serv
        @socket = sock
        @channels = []
        @peername = peer()
        @welcomed = false
        carp "initializing connection from #{@peername}"
    end

    def nick
        return @nick
    end

    def channels
        return @channels
    end

    def user
        return @user
    end

    def realname
        return @realname
    end
    
    def host
        return @peername
    end

    def userprefix
        return @usermsg
    end

    def closed?
        return !@socket.nil? && !@socket.closed?
    end

    def ready
        #check for nick and pass
        return (!@pass.nil? && !@nick.nil?) ? true : false
    end

    def peer
        begin
            sockaddr = @socket.getpeername
            begin
                return Socket.getnameinfo(sockaddr, Socket::NI_NAMEREQD).first
            rescue 
                return Socket.getnameinfo(sockaddr).first
            end
        rescue
            return @socket.peeraddr[2]
        end
    end

    def handle_pass(s)
        carp "pass = #{s}"
        @pass = s
    end
    
    def handle_nick(s)
        carp "nick => #{s}"
        if UserStore[s].nil?
            userlist = {}
            if @nick.nil?
                handle_newconnect(s)
            else
                userlist[s] = self if self.nick != s
                UserStore.delete(@nick)
                @nick = s
            end

            UserStore << self

            #send the info to the world
            #get unique users.
            @channels.each {|c|
                ChannelStore[c].eachuser {|u|
                    userlist[u.nick] = u
                }
            }
            userlist.values.each {|user|
                user.reply :nick, s
            }
            @usermsg = ":#{@nick}!~#{@user}@#{@peername}"
        else
            #check if we are just nicking ourselves.
            if !UserStore[s] == self
                #verify the connectivity of earlier guy
                if !UserStore[s].closed?
                    reply :numeric, ERR_NICKNAMEINUSE,"* #{s} ","Nickname is already in use."
                    carp "kicking spurious user #{s}"
                    handle_abort
                else
                    UserStore[s].handle_abort
                    UserStore[s] = self
                end
            end
        end
    end

    def handle_user(user, mode, unused, realname)
        @user = user
        @mode = mode
        @realname = realname
        @usermsg = ":#{@nick}!~#{@user}@#{@peername}"
        send_welcome if !@nick.nil?
    end

    def mode
        return @mode
    end

    def handle_newconnect(nick)
        @alive = true
        @nick = nick
        @host = $config['hostname']
        @ver = $config['version']
        @starttime = $config['starttime']
        send_welcome if !@user.nil?
    end

    def send_welcome
        if !@welcomed
            repl_welcome
            repl_yourhost
            repl_created
            repl_myinfo
            repl_motd
            repl_mode
            @welcomed = true
        end
    end

    def repl_welcome
        client = "#{@nick}!#{@user}@#{@peername}"
        reply :numeric, RPL_WELCOME, @nick, "Welcome to this IRC server #{client}"
    end

    def repl_yourhost
        reply :numeric, RPL_YOURHOST, @nick, "Your host is #{@host}, running version #{@ver}"
    end

    def repl_created
        reply :numeric, RPL_CREATED, @nick, "This server was created #{@starttime}"
    end

    def repl_myinfo
        reply :numeric, RPL_MYINFO, @nick, "#{@host} #{@ver} #{@serv.usermodes} #{@serv.channelmodes}"
    end

    def repl_bounce(sever, port)
        reply :numeric, RPL_BOUNCE ,"Try server #{server}, port #{port}"
    end

    def repl_ison()
        #XXX TODO
        reply :numeric, RPL_ISON,"notimpl"
    end

    def repl_away()
        @away = true
        #XXX TODO
        reply :numeric, RPL_AWAY,"notimpl"
    end

    def repl_unaway()
        #XXX TODO
        @away = false
        reply :numeric, RPL_UNAWAY, @nick,"You are no longer marked as being away"
    end

    def repl_nowaway()
        #XXX TODO
        reply :numeric, RPL_NOWAWAY, @nick,"You have been marked as being away"
    end

    def repl_motd()
        reply :numeric, RPL_MOTDSTART,'', "- Message of the Day"
        reply :numeric, RPL_MOTD,'',      "- Do the dance see the source"
        reply :numeric, RPL_ENDOFMOTD,'', "- End of /MOTD command."
    end

    def repl_mode()
    end


    def send_nonick(nick)
        reply :numeric, ERR_NOSUCHNICK, nick, "No such nick/channel"
    end

    def send_nochannel(channel)
        reply :numeric, ERR_NOSUCHCHANNEL, channel, "That channel doesn't exist"
    end

    def send_topic(channel)
        reply :numeric, RPL_TOPIC,channel, "#{ChannelStore[channel].topic}"
    end

    def names(channel)
        return ChannelStore[channel].names
    end

    def send_nameslist(channel)
        c =  ChannelStore[channel]
        if c.nil?
            carp "names failed :#{c}"
            return 
        end
        names = []
        c.eachuser {|user|
            names << c.mode(user) + user.nick if user.nick
        }
        reply :numeric, RPL_NAMREPLY,"= #{c.name}","#{names.join(' ')}"
        reply :numeric, RPL_ENDOFNAMES,"#{c.name} ","End of /NAMES list."
    end

    def send_ping()
        reply :ping, "#{$config['hostname']}"
    end

    def handle_join(channels)
        channels.split(/,/).each {|ch|
            c = ch.strip
            if c !~ CHANNEL
                send_nochannel(c)
                carp "no such channel:#{c}"
                return
            end
            channel = ChannelStore.add(c)
            if channel.join(self)
                send_topic(c)
                send_nameslist(c)
                @channels << c
            else
                carp "already joined #{c}"
            end
        }
    end

    def handle_ping(pingmsg, rest)
        reply :pong, pingmsg
    end

    def handle_pong(srv)
        carp "got pong: #{srv}"
    end

    def handle_privmsg(target, msg)
        case target.strip
        when CHANNEL
            channel= ChannelStore[target]
            if !channel.nil?
                channel.privatemsg(msg, self)
            else
                send_nonick(target)
            end
        else
            user = UserStore[target]
            if !user.nil?
                user.reply :privmsg, self.userprefix, user.nick, msg
            else
                send_nonick(target)
            end
        end
    end

    def handle_notice(target, msg)
        case target.strip
        when CHANNEL
            channel= ChannelStore[target]
            if !channel.nil?
                channel.notice(msg, self)
            else
                send_nonick(target)
            end
        else
            user = UserStore[target]
            if !user.nil?
                user.reply :notice, self.userprefix, user.nick, msg
            else
                send_nonick(target)
            end
        end
    end

    def handle_part(channel, msg)
        @channels.delete(channel)
        ChannelStore[channel].part(self, msg)
    end

    def handle_quit(msg)
        #do this to avoid double quit due to 2 threads.
        return if !@alive
        @alive = false
        @channels.each do |channel|
            ChannelStore[channel].quit(self, msg)
        end
        UserStore.delete(self.nick)
        carp "#{self.nick} #{msg}"
        @socket.close if !@socket.closed?
    end

    def handle_topic(channel, topic)
        carp "handle topic for #{channel}:#{topic}"
        if topic.nil? or topic =~ /^ *$/
            send_topic(channel)
        else
            begin
                ChannelStore[channel].topic(topic)
            rescue Exception => e
                carp e
            end
        end
    end

    def handle_list(channel)
    end

    def handle_whois(nick)
    end

    def handle_names(channels, server)
        channels.split(/,/).each {|ch| send_nameslist(ch.strip) }
    end

    def handle_who(mask, rest)
        channel = ChannelStore[mask]
        hopcount = 0
        if channel.nil?
            #match against all users
            UserStore.each {|user|
                reply :numeric, RPL_WHOREPLY ,
                    "#{user.channels[0]} #{user.userprefix} #{user.host} #{$config['hostname']} #{user.nick} H" , 
                    "#{hopcount} #{user.realname}" if File.fnmatch?(mask, "#{user.host}.#{user.realname}.#{user.nick}")
            }
            reply :numeric, RPL_ENDOFWHO, mask, "End of /WHO list."
        else
            #get all users in the channel
            channel.eachuser {|user|
                reply :numeric, RPL_WHOREPLY ,
                    "#{mask} #{user.userprefix} #{user.host} #{$config['hostname']} #{user.nick} H" , 
                    "#{hopcount} #{user.realname}"
            }
            reply :numeric, RPL_ENDOFWHO, mask, "End of /WHO list."
        end
    end

    def handle_mode(target, rest)
        #TODO: dummy
        reply :mode, target, rest
    end

    def handle_userhost(nicks)
        info = []
        nicks.split(/,/).each {|nick|
            user = UserStore[nick]
            info << user.nick + '=-' + user.nick + '@' + user.peer
        }
        reply :numeric, RPL_USERHOST,"", info.join(' ')
    end

    def handle_reload(password)
    end

    def handle_abort()
        handle_quit('aborted..')
    end

    def handle_version()
        reply :numeric, RPL_VERSION,"0.3 Ruby IRCD", ""
    end
    
    def handle_eval(s)
        reply :raw, eval(s)
    end

    def handle_unknown(s)
        carp "unknown:>#{s}<"
        reply :numeric, ERR_UNKNOWNCOMMAND,s, "Unknown command"
    end

    def handle_connect
        reply :raw, "NOTICE AUTH :#{$config['version']} initialized, welcome."
    end
    
    def reply(method, *args)
        case method
        when :raw
            arg = *args
            raw arg
        when :ping
            host = *args
            raw "PING :#{host}"
        when :pong
            msg = *args
            raw "#{@host} PONG #{@peername} :#{msg}"
        when :join
            user,channel = args
            raw "#{user} JOIN :#{channel}"
        when :part
            user,channel,msg = args
            raw "#{user} PART #{channel} :#{msg}"
        when :quit
            user,msg = args
            raw "#{user} QUIT :#{msg}"
        when :privmsg
            usermsg, channel, msg = args
            raw "#{usermsg} PRIVMSG #{channel} :#{msg}"
        when :notice
            usermsg, channel, msg = args
            raw "#{usermsg} NOTICE #{channel} :#{msg}"
        when :topic
            usermsg, channel, msg = args
            raw "#{usermsg} TOPIC #{channel} :#{msg}"
        when :nick
            nick = *args
            raw "#{@usermsg} NICK :#{nick}"
        when :mode
            nick, rest = args
            raw "#{@usermsg} MODE #{nick} :#{rest}"
        when :numeric
            numeric,msg,detail = args
            server = $config['hostname']
            raw ":#{server} #{'%03d'%numeric} #{@nick} #{msg} :#{detail}"
        end
    end
    
    def raw(arg, abrt=false)
        begin
        carp "--> #{arg}"
        @socket.print arg.chomp + "\n" if !arg.nil?
        rescue Exception => e
            carp "<#{self.userprefix}>#{e.message}"
            #puts e.backtrace.join("\n")
            handle_abort()
            raise e if abrt
        end
    end
end

class ProxyClient < IRCClient

    def initialize(nick, actor, serv)
        carp "Initializing service #{nick}"
        @nick = nick
        super(nil,serv)
        @conn = IrcClient::ProxyConnector.new(nick,'pass',self,actor)
    end

    def peer
        return @nick
    end

    def handle_connect
        @conn.connect
    end

    def getnick(user)
        if user =~ /(^[^!]+)!.*/
            return $1
        else
            return user
        end
    end

    def reply(method, *args)
        case method
        when :raw
            arg = *args
            @conn.invoke :unknown, arg
        when :ping
            host = *args
            @conn.invoke :ping, host
        when :pong
            msg = *args
            @conn.invoke :pong, msg
        when :join
            user,channel = args
            @conn.invoke :join, getnick(user), channel
        when :privmsg
            user, channel, msg = args
            @conn.invoke :privmsg, getnick(user), channel, msg
        when :notice
            user, channel, msg = args
            @conn.invoke :notice, getnick(user), channel, msg
        when :topic
            user, channel, msg = args
            @conn.invoke :topic, getnick(user), channel, msg
        when :nick
            nick = *args
            @conn.invoke :nick, nick
        when :mode
            nick, rest = args
            @conn.invoke :mode, nick, rest
        when :numeric
            numeric,msg,detail = args
            server = $config['hostname']
            @conn.invoke :numeric, server, numeric, msg, detail
        end
    end

    #From the local services
    def invoke(method, *args)
        case method
        when :pong
            server = *args
            handle_pong server
        when :pass
            pass = *args
            handle_pass pass
        when :nick
            nick = *args
            handle_nick nick
        when :user
            user, mode, vhost, realname = args
            handle_user user, mode, vhost, realname
        when :names
            channel, serv = *args
            handle_names channel, serv
        when :join
            channel = *args
            handle_join channel
        when :part
            channel, msg = args
            handle_part channel, msg
        when :quit
            msg = args
            handle_quit msg
        when :privmsg
            channel, msg = args
            handle_privmsg channel, msg
        else
            handle_unknown "#{method} #{args.join(',')}"
        end
    end
end

class IRCServer < WEBrick::GenericServer
    include NetUtils
    def usermodes
        return "aAbBcCdDeEfFGhHiIjkKlLmMnNopPQrRsStUvVwWxXyYzZ0123459*@"
    end

    def channelmodes
        return "bcdefFhiIklmnoPqstv"
    end

    def run(sock)
        client = IRCClient.new(sock, self)
        client.handle_connect
        irc_listen(sock, client)
    end

    def addservice(nick,actor)
        carp "Add service #{nick}"
        client = ProxyClient.new(nick, actor, self)
        client.handle_connect
        #the client is able to call the methods directly
        #so we dont need to bother about looping here.
    end

    def hostname
        begin
            sockaddr = @socket.getsockname
            begin
                return Socket.getnameinfo(sockaddr, Socket::NI_NAMEREQD).first
            rescue 
                return Socket.getnameinfo(sockaddr).first
            end
        rescue
            return @socket.peeraddr[2]
        end
    end

    def irc_listen(sock, client)
        begin
            while !sock.closed? && !sock.eof?
                s = sock.gets
                handle_client_input(s.chomp, client)
            end
        rescue Exception => e
            carp e
        end
        client.handle_abort()
    end

    def handle_client_input(input, client)
        carp "<-- #{input}"
        s = if input =~ PREFIX
                $1
            else
                input
            end
        case s
        when /^[ ]*$/
            return
        when /^PASS +(.+)$/i
            client.handle_pass($1.strip)
        when /^NICK +(.+)$/i
            client.handle_nick($1.strip) #done
        when /^USER +([^ ]+) +([0-9]+) +([^ ]+) +:(.*)$/i
            client.handle_user($1, $2, $3, $4) #done
        when /^USER +([^ ]+) +([0-9]+) +([^ ]+) +:*(.*)$/i
            #opera does this.
            client.handle_user($1, $2, $3, $4) #done
        when /^USER ([^ ]+) +[^:]*:(.*)/i
            #chatzilla does this.
            client.handle_user($1, '', '', $3) #done
        when /^JOIN +(.+)$/i
            client.handle_join($1) #done
        when /^PING +([^ ]+) *(.*)$/i
            client.handle_ping($1, $2) #done
        when /^PONG +:(.+)$/i , /^PONG +(.+)$/i
            client.handle_pong($1)
        when /^PRIVMSG +([^ ]+) +:(.*)$/i
            client.handle_privmsg($1, $2) #done
        when /^NOTICE +([^ ]+) +(.*)$/i
            client.handle_notice($1, $2) #done
        when /^PART +([^ ]+) *(.*)$/i
            client.handle_part($1, $2) #done
        when /^QUIT :(.*)$/i
            client.handle_quit($1) #done
        when /^QUIT *(.*)$/i
            client.handle_quit($1) #done
        when /^TOPIC +([^ ]+) *:*(.*)$/i
            client.handle_topic($1, $2) #done
        when /^LIST *(.*)$/i
            client.handle_list($1)
        when /^WHOIS +(.+)$/i
            client.handle_whois($1)
        when /^WHO +([^ ]+) *(.*)$/i
            client.handle_who($1, $2)
        when /^NAMES +([^ ]+) *(.*)$/i
            client.handle_names($1, $2)
        when /^MODE +([^ ]+) *(.*)$/i
            client.handle_mode($1, $2)
        when /^USERHOST +:(.+)$/i
            #besirc does this (not accourding to RFC 2812)
            client.handle_userhost($1)
        when /^USERHOST +(.+)$/i
            client.handle_userhost($1)
        when /^RELOAD +(.+)$/i
            client.handle_reload($1)
        when /^VERSION *$/i
            client.handle_version()
        when /^EVAL (.*)$/i
            #strictly for debug
            client.handle_eval($1)
        else
            client.handle_unknown(s)
        end
    end

    def do_ping()
        while true
            sleep 60
            UserStore.each {|client|
                client.send_ping
            }
        end
    end
end


if __FILE__ == $0
    #require 'ircclient'
    s = IRCServer.new( :Port => $config['port'] )
    begin
        while arg = ARGV.shift
            case arg
            when /-v/
                $verbose = true
            end
        end
        trap("INT"){ 
            s.carp "killing #{$$}"
            system("kill -9 #{$$}")
            s.shutdown
        }
        p = Thread.new {
            s.do_ping()
        }
        
        #s.addservice('serviceclient',IrcClient::TestActor)
        s.start

        #p.join
    rescue Exception => e
        s.carp e
    end
end
