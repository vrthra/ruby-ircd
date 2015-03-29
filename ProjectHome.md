ruby-ircd is an IRC daemon written in ruby. It extends the generic server of Webrick server.

It was created to to provide the IRC server and client implementations for [ruby-hive](http://code.google.com/p/ruby-hive) project.

[irc rfcs](http://www.irc.org/techie.html)

# Features #
  * Pure ruby
  * Light Weight
  * Supports Service Bots as threads
  * Can be extended (is a library)
  * Simple (Almost no) configuration
  * Checked with leafchat, weechat, irssi, opera, chatzilla

# Todo #
  * Chop commands [KICK, INVITE]
  * others [SERVER, OPER, SQUIT, STATS, LINKS, TIME, CONNECT, TRACE, ADMIN, INFO]
  * Check with more clients

# Usage #
```
    ircd = IRCServer.new( :Port => 6667 )
    begin
        trap("INT"){ircd.shutdown}
        p = Thread.new {ircd.do_ping()}

        # adding service bots eg:
        #ircd.addservice('TestBot',IrcClient::TestActor)
        ircd.start
    rescue Exception => e
        puts e.message
    end
```

It is intended to be simple to modify. Have a look at the source if you need
custom behavior.