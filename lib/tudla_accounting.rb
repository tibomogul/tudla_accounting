# Requires are necessary for the Engine to load these gems' tasks and classes
require "bigdecimal"
require "tailwindcss-rails"
require "importmap-rails"
require "stimulus-rails"
require "money-rails"
require "monetize"
require "ancestry"

require "tudla_accounting/version"
require "tudla_accounting/engine"
require "tudla_accounting/database_protection"

module TudlaAccounting
  class PeriodInvalid < StandardError; end
  class ConfigurationError < StandardError; end

  class << self
    attr_accessor :configuration
  end

  # What can happen to the books, each recorded as an AuditEvent and published once it
  # commits; see subscribe.
  EVENTS = %w[
    entry.posted entry.reversed entry.deleted
    account.created account.updated account.deleted
    period.created period.deleted period.closed period.reopened
    opening_balances.saved balances.rebuilt
    allocation.created allocation.reversed
    tax_code.created tax_code.updated tax_code.deleted
    bank_statement.imported bank_line.matched bank_line.unmatched
    dimension.created dimension.updated dimension_value.created dimension_value.updated
  ].freeze

  # Calls the block with each TudlaAccounting::AuditEvent for an action (or for every
  # action when none is given) once the change has committed, e.g. to sync another
  # system or send a notification:
  #
  #   TudlaAccounting.subscribe("entry.posted") { |event| LedgerSyncJob.perform_later(event.subject_id) }
  #
  # Returns the subscriber, for ActiveSupport::Notifications.unsubscribe. The events
  # are ActiveSupport::Notifications events named "<action>.tudla_accounting".
  def self.subscribe(action = nil, &block)
    raise ArgumentError, "unknown event #{action.inspect}; expected one of #{EVENTS.join(', ')}" if action && !EVENTS.include?(action)

    ActiveSupport::Notifications.subscribe(action ? "#{action}.tudla_accounting" : /\.tudla_accounting\z/) do |*, payload|
      block.call(payload[:event])
    end
  end

  class Configuration
    # receivable/payable open what is owed; receipt/disbursement (cash) and
    # credit_note/supplier_credit (no cash) are credits applied against it; refund (paid
    # back to a customer) and supplier_refund (paid back by a supplier) use up a credit.
    CARRYING_AMOUNT_ROLES = %i[receivable payable receipt disbursement credit_note supplier_credit refund supplier_refund].freeze

    attr_accessor :base_currency, :rounding, :time_zone, :organization_class,
                  :receivable_account_code, :payable_account_code, :due_date_method,
                  :retained_earnings_account_code, :related_party_method,
                  :forex_rate_provider, :unrealized_fx_gain_account_code,
                  :realized_fx_gain_account_code, :parent_controller, :current_organization,
                  :current_actor, :authorize, :cash_account_codes, :tax_basis
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
      @related_party_method = nil
      @forex_rate_provider = nil
      @unrealized_fx_gain_account_code = nil
      @realized_fx_gain_account_code = nil
      # UI: engine controllers inherit from this host controller (so its authentication and
      # helpers apply), and current_organization is called with the controller to find the
      # organization whose books are shown, e.g. ->(controller) { controller.current_organization }
      @parent_controller = "::ApplicationController"
      @current_organization = nil
      # Called with the controller for whoever is acting, recorded on audit events: a
      # record (a user) or a plain label, e.g. ->(controller) { controller.current_user }
      @current_actor = nil
      # Called with the controller and the permission a page or action needs (:read,
      # :record for drafts and accounts, :post for posting, reversing and applying
      # payments, :administer for periods and setup); a falsy result refuses it (403).
      # Everything is allowed when nil. e.g. ->(controller, permission) { controller.current_user.can?(permission) }
      @authorize = nil
      # The cash flow statement's cash: these accounts and every account beneath them
      # (e.g. %w[1010] for a "Cash and bank" parent). The report can choose others.
      @cash_account_codes = []
      # When the tax summary counts tax: :accrual (as lines are posted) or :cash (as
      # invoices and bills are paid). The report can choose either.
      @tax_basis = :accrual
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
  # The idempotency_key defaults to "Type:id", so calling it again for the same record
  # returns the entry already made; the callable can return its own key, or nil for none.
  def self.create_entry_from_source!(source)
    source_type = source.class.name
    callable = configuration.entry_sources[source_type]
    raise ArgumentError, "No source registered for #{source_type}" unless callable

    entry_hash = callable.call(source)
    return if entry_hash.nil?

    defaults = { source_type: source_type }
    if source.respond_to?(:id)
      defaults[:source_id] = source.id
      defaults[:idempotency_key] = "#{source_type}:#{source.id}" if source.id
    end
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
