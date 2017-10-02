# frozen_string_literal: true

require "concurrent/map"

module ActiveModel
  class AttributeMethodMatcher < Module #:nodoc:
    NAME_COMPILABLE_REGEXP = /\A[a-zA-Z_]\w*[!?=]?\z/
    CALL_COMPILABLE_REGEXP = /\A[a-zA-Z_]\w*[!?]?\z/

    attr_reader :prefix, :suffix, :method_missing_target
    AttributeMethodMatch = Struct.new(:target, :attr_name, :method_name)

    def initialize(options = {})
      @prefix, @suffix = options.fetch(:prefix, ""), options.fetch(:suffix, "")
      @regex = /^(?:#{Regexp.escape(@prefix)})(.*)(?:#{Regexp.escape(@suffix)})$/
        @method_missing_target = "#{@prefix}attribute#{@suffix}"
      @method_name = "#{prefix}%s#{suffix}"
      define_method_missing
    end

    def inspect
      "<#{self.class.name}: #{@regex.inspect}>"
    end

    def define_attribute_methods(*attr_names)
      handler = @method_missing_target
      attr_names.each do |attr_name|
        name = method_name(attr_name)
        unless method_defined?(name)
          define_proxy_call true, name, handler, attr_name.to_s
        end
      end
    end

    def undefine_attribute_methods
      (instance_methods - [:method_missing]).each(&method(:undef_method))
    end

    def alias_attribute(new_name, old_name)
      define_proxy_call false, method_name(new_name), method_name(old_name)
    end

    def match(method_name)
      matchers_cache.compute_if_absent(method_name) do
        if (@regex =~ method_name) && (method_name != :attributes)
          AttributeMethodMatch.new(method_missing_target, $1, method_name.to_s)
        end
      end
    end

    private

    def define_method_missing
      matcher = self

      define_method :method_missing do |method_name, *arguments, &method_block|
        if (match = matcher.match(method_name)) &&
            attribute_method?(match.attr_name) &&
            !respond_to?(method_name, true)
          attribute_missing(match, *arguments, &method_block)
        else
          super(method_name, *arguments, &method_block)
        end
      end
    end

    def matchers_cache
      @matchers_cache ||= Concurrent::Map.new(initial_capacity: 4)
    end

    def method_name(attr_name)
      @method_name % attr_name
    end

    def define_proxy_call(include_private, name, send, *extra)
      defn = if NAME_COMPILABLE_REGEXP.match?(name)
        "def #{name}(*args)"
      else
        "define_method(:'#{name}') do |*args|"
      end

      extra = (extra.map!(&:inspect) << "*args").join(", ".freeze)

      target = if CALL_COMPILABLE_REGEXP.match?(send)
        "#{"self." unless include_private}#{send}(#{extra})"
      else
        "send(:'#{send}', #{extra})"
      end

      module_eval <<-RUBY, __FILE__, __LINE__ + 1
        #{defn}
          #{target}
        end
      RUBY
    end
  end
end
