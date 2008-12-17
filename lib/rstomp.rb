#   Copyright 2005-2006 Brian McCallister
#   Copyright 2006 LogicBlaze Inc.
#   Copyright 2008 Sean O'Halpin
#   - refactored to use params hash
#   - made more 'ruby-like'
#   - use logger instead of $stderr
#
#   Licensed under the Apache License, Version 2.0 (the "License");
#   you may not use this file except in compliance with the License.
#   You may obtain a copy of the License at
#
#       http://www.apache.org/licenses/LICENSE-2.0
#
#   Unless required by applicable law or agreed to in writing, software
#   distributed under the License is distributed on an "AS IS" BASIS,
#   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#   See the License for the specific language governing permissions and
#   limitations under the License.

require 'io/wait'
require 'socket'
require 'thread'
require 'stringio'
require 'logger'

if $DEBUG
  require 'pp'
end

module RStomp
  class RStompException < Exception
  end
  class ConnectionError < RStompException
  end
  class ReceiveError < RStompException
  end
  class InvalidContentLengthError < RStompException
  end
  class TransmitError < RStompException
  end
  class NoListenerError < RStompException
  end
  class NoDataError < RStompException
  end
  class InvalidFrameTerminationError < RStompException
  end

  # Low level connection which maps commands and supports
  # synchronous receives
  class Connection
    attr_reader :current_host, :current_port

    DEFAULT_OPTIONS = {
      :user => "",
      :password => "",
      :host => 'localhost',
      :port => 61613,
      :reliable => false,
      :reconnect_delay => 5,
      :client_id => nil,
      :logfile => STDERR,
      :logger => nil,
      }

    # make them attributes
    DEFAULT_OPTIONS.each do |key, value|
      attr_accessor key
    end

    def Connection.open(params = {})
      params = DEFAULT_OPTIONS.merge(params)
      Connection.new(params)
    end

    # Create a connection
    # Options:
    # - :user => ''
    # - :password => ''
    # - :host => 'localhost'
    # - :port => 61613
    # - :reliable => false    (will keep retrying to send if true)
    # - :reconnect_delay => 5 (seconds)
    # - :client_id => nil     (used in durable subscriptions)
    # - :logfile => STDERR
    # - :logger => Logger.new(params[:logfile])
    #
    def initialize(params = {})
      params = DEFAULT_OPTIONS.merge(params)
      @host = params[:host]
      @port = params[:port]
      @secondary_host = params[:secondary_host]
      @secondary_port = params[:secondary_port]
      
      @current_host = @host
      @current_port = @port

      @user = params[:user]
      @password = params[:password]
      @reliable = params[:reliable]
      @reconnect_delay = params[:reconnect_delay]
      @client_id = params[:client_id]
      @logfile = params[:logfile]
      @logger = params[:logger] || Logger.new(@logfile)

      @transmit_semaphore = Mutex.new
      @read_semaphore = Mutex.new
      @socket_semaphore = Mutex.new

      @subscriptions = {}
      @failure = nil
      @socket = nil
      @open = false

      socket
    end

    def socket
      # Need to look into why the following synchronize does not work. (SOH: fixed)
      # SOH: Causes Exception ThreadError 'stopping only thread note: use sleep to stop forever' at 235
      # SOH: because had nested synchronize in _receive - take outside _receive (in receive) and seems OK
      @socket_semaphore.synchronize do
        s = @socket
        headers = {
          :user => @user,
          :password => @password
          }
        headers['client-id'] = @client_id unless @client_id.nil?
        # logger.debug "headers = #{headers.inspect} client_id = #{ @client_id }"
        while s.nil? or @failure != nil
          begin
            #p [:connecting, :socket, s, :failure, @failure, @failure.class.ancestors, :closed, closed?]
            # logger.info( { :status => :connecting, :host => host, :port => port }.inspect )
            @failure = nil

            s = TCPSocket.open(@current_host, @current_port)

            _transmit(s, "CONNECT", headers)
            @connect = _receive(s)
            @open = true

            # replay any subscriptions.
            @subscriptions.each { |k, v| _transmit(s, "SUBSCRIBE", v) }
          rescue Interrupt => e
            #p [:interrupt, e]
