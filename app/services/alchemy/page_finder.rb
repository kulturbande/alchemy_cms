# frozen_string_literal: true

module Alchemy
  class PageFinder
    attr_reader :urlname

    Result = Data.define(:page, :extracted_params)

    def initialize(urlname)
      @urlname = urlname
    end

    # @return [PageFinder::Result, nil]
    def call
      return if urlname.blank?

      find_by_urlname || find_by_wildcard_url
    end

    private

    # Finds a page by exact urlname match within the current language.
    def find_by_urlname
      page = Current.language.pages.contentpages.find_by(urlname: urlname)
      Result.new(page: page, extracted_params: permitted_params({})) if page
    end

    # Finds a page whose urlname pattern matches the given URL.
    # Uses a single SQL query to load all candidate pages with wildcard patterns
    # in their urlname, then matches and validates constraints in Ruby.
    def find_by_wildcard_url
      return if wildcard_definitions.empty?

      wildcard_pages = Current.language.pages.contentpages
        .where("urlname LIKE ?", "%:%")
        .to_a

      url_depth = urlname.count("/")

      matches = wildcard_pages.filter_map do |wildcard_page|
        next if wildcard_page.urlname.count("/") != url_depth

        matched_params = match_url_pattern(wildcard_page)
        [wildcard_page, matched_params] if matched_params
      end

      return if matches.empty?

      # take the first page that matched the url
      page, params = matches.min_by { |page, _| [page.depth, page.lft] }
      Result.new(page: page, extracted_params: permitted_params(params))
    end

    # Matches the urlname against a page's wildcard pattern.
    # Builds a regex from the pattern with constraints baked into capture groups,
    # then extracts and validates params in one step.
    #
    # @param wildcard_page [Alchemy::Page] a page with wildcard segments in its urlname
    # @return [Hash<Symbol, String>, nil] matched params or nil
    def match_url_pattern(wildcard_page)
      regex_parts = wildcard_page.urlname.split("/").map do |segment|
        segment_to_pattern(segment)
      end

      return if regex_parts.include?(nil)

      match = Regexp.new("\\A#{regex_parts.join("/")}\\z").match(urlname)
      return unless match

      match.named_captures.transform_keys(&:to_sym)
    end

    # Converts a single URL segment into a regex pattern string.
    # Static segments are escaped, dynamic segments (e.g. ":id") are resolved
    # to a capture group with the constraint from the matching wildcard definition.
    #
    # @param segment [String] a single URL segment, e.g. "products" or ":id"
    # @return [String, nil] regex pattern string or nil if no matching definition found
    def segment_to_pattern(segment)
      unless segment.start_with?(":")
        return Regexp.escape(segment)
      end

      key = segment[1..] # remove leading colon
      wildcard_url = wildcard_urls_by_param_key[key.to_sym]
      wildcard_url ? "(?<#{key}>#{wildcard_url.constraint_pattern(key)})" : nil
    end

    # Cache the wildcard_url definition and store it in a hash
    #
    # @return [Hash<Symbol, WildcardUrlType::Value>] param key to wildcard_url lookup
    def wildcard_urls_by_param_key
      @_wildcard_urls_by_param_key ||= wildcard_definitions.each_with_object({}) do |definition, hash|
        definition.wildcard_url.param_keys.each do |key|
          hash[key] = definition.wildcard_url
        end
      end
    end

    # @param hash [Hash] raw extracted params
    # @return [ActionController::Parameters] permitted params
    def permitted_params(hash)
      ActionController::Parameters.new(hash).permit(*hash.keys)
    end

    # Returns all page definitions that have a wildcard_url defined.
    #
    # @return [Array<PageDefinition>]
    def wildcard_definitions
      @_wildcard_definitions ||= PageDefinition.all.select { |d| d.wildcard_url&.present? }
    end
  end
end
