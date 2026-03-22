# frozen_string_literal: true

module Alchemy
  # Matches request paths against pages with URL patterns defined in their page layout.
  #
  # URL patterns allow pages to match dynamic path segments. The url_pattern
  # replaces the page's own slug in the URL. For example, a "Product Details"
  # page (child of "Products") with url_pattern ":product_id" will match
  # "/products/:product_id" instead of "/products/product-details".
  #
  # Named segments are extracted and returned as a params hash.
  #
  # Patterns compose hierarchically: if a parent page has a url_pattern,
  # child pages inherit the parent's pattern segments in their full URL.
  # All named segments from the entire ancestor chain are available as params.
  #
  # == Supported constraint types
  #
  #   integer - matches \d+
  #   uuid    - matches UUID v4 format
  #   string  - matches any non-slash characters (default)
  #
  class UrlPatternMatcher
    CONSTRAINT_PATTERNS = {
      "integer" => "\\d+",
      "uuid" => "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}",
      "string" => "[^/]+"
    }.freeze

    NAMED_SEGMENT_REGEX = /:([a-zA-Z_][a-zA-Z0-9_]*)/

    class << self
      # Finds a page matching the given path using URL pattern matching.
      #
      # First tries pages whose urlname is a prefix of the request path,
      # then checks if the remaining path matches the page's url_pattern.
      #
      # For hierarchical patterns (child pages under pattern pages),
      # builds the composite pattern from the full ancestor chain.
      #
      # @param path [String] The request path (without leading slash or locale)
      # @param language [Alchemy::Language] The current language
      # @return [Hash, nil] { page: Alchemy::Page, params: Hash } or nil
      #
      def find_match(path, language:)
        return nil if path.blank?

        candidates = find_candidates(path, language)
        try_match(path, candidates)
      end

      private

      # Returns pages that could potentially match the path.
      #
      # A page is a candidate if:
      # 1. Its layout defines a url_pattern, OR
      # 2. It is a descendant of a page whose layout defines a url_pattern
      #
      # We filter by checking if the path starts with the page's urlname prefix
      # (the static portion before any pattern segments from ancestors).
      #
      def find_candidates(path, language)
        pattern_layout_names = layouts_with_patterns.map(&:name)
        return [] if pattern_layout_names.empty?

        # Find pages whose layout has a url_pattern
        pattern_pages = language.pages.contentpages.where(
          page_layout: pattern_layout_names,
          language_code: language.code
        ).to_a

        # Also find child pages of pattern pages that could match
        # (their URL incorporates the parent's pattern)
        child_candidates = find_child_candidates(path, pattern_pages, language)

        (pattern_pages + child_candidates).uniq
      end

      # Finds non-pattern child pages whose effective URL contains
      # pattern segments from their ancestors.
      #
      def find_child_candidates(path, pattern_pages, language)
        candidates = []
        pattern_pages.each do |pattern_page|
          descendants = language.pages.contentpages.where(
            language_code: language.code
          ).where(
            "#{Alchemy::Page.table_name}.lft > ? AND #{Alchemy::Page.table_name}.rgt < ?",
            pattern_page.lft, pattern_page.rgt
          ).to_a
          candidates.concat(descendants)
        end
        candidates
      end

      # Tries to match the path against each candidate page.
      #
      # Sorts candidates by depth (deepest first) so more specific
      # matches take priority over broader ones.
      #
      def try_match(path, candidates)
        candidates.sort_by { |p| -p.depth }.each do |page|
          result = match_page(path, page)
          return result if result
        end
        nil
      end

      # Builds the full URL pattern for a page by composing patterns
      # from its ancestor chain, then tries to match the path.
      #
      def match_page(path, page)
        full_pattern = build_full_pattern(page)
        return nil unless full_pattern

        regex = compile_pattern(full_pattern, aggregate_constraints(page))
        match_data = regex.match(path)
        return nil unless match_data

        extracted_params = match_data.named_captures.transform_keys(&:to_sym)
        {page: page, params: extracted_params}
      end

      # Builds the full URL pattern for a page by walking up the ancestor chain.
      #
      # For each page in the chain, if its layout defines a url_pattern, the
      # pattern REPLACES that page's slug in the URL. Static slugs are kept as-is.
      #
      # Example:
      #   Products (page_layout: "product_overview")
      #     └── Product Details (page_layout: "product_detail", url_pattern: ":product_id")
      #         └── Comments (page_layout: "comment_overview")
      #
      #   Full pattern for Product Details: "products/:product_id"
      #   Full pattern for Comments:        "products/:product_id/comments"
      #
      def build_full_pattern(page)
        segments = []
        has_any_pattern = false

        # Walk from root to page, building segments
        chain = page_chain(page)
        chain.each do |ancestor|
          definition = PageDefinition.get(ancestor.page_layout)
          pattern = definition&.url_pattern

          if pattern.present?
            has_any_pattern = true
            # The url_pattern replaces the page's slug in the URL
            segments << pattern
          else
            segments << ancestor.slug
          end
        end

        return nil unless has_any_pattern

        segments.join("/")
      end

      # Collects url_constraints from all ancestors with patterns.
      #
      def aggregate_constraints(page)
        constraints = {}
        page_chain(page).each do |ancestor|
          definition = PageDefinition.get(ancestor.page_layout)
          if definition&.url_pattern.present?
            constraints.merge!(definition.url_constraints || {})
          end
        end
        constraints
      end

      # Returns the chain of pages from the language root's child down to this page.
      # Excludes the language root itself since it doesn't contribute to the URL.
      #
      def page_chain(page)
        return [page] if page.depth <= 1

        ancestors = page.ancestors.where("depth > 0").order(:lft).to_a
        ancestors + [page]
      end

      # Compiles a URL pattern string into a regex.
      #
      # Named segments like :id become named capture groups with
      # constraint-based patterns.
      #
      def compile_pattern(pattern, constraints = {})
        regex_str = Regexp.escape(pattern).gsub(/:([a-zA-Z_][a-zA-Z0-9_]*)/) do
          name = $1
          constraint = constraints[name] || constraints[name.to_sym] || "string"
          segment_pattern = CONSTRAINT_PATTERNS.fetch(constraint.to_s, CONSTRAINT_PATTERNS["string"])
          "(?<#{name}>#{segment_pattern})"
        end

        Regexp.new("\\A#{regex_str}\\z")
      end

      # Returns all page layout definitions that have a url_pattern.
      #
      def layouts_with_patterns
        PageDefinition.all.select { |d| d.url_pattern.present? }
      end
    end
  end
end
