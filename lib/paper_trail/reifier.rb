require "paper_trail/attribute_serializers/object_attribute"

module PaperTrail
  # Given a version record and some options, builds a new model object.
  # @api private
  module Reifier
    class << self
      # See `VersionConcern#reify` for documentation.
      # @api private
      def reify(version, options)
        options = apply_defaults_to(options, version)
        attrs = version.object_deserialized
        model = init_model(attrs, options, version)
        reify_attributes(model, version, attrs)
        model.send "#{model.class.version_association_name}=", version
        reify_associations(model, options, version)
        model
      end

      private

      # Given a hash of `options` for `.reify`, return a new hash with default
      # values applied.
      # @api private
      def apply_defaults_to(options, version)
        {
          version_at: version.created_at,
          mark_for_destruction: false,
          has_one: false,
          has_many: false,
          belongs_to: false,
          has_and_belongs_to_many: false,
          unversioned_attributes: :nil
        }.merge(options)
      end

      # @api private
      def each_enabled_association(associations)
        associations.each do |assoc|
          next unless assoc.klass.paper_trail.enabled?
          yield assoc
        end
      end

      # Initialize a model object suitable for reifying `version` into. Does
      # not perform reification, merely instantiates the appropriate model
      # class and, if specified by `options[:unversioned_attributes]`, sets
      # unversioned attributes to `nil`.
      #
      # Normally a polymorphic belongs_to relationship allows us to get the
      # object we belong to by calling, in this case, `item`.  However this
      # returns nil if `item` has been destroyed, and we need to be able to
      # retrieve destroyed objects.
      #
      # In this situation we constantize the `item_type` to get hold of the
      # class...except when the stored object's attributes include a `type`
      # key.  If this is the case, the object we belong to is using single
      # table inheritance (STI) and the `item_type` will be the base class,
      # not the actual subclass. If `type` is present but empty, the class is
      # the base class.
      def init_model(attrs, options, version)
        if options[:dup] != true && version.item
          model = version.item
          if options[:unversioned_attributes] == :nil
            init_unversioned_attrs(attrs, model)
          end
        else
          klass = version_reification_class(version, attrs)
          # The `dup` option always returns a new object, otherwise we should
          # attempt to look for the item outside of default scope(s).
          find_cond = { klass.primary_key => version.item_id }
          if options[:dup] || (item_found = klass.unscoped.where(find_cond).first).nil?
            model = klass.new
          elsif options[:unversioned_attributes] == :nil
            model = item_found
            init_unversioned_attrs(attrs, model)
          end
        end
        model
      end

      # Examine the `source_reflection`, i.e. the "source" of `assoc` the
      # `ThroughReflection`. The source can be a `BelongsToReflection`
      # or a `HasManyReflection`.
      #
      # If the association is a has_many association again, then call
      # reify_has_manys for each record in `through_collection`.
      #
      # @api private
      def hmt_collection(through_collection, assoc, options, transaction_id)
        if !assoc.source_reflection.belongs_to? && through_collection.present?
          hmt_collection_through_has_many(
            through_collection, assoc, options, transaction_id
          )
        else
          hmt_collection_through_belongs_to(
            through_collection, assoc, options, transaction_id
          )
        end
      end

      # @api private
      def hmt_collection_through_has_many(through_collection, assoc, options, transaction_id)
        through_collection.each do |through_model|
          reify_has_manys(transaction_id, through_model, options)
        end

        # At this point, the "through" part of the association chain has
        # been reified, but not the final, "target" part. To continue our
        # example, `model.sections` (including `model.sections.paragraphs`)
        # has been loaded. However, the final "target" part of the
        # association, that is, `model.paragraphs`, has not been loaded. So,
        # we do that now.
        through_collection.flat_map { |through_model|
          through_model.public_send(assoc.name.to_sym).to_a
        }
      end

      # @api private
      def hmt_collection_through_belongs_to(through_collection, assoc, options, tx_id)
        ids = through_collection.map { |through_model|
          through_model.send(assoc.source_reflection.foreign_key)
        }
        versions = load_versions_for_hmt_association(assoc, ids, tx_id, options[:version_at])
        collection = Array.new assoc.klass.where(assoc.klass.primary_key => ids)
        prepare_array_for_has_many(collection, options, versions)
        collection
      end

      # Look for attributes that exist in `model` and not in this version.
      # These attributes should be set to nil. Modifies `attrs`.
      # @api private
      def init_unversioned_attrs(attrs, model)
        (model.attribute_names - attrs.keys).each { |k| attrs[k] = nil }
      end

      # Given a `belongs_to` association and a `version`, return a record that
      # can be assigned in order to reify that association.
      # @api private
      def load_record_for_bt_association(assoc, id, options, version)
        if version.nil?
          assoc.klass.where(assoc.klass.primary_key => id).first
        else
          version.reify(
            options.merge(
              has_many: false,
              has_one: false,
              belongs_to: false,
              has_and_belongs_to_many: false
            )
          )
        end
      end

      # Given a `belongs_to` association and an `id`, return a version record
      # from the point in time identified by `transaction_id` or `version_at`.
      # @api private
      def load_version_for_bt_association(assoc, id, transaction_id, version_at)
        assoc.klass.paper_trail.version_class.
          where("item_type = ?", assoc.class_name).
          where("item_id = ?", id).
          where("created_at >= ? OR transaction_id = ?", version_at, transaction_id).
          order("id").limit(1).first
      end

      # Given a HABTM association `assoc` and an `id`, return a version record
      # from the point in time identified by `transaction_id` or `version_at`.
      # @api private
      def load_version_for_habtm(assoc, id, transaction_id, version_at)
        assoc.klass.paper_trail.version_class.
          where("item_type = ?", assoc.klass.name).
          where("item_id = ?", id).
          where("created_at >= ? OR transaction_id = ?", version_at, transaction_id).
          order("id").
          limit(1).
          first
      end

      # Given a has-one association `assoc` on `model`, return the version
      # record from the point in time identified by `transaction_id` or `version_at`.
      # @api private
      def load_version_for_has_one(assoc, model, transaction_id, version_at)
        version_table_name = model.class.paper_trail.version_class.table_name
        model.class.paper_trail.version_class.joins(:version_associations).
          where("version_associations.foreign_key_name = ?", assoc.foreign_key).
          where("version_associations.foreign_key_id = ?", model.id).
          where("#{version_table_name}.item_type = ?", assoc.class_name).
          where("created_at >= ? OR transaction_id = ?", version_at, transaction_id).
          order("#{version_table_name}.id ASC").
          first
      end

      # Given a `has_many` association on `model`, return the version records
      # from the point in time identified by `tx_id` or `version_at`.
      # @api private
      def load_versions_for_hm_association(assoc, model, version_table, tx_id, version_at)
        version_id_subquery = ::PaperTrail::VersionAssociation.
          joins(model.class.version_association_name).
          select("MIN(version_id)").
          where("foreign_key_name = ?", assoc.foreign_key).
          where("foreign_key_id = ?", model.id).
          where("#{version_table}.item_type = ?", assoc.class_name).
          where("created_at >= ? OR transaction_id = ?", version_at, tx_id).
          group("item_id").
          to_sql
        versions_by_id(model.class, version_id_subquery)
      end

      # Given a `has_many(through:)` association and an array of `ids`, return
      # the version records from the point in time identified by `tx_id` or
      # `version_at`.
      # @api private
      def load_versions_for_hmt_association(assoc, ids, tx_id, version_at)
        version_id_subquery = assoc.klass.paper_trail.version_class.
          select("MIN(id)").
          where("item_type = ?", assoc.class_name).
          where("item_id IN (?)", ids).
          where(
            "created_at >= ? OR transaction_id = ?",
            version_at,
            tx_id
          ).
          group("item_id").
          to_sql
        versions_by_id(assoc.klass, version_id_subquery)
      end

      # Set all the attributes in this version on the model.
      def reify_attributes(model, version, attrs)
        enums = model.class.respond_to?(:defined_enums) ? model.class.defined_enums : {}
        AttributeSerializers::ObjectAttribute.new(model.class).deserialize(attrs)
        attrs.each do |k, v|
          # `ObjectAttribute#deserialize` will return the mapped enum value
          # and in Rails < 5, the []= uses the integer type caster from the column
          # definition (in general) and thus will turn a (usually) string to 0 instead
          # of the correct value
          is_enum_without_type_caster = ::ActiveRecord::VERSION::MAJOR < 5 && enums.key?(k)

          if model.has_attribute?(k) && !is_enum_without_type_caster
            model[k.to_sym] = v
          elsif model.respond_to?("#{k}=")
            model.send("#{k}=", v)
          elsif version.logger
            version.logger.warn(
              "Attribute #{k} does not exist on #{version.item_type} (Version id: #{version.id})."
            )
          end
        end
      end

      # Replaces each record in `array` with its reified version, if present
      # in `versions`.
      #
      # @api private
      # @param array - The collection to be modified.
      # @param options
      # @param versions - A `Hash` mapping IDs to `Version`s
      # @return nil - Always returns `nil`
      #
      # Once modified by this method, `array` will be assigned to the
      # AR association currently being reified.
      #
      def prepare_array_for_has_many(array, options, versions)
        # Iterate each child to replace it with the previous value if there is
        # a version after the timestamp.
        array.map! do |record|
          if (version = versions.delete(record.id)).nil?
            record
          elsif version.event == "create"
            options[:mark_for_destruction] ? record.tap(&:mark_for_destruction) : nil
          else
            version.reify(
              options.merge(
                has_many: false,
                has_one: false,
                belongs_to: false,
                has_and_belongs_to_many: false
              )
            )
          end
        end

        # Reify the rest of the versions and add them to the collection, these
        # versions are for those that have been removed from the live
        # associations.
        array.concat(
          versions.values.map { |v|
            v.reify(
              options.merge(
                has_many: false,
                has_one: false,
                belongs_to: false,
                has_and_belongs_to_many: false
              )
            )
          }
        )

        array.compact!

        nil
      end

      # @api private
      def reify_associations(model, options, version)
        if options[:has_one]
          reify_has_one_associations(version.transaction_id, model, options)
        end
        if options[:belongs_to]
          reify_belongs_to_associations(version.transaction_id, model, options)
        end
        if options[:has_many]
          reify_has_manys(version.transaction_id, model, options)
        end
        if options[:has_and_belongs_to_many]
          reify_habtm_associations version.transaction_id, model, options
        end
      end

      # Reify a single `has_one` association of `model`.
      # @api private
      def reify_has_one_association(assoc, model, options, transaction_id)
        version = load_version_for_has_one(assoc, model, transaction_id, options[:version_at])
        return unless version
        if version.event == "create"
          if options[:mark_for_destruction]
            model.send(assoc.name).mark_for_destruction if model.send(assoc.name, true)
          else
            model.paper_trail.appear_as_new_record do
              model.send "#{assoc.name}=", nil
            end
          end
        else
          child = version.reify(
            options.merge(
              has_many: false,
              has_one: false,
              belongs_to: false,
              has_and_belongs_to_many: false
            )
          )
          model.paper_trail.appear_as_new_record do
            without_persisting(child) do
              model.send "#{assoc.name}=", child
            end
          end
        end
      end

      # Restore the `model`'s has_one associations as they were when this
      # version was superseded by the next (because that's what the user was
      # looking at when they made the change).
      # @api private
      def reify_has_one_associations(transaction_id, model, options = {})
        associations = model.class.reflect_on_all_associations(:has_one)
        each_enabled_association(associations) do |assoc|
          reify_has_one_association(assoc, model, options, transaction_id)
        end
      end

      # Reify a single `belongs_to` association of `model`.
      # @api private
      def reify_belongs_to_association(assoc, model, options, transaction_id)
        id = model.send(assoc.association_foreign_key)
        version = load_version_for_bt_association(assoc, id, transaction_id, options[:version_at])
        record = load_record_for_bt_association(assoc, id, options, version)
        model.send("#{assoc.name}=".to_sym, record)
      end

      # Reify all `belongs_to` associations of `model`.
      # @api private
      def reify_belongs_to_associations(transaction_id, model, options = {})
        associations = model.class.reflect_on_all_associations(:belongs_to)
        each_enabled_association(associations) do |assoc|
          reify_belongs_to_association(assoc, model, options, transaction_id)
        end
      end

      # Restore the `model`'s has_many associations as they were at version_at
      # timestamp We lookup the first child versions after version_at timestamp or
      # in same transaction.
      def reify_has_manys(transaction_id, model, options = {})
        assoc_has_many_through, assoc_has_many_directly =
          model.class.reflect_on_all_associations(:has_many).
            partition { |assoc| assoc.options[:through] }
        reify_has_many_associations(transaction_id, assoc_has_many_directly, model, options)
        reify_has_many_through_associations(transaction_id, assoc_has_many_through, model, options)
      end

      # Reify a single, direct (not `through`) `has_many` association of `model`.
      # @api private
      def reify_has_many_association(assoc, model, options, transaction_id, version_table_name)
        versions = load_versions_for_hm_association(
          assoc,
          model,
          version_table_name,
          transaction_id,
          options[:version_at]
        )
        collection = Array.new model.send(assoc.name).reload # to avoid cache
        prepare_array_for_has_many(collection, options, versions)
        model.send(assoc.name).proxy_association.target = collection
      end

      # Reify all direct (not `through`) `has_many` associations of `model`.
      # @api private
      def reify_has_many_associations(transaction_id, associations, model, options = {})
        version_table_name = model.class.paper_trail.version_class.table_name
        each_enabled_association(associations) do |assoc|
          reify_has_many_association(assoc, model, options, transaction_id, version_table_name)
        end
      end

      # Reify a single HMT association of `model`.
      # @api private
      def reify_has_many_through_association(assoc, model, options, transaction_id)
        # Load the collection of through-models. For example, if `model` is a
        # Chapter, having many Paragraphs through Sections, then
        # `through_collection` will contain Sections.
        through_collection = model.send(assoc.options[:through])

        # Now, given the collection of "through" models (e.g. sections), load
        # the collection of "target" models (e.g. paragraphs)
        collection = hmt_collection(through_collection, assoc, options, transaction_id)

        # Finally, assign the `collection` of "target" models, e.g. to
        # `model.paragraphs`.
        model.send(assoc.name).proxy_association.target = collection
      end

      # Reify all HMT associations of `model`. This must be called after the
      # direct (non-`through`) has_manys have been reified.
      # @api private
      def reify_has_many_through_associations(transaction_id, associations, model, options = {})
        each_enabled_association(associations) do |assoc|
          reify_has_many_through_association(assoc, model, options, transaction_id)
        end
      end

      # Reify a single HABTM association of `model`.
      # @api private
      def reify_habtm_association(assoc, model, options, papertrail_enabled, transaction_id)
        version_ids = PaperTrail::VersionAssociation.
          where("foreign_key_name = ?", assoc.name).
          where("version_id = ?", transaction_id).
          pluck(:foreign_key_id)

        model.send(assoc.name).proxy_association.target =
          version_ids.map do |id|
            if papertrail_enabled
              version = load_version_for_habtm(
                assoc,
                id,
                transaction_id,
                options[:version_at]
              )
              if version
                next version.reify(
                  options.merge(
                    has_many: false,
                    has_one: false,
                    belongs_to: false,
                    has_and_belongs_to_many: false
                  )
                )
              end
            end
            assoc.klass.where(assoc.klass.primary_key => id).first
          end
      end

      # Reify all HABTM associations of `model`.
      # @api private
      def reify_habtm_associations(transaction_id, model, options = {})
        model.class.reflect_on_all_associations(:has_and_belongs_to_many).each do |assoc|
          papertrail_enabled = assoc.klass.paper_trail.enabled?
          next unless
            model.class.paper_trail_save_join_tables.include?(assoc.name) ||
                papertrail_enabled
          reify_habtm_association(assoc, model, options, papertrail_enabled, transaction_id)
        end
      end

      # Given a `version`, return the class to reify. This method supports
      # Single Table Inheritance (STI) with custom inheritance columns.
      #
      # For example, imagine a `version` whose `item_type` is "Animal". The
      # `animals` table is an STI table (it has cats and dogs) and it has a
      # custom inheritance column, `species`. If `attrs["species"]` is "Dog",
      # this method returns the constant `Dog`. If `attrs["species"]` is blank,
      # this method returns the constant `Animal`. You can see this particular
      # example in action in `spec/models/animal_spec.rb`.
      #
      def version_reification_class(version, attrs)
        inheritance_column_name = version.item_type.constantize.inheritance_column
        inher_col_value = attrs[inheritance_column_name]
        class_name = inher_col_value.blank? ? version.item_type : inher_col_value
        class_name.constantize
      end

      # Given a SQL fragment that identifies the IDs of version records,
      # returns a `Hash` mapping those IDs to `Version`s.
      #
      # @api private
      # @param klass - An ActiveRecord class.
      # @param version_id_subquery - String. A SQL subquery that selects
      #   the IDs of version records.
      # @return A `Hash` mapping IDs to `Version`s
      #
      def versions_by_id(klass, version_id_subquery)
        klass.
          paper_trail.version_class.
          where("id IN (#{version_id_subquery})").
          inject({}) { |a, e| a.merge!(e.item_id => e) }
      end

      # Temporarily suppress #save so we can reassociate with the reified
      # master of a has_one relationship. Since ActiveRecord 5 the related
      # object is saved when it is assigned to the association. ActiveRecord
      # 5 also happens to be the first version that provides #suppress.
      def without_persisting(record)
        if record.class.respond_to? :suppress
          record.class.suppress { yield }
        else
          yield
        end
      end
    end
  end
end
