module TudlaAccounting
  # The tax customers withheld from their payments, by customer and quarter: the certificates
  # still to chase, and marking them received, one amount or a customer's whole quarter. The
  # SAWT lists only what is marked. See WithheldTax.
  class WithholdingCertificatesController < ApplicationController
    Group = Data.define(:contact, :quarter, :rows)

    permits :post, only: %i[mark unmark mark_all]

    def index
      @show = params[:show].presence_in(%w[received all]) || "waiting"
      @customers = organization_scope(Contact).where(id: organization_scope(WithheldTax).by_customer.select(:contact_id)).order(Arel.sql("LOWER(name)"))
      rows = { "waiting" => :certificate_waiting, "received" => :certificate_received, "all" => :standing }.fetch(@show).then { |scope| organization_scope(WithheldTax).by_customer.public_send(scope) }
      rows = rows.where(contact_id: params[:contact_id]) if params[:contact_id].present?
      quarters = FilingQuarters.new(accounting_organization)
      groups = rows.includes(:contact, :withholding_code, :payment).order(:on, :id).group_by { |row| [ row.contact, quarters.of(row.on) ] }
                   .map { |(contact, quarter), held| Group.new(contact: contact, quarter: quarter, rows: held) }
      @page = Paginator.new(groups.sort_by { |group| [ group.quarter.from, group.contact.name.downcase ] }, page: params[:page])
    end

    def mark
      organization_scope(WithheldTax).find(params[:id]).mark_certificate!(on: received_on)
      back notice: "Certificate marked received."
    rescue ArgumentError => e # an unreadable date too
      back alert: "It wasn't marked: #{e.message.downcase_first}."
    end

    def unmark
      organization_scope(WithheldTax).find(params[:id]).unmark_certificate!
      back notice: "Certificate unmarked."
    rescue ArgumentError => e
      back alert: "It wasn't unmarked: #{e.message.downcase_first}."
    end

    def mark_all
      quarter = FilingQuarters.new(accounting_organization).of(Date.iso8601(params[:quarter].to_s))
      rows = organization_scope(WithheldTax).certificate_waiting.where(contact_id: params[:contact_id], on: quarter.range).to_a
      WithheldTax.mark_certificates!(rows, on: received_on)
      back notice: "#{helpers.pluralize(rows.size, 'certificate amount')} marked received."
    rescue ArgumentError => e
      back alert: "They weren't marked: #{e.message.downcase_first}."
    end

    private

    def received_on = Date.iso8601(params[:on].to_s)

    def back(**flash_message) = redirect_back_or_to(withholding_certificates_path, allow_other_host: false, **flash_message)
  end
end
