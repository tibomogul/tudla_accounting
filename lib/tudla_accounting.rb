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
  class PeriodInvalid < StandardError; end

  class << self
    attr_accessor :configuration
  end

  class Configuration
    CARRYING_AMOUNT_ROLES = %i[receivable payable receipt disbursement].freeze

    attr_accessor :base_currency, :rounding, :time_zone, :organization_class,
                  :receivable_account_code, :payable_account_code, :due_date_method
    attr_reader :carrying_amount_sources

    def initialize
      @base_currency = "USD"
      @rounding = BigDecimal::ROUND_HALF_UP
      @time_zone = "UTC"
      @organization_class = "Organization"
      @receivable_account_code = nil
      @payable_account_code = nil
      @carrying_amount_sources = {}
      @due_date_method = :due_date
    end

    # Maps entry source class names to the carrying amount role they play, e.g.
    # { "Invoice" => :receivable, "Bill" => :payable, "Payment" => :receipt, "Disbursement" => :disbursement }
    def carrying_amount_sources=(sources)
      @carrying_amount_sources = sources.to_h.to_h do |source_type, role|
        role = role.to_sym
        raise ArgumentError, "unknown carrying amount role #{role.inspect} for #{source_type}; expected one of #{CARRYING_AMOUNT_ROLES.join(', ')}" unless CARRYING_AMOUNT_ROLES.include?(role)

        [ source_type.to_s, role ]
      end.freeze
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
