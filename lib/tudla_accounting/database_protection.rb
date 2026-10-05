# frozen_string_literal: true

module TudlaAccounting
  # PostgreSQL triggers that refuse to change or delete a posted entry or its lines, even
  # through raw SQL: posted entries are corrected by reversing them. Does nothing on other
  # databases.
  #
  # schema.rb can't hold triggers, so they are installed by the engine's migration and
  # again after db:schema:load (see lib/tasks); hosts can also call install! themselves.
  module DatabaseProtection
    SETTING = "tudla_accounting.allow_posted_changes"

    module_function

    def install!(connection = ActiveRecord::Base.connection)
      return unless supported?(connection)

      connection.execute(<<~SQL)
        #{function_sql("tudla_accounting_protect_posted_entries", "OLD.posted_at IS NOT NULL", "A posted entry")}
        #{function_sql("tudla_accounting_protect_posted_details",
                       "EXISTS (SELECT 1 FROM tudla_accounting_entries WHERE id = OLD.entry_id AND posted_at IS NOT NULL)",
                       "A line of a posted entry")}
        DROP TRIGGER IF EXISTS tudla_accounting_protect_posted_entries ON tudla_accounting_entries;
        CREATE TRIGGER tudla_accounting_protect_posted_entries BEFORE UPDATE OR DELETE ON tudla_accounting_entries
          FOR EACH ROW EXECUTE FUNCTION tudla_accounting_protect_posted_entries();
        DROP TRIGGER IF EXISTS tudla_accounting_protect_posted_details ON tudla_accounting_details;
        CREATE TRIGGER tudla_accounting_protect_posted_details BEFORE UPDATE OR DELETE ON tudla_accounting_details
          FOR EACH ROW EXECUTE FUNCTION tudla_accounting_protect_posted_details();
      SQL
    end

    def uninstall!(connection = ActiveRecord::Base.connection)
      return unless supported?(connection)

      connection.execute(<<~SQL)
        DROP TRIGGER IF EXISTS tudla_accounting_protect_posted_details ON tudla_accounting_details;
        DROP TRIGGER IF EXISTS tudla_accounting_protect_posted_entries ON tudla_accounting_entries;
        DROP FUNCTION IF EXISTS tudla_accounting_protect_posted_details();
        DROP FUNCTION IF EXISTS tudla_accounting_protect_posted_entries();
      SQL
    end

    def installed?(connection = ActiveRecord::Base.connection)
      supported?(connection) &&
        connection.select_value("SELECT COUNT(*) FROM pg_trigger WHERE tgname LIKE 'tudla_accounting_protect_posted_%'").to_i == 2
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
