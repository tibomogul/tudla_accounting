# Requires are necessary for the Engine to load these gems' tasks and classes
require "bigdecimal"
require "solid_queue"
require "solid_cache"
require "solid_cable"
require "tailwindcss-rails"
require "importmap-rails"
require "money-rails"
require "monetize"
require "ancestry"

require "tudla_accounting/version"
require "tudla_accounting/engine"

module TudlaAccounting
  class << self
    attr_accessor :configuration
  end

  class Configuration
    attr_accessor :base_currency, :rounding, :time_zone, :organization_class

    def initialize
      @base_currency = "USD"
      @rounding = BigDecimal::ROUND_HALF_UP
      @time_zone = "UTC"
      @organization_class = "Organization"
    end
  end

  def self.init_config
    self.configuration ||= Configuration.new
  end

  def self.configure
    init_config
    yield(configuration)
  end
end

TudlaAccounting.init_config