#          rescue Exception => e
          rescue RStompException, SystemCallError => e
            #p [:Exception, e]
            @failure = e
            # ensure socket is closed
            begin
              s.close if s
            rescue Object => e
            end
            s = nil
            @open = false

            switch_host_and_port unless @secondary_host.empty?

            handle_error ConnectionError, "connect failed: '#{e.message}' will retry in #{@reconnect_delay} on #{@current_host} port #{@current_port}", host.empty?
            sleep(@reconnect_delay)
          end
        end
        @socket = s
      end
    end
    
    def switch_host_and_port
      # Try connecting to the slave instead
      # Or if the slave goes down, connect back to the master
      # if it's not a reliable queue, then if the slave queue doesn't work then fail
      if !@reliable && ((@current_host == @secondary_host) && (@current_port == @secondary_port))
        @current_host = ''
        @current_port = ''
      else # switch the host from primary to secondary (or back again)
        @current_host = (@current_host == @current_host ? @secondary_host : @current_host)
        @current_port = (@current_port == @current_port ? @secondary_port : @current_port)
      end
    end

    # Is this connection open?
    def open?
      @open
    end

    # Is this connection closed?
    def closed?
      !open?
    end

    # Begin a transaction, requires a name for the transaction
    def begin(name, headers = {})
      headers[:transaction] = name
      transmit "BEGIN", headers
    end

    # Acknowledge a message, used then a subscription has specified
    # client acknowledgement ( connection.subscribe "/queue/a", :ack => 'client' )
    #
    # Accepts a transaction header ( :transaction => 'some_transaction_id' )
    def ack(message_id, headers = {})
      headers['message-id'] = message_id
      transmit "ACK", headers
    end

    # Commit a transaction by name
    def commit(name, headers = {})
      headers[:transaction] = name
      transmit "COMMIT", headers
    end

    # Abort a transaction by name
    def abort(name, headers = {})
      headers[:transaction] = name
      transmit "ABORT", headers
    end

    # Subscribe to a destination, must specify a name
    def subscribe(name, headers = {}, subscription_id = nil)
      headers[:destination] = name
      transmit "SUBSCRIBE", headers

      # Store the sub so that we can replay if we reconnect.
      if @reliable
        subscription_id = name if subscription_id.nil?
        @subscriptions[subscription_id]=headers
      end
    end

    # Unsubscribe from a destination, must specify a name
    def unsubscribe(name, headers = {}, subscription_id = nil)
      headers[:destination] = name
      transmit "UNSUBSCRIBE", headers
      if @reliable
        subscription_id = name if subscription_id.nil?
        @subscriptions.delete(subscription_id)
      end
    end

    # Send message to destination
    #
    # Accepts a transaction header ( :transaction => 'some_transaction_id' )
    def send(destination, message, headers = {})
      headers[:destination] = destination
      transmit "SEND", headers, message
    end

    # drain socket
    def discard_all_until_eof
      @read_semaphore.synchronize do
        while @socket do
          break if @socket.gets.nil?
        end
      end
    end
    private :discard_all_until_eof

    # Close this connection
    def disconnect(headers = {})
      transmit "DISCONNECT", headers
      discard_all_until_eof
      begin
        @socket.close
      rescue Object => e
      end
      @socket = nil
      @open = false
    end

    # Return a pending message if one is available, otherwise
    # return nil
    def poll
      @read_semaphore.synchronize do
        if @socket.nil? or !@socket.ready?
          nil
        else
          receive
        end
      end
    end

    # Receive a frame, block until the frame is received
    def receive
      # The receive may fail so we may need to retry.
      # TODO: use retry count?
      while true
        begin
          s = socket
          rv = _receive(s)
          return rv
