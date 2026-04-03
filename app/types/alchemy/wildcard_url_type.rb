# frozen_string_literal: true

module Alchemy
  class WildcardUrlType < ActiveModel::Type::Value
    class Value
      attr_reader :pattern, :params

      def initialize(pattern:, params: {})
        @pattern = pattern
        @params = params
      end

      def present?
        pattern.present?
      end

      def param_keys
        @_param_keys ||= pattern.scan(/:(\w+)/).flatten.map(&:to_sym)
      end

      # Returns the regex pattern string for a param's constraint.
      #
      # @param key [String] the param name
      # @return [String] regex pattern source
      def constraint_pattern(key)
        constraint = params[key.to_s] || params[key.to_sym]
        format_matchers = Alchemy.config.format_matchers

        return strip_anchors(format_matchers[:string].source) if constraint.nil?
        return strip_anchors(constraint.source) if constraint.is_a?(Regexp)

        strip_anchors(format_matchers[constraint.to_sym].source)
      end

      private

      # Strips \A, \z, ^, $ anchors from a regex source string.
      # Does not strip ^ inside character classes (e.g. [^/]).
      #
      # @param source [String] regex source
      # @return [String] anchor-free regex source
      def strip_anchors(source)
        source.gsub(/\\A|\\z|\\Z|(?<!\[)\^|\$/, "")
      end
    end

    def cast(value)
      case value
      when nil then nil
      when String
        Value.new(pattern: value)
      when Hash
        attrs = value.symbolize_keys
        Value.new(
          pattern: attrs[:pattern],
          params: attrs[:params] || {}
        )
      else
        value
      end
    end

    def assert_valid_value(value)
      return if value.nil?

      unless value.is_a?(String) || value.is_a?(Hash)
        raise ArgumentError, "#{value.inspect} is not a valid wildcard_url. Must be a String or Hash."
      end

      if value.is_a?(Hash)
        attrs = value.symbolize_keys
        unless attrs[:pattern].is_a?(String)
          raise ArgumentError, "wildcard_url hash must include a \"pattern\" key with a String value."
        end

        valid_matchers = Configurations::FormatMatchers.defined_options
        (attrs[:params] || {}).each do |key, constraint|
          next if constraint.is_a?(Regexp)

          unless valid_matchers.include?(constraint.to_sym)
            raise ArgumentError,
              "Unknown format matcher \"#{constraint}\" for wildcard param \":#{key}\". " \
              "Available matchers: #{valid_matchers.join(", ")}"
          end
        end
      end
    end
  end
end
