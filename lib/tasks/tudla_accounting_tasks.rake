namespace :tudla_accounting do
  desc "Install the database triggers that protect posted entries (PostgreSQL)"
  task protect_posted_entries: :environment do
    TudlaAccounting::DatabaseProtection.install!
  end

  namespace :balances do
    # ORGANIZATION=Type:id picks one organization; otherwise every organization with accounts.
    organizations = lambda do
      if (target = ENV["ORGANIZATION"]).present?
        type, id = target.split(":", 2)
        [ type.constantize.find(id) ]
      else
        TudlaAccounting::Account.distinct.order(:organization_type, :organization_id).pluck(:organization_type, :organization_id).map { |type, id| type.constantize.find(id) }
      end
    end

    describe = lambda do |organization|
      "#{organization.class.name}:#{organization.id}"
    end

    desc "Compare stored balances with the posted entries (ORGANIZATION=Type:id for one); exits 1 on a difference"
    task check: :environment do
      differences = organizations.call.flat_map do |organization|
        TudlaAccounting::BalanceRebuilder.new(organization).differences.each do |difference|
          puts [ describe.call(organization), difference.account.code, difference.period.from_date.to_date, difference.field,
                 "stored #{difference.stored.inspect}", "expected #{difference.expected}" ].join("  ")
        end
      end
      puts differences.empty? ? "Balances agree with the posted entries." : "#{differences.size} difference(s) found."
      exit 1 if differences.any?
    end

    desc "Rewrite stored balances from the posted entries (ORGANIZATION=Type:id for one)"
    task rebuild: :environment do
      organizations.call.each do |organization|
        puts "#{describe.call(organization)}: #{TudlaAccounting::BalanceRebuilder.new(organization).rebuild!} balance(s) corrected"
      end
    end
  end
end