#        rescue Interrupt
#          raise
        rescue RStompException, SystemCallError => e
          @failure = e
          handle_error ReceiveError, "receive failed: #{e.message}"
          # TODO: maybe sleep here?
        end
      end
    end

    private
    def _receive( s )
      #logger.debug "_receive"
      line = ' '
      @read_semaphore.synchronize do
        #logger.debug "inside semaphore"
        # skip blank lines
        while line =~ /^\s*$/
          #logger.debug "skipping blank line " + s.inspect
          line = s.gets
        end
        if line.nil?
          # FIXME: this loses data - maybe retry here if connection returns nil?
          raise NoDataError, "connection returned nil"
          nil
        else
          #logger.debug "got message data"
          Message.new do |m|
            m.command = line.chomp
            m.headers = {}
            until (line = s.gets.chomp) == ''
              k = (line.strip[0, line.strip.index(':')]).strip
              v = (line.strip[line.strip.index(':') + 1, line.strip.length]).strip
              m.headers[k] = v
            end

            if m.headers['content-length']
              m.body = s.read m.headers['content-length'].to_i
              # expect an ASCII NUL (i.e. 0)
              c = s.getc
              handle_error InvalidContentLengthError, "Invalid content length received" unless c == 0
            else
              m.body = ''
              until (c = s.getc) == 0
                m.body << c.chr
              end
            end
            if $DEBUG
              logger.debug "Message #: #{m.headers['message-id']}"
              logger.debug "  Command: #{m.command}"
              logger.debug "  Headers:"
              m.headers.sort.each do |key, value|
                logger.debug "    #{key}: #{m.headers[key]}"
              end
              logger.debug "  Body: [#{m.body}]\n"
            end
            m
            #c = s.getc
            #handle_error InvalidFrameTerminationError, "Invalid frame termination received" unless c == 10
          end
        end
      end
    end

    private

    # route all error handling through this method
    def handle_error(exception_class, error_message, force_raise = !@reliable)
      logger.warn error_message
      # if not an internal exception, then raise
      if !(exception_class <= RStompException)
        force_raise = true
      end
      raise exception_class, error_message if force_raise
    end

    def transmit(command, headers = {}, body = '')
      # The transmit may fail so we may need to retry.
      # Maybe use retry count?
      while true
        begin
          _transmit(socket, command, headers, body)
          return
