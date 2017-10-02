# frozen_string_literal: true

require "concurrent/map"

module ActiveModel
  class AttributeMethodMatcher < Module #:nodoc:
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
        define_method name do |*arguments, &block|
          send(handler, attr_name, *arguments, &block)
        end unless method_defined?(name)
      end
    end

    def undefine_attribute_methods
      (instance_methods - [:method_missing]).each(&method(:undef_method))
    end

    def alias_attribute(new_name, old_name)
      handler = method_name(old_name)
      define_method method_name(new_name) do |*arguments, &block|
        send(handler, *arguments, &block)
      end
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
  end
end
