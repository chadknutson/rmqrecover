require "option_parser"
require "io/hexdump"
require "amqp-client"

class RMQRecover
  VERSION = "1.1.1"

  record Message,
    exchange : String,
    routing_key : String,
    properties : AMQP::Client::Properties,
    body : IO::Memory

  def initialize(@root : String, @hexdump = false)
  end

  def republish(uri_str)
    uri = URI.parse(uri_str)
    vhosts(@root) do |vhost, vhost_path|
      i = 0
      begin
        uri.path = "/#{URI.encode_www_form(vhost)}"
        AMQP::Client.start(uri) do |amqp|
          ch = amqp.channel
          messages(vhost_path) do |msg|
            ch.basic_publish msg.body, msg.exchange, msg.routing_key, props: msg.properties
            i += 1
          end
        end
      ensure
        puts "Republished #{i} messages to vhost #{vhost}"
      end
    end
  rescue ex
    {% if flag?(:release) %}
      abort ex.message
    {% else %}
      raise ex
    {% end %}
  end

  def report
    vhosts(@root) do |vhost, vhost_path|
      i = 0
      messages(vhost_path) do |msg|
        i += 1
      end
      puts "Found #{i} messages in vhost #{vhost}"
    end
  rescue ex
    {% if flag?(:release) %}
      abort ex.message
    {% else %}
      raise ex
    {% end %}
  end

  # finds vhost directories in a directy
  # yields the name of the vhost and the path to it
  private def vhosts(path, &blk : String, String -> Nil)
    Dir.each_child(path) do |c|
      f = File.join path, c
      if c == ".vhost"
        yield File.read(f), path
      elsif File.directory? f
        vhosts(f, &blk)
      end
    end
  end

  # recursivly find files with extension 'idx' or 'rdq'
  # yields matching paths
  private def message_files(path, &blk : String -> Nil)
    Dir.each_child(path) do |c|
      f = File.join(path, c)
      if c.ends_with?(".idx") || c.ends_with?(".rdq")
        yield f
      elsif File.directory? f
        message_files f, &blk
      end
    end
  end

  # recurisvly extract all messages from a directory
  private def messages(path, &blk : Message -> Nil)
    message_files(path) do |file|
      File.open(file) do |f|
        f.buffer_size = 1024 * 1024
        if @hexdump
          STDERR.puts file
          io = IO::Hexdump.new(f, read: true)
          extract io, File.extname(file), &blk
        else
          extract f, File.extname(file), &blk
        end
      rescue ex
        STDERR.puts "#{file}:#{f.pos}"
        raise ex
      end
    end
  end

  # Yields messages from a rabbitmq message file
  # currently only reads exchange, routing key and body
  # erlang binary format description:
  # http://erlang.org/doc/apps/erts/erl_ext_dist.html
  private def extract(io, ext, &blk : Message -> Nil)
    body = IO::Memory.new
    loop do
      case ext
      when ".idx"
        skip_until(io, UInt8.static_array(0x68, 0x06))
      when ".rdq"
        io.read_bytes Int32, IO::ByteFormat::NetworkEndian # 0x00000000
        size = io.read_bytes Int32, IO::ByteFormat::NetworkEndian
        io.skip 19 # ?
      end

      value(io).as(String) == "basic_message" || raise "Expected 'basic_message'"

      expect(io, 0x68) # tuple
      expect(io, 0x04) # tuple size

      value(io).as(String) == "resource" || raise "Expected 'resource'"
      vhost = value(io).as(String)
      value(io).as(String) == "exchange" || raise "Expected 'exchange'"
      exchange = value(io).as(String)

      expect(io, 0x6c) # array
      rk_size = io.read_bytes Int32, IO::ByteFormat::NetworkEndian # 0001 array size
      rk_size == 1 || raise "Expected routing key array to have 1 element but had #{rk_size}"
      rk = value(io).as(String)
      expect(io, 0x6a) # nil, tail of array

      expect(io, 0x68) # tuple
      expect(io, 0x06) # tuple size

      value(io).as(String) == "content" || raise "Expected 'content'"
      value(io) # 0x3c (60) some small int?

      p = AMQP::Client::Properties.new delivery_mode: 2_u8

      # expect be small tuple or string "none"
      prop_type = io.read_byte || IO::EOFError.new
      case prop_type
      when 0x64 # short string
        str = io.read_string(io.read_bytes Int16, IO::ByteFormat::NetworkEndian)
        raise "Unknown properties '#{str}'" unless str == "none"
      when 0x68 # when properties is a tuple
        expect(io, 0x0f) # length of tuple

        value(io).as(String) == "P_basic" || raise "Expected 'P_basic'"

        p.content_type = value(io).as?(String)
        p.content_encoding = value(io).as?(String)

        header_type = io.read_byte || raise IO::EOFError.new
        p.headers =
          case header_type
          when 0x6a # nil
            nil
          when 0x6c # long array
            size = io.read_bytes Int32, IO::ByteFormat::NetworkEndian
            AMQ::Protocol::Table.new.tap do |h|
              size.times do
                key, value = typed_key_value(io)
                h[key] = value
              end
              expect(io, 0x6a) # nil, tail of list
            end
          else raise "Unexpected header type '%x'" % header_type
          end

        p.delivery_mode = value(io).as(UInt8)

        if priority = value(io).as?(Int)
          p.priority = priority > UInt8::MAX ? UInt8::MAX : priority.to_u8
        end

        p.correlation_id = value(io).as?(String)
        p.reply_to = value(io).as?(String)
        p.expiration = value(io).as?(String)
        p.message_id = value(io).as?(String)
        if timestamp = value(io).as?(Int)
          p.timestamp = Time.unix timestamp
        end
        p.type = value(io).as?(String)
        p.user_id = value(io).as?(String)
        p.app_id = value(io).as?(String)
        p.reserved1 = value(io).as?(String)
      else raise "Unexpected property byte %x" % prop_type
      end

      value(io) # none/garbage
      value(io) # none/"rabbitmq_framing_amqp_0_9_1"

      body_type = io.read_byte || raise IO::EOFError.new
      case body_type
      when 0x6c # array
        body_parts = io.read_bytes Int32, IO::ByteFormat::NetworkEndian
        body_parts.times do
          expect(io, 0x6d) # long string
          body_size = io.read_bytes Int32, IO::ByteFormat::NetworkEndian
          IO.copy io, body, body_size
        end
        expect(io, 0x6a) # nil, tail of list
        body.rewind
      when 0x6a
        nil
      else raise "Unexpected body type %x" % body_type
      end
      yield Message.new(exchange, rk, p, body)

      value(io) # garbage?
      value(io) # true
      case ext
      when ".rdq"
        expect(io, 0xff) # delimiter
      end
    rescue IO::EOFError
      break
    ensure
      body.clear
    end
  end

  # parse values, according to erlang term to binary format
  private def value(io) : AMQ::Protocol::Field
    type = io.read_byte || raise IO::EOFError.new
    case type
    when 0x61
      io.read_byte || raise IO::EOFError.new # uint8
    when 0x62 # int32
     io.read_bytes Int32, IO::ByteFormat::NetworkEndian
    when 0x64 # short string
      v = io.read_string(io.read_bytes Int16, IO::ByteFormat::NetworkEndian)
      v == "undefined" ? nil : v
    when 0x6a # nil
      nil
    when 0x6d # long string
      io.read_string(io.read_bytes Int32, IO::ByteFormat::NetworkEndian)
    when 0x6e # big int
      v = 0_i64
      len = io.read_byte || raise IO::EOFError.new
      sign = io.read_byte || raise IO::EOFError.new
      len.times do |i|
        d = io.read_byte || raise IO::EOFError.new
        v += (d.to_i64 * (256_i64**i))
      end
      sign.zero? ? v : -v
    else raise "Unknown data type %x" % type
    end
  end

  # parse values that are prefixed with a type name
  private def typed_value(io)
    value_type = value(io).as(String)
    case value_type
    when "bool"
      value(io).as(String) == "true"
    when "long"
      value(io)
    when "longstr"
      value(io).as(String)
    when "array"
      expect(io, 0x6c) # long array
      size = io.read_bytes Int32, IO::ByteFormat::NetworkEndian
      a = Array(AMQ::Protocol::Field).new(size) do
        expect(io, 0x68) # tuple
        expect(io, 0x02) # tuple size
        typed_value(io)
      end
      expect(io, 0x6a) # nil, tail of list
      a
    when "table"
      expect(io, 0x6c) # long array
      size = io.read_bytes Int32, IO::ByteFormat::NetworkEndian
      AMQ::Protocol::Table.new.tap do |h|
        size.times do
          key, value = typed_key_value(io)
          h[key] = value
        end
        expect(io, 0x6a) # nil, tail of list
      end
    when "timestamp"
      Time.unix value(io).as(Int32)
    else raise "Unknown header type '#{value_type}'"
    end
  end

  private def typed_key_value(io)
    expect(io, 0x68) # small tuple
    expect(io, 0x03) # tuple size

    key = value(io).as(String)
    value = typed_value(io)
    { key, value }
  end

  private def expect(io : IO, expected : UInt8) : UInt8
    b = io.read_byte || raise IO::EOFError.new
    b == expected || raise "Expected '%x', got '%x'" % { expected, b }
    b
  end

  # searches in a byte stream for a match, one byte at a time
  private def skip_until(io, slice) : Nil
    match = slice.to_slice
    window = Bytes.new(match.size)
    until window == match
      window.map_with_index! do |v, i|
        if i < window.size - 1
          window[i + 1]
        else
          io.read_byte || raise IO::EOFError.new
        end
      end
    end
  end
end

path = ""
mode = "report"
uri = ""
hexdump = false

parser = OptionParser.parse do |parser|
  parser.banner = "Usage: #{File.basename PROGRAM_NAME} [ arguments ]"
  parser.on("-D DIR", "--directory=DIR", "mnesia directory to scan") { |v| path = v }
  parser.on("-m MODE", "--mode=MODE", "report (default) or republish") { |v| mode = v }
  parser.on("-u NAME", "--uri=URI", "AMQP URI to republish to") { |v| uri = v }
  parser.on("-v", "--verbose", "Hexdump while reading") { hexdump = true }
  parser.on("--version", "Show version") { puts RMQRecover::VERSION; exit }
  parser.on("-h", "--help", "Show this help") { puts parser; exit }
  parser.invalid_option do |flag|
    STDERR.puts "ERROR: #{flag} is not a valid option."
    abort parser
  end
end

MODES = { "report", "republish" }
abort "ERROR: invalid mode" unless MODES.includes? mode
abort "ERROR: missing --directory argument" if path.empty?

r = RMQRecover.new(path, hexdump)
case mode
when "report"
  r.report
when "republish"
  abort "ERROR: missing --uri argument" if uri.empty?
  r.republish uri
end
