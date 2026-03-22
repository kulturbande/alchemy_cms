# Plan: Alchemy CMS Wildcard/Pattern Routing

## Overview

Add support for URL pattern matching in Alchemy page routing. A page layout can define a `url_pattern` with named segments (e.g., `:id`, `:slug`) and type constraints. When a request doesn't match any exact page `urlname`, the system tries pattern matching against pages whose layouts define patterns.

## How It Works

### Configuration in `page_layouts.yml`

```yaml
- name: product_detail
  url_pattern: ":id"
  url_constraints:
    id: "integer"
  elements: [product_info]

- name: blog_post
  url_pattern: ":year/:month/:slug"
  url_constraints:
    year: "integer"
    month: "integer"
    slug: "string"
  elements: [article]

- name: user_profile
  url_pattern: ":uuid/profile"
  url_constraints:
    uuid: "uuid"
  elements: [profile]
```

### Matching behavior

The pattern is **relative to the page's `urlname`** (its position in the tree):

- Page with `urlname: "products"` and `url_pattern: ":id"` → matches `/products/123`
- Page with `urlname: "blog"` and `url_pattern: ":year/:month/:slug"` → matches `/blog/2024/03/my-post`
- Page with `urlname: "users"` and `url_pattern: ":uuid/profile"` → matches `/users/550e8400-.../profile`

Exact page matches always take priority over pattern matches.

### Available constraint types

| Type | Regex | Example |
|------|-------|---------|
| `integer` | `\d+` | `123` |
| `uuid` | `[0-9a-f]{8}-[0-9a-f]{4}-...` | `550e8400-e29b-...` |
| `string` | `[^/]+` (default) | `my-slug` |

### Accessing matched params

Matched segments are available in `params` under their segment name:

```ruby
# In a view or controller callback for /products/123:
params[:id]  # => "123"
```

## Implementation Steps

### Step 1: Extend `PageDefinition` to support `url_pattern` and `url_constraints`

**File**: `app/models/alchemy/page_definition.rb`

- Add `url_pattern` and `url_constraints` to the attribute reader
- `url_pattern` is a string like `":id"` or `":year/:slug"`
- `url_constraints` is a hash mapping segment names to type strings

### Step 2: Create `Alchemy::UrlPatternMatcher` service

**File**: `app/services/alchemy/url_pattern_matcher.rb` (new)

Responsible for:
1. Compiling a `url_pattern` + `url_constraints` into a regex
2. Matching a request path against a page's full pattern (urlname + "/" + url_pattern)
3. Extracting named params from a match

```ruby
module Alchemy
  class UrlPatternMatcher
    CONSTRAINT_PATTERNS = {
      "integer" => '\d+',
      "uuid"    => '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}',
      "string"  => '[^/]+'
    }.freeze

    def initialize(page)
      # Build regex from page.urlname + page.definition.url_pattern
    end

    def match(path)
      # Returns hash of matched params or nil
    end
  end
end
```

### Step 3: Create `Alchemy::PatternPage` finder

**File**: `app/models/alchemy/page/url_pattern_finder.rb` (new module) or integrated into existing lookup

Responsible for:
1. Finding all pages in the current language whose layout defines a `url_pattern`
2. Trying each page's pattern against the request path
3. Returning the first matching page + extracted params

Optimization: Pre-filter candidate pages by checking if the request path starts with the page's `urlname` prefix before running regex matching.

### Step 4: Integrate into `PagesController`

**File**: `app/controllers/alchemy/pages_controller.rb`

Modify `load_page` to fall back to pattern matching when exact `urlname` lookup returns nil:

```ruby
def load_page
  @page = Current.language.pages.contentpages.find_by(
    urlname: params[:urlname],
    language_code: params[:locale] || Current.language.code
  )

  # Fallback to pattern matching if no exact match
  if @page.nil?
    result = Alchemy::UrlPatternMatcher.find_match(
      params[:urlname],
      language: Current.language
    )
    if result
      @page = result[:page]
      params.merge!(result[:params])
    end
  end
end
```

This happens **before** legacy URL redirect checks, so patterns take priority over legacy redirects.

### Step 5: Add `url_pattern` and `url_constraints` to `PageDefinition`

**File**: `app/models/alchemy/page_definition.rb`

Add the two new attributes alongside existing ones.

### Step 6: Tests

- **Unit tests** for `UrlPatternMatcher`: pattern compilation, matching, constraint validation, edge cases
- **Model tests** for `PageDefinition`: new attributes parsed correctly
- **Controller tests** for `PagesController`: pattern fallback works, params are set, exact match still takes priority
- **Integration test**: full request cycle with pattern matching

### Step 7: Documentation

- Update page_layouts.yml example in `spec/dummy/`
- Add inline code comments where appropriate

## Design Decisions

1. **Pattern is relative to page urlname**: This preserves the tree structure. The page's position in the tree defines its base URL; the pattern extends it.

2. **Exact match takes priority**: If a child page exists with the exact urlname, it wins over a parent's pattern. This prevents patterns from shadowing real pages.

3. **Params in `params` hash**: Standard Rails convention. No special accessor needed. Views and callbacks access them like any other route param.

4. **Pre-filtering by urlname prefix**: Avoids running regex against all pattern pages. Only pages whose `urlname` is a prefix of the request path are candidates.

5. **Pattern before legacy redirects**: A valid pattern match should take precedence over a stale legacy URL redirect.