#        rescue Interrupt
#          raise
        rescue RStompException, SystemCallError => e
          @failure = e
          handle_error TransmitError, "transmit '#{command}' failed: #{e.message} (#{body})"
        end
        # TODO: sleep here?
      end
    end

    private
    def _transmit(s, command, headers={}, body='')
      msg = StringIO.new
      msg.puts command
      headers.each {|k, v| msg.puts "#{k}: #{v}" }
      msg.puts "content-length: #{body.nil? ? 0 : body.length}"
      msg.puts "content-type: text/plain; charset=UTF-8"
      msg.puts
      msg.write body
      msg.write "\0"
      if $DEBUG
        msg.rewind
        logger.debug "_transmit"
        msg.read.each_line do |line|
          logger.debug line.chomp
        end
      end
      msg.rewind
      @transmit_semaphore.synchronize do
        s.write msg.read
      end
    end
  end

  # Container class for frames, misnamed technically
  class Message
    attr_accessor :headers, :body, :command

    def initialize(&block)
      yield(self) if block_given?
    end

    def to_s
      "<#{self.class} headers=#{headers.inspect} body=#{body.inspect} command=#{command.inspect} >"
    end
  end

  # Typical Stomp client class. Uses a listener thread to receive frames
  # from the server, any thread can send.
  #
  # Receives all happen in one thread, so consider not doing much processing
  # in that thread if you have much message volume.
  class Client

    # Accepts the same options as Connection.open
    # Also accepts a :uri parameter of form 'stomp://host:port' or 'stomp://user:password@host:port' in place
    # of :user, :password, :host and :port parameters
    def initialize(params = {})
      params = Connection::DEFAULT_OPTIONS.merge(params)
      uri = params.delete(:uri)
      if uri =~ /stomp:\/\/([\w\.]+):(\d+)/
        params[:user] = ""
        params[:password] = ""
        params[:host] = $1
        params[:port] = $2
      elsif uri =~ /stomp:\/\/([\w\.]+):(\w+)@(\w+):(\d+)/
        params[:user] = $1
        params[:password] = $2
        params[:host] = $3
        params[:port] = $4
      end

      @id_mutex = Mutex.new
      @ids = 1
      @connection = Connection.open(params)
      @listeners = {}
      @receipt_listeners = {}
      @running = true
      @replay_messages_by_txn = {}
      @listener_thread = Thread.start do
        while @running
          message = @connection.receive
          break if message.nil?
          case message.command
          when 'MESSAGE':
            if listener = @listeners[message.headers['destination']]
              listener.call(message)
            end
          when 'RECEIPT':
            if listener = @receipt_listeners[message.headers['receipt-id']]
              listener.call(message)
            end
          end
        end
      end
    end

    # Join the listener thread for this client,
    # generally used to wait for a quit signal
    def join
      @listener_thread.join
    end

    # Accepts the same options as Connection.open
    def self.open(params = {})
      params = Connection::DEFAULT_OPTIONS.merge(params)
      Client.new(params)
    end

    # Begin a transaction by name
    def begin(name, headers = {})
      @connection.begin name, headers
    end

    # Abort a transaction by name
    def abort(name, headers = {})
      @connection.abort name, headers

      # lets replay any ack'd messages in this transaction
      replay_list = @replay_messages_by_txn[name]
      if replay_list
        replay_list.each do |message|
          if listener = @listeners[message.headers['destination']]
            listener.call(message)
          end
        end
      end
    end

    # Commit a transaction by name
    def commit(name, headers = {})
      txn_id = headers[:transaction]
      @replay_messages_by_txn.delete(txn_id)
      @connection.commit(name, headers)
    end

    # Subscribe to a destination, must be passed a block taking one parameter (the message)
    # which will be used as a callback listener
    #
    # Accepts a transaction header ( :transaction => 'some_transaction_id' )
    def subscribe(destination, headers = {}, &block)
      handle_error NoListenerError, "No listener given" unless block_given?
      @listeners[destination] = block
      @connection.subscribe(destination, headers)
    end

    # Unsubscribe from a channel
    def unsubscribe(name, headers = {})
      @connection.unsubscribe name, headers
      @listeners[name] = nil
    end

    # Acknowledge a message, used when a subscription has specified
    # client acknowledgement ( connection.subscribe "/queue/a", :ack => 'client' )
    #
    # Accepts a transaction header ( :transaction => 'some_transaction_id' )
    def acknowledge(message, headers = {}, &block)
      txn_id = headers[:transaction]
      if txn_id
        # lets keep around messages ack'd in this transaction in case we rollback
        replay_list = @replay_messages_by_txn[txn_id]
        if replay_list.nil?
          replay_list = []
          @replay_messages_by_txn[txn_id] = replay_list
        end
        replay_list << message
      end
      if block_given?
        headers['receipt'] = register_receipt_listener(block)
      end
      @connection.ack(message.headers['message-id'], headers)
    end

    # Send message to destination
    #
    # If a block is given a receipt will be requested and passed to the
    # block on receipt
    #
    # Accepts a transaction header ( :transaction => 'some_transaction_id' )
    def send(destination, message, headers = {}, &block)
      if block_given?
        headers['receipt'] = register_receipt_listener(block)
      end
      @connection.send destination, message, headers
    end

    # Is this client open?
    def open?
      @connection.open?
    end

    # Close out resources in use by this client
    def close
      @connection.disconnect
      @running = false
    end

    private
    def register_receipt_listener(listener)
      id = -1
      @id_mutex.synchronize do
        id = @ids.to_s
        @ids = @ids.succ
      end
      @receipt_listeners[id] = listener
      id
    end

  end
end
