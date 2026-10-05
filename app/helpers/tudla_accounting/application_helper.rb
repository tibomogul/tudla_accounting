module TudlaAccounting
  # Building blocks for the engine's pages. Styling comes from the tc- component classes
  # in app/assets/tailwind/tudla_accounting/engine.css.
  module ApplicationHelper
    BADGE_TONES = %i[neutral primary success danger warning].freeze

    # An amount in accounting style: thousands separators, no currency symbol (the
    # currency is shown once per table), negatives in parentheses.
    def tc_money(money)
      return "" if money.nil?

      text = money.abs.format(symbol: false)
      money.negative? ? tag.span("(#{text})", class: "tc-negative") : text
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
      from = period.from_date.to_date
      thru = period.thru_date.to_date
      if from == from.beginning_of_year && thru == from.end_of_year
        from.year.to_s
      elsif from == from.beginning_of_month && thru == from.end_of_month
        from.strftime("%b %Y")
      else
        "#{tc_date(from)} – #{tc_date(thru)}"
      end
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
