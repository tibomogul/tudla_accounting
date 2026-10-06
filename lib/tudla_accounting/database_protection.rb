# frozen_string_literal: true

module TudlaAccounting
  # PostgreSQL triggers that keep the books' history fixed, even against raw SQL: a posted
  # entry or its lines can't be changed or deleted (they are corrected by reversing them),
  # nothing can be posted into a closed period, and audit events can't be changed or
  # deleted. Does nothing on other databases.
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
        #{audit_function_sql}
        #{trigger_sql(connection, "tudla_accounting_protect_posted_entries", "BEFORE UPDATE OR DELETE")}
        #{trigger_sql(connection, "tudla_accounting_protect_posted_details", "BEFORE UPDATE OR DELETE")}
        #{trigger_sql(connection, "tudla_accounting_protect_closed_periods", "BEFORE INSERT OR UPDATE OF posted_at")}
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
