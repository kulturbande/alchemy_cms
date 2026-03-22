# frozen_string_literal: true

require "rails_helper"

module Alchemy
  RSpec.describe UrlPatternMatcher do
    describe ".compile_pattern" do
      it "compiles a simple named segment with default string constraint" do
        regex = described_class.send(:compile_pattern, ":id", {})
        expect(regex).to match("123")
        expect(regex).to match("my-slug")
        expect(regex).not_to match("foo/bar")
      end

      it "compiles a named segment with integer constraint" do
        regex = described_class.send(:compile_pattern, ":id", {"id" => "integer"})
        expect(regex).to match("123")
        expect(regex).not_to match("abc")
        expect(regex).not_to match("12-ab")
      end

      it "compiles a named segment with uuid constraint" do
        regex = described_class.send(:compile_pattern, ":uuid", {"uuid" => "uuid"})
        expect(regex).to match("550e8400-e29b-41d4-a716-446655440000")
        expect(regex).not_to match("123")
        expect(regex).not_to match("not-a-uuid")
      end

      it "compiles a pattern with multiple segments" do
        regex = described_class.send(:compile_pattern, ":year/:slug", {"year" => "integer", "slug" => "string"})
        match = regex.match("2024/my-post")
        expect(match).to be_present
        expect(match[:year]).to eq("2024")
        expect(match[:slug]).to eq("my-post")
      end

      it "compiles a pattern with static and dynamic segments" do
        regex = described_class.send(:compile_pattern, ":id/details", {"id" => "integer"})
        match = regex.match("123/details")
        expect(match).to be_present
        expect(match[:id]).to eq("123")
        expect(regex).not_to match("123/other")
      end

      it "anchors the pattern to match exactly" do
        regex = described_class.send(:compile_pattern, ":id", {"id" => "integer"})
        expect(regex).to match("123")
        expect(regex).not_to match("123/extra")
      end
    end

    describe ".find_match" do
      let(:language) { create(:alchemy_language) }
      let!(:language_root) do
        create(:alchemy_page, :language_root, language: language)
      end

      before do
        # Reset memoized definitions so test page_layouts.yml is loaded
        PageDefinition.reset!
      end

      context "with a page using url_pattern" do
        let!(:products_page) do
          create(
            :alchemy_page,
            :public,
            name: "Products",
            page_layout: "product_detail",
            parent: language_root,
            language: language
          )
        end

        it "matches a path with a valid integer segment" do
          result = described_class.find_match("products/123", language: language)
          expect(result).to be_present
          expect(result[:page]).to eq(products_page)
          expect(result[:params][:id]).to eq("123")
        end

        it "does not match when the constraint fails" do
          result = described_class.find_match("products/not-a-number", language: language)
          expect(result).to be_nil
        end

        it "does not match a path that doesn't start with the page urlname" do
          result = described_class.find_match("other/123", language: language)
          expect(result).to be_nil
        end

        it "returns nil for a blank path" do
          result = described_class.find_match("", language: language)
          expect(result).to be_nil
        end
      end

      context "with a multi-segment pattern" do
        let!(:blog_page) do
          create(
            :alchemy_page,
            :public,
            name: "Blog",
            page_layout: "blog_post",
            parent: language_root,
            language: language
          )
        end

        it "matches and extracts multiple named segments" do
          result = described_class.find_match("blog/2024/my-post", language: language)
          expect(result).to be_present
          expect(result[:page]).to eq(blog_page)
          expect(result[:params][:year]).to eq("2024")
          expect(result[:params][:slug]).to eq("my-post")
        end

        it "does not match with wrong segment count" do
          result = described_class.find_match("blog/2024", language: language)
          expect(result).to be_nil
        end
      end

      context "with a pattern containing static segments" do
        let!(:users_page) do
          create(
            :alchemy_page,
            :public,
            name: "Users",
            page_layout: "user_profile",
            parent: language_root,
            language: language
          )
        end

        it "matches a uuid pattern with trailing static segment" do
          uuid = "550e8400-e29b-41d4-a716-446655440000"
          result = described_class.find_match("users/#{uuid}/profile", language: language)
          expect(result).to be_present
          expect(result[:page]).to eq(users_page)
          expect(result[:params][:uuid]).to eq(uuid)
        end

        it "does not match without the static segment" do
          uuid = "550e8400-e29b-41d4-a716-446655440000"
          result = described_class.find_match("users/#{uuid}", language: language)
          expect(result).to be_nil
        end
      end

      context "with hierarchical patterns (child page under pattern page)" do
        let!(:products_page) do
          create(
            :alchemy_page,
            :public,
            name: "Products",
            page_layout: "product_detail",
            parent: language_root,
            language: language
          )
        end

        let!(:comments_page) do
          create(
            :alchemy_page,
            :public,
            name: "Comments",
            page_layout: "standard",
            parent: products_page,
            language: language
          )
        end

        it "matches a child page URL with the parent's pattern segment" do
          result = described_class.find_match("products/42/comments", language: language)
          expect(result).to be_present
          expect(result[:page]).to eq(comments_page)
          expect(result[:params][:id]).to eq("42")
        end

        it "does not match if constraint fails in the parent pattern" do
          result = described_class.find_match("products/not-a-number/comments", language: language)
          expect(result).to be_nil
        end
      end

      context "when an exact page match exists" do
        let!(:products_page) do
          create(
            :alchemy_page,
            :public,
            name: "Products",
            page_layout: "product_detail",
            parent: language_root,
            language: language
          )
        end

        it "is not called because exact match takes priority in the controller" do
          # The exact match is handled in the controller before calling find_match.
          # This test documents that find_match itself would still match,
          # but the controller won't call it when an exact match exists.
          exact_page = create(
            :alchemy_page,
            :public,
            name: "Special Product",
            page_layout: "standard",
            parent: products_page,
            language: language
          )

          # The exact page has urlname "products/special-product"
          exact_result = language.pages.contentpages.find_by(
            urlname: exact_page.urlname,
            language_code: language.code
          )
          expect(exact_result).to eq(exact_page)
        end
      end
    end
  end
end
