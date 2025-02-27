require "spec_helper"

module Scenic
  module Adapters
    describe Postgres, :db do
      describe "#create_view" do
        it "successfully creates a view" do
          adapter = Postgres.new

          adapter.create_view("greetings", "SELECT text 'hi' AS greeting")

          expect(adapter.views.map(&:name)).to include("greetings")
        end
      end

      describe "#create_materialized_view" do
        it "successfully creates a materialized view" do
          adapter = Postgres.new

          adapter.create_materialized_view(
            "greetings",
            "SELECT text 'hi' AS greeting"
          )

          view = adapter.views.first
          expect(view.name).to eq("greetings")
          expect(view.materialized).to eq true
        end

        it "handles semicolon in definition when using `with no data`" do
          adapter = Postgres.new

          adapter.create_materialized_view(
            "greetings",
            "SELECT text 'hi' AS greeting; \n",
            no_data: true
          )

          view = adapter.views.first
          expect(view.name).to eq("greetings")
          expect(view.materialized).to eq true
        end

        it "raises an exception if the version of PostgreSQL is too old" do
          connection = double("Connection", supports_materialized_views?: false)
          connectable = double("Connectable", connection: connection)
          adapter = Postgres.new(connectable)
          err = Scenic::Adapters::Postgres::MaterializedViewsNotSupportedError

          expect { adapter.create_materialized_view("greetings", "select 1") }
            .to raise_error err
        end
      end

      describe "#replace_view" do
        it "successfully replaces a view" do
          adapter = Postgres.new

          adapter.create_view("greetings", "SELECT text 'hi' AS greeting")

          view = adapter.views.first.definition
          expect(view).to eql "SELECT 'hi'::text AS greeting;"

          adapter.replace_view("greetings", "SELECT text 'hello' AS greeting")

          view = adapter.views.first.definition
          expect(view).to eql "SELECT 'hello'::text AS greeting;"
        end
      end

      describe "#drop_view" do
        it "successfully drops a view" do
          adapter = Postgres.new

          adapter.create_view("greetings", "SELECT text 'hi' AS greeting")
          adapter.drop_view("greetings")

          expect(adapter.views.map(&:name)).not_to include("greetings")
        end
      end

      describe "#drop_materialized_view" do
        it "successfully drops a materialized view" do
          adapter = Postgres.new

          adapter.create_materialized_view(
            "greetings",
            "SELECT text 'hi' AS greeting"
          )
          adapter.drop_materialized_view("greetings")

          expect(adapter.views.map(&:name)).not_to include("greetings")
        end

        it "raises an exception if the version of PostgreSQL is too old" do
          connection = double("Connection", supports_materialized_views?: false)
          connectable = double("Connectable", connection: connection)
          adapter = Postgres.new(connectable)
          err = Scenic::Adapters::Postgres::MaterializedViewsNotSupportedError

          expect { adapter.drop_materialized_view("greetings") }
            .to raise_error err
        end
      end

      describe "#refresh_materialized_view" do
        it "raises an exception if the version of PostgreSQL is too old" do
          connection = double("Connection", supports_materialized_views?: false)
          connectable = double("Connectable", connection: connection)
          adapter = Postgres.new(connectable)
          err = Scenic::Adapters::Postgres::MaterializedViewsNotSupportedError

          expect { adapter.refresh_materialized_view(:tests) }
            .to raise_error err
        end

        it "can refresh the views dependencies first" do
          connection = double("Connection").as_null_object
          connectable = double("Connectable", connection: connection)
          adapter = Postgres.new(connectable)
          expect(Scenic::Adapters::Postgres::RefreshDependencies)
            .to receive(:call)
            .with(:tests, adapter, connection, concurrently: true)

          adapter.refresh_materialized_view(
            :tests,
            cascade: true,
            concurrently: true
          )
        end

        context "refreshing concurrently" do
          it "raises descriptive error if concurrent refresh is not possible" do
            adapter = Postgres.new
            adapter.create_materialized_view(:tests, "SELECT text 'hi' as text")

            expect {
              adapter.refresh_materialized_view(:tests, concurrently: true)
            }.to raise_error(/Create a unique index with no WHERE clause/)
          end

          it "raises an exception if the version of PostgreSQL is too old" do
            connection = double("Connection", postgresql_version: 90300)
            connectable = double("Connectable", connection: connection)
            adapter = Postgres.new(connectable)
            e = Scenic::Adapters::Postgres::ConcurrentRefreshesNotSupportedError

            expect {
              adapter.refresh_materialized_view(:tests, concurrently: true)
            }.to raise_error e
          end

          it "falls back to non-concurrent refresh if not populated" do
            adapter = Postgres.new
            adapter.create_materialized_view(:testing, "SELECT unnest('{1, 2}'::int[])", no_data: true)

            expect { adapter.refresh_materialized_view(:testing, concurrently: true) }
              .not_to raise_error
          end
        end
      end

      describe "#views" do
        it "returns the views defined on this connection" do
          adapter = Postgres.new

          ActiveRecord::Base.connection.execute <<-SQL
            CREATE VIEW parents AS SELECT text 'Joe' AS name
          SQL

          ActiveRecord::Base.connection.execute <<-SQL
            CREATE VIEW children AS SELECT text 'Owen' AS name
          SQL

          ActiveRecord::Base.connection.execute <<-SQL
            CREATE MATERIALIZED VIEW people AS
            SELECT name FROM parents UNION SELECT name FROM children
          SQL

          ActiveRecord::Base.connection.execute <<-SQL
            CREATE VIEW people_with_names AS
            SELECT name FROM people
            WHERE name IS NOT NULL
          SQL

          expect(adapter.views.map(&:name)).to eq [
            "children",
            "parents",
            "people",
            "people_with_names"
          ]
        end

        context "with views in non public schemas" do
          it "returns also the non public views" do
            adapter = Postgres.new

            ActiveRecord::Base.connection.execute <<-SQL
              CREATE VIEW parents AS SELECT text 'Joe' AS name
            SQL

            ActiveRecord::Base.connection.execute <<-SQL
              CREATE SCHEMA scenic;
              CREATE VIEW scenic.more_parents AS SELECT text 'Maarten' AS name;
              SET search_path TO scenic, public;
            SQL

            expect(adapter.views.map(&:name)).to eq [
              "parents",
              "scenic.more_parents"
            ]
          end
        end
      end

      describe "#populated?" do
        it "returns false if a materialized view is not populated" do
          adapter = Postgres.new

          ActiveRecord::Base.connection.execute <<-SQL
            CREATE MATERIALIZED VIEW greetings AS
            SELECT text 'hi' AS greeting
            WITH NO DATA
          SQL

          expect(adapter.populated?("greetings")).to be false
        end

        it "returns true if a materialized view is populated" do
          adapter = Postgres.new

          ActiveRecord::Base.connection.execute <<-SQL
            CREATE MATERIALIZED VIEW greetings AS
            SELECT text 'hi' AS greeting
          SQL

          expect(adapter.populated?("greetings")).to be true
        end

        it "strips out the schema from table_name" do
          adapter = Postgres.new

          ActiveRecord::Base.connection.execute <<-SQL
            CREATE MATERIALIZED VIEW greetings AS
            SELECT text 'hi' AS greeting
            WITH NO DATA
          SQL

          expect(adapter.populated?("public.greetings")).to be false
        end

        it "raises an exception if the version of PostgreSQL is too old" do
          connection = double("Connection", supports_materialized_views?: false)
          connectable = double("Connectable", connection: connection)
          adapter = Postgres.new(connectable)
          err = Scenic::Adapters::Postgres::MaterializedViewsNotSupportedError

          expect { adapter.populated?("greetings") }.to raise_error err
        end
      end

      describe "#update_materialized_view" do
        it "updates the definition of a materialized view in place" do
          adapter = Postgres.new
          create_materialized_view("hi", "SELECT 'hi' AS greeting")
          new_definition = "SELECT 'hello' AS greeting"

          adapter.update_materialized_view("hi", new_definition)
          result = adapter.connection.execute("SELECT * FROM hi").first["greeting"]

          expect(result).to eq "hello"
        end

        it "updates the definition of a materialized view side by side", :silence do
          adapter = Postgres.new
          create_materialized_view("hi", "SELECT 'hi' AS greeting")
          new_definition = "SELECT 'hello' AS greeting"

          adapter.update_materialized_view("hi", new_definition, side_by_side: true)
          result = adapter.connection.execute("SELECT * FROM hi").first["greeting"]

          expect(result).to eq "hello"
        end

        it "raises an exception if the version of PostgreSQL is too old" do
          connection = double("Connection", supports_materialized_views?: false)
          connectable = double("Connectable", connection: connection)
          adapter = Postgres.new(connectable)

          expect { adapter.create_materialized_view("greetings", "select 1") }
            .to raise_error Postgres::MaterializedViewsNotSupportedError
        end
      end
    end
  end
end
