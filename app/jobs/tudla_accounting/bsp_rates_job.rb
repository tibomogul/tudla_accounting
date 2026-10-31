# frozen_string_literal: true

module TudlaAccounting
  # Stores the day's BSP Reference Exchange Rate Bulletin (BspForexRateProvider#record_bulletin!),
  # so every currency it quotes has a rate for every business day, after the BSP's monthly
  # cross rates file has moved on. The host app schedules it after the bulletin is out
  # (mid-morning, Manila time), e.g. with Solid Queue's config/recurring.yml:
  #
  #   bsp_rates:
  #     class: TudlaAccounting::BspRatesJob
  #     schedule: every weekday at 11am Asia/Manila
  class BspRatesJob < ApplicationJob
    queue_as :default

    def perform
      stored = BspForexRateProvider.new.record_bulletin!
      Rails.logger.info("TudlaAccounting: stored #{stored} BSP rates")
    end
  end
end
