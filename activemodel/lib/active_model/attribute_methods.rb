# frozen_string_literal: true

require "concurrent/map"

module ActiveModel
  # Raised when an attribute is not defined.
  #
  #   class User < ActiveRecord::Base
  #     has_many :pets
  #   end
  #
  #   user = User.first
  #   user.pets.select(:id).first.user_id
  #   # => ActiveModel::MissingAttributeError: missing attribute: user_id
  class MissingAttributeError < NoMethodError
  end

  # == Active \Model \Attribute \Methods
  #
  # Provides a way to add prefixes and suffixes to your methods as
  # well as handling the creation of <tt>ActiveRecord::Base</tt>-like
  # class methods such as +table_name+.
  #
  # The requirements to implement <tt>ActiveModel::AttributeMethods</tt> are to:
  #
  # * <tt>include ActiveModel::AttributeMethods</tt> in your class.
  # * Call each of its methods you want to add, such as +attribute_method_suffix+
  #   or +attribute_method_prefix+.
  # * Call +define_attribute_methods+ after the other methods are called.
  # * Define the various generic +_attribute+ methods that you have declared.
  # * Define an +attributes+ method which returns a hash with each
  #   attribute name in your model as hash key and the attribute value as hash value.
  #   Hash keys must be strings.
  #
  # A minimal implementation could be:
  #
  #   class Person
  #     include ActiveModel::AttributeMethods
  #
  #     attribute_method_affix  prefix: 'reset_', suffix: '_to_default!'
  #     attribute_method_suffix '_contrived?'
  #     attribute_method_prefix 'clear_'
  #     define_attribute_methods :name
  #
  #     attr_accessor :name
  #
  #     def attributes
  #       { 'name' => @name }
  #     end
  #
  #     private
  #
  #     def attribute_contrived?(attr)
  #       true
  #     end
  #
  #     def clear_attribute(attr)
  #       send("#{attr}=", nil)
  #     end
  #
  #     def reset_attribute_to_default!(attr)
  #       send("#{attr}=", 'Default Name')
  #     end
  #   end
  module AttributeMethods
    extend ActiveSupport::Concern

    NAME_COMPILABLE_REGEXP = /\A[a-zA-Z_]\w*[!?=]?\z/
    CALL_COMPILABLE_REGEXP = /\A[a-zA-Z_]\w*[!?]?\z/

    included do
      class_attribute :attribute_aliases, instance_writer: false, default: {}
      include AttributeMethodMatcher.new
    end

    module ClassMethods
      # Declares a method available for all attributes with the given prefix.
      # Uses +method_missing+ and <tt>respond_to?</tt> to rewrite the method.
      #
      #   #{prefix}#{attr}(*args, &block)
      #
      # to
      #
      #   #{prefix}attribute(#{attr}, *args, &block)
      #
      # An instance method <tt>#{prefix}attribute</tt> must exist and accept
      # at least the +attr+ argument.
      #
      #   class Person
      #     include ActiveModel::AttributeMethods
      #
      #     attr_accessor :name
      #     attribute_method_prefix 'clear_'
      #     define_attribute_methods :name
      #
      #     private
      #
      #     def clear_attribute(attr)
      #       send("#{attr}=", nil)
      #     end
      #   end
      #
      #   person = Person.new
      #   person.name = 'Bob'
      #   person.name          # => "Bob"
      #   person.clear_name
      #   person.name          # => nil
      def attribute_method_prefix(*prefixes)
        prefixes.each { |prefix| include AttributeMethodMatcher.new prefix: prefix }
        undefine_attribute_methods
      end

      # Declares a method available for all attributes with the given suffix.
      # Uses +method_missing+ and <tt>respond_to?</tt> to rewrite the method.
      #
      #   #{attr}#{suffix}(*args, &block)
      #
      # to
      #
      #   attribute#{suffix}(#{attr}, *args, &block)
      #
      # An <tt>attribute#{suffix}</tt> instance method must exist and accept at
      # least the +attr+ argument.
      #
      #   class Person
      #     include ActiveModel::AttributeMethods
      #
      #     attr_accessor :name
      #     attribute_method_suffix '_short?'
      #     define_attribute_methods :name
      #
      #     private
      #
      #     def attribute_short?(attr)
      #       send(attr).length < 5
      #     end
      #   end
      #
      #   person = Person.new
      #   person.name = 'Bob'
      #   person.name          # => "Bob"
      #   person.name_short?   # => true
      def attribute_method_suffix(*suffixes)
        suffixes.each { |suffix| include AttributeMethodMatcher.new suffix: suffix }
        undefine_attribute_methods
      end

      # Declares a method available for all attributes with the given prefix
      # and suffix. Uses +method_missing+ and <tt>respond_to?</tt> to rewrite
      # the method.
      #
      #   #{prefix}#{attr}#{suffix}(*args, &block)
      #
      # to
      #
      #   #{prefix}attribute#{suffix}(#{attr}, *args, &block)
      #
      # An <tt>#{prefix}attribute#{suffix}</tt> instance method must exist and
      # accept at least the +attr+ argument.
      #
      #   class Person
      #     include ActiveModel::AttributeMethods
      #
      #     attr_accessor :name
      #     attribute_method_affix prefix: 'reset_', suffix: '_to_default!'
      #     define_attribute_methods :name
      #
      #     private
      #
      #     def reset_attribute_to_default!(attr)
      #       send("#{attr}=", 'Default Name')
      #     end
      #   end
      #
      #   person = Person.new
      #   person.name                         # => 'Gem'
      #   person.reset_name_to_default!
      #   person.name                         # => 'Default Name'
      def attribute_method_affix(*affixes)
        affixes.each { |affix| include AttributeMethodMatcher.new prefix: affix[:prefix], suffix: affix[:suffix] }
        undefine_attribute_methods
      end

      # Allows you to make aliases for attributes.
      #
      #   class Person
      #     include ActiveModel::AttributeMethods
      #
      #     attr_accessor :name
      #     attribute_method_suffix '_short?'
      #     define_attribute_methods :name
      #
      #     alias_attribute :nickname, :name
      #
      #     private
      #
      #     def attribute_short?(attr)
      #       send(attr).length < 5
      #     end
      #   end
      #
      #   person = Person.new
      #   person.name = 'Bob'
      #   person.name            # => "Bob"
      #   person.nickname        # => "Bob"
      #   person.name_short?     # => true
      #   person.nickname_short? # => true
      def alias_attribute(new_name, old_name)
        self.attribute_aliases = attribute_aliases.merge(new_name.to_s => old_name.to_s)
        ancestors.each do |ancestor|
          ancestor.alias_attribute(new_name, old_name) if ancestor.is_a?(AttributeMethodMatcher)
        end
      end

      # Is +new_name+ an alias?
      def attribute_alias?(new_name)
        attribute_aliases.key? new_name.to_s
      end

      # Returns the original name for the alias +name+
      def attribute_alias(name)
        attribute_aliases[name.to_s]
      end

      # Declares the attributes that should be prefixed and suffixed by
      # <tt>ActiveModel::AttributeMethods</tt>.
      #
      # To use, pass attribute names (as strings or symbols). Be sure to declare
      # +define_attribute_methods+ after you define any prefix, suffix or affix
      # methods, or they will not hook in.
      #
      #   class Person
      #     include ActiveModel::AttributeMethods
      #
      #     attr_accessor :name, :age, :address
      #     attribute_method_prefix 'clear_'
      #
      #     # Call to define_attribute_methods must appear after the
      #     # attribute_method_prefix, attribute_method_suffix or
      #     # attribute_method_affix declarations.
      #     define_attribute_methods :name, :age, :address
      #
      #     private
      #
      #     def clear_attribute(attr)
      #       send("#{attr}=", nil)
      #     end
      #   end
      def define_attribute_methods(*attr_names)
        ancestors.each do |ancestor|
          ancestor.define_attribute_methods(*(attr_names.flatten)) if ancestor.is_a?(AttributeMethodMatcher)
        end
      end

      # Declares an attribute that should be prefixed and suffixed by
      # <tt>ActiveModel::AttributeMethods</tt>.
      #
      # To use, pass an attribute name (as string or symbol). Be sure to declare
      # +define_attribute_method+ after you define any prefix, suffix or affix
      # method, or they will not hook in.
      #
      #   class Person
      #     include ActiveModel::AttributeMethods
      #
      #     attr_accessor :name
      #     attribute_method_suffix '_short?'
      #
      #     # Call to define_attribute_method must appear after the
      #     # attribute_method_prefix, attribute_method_suffix or
      #     # attribute_method_affix declarations.
      #     define_attribute_method :name
      #
      #     private
      #
      #     def attribute_short?(attr)
      #       send(attr).length < 5
      #     end
      #   end
      #
      #   person = Person.new
      #   person.name = 'Bob'
      #   person.name        # => "Bob"
      #   person.name_short? # => true
      alias_method :define_attribute_method, :define_attribute_methods

      # Removes all the previously dynamically defined methods from the class.
      #
      #   class Person
      #     include ActiveModel::AttributeMethods
      #
      #     attr_accessor :name
      #     attribute_method_suffix '_short?'
      #     define_attribute_method :name
      #
      #     private
      #
      #     def attribute_short?(attr)
      #       send(attr).length < 5
      #     end
      #   end
      #
      #   person = Person.new
      #   person.name = 'Bob'
      #   person.name_short? # => true
      #
      #   Person.undefine_attribute_methods
      #
      #   person.name_short? # => NoMethodError
      def undefine_attribute_methods
        ancestors.each do |ancestor|
          ancestor.undefine_attribute_methods if ancestor.is_a? AttributeMethodMatcher
        end
      end

    end

    # +attribute_missing+ is like +method_missing+, but for attributes. When
    # +method_missing+ is called we check to see if there is a matching
    # attribute method. If so, we tell +attribute_missing+ to dispatch the
    # attribute. This method can be overloaded to customize the behavior.
    def attribute_missing(match, *args, &block)
      __send__(match.target, match.attr_name, *args, &block)
    end

    alias :respond_to_without_attributes? :respond_to?

    private
      def attribute_method?(attr_name)
        respond_to_without_attributes?(:attributes) && attributes.include?(attr_name)
      end

      def missing_attribute(attr_name, stack)
        raise ActiveModel::MissingAttributeError, "missing attribute: #{attr_name}", stack
      end

      def _read_attribute(attr)
        __send__(attr)
      end

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
end
