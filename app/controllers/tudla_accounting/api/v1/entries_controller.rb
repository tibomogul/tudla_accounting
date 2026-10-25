module TudlaAccounting
  module Api
    module V1
      # Journal entries with their lines: posted or drafts, dated from and to (days the
      # entries are dated, inclusive), touching an account (its code), with a reference,
      # or changed since a time.
      #
      # Recording one (create, :record) makes a draft, or with "post": true (and :post)
      # posts it too, all or nothing. An Idempotency-Key makes a retried request return
      # the entry the first made. Drafts can be posted (post) or deleted (destroy); posted
      # entries reversed (reverse).
      class EntriesController < BaseController
        include Representation

        permits :record, only: %i[create destroy]
        permits :post, only: %i[post reverse]

        def index
          entries = organization_scope(Entry).includes(details: [ :account, :tax_code, :foreign_exchange, { tags: %i[dimension dimension_value] } ])
          entries = entries.where.not(posted_at: nil) if params[:status] == "posted"
          entries = entries.where(posted_at: nil) if params[:status] == "draft"
          entries = entries.where(transacted_at: day_start(date_param(:from))..) if params[:from].present?
          entries = entries.where(transacted_at: ...day_start(date_param(:to) + 1)) if params[:to].present?
          entries = entries.where(reference: params[:reference]) if params[:reference].present?
          if params[:account].present?
            account = organization_scope(Account).find_by!(code: params[:account])
            entries = entries.where(id: Detail.where(account_id: account.subtree_ids).select(:entry_id))
          end
          render_page(updated_since(entries).order(:transacted_at, :id)) { |entry| entry_json(entry) }
        end

        def show
          render json: { data: entry_json(organization_scope(Entry).find(params[:id])) }
        end

        def create
          existing = replay(organization_scope(Entry))
          return render_made(entry_json(existing)) if existing

          posting = boolean(body[:post])
          require_permission!(:post) if posting
          entry = Entry.transaction do
            made = Entry.create_from_ruby_hash(entry_hash)
            made.post(made.transacted_at) if posting && made.draft?
            made
          end
          render_made(entry_json(entry.reload))
        end

        # Posts a draft, on the day it is dated.
        def post
          entry = organization_scope(Entry).find(params[:id])
          raise ArgumentError, "The entry is posted already" if entry.posted?

          entry.post(entry.transacted_at)
          render json: { data: entry_json(entry.reload) }
        end

        # Reverses a posted entry on `on` (a date; today by default), returning the reversal.
        def reverse
          entry = organization_scope(Entry).find(params[:id])
          reversal = entry.reverse!(on: date_param(:on) || ActiveSupport::TimeZone[TudlaAccounting.configuration.time_zone].today)
          render json: { data: entry_json(reversal.reload) }, status: :created
        end

        def destroy
          entry = organization_scope(Entry).find(params[:id])
          raise ArgumentError, "Only a draft can be deleted; reverse a posted entry instead" if entry.posted?

          entry.destroy!
          head :no_content
        end

        private

        # The request as Entry.create_from_ruby_hash takes it: lines given as a debit or a
        # credit (decimal strings) to an account code, signed the way it wants them.
        def entry_hash
          lines = body[:lines]
          raise ArgumentError, "lines must be a list of at least two lines" unless lines.is_a?(Array) && lines.size >= 2

          { organization_type: accounting_organization.class.polymorphic_name, organization_id: accounting_organization.id,
            particulars: body[:particulars].to_s.presence || raise(ArgumentError, "particulars is missing"), reference: body[:reference]&.to_s,
            transacted_at: transacted_at.iso8601, reverse_on: body[:reverse_on].presence&.to_s, tax_inclusive: boolean(body[:tax_inclusive]),
            idempotency_key: idempotency_key, details: lines.each_with_index.map { |line, index| line_hash(line, "Line #{index + 1}") } }
        end

        # A date (the start of that day in the books' time zone) or a time.
        def transacted_at
          value = body[:date].to_s
          raise ArgumentError, "date is missing" if value.empty?

          begin
            value.match?(/\A\d{4}-\d{2}-\d{2}\z/) ? day_start(Date.iso8601(value)) : Time.iso8601(value)
          rescue Date::Error, ArgumentError
            raise ArgumentError, "date must be an ISO 8601 date (YYYY-MM-DD) or time"
          end
        end

        def line_hash(line, label)
          raise ArgumentError, "#{label} must be an object" unless line.is_a?(Hash)

          account = account_by_code(line[:account_code], label)
          debit, credit = line.values_at(:debit, :credit).map(&:presence)
          raise ArgumentError, "#{label} needs a debit or a credit, not both" unless debit.nil? ^ credit.nil?

          currency = accounting_organization.currency
          amount = cents(debit || credit, "#{label}'s #{debit ? 'debit' : 'credit'}")
          raise ArgumentError, "#{label}'s amount must be more than zero" unless amount.positive?

          increases = debit ? account.debit_balance? : !account.debit_balance?
          hash = { account_code: account.code, amount: "#{currency} #{'-' unless increases}#{plain(amount, currency)}", description: line[:description]&.to_s,
                   tax_code: line[:tax_code].presence&.to_s, tax_inclusive: (boolean(line[:tax_inclusive]) if line.key?(:tax_inclusive)),
                   dimensions: line[:dimensions].presence }.compact
          hash[:fx] = foreign(line[:foreign], label) if line[:foreign].present?
          hash
        end

        def foreign(given, label)
          raise ArgumentError, "#{label}'s foreign must be an object with currency, amount and rate" unless given.is_a?(Hash)

          currency = Money::Currency.find(given[:currency].to_s) or raise ArgumentError, "#{label}'s foreign currency #{given[:currency].inspect} isn't known"
          { other_currency_amount: "#{currency.iso_code} #{plain(cents(given[:amount], "#{label}'s foreign amount", currency: currency).abs, currency.iso_code)}",
            fx_rate: decimal(given[:rate], "#{label}'s foreign rate").to_s("F") }
        end

        def plain(cents, currency) = AmountParser.text(Money.new(cents, currency))
      end
    end
  end
end
