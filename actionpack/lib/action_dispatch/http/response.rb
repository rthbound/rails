require 'active_support/core_ext/module/attribute_accessors'
require 'action_dispatch/http/filter_redirect'
require 'action_dispatch/http/cache'
require 'monitor'

module ActionDispatch # :nodoc:
  # Represents an HTTP response generated by a controller action. Use it to
  # retrieve the current state of the response, or customize the response. It can
  # either represent a real HTTP response (i.e. one that is meant to be sent
  # back to the web browser) or a TestResponse (i.e. one that is generated
  # from integration tests).
  #
  # \Response is mostly a Ruby on \Rails framework implementation detail, and
  # should never be used directly in controllers. Controllers should use the
  # methods defined in ActionController::Base instead. For example, if you want
  # to set the HTTP response's content MIME type, then use
  # ActionControllerBase#headers instead of Response#headers.
  #
  # Nevertheless, integration tests may want to inspect controller responses in
  # more detail, and that's when \Response can be useful for application
  # developers. Integration test methods such as
  # ActionDispatch::Integration::Session#get and
  # ActionDispatch::Integration::Session#post return objects of type
  # TestResponse (which are of course also of type \Response).
  #
  # For example, the following demo integration test prints the body of the
  # controller response to the console:
  #
  #  class DemoControllerTest < ActionDispatch::IntegrationTest
  #    def test_print_root_path_to_console
  #      get('/')
  #      puts response.body
  #    end
  #  end
  class Response
    class Header < DelegateClass(Hash) # :nodoc:
      def initialize(response, header)
        @response = response
        super(header)
      end

      def []=(k,v)
        if @response.sending? || @response.sent?
          raise ActionDispatch::IllegalStateError, 'header already sent'
        end

        super
      end

      def merge(other)
        self.class.new @response, __getobj__.merge(other)
      end

      def to_hash
        __getobj__.dup
      end
    end

    # The request that the response is responding to.
    attr_accessor :request

    # The HTTP status code.
    attr_reader :status

    # Get headers for this response.
    attr_reader :header

    alias_method :headers,  :header

    delegate :[], :[]=, :to => :@header
    delegate :each, :to => :@stream

    CONTENT_TYPE = "Content-Type".freeze
    SET_COOKIE   = "Set-Cookie".freeze
    LOCATION     = "Location".freeze
    NO_CONTENT_CODES = [100, 101, 102, 204, 205, 304]

    cattr_accessor(:default_charset) { "utf-8" }
    cattr_accessor(:default_headers)

    include Rack::Response::Helpers
    # Aliasing these off because AD::Http::Cache::Response defines them
    alias :_cache_control :cache_control
    alias :_cache_control= :cache_control=

    include ActionDispatch::Http::FilterRedirect
    include ActionDispatch::Http::Cache::Response
    include MonitorMixin

    class Buffer # :nodoc:
      def initialize(response, buf)
        @response = response
        @buf      = buf
        @closed   = false
        @str_body = nil
      end

      def body
        @str_body ||= begin
                        buf = ''
                        each { |chunk| buf << chunk }
                        buf
                      end
      end

      def write(string)
        raise IOError, "closed stream" if closed?

        @str_body = nil
        @response.commit!
        @buf.push string
      end

      def each(&block)
        x = @buf.each(&block)
        x
      end

      def abort
      end

      def close
        @response.commit!
        @closed = true
      end

      def closed?
        @closed
      end
    end

    def self.create(status = 200, header = {}, body = [], default_headers: self.default_headers)
      header = merge_default_headers(header, default_headers)
      new status, header, body
    end

    def self.merge_default_headers(original, default)
      default.respond_to?(:merge) ? default.merge(original) : original
    end

    # The underlying body, as a streamable object.
    attr_reader :stream

    def initialize(status = 200, header = {}, body = [])
      super()

      @header = Header.new(self, header)

      self.body, self.status = body, status

      @cv           = new_cond
      @committed    = false
      @sending      = false
      @sent         = false

      prepare_cache_control!

      yield self if block_given?
    end

    def has_header?(key);   headers.key? key;   end
    def get_header(key);    headers[key];       end
    def set_header(key, v); headers[key] = v;   end
    def delete_header(key); headers.delete key; end

    def await_commit
      synchronize do
        @cv.wait_until { @committed }
      end
    end

    def await_sent
      synchronize { @cv.wait_until { @sent } }
    end

    def commit!
      synchronize do
        before_committed
        @committed = true
        @cv.broadcast
      end
    end

    def sending!
      synchronize do
        before_sending
        @sending = true
        @cv.broadcast
      end
    end

    def sent!
      synchronize do
        @sent = true
        @cv.broadcast
      end
    end

    def sending?;   synchronize { @sending };   end
    def committed?; synchronize { @committed }; end
    def sent?;      synchronize { @sent };      end

    # Sets the HTTP status code.
    def status=(status)
      @status = Rack::Utils.status_code(status)
    end

    # Sets the HTTP content type.
    def content_type=(content_type)
      header_info = parse_content_type
      set_content_type content_type.to_s, header_info.charset || self.class.default_charset
    end

    # Sets the HTTP response's content MIME type. For example, in the controller
    # you could write this:
    #
    #  response.content_type = "text/plain"
    #
    # If a character set has been defined for this response (see charset=) then
    # the character set information will also be included in the content type
    # information.

    def content_type
      parse_content_type.mime_type
    end

    def sending_file=(v)
      if true == v
        self.charset = false
      end
    end

    # Sets the HTTP character set. In case of nil parameter
    # it sets the charset to utf-8.
    #
    #   response.charset = 'utf-16' # => 'utf-16'
    #   response.charset = nil      # => 'utf-8'
    def charset=(charset)
      header_info = parse_content_type
      if false == charset
        set_header CONTENT_TYPE, header_info.mime_type
      else
        content_type = header_info.mime_type
        set_content_type content_type, charset || self.class.default_charset
      end
    end

    # The charset of the response. HTML wants to know the encoding of the
    # content you're giving them, so we need to send that along.
    def charset
      header_info = parse_content_type
      header_info.charset || self.class.default_charset
    end

    # The response code of the request.
    def response_code
      @status
    end

    # Returns a string to ensure compatibility with <tt>Net::HTTPResponse</tt>.
    def code
      @status.to_s
    end

    # Returns the corresponding message for the current HTTP status code:
    #
    #   response.status = 200
    #   response.message # => "OK"
    #
    #   response.status = 404
    #   response.message # => "Not Found"
    #
    def message
      Rack::Utils::HTTP_STATUS_CODES[@status]
    end
    alias_method :status_message, :message

    # Returns the content of the response as a string. This contains the contents
    # of any calls to <tt>render</tt>.
    def body
      @stream.body
    end

    def write(string)
      @stream.write string
    end

    # Allows you to manually set or override the response body.
    def body=(body)
      if body.respond_to?(:to_path)
        @stream = body
      else
        synchronize do
          @stream = build_buffer self, munge_body_object(body)
        end
      end
    end

    # Avoid having to pass an open file handle as the response body.
    # Rack::Sendfile will usually intercept the response and uses
    # the path directly, so there is no reason to open the file.
    class FileBody #:nodoc:
      attr_reader :to_path

      def initialize(path)
        @to_path = path
      end

      def body
        File.binread(to_path)
      end

      # Stream the file's contents if Rack::Sendfile isn't present.
      def each
        File.open(to_path, 'rb') do |file|
          while chunk = file.read(16384)
            yield chunk
          end
        end
      end
    end

    # Send the file stored at +path+ as the response body.
    def send_file(path)
      commit!
      @stream = FileBody.new(path)
    end

    def reset_body!
      @stream = build_buffer(self, [])
    end

    def body_parts
      parts = []
      @stream.each { |x| parts << x }
      parts
    end

    # The location header we'll be responding with.
    alias_method :redirect_url, :location

    def close
      stream.close if stream.respond_to?(:close)
    end

    def abort
      if stream.respond_to?(:abort)
        stream.abort
      elsif stream.respond_to?(:close)
        # `stream.close` should really be reserved for a close from the
        # other direction, but we must fall back to it for
        # compatibility.
        stream.close
      end
    end

    # Turns the Response into a Rack-compatible array of the status, headers,
    # and body. Allows explicit splatting:
    #
    #   status, headers, body = *response
    def to_a
      commit!
      rack_response @status, @header.to_hash
    end
    alias prepare! to_a

    # Returns the response cookies, converted to a Hash of (name => value) pairs
    #
    #   assert_equal 'AuthorOfNewPage', r.cookies['author']
    def cookies
      cookies = {}
      if header = get_header(SET_COOKIE)
        header = header.split("\n") if header.respond_to?(:to_str)
        header.each do |cookie|
          if pair = cookie.split(';').first
            key, value = pair.split("=").map { |v| Rack::Utils.unescape(v) }
            cookies[key] = value
          end
        end
      end
      cookies
    end

  private

    ContentTypeHeader = Struct.new :mime_type, :charset
    NullContentTypeHeader = ContentTypeHeader.new nil, nil

    def parse_content_type
      content_type = get_header CONTENT_TYPE
      if content_type
        type, charset = content_type.split(/;\s*charset=/)
        type = nil if type.empty?
        ContentTypeHeader.new(type, charset)
      else
        NullContentTypeHeader
      end
    end

    def set_content_type(content_type, charset)
      type = (content_type || '').dup
      type << "; charset=#{charset}" if charset
      set_header CONTENT_TYPE, type
    end

    def before_committed
      return if committed?
      assign_default_content_type_and_charset!
      handle_conditional_get!
      handle_no_content!
    end

    def before_sending
      # Normally we've already committed by now, but it's possible
      # (e.g., if the controller action tries to read back its own
      # response) to get here before that. In that case, we must force
      # an "early" commit: we're about to freeze the headers, so this is
      # our last chance.
      commit! unless committed?

      headers.freeze
      request.commit_cookie_jar! unless committed?
    end

    def build_buffer(response, body)
      Buffer.new response, body
    end

    def munge_body_object(body)
      body.respond_to?(:each) ? body : [body]
    end

    def assign_default_content_type_and_charset!
      return if content_type

      ct = parse_content_type
      set_content_type(ct.mime_type || Mime[:html].to_s,
                       ct.charset || self.class.default_charset)
    end

    class RackBody
      def initialize(response)
        @response = response
      end

      def each(*args, &block)
        @response.each(*args, &block)
      end

      def close
        # Rack "close" maps to Response#abort, and *not* Response#close
        # (which is used when the controller's finished writing)
        @response.abort
      end

      def body
        @response.body
      end

      def respond_to?(method, include_private = false)
        if method.to_s == 'to_path'
          @response.stream.respond_to?(method)
        else
          super
        end
      end

      def to_path
        @response.stream.to_path
      end

      def to_ary
        nil
      end
    end

    def handle_no_content!
      if NO_CONTENT_CODES.include?(@status)
        @header.delete CONTENT_TYPE
        @header.delete 'Content-Length'
      end
    end

    def rack_response(status, header)
      if NO_CONTENT_CODES.include?(status)
        [status, header, []]
      else
        [status, header, RackBody.new(self)]
      end
    end
  end
end
