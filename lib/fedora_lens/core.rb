require 'rdf'
require 'ldp'
require 'active_support/concern'
require 'active_support/core_ext/object'
require 'active_support/core_ext/class/attribute'
require 'active_support/core_ext/module/attribute_accessors'
require 'active_support/core_ext/hash'
require 'fedora_lens/errors'

module FedoraLens
  extend ActiveSupport::Autoload
  autoload :AttributeMethods

  module AttributeMethods
    extend ActiveSupport::Autoload

    eager_autoload do
      autoload :Declarations
      autoload :Read
      autoload :Write
    end
  end

  HOST = "http://localhost:8983/fedora/rest"

  class << self
    def connection
      @@connection ||= Ldp::Client.new(host)
    end

    def host
      HOST
    end

    def base_path
      @@base_path ||= ''
    end

    # Set a base path if you want to put all your objects below a certain path
    # example:
    #   FedoraLens.base_path = '/text
    def base_path= path
      @@base_path =  path
    end

  end

  module Core
    extend ActiveSupport::Concern

    included do
      include FedoraLens::AttributeMethods
      attr_reader :orm
    end

    def initialize(subject_or_data = {}, data = nil)
      init_core(subject_or_data, data)
    end

    def persisted?()      false end

    def errors
      obj = Object.new
      def obj.[](key)         [] end
      def obj.full_messages() [] end
      obj
    end

    def read_attribute_for_validation(key)
      @attributes[key]
    end

    def reload
      @orm = @orm.reload
      @attributes = get_attributes_from_orm(@orm)
    end

    def delete
      @orm.resource.delete
    end

    def save
      new_record? ? create_record : update_record
    end

    def save!
      save || raise(RecordNotSaved)
    end

    def new_record?
      @orm.resource.new?
    end

    def uri
      @orm.try(:resource).try(:subject_uri).try(:to_s)
    end

    def id
      self.class.uri_to_id(URI.parse(uri)) if uri.present?
    end

    protected
      # This allows you to overide the initializer, but still use this behavior
      def init_core(subject_or_data = {}, data = nil)
        case subject_or_data
          when Ldp::Resource::RdfSource
            @orm = Ldp::Orm.new(subject_or_data)
            @attributes = get_attributes_from_orm(@orm)
          when NilClass, Hash
            data = subject_or_data || {}
            @orm = Ldp::Orm.new(Ldp::Resource::RdfSource.new(FedoraLens.connection, nil, RDF::Graph.new, FedoraLens.host + FedoraLens.base_path))
            @attributes = data.with_indifferent_access
          when String
            data ||= {}
            @orm = Ldp::Orm.new(Ldp::Resource::RdfSource.new(FedoraLens.connection, subject_or_data, RDF::Graph.new))
            @attributes = data.with_indifferent_access
          else
            raise ArgumentError, "#{subject_or_data.class} is not acceptable"
          end
      end

      def create_record
        push_attributes_to_orm
        create_and_fetch_attributes
        true
      end

      def update_record
        push_attributes_to_orm
        update_and_fetch_attributes
      end


    private

    def update_and_fetch_attributes
      orm.save!.tap do
        clear_cached_response
        # This is slow, but it enables us to get attributes like http://fedora.info/definitions/v4/repository#lastModified
        # TODO perhaps attributes could be lazily fetched
        @attributes = get_attributes_from_orm(@orm)
        clear_cached_response
      end
    end

    def create_and_fetch_attributes
        @orm = orm.create
        # This is slow, but it enables us to get attributes like http://fedora.info/definitions/v4/repository#created
        # TODO perhaps attributes could be lazily fetched
        @attributes = get_attributes_from_orm(@orm)
        clear_cached_response
    end

    # TODO this causes slowness because we're losing the cached GET response. However it prevents ETag exceptions caused when a
    # subnode is added before an update.
    def clear_cached_response
      # This strips the current cached response (and ETag) from the current ORM to avoid ETag exceptions on the next update,
      # since the etag will change if a child node is added.
      @orm = Ldp::Orm.new @orm.resource.class.new @orm.resource.client, @orm.resource.subject
    end


    def push_attributes_to_orm
      @orm = self.class.orm_to_hash.put(@orm, @attributes)
    end

    def get_attributes_from_orm(orm)
      self.class.orm_to_hash.get(orm).with_indifferent_access
    end

    module ClassMethods
      def find(id)
        resource = Ldp::Resource::RdfSource.new(FedoraLens.connection, id_to_uri(id))
        raise Ldp::NotFound if resource.new?
        self.new(resource)
      end

      def id_to_uri(id)
        id = "/#{id}" unless id.start_with? '/'
        id = FedoraLens.base_path + id unless id.start_with? "#{FedoraLens.base_path}/"
        FedoraLens.host + id
      end

      def uri_to_id(uri)
        id = uri.to_s.sub(FedoraLens.host + FedoraLens.base_path, '')
        id.start_with?('/') ? id[1..-1] : id
      end

      def create(data)
        model = self.new(data)
        model.save
        model
      end

      def orm_to_hash
        if @orm_to_hash.nil?
          aggregate_lens = attributes_as_lenses.inject({}) do |acc, (name, path)|
            lens = path.inject {|outer, inner| Lenses.compose(outer, inner)}
            acc.merge(name => lens)
          end
          @orm_to_hash = Lenses.orm_to_hash(aggregate_lens)
        end
        @orm_to_hash
      end

      # def has_one(name, scope = nil, options = {})
      #   ActiveRecord::Associations::Builder::HasOne.build(self, name, scope, options)
      # end
    end
  end
end

require 'fedora_lens/lenses'

