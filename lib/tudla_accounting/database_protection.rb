# frozen_string_literal: true

module TudlaAccounting
  # PostgreSQL triggers that keep the books' history fixed, even against raw SQL: a posted
  # entry or its lines can't be changed or deleted (they are corrected by reversing them),
  # nothing can be posted into a closed period or to an account with sub-accounts (which
  # holds only what they add up to), an account with posted lines of its own can't take
  # sub-accounts, and audit events can't be changed or deleted. Does nothing on other
  # databases.
  #
  # schema.rb can't hold triggers, so they are installed by the engine's migrations and
  # again whenever Rails loads a schema (db:schema:load, db:prepare, db:migrate on an empty
  # database, the test database being brought up to date): see SchemaLoading. Hosts can
  # also call install! themselves, or run tudla_accounting:protect_posted_entries.
  module DatabaseProtection
    # Prepended to ActiveRecord::Tasks::DatabaseTasks (see the engine): reinstalls the
    # triggers on the database a schema was just loaded into. Databases without the
    # engine's tables (Solid Queue's, say) are left alone.
    module SchemaLoading
      def load_schema(...)
        super.tap { DatabaseProtection.install!(migration_connection) }
      end
    end

    SETTING = "tudla_accounting.allow_posted_changes"
    TRIGGERS = {
      "tudla_accounting_protect_posted_entries" => "tudla_accounting_entries",
      "tudla_accounting_protect_posted_details" => "tudla_accounting_details",
      "tudla_accounting_protect_closed_periods" => "tudla_accounting_entries",
      "tudla_accounting_protect_parent_entries" => "tudla_accounting_entries",
      "tudla_accounting_protect_parent_details" => "tudla_accounting_details",
      "tudla_accounting_protect_sub_accounts" => "tudla_accounting_accounts",
      "tudla_accounting_protect_audit_events" => "tudla_accounting_audit_events"
    }.freeze

    module_function

    def install!(connection = ActiveRecord::Base.connection)
      return unless supported?(connection)

      connection.execute(<<~SQL)
        #{function_sql("tudla_accounting_protect_posted_entries", "OLD.posted_at IS NOT NULL", "A posted entry")}
        #{function_sql("tudla_accounting_protect_posted_details",
                       "EXISTS (SELECT 1 FROM tudla_accounting_entries WHERE id = OLD.entry_id AND posted_at IS NOT NULL)",
                       "A line of a posted entry")}
        #{closed_period_function_sql}
        #{parent_account_functions_sql}
        #{audit_function_sql}
        #{trigger_sql(connection, "tudla_accounting_protect_posted_entries", "BEFORE UPDATE OR DELETE")}
        #{trigger_sql(connection, "tudla_accounting_protect_posted_details", "BEFORE UPDATE OR DELETE")}
        #{trigger_sql(connection, "tudla_accounting_protect_closed_periods", "BEFORE INSERT OR UPDATE OF posted_at")}
        #{trigger_sql(connection, "tudla_accounting_protect_parent_entries", "BEFORE INSERT OR UPDATE OF posted_at")}
        #{trigger_sql(connection, "tudla_accounting_protect_parent_details", "BEFORE INSERT OR UPDATE OF account_id, entry_id")}
        #{trigger_sql(connection, "tudla_accounting_protect_sub_accounts", "BEFORE INSERT OR UPDATE OF ancestry")}
        #{trigger_sql(connection, "tudla_accounting_protect_audit_events", "BEFORE UPDATE OR DELETE")}
      SQL
    end

    def uninstall!(connection = ActiveRecord::Base.connection)
      return unless supported?(connection)

      connection.execute(TRIGGERS.map { |name, table| <<~SQL }.join)
        #{"DROP TRIGGER IF EXISTS #{name} ON #{table};" if connection.table_exists?(table)}
        DROP FUNCTION IF EXISTS #{name}();
      SQL
    end

    def installed?(connection = ActiveRecord::Base.connection)
      supported?(connection) &&
        connection.select_value("SELECT COUNT(*) FROM pg_trigger WHERE tgname LIKE 'tudla_accounting_protect_%'").to_i == TRIGGERS.size
    end

    def supported?(connection)
      connection.adapter_name.match?(/postg/i) && connection.table_exists?(:tudla_accounting_entries)
    end

    # Lets the block change or delete posted entries, e.g. when purging an organization's
    # books. The permission covers only the block, even inside a larger transaction: it
    # is switched off when the block finishes, and rolled back with it if it fails.
    def allowing_posted_changes(connection = ActiveRecord::Base.connection, &block)
      return connection.transaction(requires_new: true, &block) unless supported?(connection)

      connection.transaction(requires_new: true) do
        connection.execute("SET LOCAL #{SETTING} = 'on'")
        result = block.call
        connection.execute("SET LOCAL #{SETTING} = 'off'")
        result
      end
    end

    # Each trigger is created once its table exists (the audit table comes in a later
    # migration than the entries).
    def trigger_sql(connection, name, timing)
      return "" unless connection.table_exists?(TRIGGERS.fetch(name))

      <<~SQL
        DROP TRIGGER IF EXISTS #{name} ON #{TRIGGERS.fetch(name)};
        CREATE TRIGGER #{name} #{timing} ON #{TRIGGERS.fetch(name)} FOR EACH ROW EXECUTE FUNCTION #{name}();
      SQL
    end

    # Posting stamps posted_at, so an entry being posted (or inserted already posted) must
    # not fall in a closed period of its organization.
    def closed_period_function_sql
      <<~SQL
        CREATE OR REPLACE FUNCTION tudla_accounting_protect_closed_periods() RETURNS trigger AS $$
        BEGIN
          IF current_setting('#{SETTING}', true) = 'on' OR NEW.posted_at IS NULL THEN
            RETURN NEW;
          END IF;
          IF TG_OP = 'UPDATE' AND OLD.posted_at IS NOT DISTINCT FROM NEW.posted_at THEN
            RETURN NEW;
          END IF;
          IF EXISTS (SELECT 1 FROM tudla_accounting_periods
                     WHERE organization_type = NEW.organization_type AND organization_id = NEW.organization_id
                       AND closed_at IS NOT NULL AND from_date <= NEW.posted_at AND thru_date >= NEW.posted_at) THEN
            RAISE EXCEPTION 'Entry % falls in a closed period and cannot be posted', NEW.id;
          END IF;
          RETURN NEW;
        END;
        $$ LANGUAGE plpgsql;
      SQL
    end

    # An account with sub-accounts holds what they add up to (see BalancePoster), so a
    # posted line goes to one of them: an entry being posted (or a line of a posted entry
    # saved) can't name an account with sub-accounts, and an account with posted lines of
    # its own can't take any. An account's sub-accounts have its ancestry followed by its
    # id; the parent is the last id in an ancestry. (An opening balance of its own is
    # refused by the model alone: AccountRoleAssigner moves one onto the sub-account it
    # makes.)
    def parent_account_functions_sql
      has_sub_accounts = ->(account) do
        "EXISTS (SELECT 1 FROM tudla_accounting_accounts sub WHERE sub.ancestry = #{account}.ancestry || #{account}.id || '/')"
      end
      <<~SQL
        CREATE OR REPLACE FUNCTION tudla_accounting_protect_parent_entries() RETURNS trigger AS $$
        DECLARE
          parent_code text;
        BEGIN
          IF current_setting('#{SETTING}', true) = 'on' OR NEW.posted_at IS NULL THEN
            RETURN NEW;
          END IF;
          IF TG_OP = 'UPDATE' AND OLD.posted_at IS NOT NULL THEN
            RETURN NEW;
          END IF;
          SELECT account.code INTO parent_code FROM tudla_accounting_details line
            JOIN tudla_accounting_accounts account ON account.id = line.account_id
            WHERE line.entry_id = NEW.id AND #{has_sub_accounts.call("account")} LIMIT 1;
          IF parent_code IS NOT NULL THEN
            RAISE EXCEPTION 'Entry % has a line on account %, which has sub-accounts, and cannot be posted', NEW.id, parent_code;
          END IF;
          RETURN NEW;
        END;
        $$ LANGUAGE plpgsql;

        CREATE OR REPLACE FUNCTION tudla_accounting_protect_parent_details() RETURNS trigger AS $$
        BEGIN
          IF current_setting('#{SETTING}', true) = 'on' THEN
            RETURN NEW;
          END IF;
          IF EXISTS (SELECT 1 FROM tudla_accounting_entries WHERE id = NEW.entry_id AND posted_at IS NOT NULL)
             AND EXISTS (SELECT 1 FROM tudla_accounting_accounts account WHERE account.id = NEW.account_id AND #{has_sub_accounts.call("account")}) THEN
            RAISE EXCEPTION 'A line of a posted entry cannot go to account %, which has sub-accounts', NEW.account_id;
          END IF;
          RETURN NEW;
        END;
        $$ LANGUAGE plpgsql;

        CREATE OR REPLACE FUNCTION tudla_accounting_protect_sub_accounts() RETURNS trigger AS $$
        DECLARE
          parent_id bigint := substring(NEW.ancestry from '(\\d+)/$')::bigint;
        BEGIN
          IF current_setting('#{SETTING}', true) = 'on' OR parent_id IS NULL THEN
            RETURN NEW;
          END IF;
          IF EXISTS (SELECT 1 FROM tudla_accounting_details line JOIN tudla_accounting_entries entry ON entry.id = line.entry_id
                     WHERE line.account_id = parent_id AND entry.posted_at IS NOT NULL) THEN
            RAISE EXCEPTION 'Account % has posted lines of its own and cannot take sub-accounts', parent_id;
          END IF;
          RETURN NEW;
        END;
        $$ LANGUAGE plpgsql;
      SQL
    end

    def audit_function_sql
      <<~SQL
        CREATE OR REPLACE FUNCTION tudla_accounting_protect_audit_events() RETURNS trigger AS $$
        BEGIN
          IF current_setting('#{SETTING}', true) = 'on' THEN
            RETURN COALESCE(NEW, OLD);
          END IF;
          RAISE EXCEPTION 'Audit events (id %) cannot be changed or deleted', OLD.id;
        END;
        $$ LANGUAGE plpgsql;
      SQL
    end

    def function_sql(name, posted_condition, subject)
      <<~SQL
        CREATE OR REPLACE FUNCTION #{name}() RETURNS trigger AS $$
        BEGIN
          IF current_setting('#{SETTING}', true) = 'on' THEN
            RETURN COALESCE(NEW, OLD);
          END IF;
          IF #{posted_condition} THEN
            IF TG_OP = 'DELETE' THEN
              RAISE EXCEPTION '#{subject} (id %) cannot be deleted; reverse it instead', OLD.id;
            END IF;
            IF (to_jsonb(NEW) - 'updated_at') IS DISTINCT FROM (to_jsonb(OLD) - 'updated_at') THEN
              RAISE EXCEPTION '#{subject} (id %) cannot be changed; reverse it instead', OLD.id;
            END IF;
          END IF;
          RETURN COALESCE(NEW, OLD);
        END;
        $$ LANGUAGE plpgsql;
      SQL
    end
  end
end
