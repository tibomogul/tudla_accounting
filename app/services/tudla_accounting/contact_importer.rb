# frozen_string_literal: true

module TudlaAccounting
  # Adds an organization's contacts from a CSV or XLSX file (SpreadsheetRows), all or
  # nothing, and updates those already there by name (ignoring case; their name keeps its spelling). Columns, by
  # heading in any case: Name (needed), Kind (customer, supplier or both; customer if
  # blank), Email, Phone, Address, Postal code, Tax number, Payment terms (days), Currency (its code;
  # blank for the organization's), Default account (its code), Default tax code (its
  # code), Default withholding code (its code), Taxable payments (yes or no; left as it is
  # when blank), Notes. Other columns are left out.
  #
  #   ContactImporter.call(organization, upload.path, ".csv") # => { added: 12, updated: 3 }
  class ContactImporter
    COLUMNS = { "name" => :name, "kind" => :kind, "email" => :email, "phone" => :phone, "address" => :address, "postal code" => :postal_code, "tax number" => :tax_number,
                "payment terms" => :payment_terms_days, "currency" => :currency, "default account" => :default_account, "default tax code" => :default_tax_code, "default withholding code" => :default_withholding_code, "taxable payments" => :taxable_payments,
                "notes" => :notes }.freeze
    YES_NO = { "yes" => true, "y" => true, "true" => true, "1" => true, "no" => false, "n" => false, "false" => false, "0" => false }.freeze

    def self.call(...) = new(...).call

    def initialize(organization, path, extension)
      @organization = organization
      @rows = SpreadsheetRows.read(path, extension)
    end

    def call
      headings = @rows.first.to_a.map { |heading| heading.to_s.strip.downcase.delete_suffix(" (days)") }
      raise ArgumentError, "The file has no Name column" unless headings.include?("name")

      accounts = Account.where(organization: @organization).index_by(&:code)
      tax_codes = TaxCode.where(organization: @organization).index_by(&:code)
      withholding_codes = WithholdingCode.where(organization: @organization).index_by(&:code)
      existing = Contact.where(organization: @organization).index_by { |contact| contact.name.downcase }
      counts = { added: 0, updated: 0 }
      problems = []
      Contact.transaction do
        @rows.drop(1).each.with_index(2) do |cells, number|
          row = headings.zip(cells).to_h { |heading, cell| [ COLUMNS[heading], cell.is_a?(Float) && cell == cell.floor ? cell.to_i.to_s : cell.to_s.strip ] }.except(nil)
          next if row.values.all?(&:blank?)

          contact = existing[row[:name].to_s.squish.downcase] || Contact.new(organization: @organization)
          contact.name = row[:name] if contact.new_record? # one already here keeps its spelling
          contact.assign_attributes(row.slice(:email, :phone, :address, :postal_code, :tax_number, :payment_terms_days, :currency, :notes).compact)
          contact.kind = row[:kind].downcase if row[:kind].present?
          if row[:taxable_payments].present?
            flag = YES_NO[row[:taxable_payments].downcase]
            flag.nil? ? problems << "Row #{number}: taxable payments must be yes or no, not #{row[:taxable_payments]}" : contact.taxable_payments = flag
          end
          { default_account: accounts, default_tax_code: tax_codes, default_withholding_code: withholding_codes }.each do |field, by_code|
            next if row[field].blank?

            by_code[row[field]] ? contact.public_send("#{field}=", by_code[row[field]]) : problems << "Row #{number}: no #{field.to_s.humanize(capitalize: false).delete_prefix('default ')} has the code #{row[field]}"
          end
          added = contact.new_record?
          if contact.save
            counts[added ? :added : :updated] += 1
            existing[contact.name.downcase] = contact
          else
            problems << "Row #{number}: #{contact.errors.full_messages.to_sentence}"
          end
        end
        raise ArgumentError, problems.first(10).join("; ") if problems.any?
      end
      counts
    end
  end
end
