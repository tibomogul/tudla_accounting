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
                  :receivable_account_code, :payable_account_code, :due_date_method,
                  :retained_earnings_account_code
    attr_reader :carrying_amount_sources, :entry_sources

    def initialize
      @base_currency = "USD"
      @rounding = BigDecimal::ROUND_HALF_UP
      @time_zone = "UTC"
      @organization_class = "Organization"
      @receivable_account_code = nil
      @payable_account_code = nil
      @carrying_amount_sources = {}
      @due_date_method = :due_date
      @retained_earnings_account_code = nil
      @entry_sources = {}
    end

    def initialize_copy(source)
      super
      @entry_sources = source.entry_sources.dup
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
    apply_money_settings!
  end

  # Registers how to turn a host-app record into an entry. The callable receives
  # the record and returns a hash for Entry.create_from_ruby_hash (or nil to skip).
  # Register by class name so it survives code reloading:
  #
  #   TudlaAccounting.register_entry_source("Invoice", ->(invoice) { { ... } })
  def self.register_entry_source(source_type, callable)
    raise ArgumentError, "source_type must be a String" unless source_type.is_a?(String)
    raise ArgumentError, "callable must respond to call" unless callable.respond_to?(:call)

    configuration.entry_sources[source_type] = callable
    configuration.entry_sources
  end

  # Creates (but does not post) the entry for a host-app record using its
  # registered callable. source_type and source_id default to the record's,
  # so the entry is linked back to it. Returns nil if the callable returns nil.
  def self.create_entry_from_source!(source)
    source_type = source.class.name
    callable = configuration.entry_sources[source_type]
    raise ArgumentError, "No source registered for #{source_type}" unless callable

    entry_hash = callable.call(source)
    return if entry_hash.nil?

    defaults = { source_type: source_type }
    defaults[:source_id] = source.id if source.respond_to?(:id)
    TudlaAccounting::Entry.create_from_ruby_hash(defaults.merge(entry_hash))
  end

  # Pushes base_currency and rounding into money-rails (Money's global defaults).
  # Runs after every configure and again once the host app has booted, because
  # engine initializers load before the host's: settings made in a host
  # initializer would otherwise never reach money-rails.
  def self.apply_money_settings!
    MoneyRails.configure do |money|
      money.default_currency = Money::Currency.new(configuration.base_currency)
      money.rounding_mode = configuration.rounding
      money.locale_backend = :currency
    end
  end
end

TudlaAccounting.init_config
