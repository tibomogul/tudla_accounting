module TudlaAccounting
  # Building blocks for the engine's pages. Styling comes from the tc- component classes
  # in app/assets/tailwind/tudla_accounting/engine.css.
  module ApplicationHelper
    BADGE_TONES = %i[neutral primary success danger warning].freeze

    # The host app's home page: its root route, or "/" when it has none (a new app).
    def tc_host_root_path
      main_app.respond_to?(:root_path) ? main_app.root_path : "/"
    end

    # An amount in accounting style: thousands separators, no currency symbol (the
    # currency is shown once per table), negatives in parentheses. One in a foreign
    # currency is written as the organization's own amounts are, not as that currency's
    # country writes it (MoneyFormatter.number).
    def tc_money(money)
      return "" if money.nil?

      text = MoneyFormatter.number(money.abs, tc_money_style(money))
      money.negative? ? tag.span("(#{text})", class: "tc-negative") : text
    end

    # An amount standing alone, in a heading, a badge or a message: "$1,234.56" in the
    # organization's currency, "EUR 1,234.56" in another (MoneyFormatter.labelled).
    def tc_money_text(money)
      money && MoneyFormatter.labelled(money, tc_money_style(money))
    end

    # Whose style amounts are written in: the organization's (its number format), or
    # without one the amount's currency's.
    def tc_money_style(money)
      (accounting_organization if respond_to?(:accounting_organization)) || money.currency
    end

    # An amount as a form field holds it: "1234.50" ("1234,50" in comma books), with the
    # organization's decimal mark and no thousands separators whatever the currency's own
    # style, as the forms read amounts back ("" for none). Every amount field is filled
    # with it, so saving a form unchanged keeps it.
    def tc_amount_field(money)
      money ? AmountParser.text(money, format: tc_number_format) : ""
    end

    # Any other number (a quantity, a rate, a percentage) as the pages write it and its
    # fields hold it: "2.5", or "2,5" in comma books ("" for none).
    def tc_number(value)
      value.nil? ? "" : AmountParser.number_text(value, format: tc_number_format)
    end

    # How the organization's pages write numbers (NumberFormat).
    def tc_number_format
      @tc_number_format ||= NumberFormat.for((accounting_organization if respond_to?(:accounting_organization)) || TudlaAccounting.configuration.base_currency)
    end

    def tc_date(value)
      value&.to_date&.strftime("%-d %b %Y")
    end

    def tc_badge(text, tone: :neutral)
      raise ArgumentError, "Unknown badge tone #{tone.inspect}" unless BADGE_TONES.include?(tone)

      tag.span(text, class: [ "tc-badge", ("tc-badge-#{tone}" unless tone == :neutral) ])
    end

    # Page title with optional subtitle and actions (the block).
    def tc_page_header(title, subtitle: nil, &actions)
      content_for(:title, title)
      render "tudla_accounting/shared/page_header", title: title, subtitle: subtitle, actions: actions && capture(&actions)
    end

    # Navigation link, marked current when the page is in its section.
    def tc_nav_link(text, path, section: path)
      current = request.path == path || (section != root_path && request.path.start_with?(section))
      link_to text, path, class: "tc-nav-link", aria: { current: ("page" if current) }
    end

    # "2026" for a calendar year, otherwise its date range; "Mar 2026" for a month.
    def tc_period_label(period)
      period.label
    end

    # A labelled form field with its hint and errors, e.g.
    #   tc_field(form, :name) / tc_field(form, :category, as: :select, choices: [...])
    def tc_field(form, attribute, as: :text_field, label: nil, hint: nil, choices: nil, **options)
      errors = form.object.respond_to?(:errors) ? form.object.errors[attribute] : []
      options[:class] = [ "tc-input", ("tc-input-error" if errors.any?), options[:class] ]
      input = as == :select ? form.select(attribute, choices, {}, options) : form.public_send(as, attribute, options)

      tag.div(class: "space-y-1") do
        safe_join([
          form.label(attribute, label, class: "tc-label"),
          input,
          (tag.p(hint, class: "tc-hint") if hint),
          *errors.map { |message| tag.p("#{(label || attribute.to_s.humanize)} #{message}", class: "tc-error-text") }
        ].compact)
      end
    end
  end
end
