# frozen_string_literal: true

module Alchemy
  class BasePageService
    attr_reader :page, :params, :preview_mode

    def initialize(page, params: ActionController::Parameters.new, preview_mode: false)
      @page = page
      @params = params
      @preview_mode = preview_mode
    end

    # entrypoint method of the page service
    # It can initialize and load necessary data or raise an Alchemy::PageNotFound error
    def call
      raise NotImplementedError
    end
  end
end
