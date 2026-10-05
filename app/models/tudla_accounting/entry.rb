# frozen_string_literal: true

module TudlaAccounting
  class Entry < ApplicationRecord
    belongs_to :organization, polymorphic: true
    belongs_to :source, polymorphic: true, optional: true
    belongs_to :related, polymorphic: true, optional: true

    has_many :details, dependent: :destroy, class_name: "TudlaAccounting::Detail"

    accepts_nested_attributes_for :details

    validates :particulars, presence: true
    validate :has_one_currency?
    validate :has_credit_amounts?
    validate :has_debit_amounts?
    validate :amounts_cancel?

    before_validation :set_detail_organizations, on: :create

    def post(posted_at)
      raise ArgumentError, "posted_at must be a datetime" unless posted_at.is_a?(Time) || posted_at.is_a?(ActiveSupport::TimeWithZone)
      raise ArgumentError, "entry must be valid" unless valid?

      transaction do
        lock_organization!
        raise ArgumentError, "entry is already posted" if self.class.where(id: id).where.not(posted_at: nil).exists?

        details.each do |detail|
          detail.post(posted_at)
        end
        update!(posted_at: posted_at)
        CarryingAmountProcessor.call(entry: self)
        true
      end
    end

    def self.create_from_ruby_hash(hash)
      raise ArgumentError, "transacted_at must be a valid ISO 8601 datetime string" unless hash[:transacted_at].is_a?(String)
      begin
        transacted_at = Time.iso8601(hash[:transacted_at])
      rescue ArgumentError
        raise ArgumentError, "transacted_at must be a valid ISO 8601 datetime string"
      end

      if hash[:posted_at].present?
        raise ArgumentError, "posted_at must be a valid ISO 8601 datetime string" unless hash[:posted_at].is_a?(String)
        begin
          posted_at = Time.iso8601(hash[:posted_at])
        rescue ArgumentError
          raise ArgumentError, "posted_at must be a valid ISO 8601 datetime string"
        end
      end

      raise ArgumentError, "particulars must be a string" unless hash[:particulars].is_a?(String)

      raise ArgumentError, "details must be an array" unless hash[:details].is_a?(Array)
      raise ArgumentError, "details must have at least 2 elements" unless hash[:details].length >= 2

      details_attributes = []
      hash[:details].each do |detail|
        raise ArgumentError, "each detail must have an account_code" unless detail[:account_code].present?
        raise ArgumentError, "each detail must have an amount" unless detail[:amount].present?
        raise ArgumentError, "amount must be a string" unless detail[:amount].is_a?(String)

        account = Account.find_by(code: detail[:account_code], organization_type: hash[:organization_type], organization_id: hash[:organization_id])
        raise ArgumentError, "invalid account_code: #{detail[:account_code]}" unless account

        money = parse_money(detail[:amount])

        amount_positive = money.positive?
        amount_cents = money.cents.abs

        tally = if amount_positive
                  account.debit_balance? ? Detail::TALLY_DEBIT : Detail::TALLY_CREDIT
        else
                  account.debit_balance? ? Detail::TALLY_CREDIT : Detail::TALLY_DEBIT
        end

        detail_attributes = {
          account: account,
          tally: tally,
          amount_cents: amount_cents,
          currency: money.currency.iso_code,
          organization_type: hash[:organization_type],
          organization_id: hash[:organization_id]
        }

        if detail[:fx]
          fx_hash = detail[:fx]
          raise ArgumentError, "fx node must have an other_currency_amount" unless fx_hash[:other_currency_amount].present?
          raise ArgumentError, "fx node must have an fx_rate" unless fx_hash[:fx_rate].present?

          other_currency_money = parse_money(fx_hash[:other_currency_amount])
          raise ArgumentError, "fx currency does not match the account currency" unless other_currency_money.currency.iso_code == account.currency

          rate = BigDecimal(fx_hash[:fx_rate])

          detail_attributes[:foreign_exchange_attributes] = {
            other_currency_cents: other_currency_money.cents,
            other_currency: other_currency_money.currency.iso_code,
            rate: rate
          }
        end

        details_attributes << detail_attributes
      end

      transaction do
        attributes = {
          organization_type: hash[:organization_type],
          organization_id: hash[:organization_id],
          source_type: hash[:source_type],
          source_id: hash[:source_id],
          particulars: hash[:particulars],
          transacted_at: transacted_at,
          details_attributes: details_attributes
        }
        attributes[:posted_at] = posted_at if hash[:posted_at].present?
        create!(attributes)
      end
    end

    # Parses "AUD 1,100.00" (or "1100.00" in the default currency). Monetize 2 only
    # recognizes a currency code that is also in its symbol table, so codes such as AUD
    # and NZD would silently fall back to the default currency; read the code here.
    def self.parse_money(text)
      code, number = text.to_s.strip.match(/\A([A-Za-z]{3})\s+(.+)\z/)&.captures
      return Monetize.parse(text) unless code

      currency = Money::Currency.find(code)
      raise ArgumentError, "unknown currency #{code} in amount #{text.inspect}" unless currency

      Monetize.parse(number, currency)
    end
    private_class_method :parse_money

    private

    def debit_amounts
      details.inject([]) { |arr, x| x.debit? ? arr << x : arr }
    end

    def credit_amounts
      details.inject([]) { |arr, x| x.credit? ? arr << x : arr }
    end

    def has_one_currency?
      details.map(&:currency).uniq.count == 1
    end

    def has_credit_amounts?
      errors.add(:base, "Entry must have at least one credit amount") if credit_amounts.blank?
    end

    def has_debit_amounts?
      errors.add(:base, "Entry must have at least one debit amount") if debit_amounts.blank?
    end

    def amounts_cancel?
      errors.add(:base, "The credit and debit amounts are not equal") if difference_of_amounts != 0
    end

    def difference_of_amounts
      credit_amount_total = credit_amounts.inject(Money.new(0, organization.currency)) { |sum, credit_amount| sum + credit_amount.amount }
      debit_amount_total = debit_amounts.inject(Money.new(0, organization.currency)) { |sum, debit_amount| sum + debit_amount.amount }
      credit_amount_total - debit_amount_total
    end

    def set_detail_organizations
      details.each do |detail|
        if detail.new_record? && detail.organization.nil?
          detail.organization = organization
        end
      end
    end
  end
end
