# encoding: utf-8

require 'mongoid'
require 'mongoid-grid_fs'
require 'carrierwave'
require 'carrierwave/validations/active_model'

module CarrierWave
  module Mongoid
    include CarrierWave::Mount
    ##
    # See +CarrierWave::Mount#mount_uploader+ for documentation
    #
    def mount_uploader(column, uploader=nil, options={}, &block)
      field options[:mount_on] || column

      super

      alias_method :read_uploader, :read_attribute
      alias_method :write_uploader, :write_attribute
      public :read_uploader
      public :write_uploader

      include CarrierWave::Validations::ActiveModel

      validates_integrity_of  column if uploader_option(column.to_sym, :validate_integrity)
      validates_processing_of column if uploader_option(column.to_sym, :validate_processing)

      after_save :"store_#{column}!"
      before_save :"write_#{column}_identifier"
      after_destroy :"remove_#{column}!"
      before_update :"store_previous_model_for_#{column}"
      after_save :"remove_previously_stored_#{column}"

      class_eval <<-RUBY, __FILE__, __LINE__+1
        def #{column}=(new_file)
          column = _mounter(:#{column}).serialization_column
          send(:"\#{column}_will_change!")
          super
        end

        # Overrides Mongoid's default dirty behavior to instead work more like
        # ActiveRecord's. Mongoid doesn't deem an attribute as changed unless
        # the new value is different than the original. Given that CarrierWave
        # caches files before save, it's necessary to know that there's a
        # pending change even though the attribute value itself might not
        # reflect that yet.
        def #{column}_changed?
          changed_attributes.has_key?("#{column}")
        end

        def find_previous_model_for_#{column}
          if self.embedded?
            ancestors       = [[ self.metadata.key, self._parent ]].tap { |x| x.unshift([ x.first.last.metadata.key, x.first.last._parent ]) while x.first.last.embedded? }
            first_parent = ancestors.first.last
            reloaded_parent = first_parent.class.unscoped.find(first_parent.to_key.first)
            association = ancestors.inject(reloaded_parent) { |parent,(key,ancestor)| (parent.is_a?(Array) ? parent.find(ancestor.to_key.first) : parent).send(key) }
            association.is_a?(Array) ? association.find(to_key.first) : association
          else
            self.class.unscoped.for_ids(to_key).first
          end
        end

        def serializable_hash(options=nil)
          hash = {}

          except = options && options[:except] && Array.wrap(options[:except]).map(&:to_s)
          only   = options && options[:only]   && Array.wrap(options[:only]).map(&:to_s)

          self.class.uploaders.each do |column, uploader|
            if (!only && !except) || (only && only.include?(column.to_s)) || (except && !except.include?(column.to_s))
              hash[column.to_s] = _mounter(column.to_sym).uploader.serializable_hash
            end
          end
          super(options).merge(hash)
        end
      RUBY
    end
  end # Mongoid
end # CarrierWave

CarrierWave::Storage.autoload :GridFS, 'carrierwave/storage/grid_fs'

class CarrierWave::Uploader::Base
  add_config :grid_fs_access_url

  configure do |config|
    config.storage_engines[:grid_fs] = "CarrierWave::Storage::GridFS"
  end
end

Mongoid::Document::ClassMethods.send(:include, CarrierWave::Mongoid)
