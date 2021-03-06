require 'data_objects'
require 'rdf/ntriples'
require 'enumerator'
require 'rdf/do/version'

module RDF

  ##
  # RDF::DataObjects offers an RDF::Repository which is backed by a DataObjects
  # connection.  All inserts and deletes to this repository are done in real
  # time; no flushing is required.
  #
  # Each RDF::DataObjects::Repository includes an RDF::DataObjects::Adapter, such as
  # RDF::DataObjects::Adapters::Sqlite3.
  #
  # @see RDF::DataObjects::Adapters
  # @see RDF::Repository
  module DataObjects
    ##
    # RDF::DataObjects::Repository is an RDF::Repository is backed by a
    # DataObjects connection.
    #
    class Repository < RDF::Repository

      ## Create a new RDF::DataObjects::Repository
      # 
      # The `options` parameter can be anything that
      # DataObjects::Connection.new accepts.  The correct
      # RDF::Repository::DataObjects adapter will be loaded based on the URI
      # scheme of the created connection.
      #
      # @example
      #     RDF::DataObjects::Repository.new  # => new Repository based on sqlite3://:memory:
      #     RDF::DataObjects::Repository.new 'postgres://localhost/database'  # => New repository based on postgres adapter
      # @param [Any] options
      # @return [RDF::DataObjects::Repository]
      def initialize(options = {})
        begin
          case options
            when String
              @db     = ::DataObjects::Connection.new(options)
            when Hash
              @db     = ::DataObjects::Connection.new(options[:db])
              adapter = options[:adapter]
              @prefixes = options[:prefixes]
            when nil
              @db    = ::DataObjects::Connection.new('sqlite3://:memory:')
          end
          adapter = @db.instance_variable_get("@uri").scheme
          require 'rdf/do/adapters/' + adapter.to_s
        rescue Exception => e
          raise LoadError, "Could not load a DataObjects adapter for #{options}.  You may need to add a 'require do_adapter', or you may be trying to use an unsupported adapter (Currently supporting postgres, sqlite3).  The error message was: #{e.message}"
        end
        @adapter = RDF::DataObjects::Adapters::const_get(adapter.to_s.capitalize)
        @adapter.migrate? self
      end

      ##
      # Close and dispose of this connection.
      #
      # @return [void]
      def dispose
        close
        @db.dispose
      end

      ##
      # Close this connection.
      #
      # @return [void]
      def close
        @db.close
        @adapter = nil
      end

      ##
      # Returns true if this repository is empty.
      #
      # @see RDF::Enumerable#empty
      # @return [Boolean]
      def empty?
        count == 0
      end

      ##
      # Insert a single statement into this repository.
      #
      # @see RDF::Mutable#insert_statement
      # @param [RDF::Statement]
      # @return [void]
      def insert_statement(statement)
        insert_statements [statement]
      end

      ##
      # Delete a single statement from this repository.
      #
      # @see RDF::Mutable#delete_statement
      # @param [RDF::Statement]
      # @return [void]
      def delete_statement(statement)
        delete_statements [statement]
      end

      ##
      # Insert multiple statements into this repository
      #
      # @see RDF::Mutable#insert_statements
      # @param  [Array]
      # @return [void]
      def insert_statements(statements)
        if @adapter.respond_to?(:multiple_insert_sql)
          each = statements.respond_to?(:each_statement) ? :each_statement : :each
          args = []
          count = 0
          statements.__send__(each) do |s|
            count += 1
            args += [serialize(s. subject),serialize(s.predicate), serialize(s.object), serialize(s.context)]
          end
          query = @adapter.multiple_insert_sql(count)
          exec(query,*(args.flatten))
        else
          query = @adapter.insert_sql
          statements.each do |s|
            exec(query, serialize(s. subject),serialize(s.predicate), serialize(s.object), serialize(s.context)) 
          end
        end
      end

      ##
      # Remove multiple statements from this repository
      #
      # @see RDF::Mutable#delete_statements
      # @param  [Array]
      # @return [void]
      def delete_statements(statements)
        query = @adapter.delete_sql
        statements.each do |s|
          exec(query, serialize(s. subject), serialize(s.predicate), serialize(s.object), serialize(s.context)) 
        end
      end
      
      ##
      # N3/Turtle-style hash of prefixes/namespaces to be used in serialize/unserialize
      # for a smaller database disk space used. From the outside
      # everything should still look like NTriples, prefixes are implemented low level
      # to avoid a dependency to a N3/Turtle parser gem.
      # It is recommended to not add more prefixes once there are triples in
      # the db, otherwise old triples saved without the prefix format will not
      # be returned by queries. In such cases you should first get a list of those
      # old triples, delete them from db, set new prefixes to repository, then add
      # and save the triples using prefixes.
      #
      # @see RDF::DataObjects::Repository#serialize
      # @see RDF::DataObjects::Repository#unserialize
      attr_accessor :prefixes

      ## 
      # Serialize an RDF::Value into N-triples format.
      # Nil values will be encoded as 'nil' to avoid problems with SQL
      # implementations considering null values as distinct from one another.
      # If prefixes are used, the result will be a N3 style "prefix:resourceName" string
      #
      # @see RDF::DataObjects::Repository#unserialize
      # @see RDF::DataObjects::Repository#prefixes
      # @param [RDF::Value]
      # @return [String]
      def serialize(value)
        return 'nil' if value.nil?
        if !@prefixes.nil? && value.respond_to?(:uri?) && value.uri?
          val = value.to_s
          @prefixes.each do |prefix, uri|
            return prefix + ":" + val[uri.length, val.length - uri.length] if val.index(uri) == 0
          end
        end
        RDF::NTriples::Writer.serialize(value)
      end

      ##
      # Unserialize an RDF::Value from N-triples format.
      # Expects nil values to be encoded as 'nil'.
      # If prefixes are used, N3 style strings of a "prefix:resourceName"
      # format will also be unserializad to the full URI.
      #
      # @see RDF::DataObjects::Repository#serialize
      # @see RDF::DataObjects::Repository#prefixes
      # @param [String]
      # @return [RDF::Value]
      def unserialize(value)
        return nil if value == 'nil'
        if !@prefixes.nil?
          @prefixes.each do |prefix, uri|
            return RDF::URI.new(uri + value[prefix.length + 1, value.length - prefix.length - 1]) if value.index(prefix + ":") == 0
          end
        end
        RDF::NTriples::Reader.unserialize(value)
      end
     
      ##
      # Execute the given non-query SQL with the given arguments against this
      # repository's DataObjects::Connection.
      #
      # If the given sql is in a prepared statement format, it will be executed
      # with the given *args.
      #
      # @param [String] sql
      # @param [*RDF::Value] args
      def exec(sql, *args)
        @db.create_command(sql).execute_non_query(*args)
      end

      ##
      # Execute the given query SQL with the given arguments against this
      # repository's DataObjects::Connection.
      #
      # If the given sql is in a prepared statement format, it will be executed
      # with the given *args.
      #
      # @param [String] sql
      # @param [*RDF::Value] args
      def result(sql, *args)
        @db.create_command(sql).execute_reader(*args)
      end

      ##
      # Iterate over all RDF::Statements in this repository.
      #
      # @see RDF::Enumerable#each
      # @param [Proc] &block
      # @return [Enumerable::Enumerator, void]
      def each(&block)
        return enum_for(:each) unless block_given?
        reader = result(@adapter.each_sql)
        while reader.next!
          block.call(RDF::Statement.new(
                     :subject   => unserialize(reader.values[0]),
                     :predicate => unserialize(reader.values[1]),
                     :object    => unserialize(reader.values[2]),
                     :context   => unserialize(reader.values[3])))
        end
      end

      ##
      # Iterate over all RDF::Resource subjects in this repository.
      #
      # @see RDF::Enumerable#each_subject
      # @param [Proc] &block
      # @return [Enumerable::Enumerator, void]
      def each_subject(&block) 
        return enum_for(:each_subject) unless block_given?
        reader = result(@adapter.each_subject_sql)
        while reader.next!
          block.call(unserialize(reader.values[0]))
        end
      end

      ##
      # Iterate over all RDF::Resource predicates in this repository.
      #
      # @see RDF::Enumerable#each_predicate
      # @param [Proc] &block
      # @return [Enumerable::Enumerator, void]
      def each_predicate(&block)
        return enum_for(:each_predicate) unless block_given?
        reader = result(@adapter.each_predicate_sql)
        while reader.next!
          block.call(unserialize(reader.values[0]))
        end
      end

      ##
      # Iterate over all RDF::Value objects in this repository.
      #
      # @see RDF::Enumerable#each_object
      # @param [Proc] &block
      # @return [Enumerable::Enumerator, void]
      def each_object(&block)
        return enum_for(:each_object) unless block_given?
        reader = result(@adapter.each_object_sql)
        while reader.next!
          block.call(unserialize(reader.values[0]))
        end
      end

      ##
      # Iterate over all RDF::Resource contexts in this repository.
      #
      # @see RDF::Enumerable#each_context
      # @param [Proc] &block
      # @return [Enumerable::Enumerator, void]
      def each_context(&block)
        return enum_for(:each_context) unless block_given?
        reader = result(@adapter.each_context_sql)
        while reader.next!
          context = unserialize(reader.values[0])
          block.call(context) unless context.nil?
        end
      end

      ## Implementation of RDF::Queryable#query
      #  
      # This implementation will do well for statements and hashes, and not so
      # well for RDF::Query objects.
      # 
      # Accepts a query pattern argument as in RDF::Queryable.  See
      # {RDF::Queryable} for more information.
      #
      # @param [RDF::Statement, Hash, Array] pattern
      # @return [RDF::Enumerable, void]  
      # @see RDF::Queryable#query
      def query_pattern(pattern, &block)
        ph = pattern.to_hash
        ph = ph.merge(pattern.options) if pattern.respond_to? :options
        reader = @adapter.query(self, ph)
        while reader.next!
          yield RDF::Statement.new(
              :subject   => unserialize(reader.values[0]),
              :predicate => unserialize(reader.values[1]),
              :object    => unserialize(reader.values[2]),
              :context   => unserialize(reader.values[3]))
        end
      end

      ##
      # The number of statements in this repository
      # 
      # @see RDF::Enumerable#count
      # @return [Integer]
      def count
        result = result(@adapter.count_sql)
        result.next!
        result.values.first
      end

    end
  end
end

