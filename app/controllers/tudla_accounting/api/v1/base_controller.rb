module TudlaAccounting
  module Api
    module V1
      # The JSON API's requests: each carries an API token (Authorization: Bearer
      # tudla_...), which picks the organization whose books it reaches and acts as itself
      # on the audit trail. Not the host's controller: the host's sign-in and sessions
      # don't apply, only the token. Each action needs one of the token's permissions
      # (:read unless the controller says otherwise with permits), and a token may make
      # api_rate_limit requests a minute.
      #
      # Errors are { "error": { "code": ..., "message": ... } } with the matching status.
      # Lists are paged: page (from 1) and per_page (up to MAX_PER_PAGE), with "meta"
      # giving the page, per_page, total_count and total_pages.
      class BaseController < ActionController::API
        PER_PAGE = 50
        MAX_PER_PAGE = 200

        class_attribute :api_permissions, default: {}

        def self.permits(permission, only:)
          raise ArgumentError, "unknown permission #{permission.inspect}" unless ApplicationController::PERMISSIONS.include?(permission)

          self.api_permissions = api_permissions.merge(Array(only).to_h { |action| [ action.to_s, permission ] })
        end

        before_action :authenticate
        before_action :limit_rate
        before_action :authorize

        rescue_from ActiveRecord::RecordNotFound do
          error(:not_found, "Not found", :not_found)
        end
        rescue_from ActionController::ParameterMissing, ArgumentError do |exception|
          error(:invalid_request, exception.message.upcase_first, :unprocessable_content)
        end
        rescue_from ActiveRecord::RecordInvalid do |exception|
          errors = exception.record.errors
          error(:invalid, errors.full_messages.to_sentence, :unprocessable_content, details: errors.to_hash)
        end

        private

        attr_reader :api_token

        def accounting_organization = api_token.organization

        # The engine's helpers the reports use to name things (there are no views here).
        def helpers
          @helpers ||= Object.new.extend(TudlaAccounting::ApplicationHelper, TudlaAccounting::ReportsHelper)
        end

        def organization_scope(model)
          model.where(organization: accounting_organization)
        end

        def authenticate
          secret = request.authorization.to_s[/\ABearer\s+(.+)\z/i, 1]
          @api_token = ApiToken.authenticate(secret)
          return Current.actor = @api_token if @api_token

          response.headers["WWW-Authenticate"] = %(Bearer realm="TudlaAccounting", error="invalid_token")
          error(:invalid_token, secret ? "The token is unknown, revoked or expired" : "Send an API token as Authorization: Bearer <token>", :unauthorized)
        end

        def authorize
          permission = api_permissions.fetch(action_name, :read)
          error(:forbidden, "This token can't #{permission}; issue one that can", :forbidden) unless api_token.can?(permission)
        end

        # For what an action does only on request (posting what it records, say).
        class Forbidden < StandardError; end
        rescue_from(Forbidden) { |exception| error(:forbidden, exception.message, :forbidden) }

        def require_permission!(permission)
          raise Forbidden, "This token can't #{permission}; issue one that can" unless api_token.can?(permission)
        end

        # A fixed window a minute long per token; a store that can't count (a null store)
        # limits nothing.
        def limit_rate
          limit = TudlaAccounting.configuration.api_rate_limit
          return unless limit

          window = Time.current.to_i / 60
          count = rate_limit_store.increment("tudla_accounting/api/#{api_token.id}/#{window}", 1, expires_in: 2.minutes)
          return unless count

          response.headers["X-RateLimit-Limit"] = limit.to_s
          response.headers["X-RateLimit-Remaining"] = [ limit - count, 0 ].max.to_s
          return if count <= limit

          response.headers["Retry-After"] = ((window + 1) * 60 - Time.current.to_i).to_s
          error(:rate_limited, "Too many requests: this token may make #{limit} a minute", :too_many_requests)
        end

        def rate_limit_store
          TudlaAccounting.configuration.api_rate_limit_store || Rails.cache
        end

        # The request's JSON body (or form fields), as a hash with indifferent access; each
        # action reads and checks what it needs.
        def body
          @body ||= params.except(:controller, :action, :format, :id).to_unsafe_h
        end

        def boolean(value) = ActiveModel::Type::Boolean.new.cast(value) || false

        # The request's Idempotency-Key, as stored ("api:<key>"), or nil.
        def idempotency_key
          key = request.headers["Idempotency-Key"].to_s.strip
          return if key.empty?
          raise ArgumentError, "Idempotency-Key must be at most 200 characters" if key.length > 200

          "api:#{key}"
        end

        # The record an earlier request with this Idempotency-Key made, marked as a replay;
        # nil when there was none.
        def replay(scope)
          key = idempotency_key or return
          record = scope.find_by(idempotency_key: key) or return
          response.headers["Idempotent-Replayed"] = "true"
          record
        end

        # A made (201) or replayed (200) record.
        def render_made(json)
          render json: { data: json }, status: response.headers["Idempotent-Replayed"] ? :ok : :created
        end

        # Cents for an amount given as a decimal string (or number) in the organization's
        # currency (or another), read as AmountParser reads it; ArgumentError naming what it
        # was for otherwise, or that it has more decimal places than the currency.
        def cents(value, label, currency: accounting_organization.currency)
          raise ArgumentError, "#{label} is missing" if value.blank?

          decimal(value, label) # a number at all
          begin
            AmountParser.cents(value, currency)
          rescue ArgumentError => e # too many decimal places
            raise ArgumentError, "#{label}: #{e.message}"
          end
        end

        def decimal(value, label)
          AmountParser.decimal(value)
        rescue ArgumentError
          raise ArgumentError, "#{label} must be a decimal number, such as \"1234.50\""
        end

        def account_by_code(code, label)
          organization_scope(Account).find_by(code: code.to_s) or raise ArgumentError, "#{label}: there is no account #{code}"
        end

        def tax_code_by_code(code, label)
          organization_scope(TaxCode).find_by(code: code.to_s) or raise ArgumentError, "#{label}: there is no tax code #{code}"
        end

        def contact_by_id(id)
          raise ArgumentError, "contact_id is missing" if id.blank?

          organization_scope(Contact).find(id)
        end

        def error(code, message, status, details: nil)
          render json: { error: { code: code.to_s, message: message, details: details }.compact }, status: status
        end

        # { data: [...], meta: {...} } for a page of the scope, each record as the block gives
        # it; with_page adds to the page's query (columns that can't be counted).
        def render_page(scope, with_page: :itself.to_proc, &representation)
          per_page = params[:per_page].present? ? params[:per_page].to_i.clamp(1, MAX_PER_PAGE) : PER_PAGE
          page = Paginator.new(scope, page: params[:page], per_page: per_page)
          render json: { data: with_page.call(page.records).map(&representation),
                         meta: { page: page.page, per_page: per_page, total_count: page.total_count, total_pages: page.total_pages } }
        end

        # A date parameter, nil when blank; ArgumentError when it isn't an ISO 8601 date.
        def date_param(name)
          Date.iso8601(params[name]) if params[name].present?
        rescue Date::Error
          raise ArgumentError, "#{name} must be an ISO 8601 date (YYYY-MM-DD)"
        end

        def time_param(name)
          Time.iso8601(params[name]) if params[name].present?
        rescue ArgumentError
          raise ArgumentError, "#{name} must be an ISO 8601 time"
        end

        # Today in the books' time zone.
        def today
          ActiveSupport::TimeZone[TudlaAccounting.configuration.time_zone].today
        end

        def day_start(date)
          ActiveSupport::TimeZone[TudlaAccounting.configuration.time_zone].local(date.year, date.month, date.day)
        end

        # Records changed since a time, for syncing.
        def updated_since(scope)
          since = time_param(:updated_since)
          since ? scope.where(scope.arel_table[:updated_at].gt(since)) : scope
        end
      end
    end
  end
end
