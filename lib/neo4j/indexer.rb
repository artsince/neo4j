module Neo4j

  # This class is responsible for keeping the lucene index synchronized with the node space
  # Each Neo4j::NodeMixin class has a reference to this class.
  # The node will call a xxx_changed method when a  node has changed.
  # If a trigger is registered on this index for this change then it will
  # find all the nodes that needs to be reindexed.
  #
  class Indexer
    attr_accessor :triggers

    def initialize(lucene_index)
      @lucene_index = lucene_index
      @property_index_updater = PropertyIndexUpdater.new
      @relation_index_updaters = {}
    end
    
    def add_index_on_property(prop)
      @property_index_updater.properties << prop
    end

    def remove_index_on_property(prop)
      @property_index_updater.delete(prop)
    end

    def add_index_in_relation_on_property(index_key, rel_type, prop)
      @relation_index_updaters[index_key] ||= RelationIndexUpdater.new(index_key, rel_type)
      @relation_index_updaters[index_key].properties << prop
    end

    def remove_index_in_relation_on_property(index_key, rel_type, prop)
      @relation_index_updaters[index_key] ||= RelationIndexUpdater.new(index_key, rel_type)
      @relation_index_updaters[index_key].properties.delete(prop)
    end

    def find_updater_for_property(prop)
      all = @relation_index_updaters.values.find_all { |updater| updater.on_property_changed?(prop) }
      all << @property_index_updater if @property_index_updater.on_property_changed?(prop)
      all
    end

    def find_updater_for_relation(relation_type)
      @relation_index_updaters.values.find_all { |updater| updater.on_relation_created_or_deleted?(relation_type) }
    end
    
    def on_property_changed(node, prop)
      # which triggers will be triggered when the property is changed ?
      trigger_update_index(node, find_updater_for_property(prop))
    end

    def on_node_deleted(node)
      @lucene_index.delete(node.neo_node_id)
      # we do not need to trigger reindex with all updaters, since
      # that will be handled with deleted relations
      # trigger_update_index(node, all_updaters)
    end

    def on_relation_created_or_deleted(from_node, relation_type)
      trigger_update_index(from_node, find_updater_for_relation(relation_type))
    end

    # for all the given triggers find all the nodes that they think needs to be reindexed
    def trigger_update_index(node, updaters)
      updaters.each do |updater|
        # notice that a trigger on one node may trigger updates on several other nodes
        updater.nodes_to_be_reindexed(node).each {|related_node| related_node.update_index}
      end
    end

    def all_updaters
      [@property_index_updater] + @relation_index_updaters.values
    end
    
    # This method is called from the Neo4j::NodeMixin class when
    # the index for the nodex should be updated.
    # It is triggered from the Neo4j::Indexer#trigger_update_index method
    def update_index(node)
      document = {:id => node.neo_node_id }
      all_updaters.each do |updater|
        updater.update_document(document, node)
      end

      @lucene_index << document
    end
  end

  class PropertyIndexUpdater
    attr_reader :properties

    def initialize
      @properties = []
    end
    
    def nodes_to_be_reindexed(node)
      puts "nodes_to_be_reindexed '#{node.to_s}'"
      [node]
    end
    
    def on_property_changed?(prop)
      @properties.include?(prop)
    end

    def on_relation_created_or_deleted?(rel_type)
      false
    end

    def update_document(document, node)
      @properties.each {|prop| document[prop] = node.send(prop)}
    end
  end


  # A.x -d-> B.y  A.index d.y
  # B << RelationIndexUpdater.new('d').properties << 'y'
  # when a B node changes then all its A nodes has to be reindexed with the value
  # of all nodes in the d relationship type.
  #
  class RelationIndexUpdater
    attr_reader :rel_type, :properties
    
    def initialize(index_base_key, rel_type)
      @properties = []
      @rel_type = rel_type
      # usally the same as rel_type, but we can have a different name of the
      # index then the name of the relationship type
      @index_base_key = index_base_key
    end

    def on_property_changed?(property)
      @properties.include?(property)
    end

    def on_relation_created_or_deleted?(rel_type)
      @rel_type == rel_type
    end

    def nodes_to_be_reindexed(node)
      node.relations.both(@rel_type).nodes
    end

    def index_key(property)
      "#@index_base_key.#{property}".to_sym
    end
    
    def update_document(node, document)
      return if node.deleted?
      
      relations = node.relations.both(@rel_type).nodes
      relations.each do |other_node|
        next if other_node.deleted?
        @properties.each {|p| document[index_key(p)] = []}
        @properties.each {|p| document[index_key(p)] << other_node.send(p)}
      end

    end
  end

end