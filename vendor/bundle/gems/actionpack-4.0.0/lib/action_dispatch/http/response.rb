require 'active_support/core_ext/class/attribute_accessors'
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
    attr_accessor :request, :header
    attr_reader :status
    attr_writer :sending_file

    alias_method :headers=, :header=
    alias_method :headers,  :header

    delegate :[], :[]=, :to => :@header
    delegate :each, :to => :@stream

    # Sets the HTTP response's content MIME type. For example, in the controller
    # you could write this:
    #
    #  response.content_type = "text/plain"
    #
    # If a character set has been defined for this response (see charset=) then
    # the character set information will also be included in the content type
    # information.
    attr_accessor :charset
    attr_reader   :content_type

    CONTENT_TYPE = "Content-Type".freeze
    SET_COOKIE   = "Set-Cookie".freeze
    LOCATION     = "Location".freeze
    NO_CONTENT_CODES = [204, 304]

    cattr_accessor(:default_charset) { "utf-8" }
    cattr_accessor(:default_headers)

    include Rack::Response::Helpers
    include ActionDispatch::Http::FilterRedirect
    include ActionDispatch::Http::Cache::Response
    include MonitorMixin

    class Buffer # :nodoc:
      def initialize(response, buf)
        @response = response
        @buf      = buf
        @closed   = false
      end

      def write(string)
        raise IOError, "closed stream" if closed?

        @response.commit!
        @buf.push string
      end

      def each(&block)
        @buf.each(&block)
      end

      def close
        @response.commit!
        @closed = true
      end

      def closed?
        @closed
      end
    end

    attr_reader :stream

    def initialize(status = 200, header = {}, body = [])
      super()

      header = merge_default_headers(header, self.class.default_headers)

      self.body, self.header, self.status = body, header, status

      @sending_file = false
      @blank        = false
      @cv           = new_cond
      @committed    = false
      @content_type = nil
      @charset      = nil

      if content_type = self[CONTENT_TYPE]
        type, charset = content_type.split(/;\s*charset=/)
        @content_type = Mime::Type.lookup(type)
        @charset = charset || self.class.default_charset
      end

      prepare_cache_control!

      yield self if block_given?
    end

    def await_commit
      synchronize do
        @cv.wait_until { @committed }
      end
    end

    def commit!
      synchronize do
        @committed = true
        @cv.broadcast
      end
    end

    def committed?
      @committed
    end

    # Sets the HTTP status code.
    def status=(status)
      @status = Rack::Utils.status_code(status)
    end

    def content_type=(content_type)
      @content_type = content_type.to_s
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

    def respond_to?(method)
      if method.to_s == 'to_path'
        stream.respond_to?(:to_path)
      else
        super
      end
    end

    def to_path
      stream.to_path
    end

    # Returns the content of the response as a string. This contains the contents
    # of any calls to <tt>render</tt>.
    def body
      strings = []
      each { |part| strings << part.to_s }
      strings.join
    end

    EMPTY = " "

    # Allows you to manually set or override the response body.
    def body=(body)
      @blank = true if body == EMPTY

      if body.respond_to?(:to_path)
        @stream = body
      else
        @stream = build_buffer self, munge_body_object(body)
      end
    end

    def body_parts
      parts = []
      @stream.each { |x| parts << x }
      parts
    end

    def set_cookie(key, value)
      ::Rack::Utils.set_cookie_header!(header, key, value)
    end

    def delete_cookie(key, value={})
      ::Rack::Utils.delete_cookie_header!(header, key, value)
    end

    def location
      headers[LOCATION]
    end
    alias_method :redirect_url, :location

    def location=(url)
      headers[LOCATION] = url
    end

    def close
      stream.close if stream.respond_to?(:close)
    end

    def to_a
      rack_response @status, @header.to_hash
    end
    alias prepare! to_a
    alias to_ary   to_a # For implicit splat on 1.9.2

    # Returns the response cookies, converted to a Hash of (name => value) pairs
    #
    #   assert_equal 'AuthorOfNewPage', r.cookies['author']
    def cookies
      cookies = {}
      if header = self[SET_COOKIE]
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

    def merge_default_headers(original, default)
      return original unless default.respond_to?(:merge)

      default.merge(original)
    end

    def build_buffer(response, body)
      Buffer.new response, body
    end

    def munge_body_object(body)
      body.respond_to?(:each) ? body : [body]
    end

    def assign_default_content_type_and_charset!(headers)
      return if headers[CONTENT_TYPE].present?

      @content_type ||= Mime::HTML
      @charset      ||= self.class.default_charset unless @charset == false

      type = @content_type.to_s.dup
      type << "; charset=#{@charset}" if append_charset?

      headers[CONTENT_TYPE] = type
    end

    def append_charset?
      !@sending_file && @charset != false
    end

    def rack_response(status, header)
      assign_default_content_type_and_charset!(header)
      handle_conditional_get!

      header[SET_COOKIE] = header[SET_COOKIE].join("\n") if header[SET_COOKIE].respond_to?(:join)

      if NO_CONTENT_CODES.include?(@status)
        header.delete CONTENT_TYPE
        [status, header, []]
      else
        [status, header, self]
      end
    end
  end
end
