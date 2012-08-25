# -*- encoding : utf-8 -*-

class Card < ActiveRecord::Base
  cattr_accessor :cache

  # userstamp methods
  model_stamper # Card is both stamped and stamper
  stampable :stamper_class_name => :card

  #FIXME - need to convert all these to WQL

  belongs_to :trunk, :class_name=>'Card', :foreign_key=>'trunk_id' #, :dependent=>:dependent
  has_many   :right_junctions, :class_name=>'Card', :foreign_key=>'trunk_id'#, :dependent=>:destroy

  belongs_to :tag, :class_name=>'Card', :foreign_key=>'tag_id' #, :dependent=>:destroy
  has_many   :left_junctions, :class_name=>'Card', :foreign_key=>'tag_id'  #, :dependent=>:destroy

  belongs_to :current_revision, :class_name => 'Revision', :foreign_key=>'current_revision_id'
  has_many   :revisions, :order => 'id', :foreign_key=>'card_id'


  attr_accessor :comment, :comment_author, :confirm_rename, :confirm_destroy,
    :cards, :set_mods_loaded, :update_referencers, :allow_type_change,
    :loaded_trunk, :nested_edit, :virtual, :attribute,
    :error_view, :error_status, :selected_rev_id, :attachment_id
    #should build flexible handling for set-specific attributes

  attr_reader :type_args, :broken_type
  
  before_destroy :base_before_destroy
  before_save :set_stamper, :base_before_save, :set_read_rule, :set_tracked_attributes
  after_save :base_after_save, :update_ruled_cards, :update_queue
  
  cache_attributes 'name', 'type_id' #Review - still worth it in Rails 3?

  @@junk_args = %w{ missing skip_virtual id }

  # ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  # INITIALIZATION METHODS

  def self.new args={}, options={}
    args = (args || {}).stringify_keys
    @@junk_args.each { |a| args.delete(a) }
    %w{ type typecode }.each { |k| args.delete(k) if args[k].blank? }
    args.delete('content') if args['attach'] # should not be handled here!

    if name = args['name'] and !name.blank?
      if  Card.cache                                       and
          cc = Card.cache.read_local(name.to_cardname.key) and
          cc.type_args                                     and
          args['type']          == cc.type_args[:type]     and
          args['typecode']      == cc.type_args[:typecode] and
          args['type_id']       == cc.type_args[:type_id]  and
          args['loaded_trunk']  == cc.loaded_trunk

        args['type_id'] = cc.type_id
        return cc.send( :initialize, args )
      end
    end
    super args
  end

  def initialize args={}
    args['name']    = args['name'   ].to_s
    args['type_id'] = args['type_id'].to_i
    
    args.delete('type_id') if args['type_id'] == 0 # can come in as 0, '', or nil
    
    @type_args = { # these are cached to optimize #new
      :type     => args.delete('type'    ),
      :typecode => args.delete('typecode'),
      :type_id  => args[       'type_id' ]
    }

    skip_modules = args.delete 'skip_modules'

    super args
    
    if tid = get_type_id(@type_args)
      self.type_id_without_tracking = tid
    end

    include_set_modules unless skip_modules
    self
  end

  def new_card?() new_record? || @from_trash  end
  def known?()    real? || virtual?           end
  def real?()     !new_card?                  end

  def reset_mods() @set_mods_loaded=false     end
  def include_set_modules
    #warn "including set modules for #{name}"
    unless @set_mods_loaded
      sm=set_modules
      #warn "set modules[#{name}] #{sm.inspect} #{sm.map(&:class)*', '}"
      sm.each {|m| singleton_class.send :include, m }
      @set_mods_loaded=true
    end
    self
  end


  class << self
    def const_missing(const)
      if const.to_s =~ /^([A-Z]\S*)ID$/ and code=$1.underscore.to_sym
        code = ID_CONST_ALIAS[code] || code

        #warn Rails.logger.warn("const_miss #{const.inspect}, #{code.inspect}, #{caller[0..8]*"\n"}")
        if card_id = Wagn::Codename[code]
          #warn Rails.logger.warn("const_miss #{const.inspect}, #{code}, #{card_id}")
          const_set const, card_id
        else raise "Missing codename #{code} (#{const}) #{caller*"\n"}"
        end
      else super end
    end
  end

  ID_CONST_ALIAS = {
    :default_type => :basic,
    :anon        => :anonymous,
    :auth        => :anyone_signed_in,
    :admin       => :administrator
  }

  DefaultTypename = 'Basic'


  def to_user() User.where(:card_id=>id).first end

  def among? authzed
    prties = parties
    authzed.each { |auth| return true if prties.member? auth }
    authzed.member? Card::AnyoneID
  end

  def parties
    @parties ||=  (all_roles << self.id).flatten.reject(&:blank?)
  end

  def read_rules
    @read_rules ||= begin
      if id==Card::WagbotID
        [] # avoids infinite loop
      else
        party_keys = ['in', Card::AnyoneID] + parties
        Session.as_bot do
          Card.search(:right=>'*read', :refer_to=>{:id=>party_keys}, :return=>:id).map &:to_i
        end
      end
    end
  end

  def all_roles
    ids = Session.as_bot { trait_card(:roles).item_cards(:limit=>0).map(&:id) }
    @all_roles ||= (id==Card::AnonID ? [] : [Card::AuthID] + ids)
  end



  def existing_trait_card tagcode
    Card.fetch cardname.trait_name(tagcode), :skip_modules=>true, :skip_virtual=>true
  end

  def trait_card tagcode
    Card.fetch_or_new cardname.trait_name(tagcode), :skip_virtual=>true
  end

  def get_type_id(args={})
    #warn("get_type_id(#{args.inspect})")
    return if args[:type_id]

    type_id = case
      when args[:typecode] ;  code=args[:typecode] and (
                              Wagn::Codename[code] || (c=Card[code] and c.id))
      when args[:type]     ;  Card.fetch_id args[:type]
      else :noop
      end
    
    case type_id
    when :noop      ; 
    when false, nil ; @broken_type = args[:type] || args[:typecode]
    else            ; return type_id
    end
    
    #warn Rails.logger.warn("get_type_id templ #{name} (#{args.inspect})")
    if name && t=template
      reset_patterns
      t.type_id
    else
      # if we get here we have no *all+*default -- let's address that!
      Card::DefaultTypeID  
    end
  end

  

  # ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  # SAVING

  def update_attributes(args={})
    if newtype = args.delete(:type) || args.delete('type')
      args[:type_id] = Card.fetch_id( newtype )
    end
    super args
  end

  def set_stamper()
    #warn "set stamper[#{name}] #{Session.user_id}, #{Session.as_id}" #{caller*"\n"}"
    self.updater_id = Session.user_id
    self.creator_id = self.updater_id if new_card?
    #warn "set stamper[#{name}] #{self.creator_id}, #{self.updater_id}, #{Session.user_id}, #{Session.as_id}" #{caller*"\n"}"
  end

  def base_before_save
    if self.respond_to?(:before_save) and self.before_save == false
      errors.add(:save, "could not prepare card for destruction")
      return false
    end
  end

  def base_after_save
    save_subcards
    self.virtual = false
    @from_trash = false
    Wagn::Hook.call :after_create, self if @was_new_card
    send_notifications
    true
  rescue Exception=>e
    @subcards.each{ |card| card.expire_pieces }
    Rails.logger.info "after save issue: #{e.message}"
    raise e
  end

  def save_subcards
    @subcards = []
    return unless cards
    cards.each_pair do |sub_name, opts|
      opts[:nested_edit] = self
      sub_name = sub_name.gsub('~plus~','+')
      absolute_name = cardname.to_absolute_name(sub_name)
      if card = Card[absolute_name]
        card = card.refresh if card.frozen?
        card.update_attributes opts
      elsif opts[:content].present? and opts[:content].strip.present?
        opts[:name] = absolute_name
        card = Card.create opts
      end
      @subcards << card if card
      if card and card.errors.any?
        card.errors.each do |field, err|
          self.errors.add card.name, err
        end
        raise ActiveRecord::Rollback, "broke save_subcards"
      end
    end
  end

  def save_with_trash!
    save || raise(errors.full_messages.join('. '))
  end
  alias_method_chain :save!, :trash

  def save_with_trash(*args)#(perform_checking=true)
    pull_from_trash if new_record?
    self.trash = !!trash
    save_without_trash(*args)#(perform_checking)
  rescue Exception => e
    Rails.logger.warn "exception #{e} #{caller[0..1]*', '}"
    raise e
  end
  alias_method_chain :save, :trash

  def save_with_permissions *args
    Rails.logger.debug "Card#save_with_permissions:"
    run_checked_save :save_without_permissions
  end
  alias_method_chain :save, :permissions
   
  def save_with_permissions! *args
    Rails.logger.debug "Card#save_with_permissions!"
    run_checked_save :save_without_permissions!
  end
  alias_method_chain :save!, :permissions
  
  def run_checked_save method
    if approved?
      begin
        #warn "run_checked_save #{method}, tc:#{typecode.inspect}, #{type_id.inspect}"
        self.send(method)
      rescue Exception => e
        rescue_save(e, method)
      end
    else
      raise PermissionDenied.new(self)
    end
  end

  def rescue_save(e, method)
    expire_pieces
    #warn "Model exception #{method}:#{e.message} #{name}"
    Rails.logger.info "Model exception #{method}:#{e.message} #{name}"
    Rails.logger.debug "BT [[[\n#{ e.backtrace*"\n"} \n]]]"
    raise Wagn::Oops, "error saving #{self.name}: #{e.message}, #{e.backtrace*"\n"}"
  end

  def expire_pieces
    cardname.piece_names.each do |piece|
      #warn "clearing for #{piece.inspect}"
      Card.clear_cache piece
    end
  end

  def pull_from_trash
    return unless key
    return unless trashed_card = Card.find_by_key_and_trash(key, true)
    #could optimize to use fetch if we add :include_trashed_cards or something.
    #likely low ROI, but would be nice to have interface to retrieve cards from trash...
    self.id = trashed_card.id
    @from_trash = self.confirm_rename = @trash_changed = true
    @new_record = false
  end

  # ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  # DESTROY

  def destroy_with_trash(caller="")
    run_callbacks( :destroy ) do
      deps = self.dependents
      @trash_changed = true
      self.update_attributes :trash => true
      deps.each do |dep|
        next if dep.trash #shouldn't be getting trashed cards
        dep.confirm_destroy = true
        dep.destroy_with_trash("#{caller} -> #{name}")
      end
      true
    end
  end
  alias_method_chain :destroy, :trash

  def destroy_with_validation
    errors.clear
    validate_destroy

    if !dependents.empty? && !confirm_destroy
      errors.add(:confirmation_required, "because #{name} has #{dependents.size} dependents")
    end

    dependents.each do |dep|
      dep.send :validate_destroy
      if !dep.errors[:destroy].empty?
        errors.add(:destroy, "can't destroy dependent card #{dep.name}: #{dep.errors[:destroy]}")
      end
    end

    errors.empty? ? destroy_without_validation : false
  end
  alias_method_chain :destroy, :validation

  def destroy!
    # FIXME: do we want to overide confirmation by setting confirm_destroy=true here?
    # This is aliased in Permissions, which could be related to the above comment
    self.confirm_destroy = true
    destroy or raise Wagn::Oops, "Destroy failed: #{errors.full_messages.join(',')}"
  end

  def base_before_destroy
    self.before_destroy if respond_to? :before_destroy
  end

  def destroy_with_permissions
    ok! :delete
    # FIXME this is not tested and the error will be confusing
    dependents.each do |dep| dep.ok! :delete end
    destroy_without_permissions
  end
  
  def destroy_with_permissions!
    ok! :delete
    dependents.each do |dep| dep.ok! :delete end
    destroy_without_permissions!
  end


  # ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  # NAME / RELATED NAMES


  # FIXME: use delegations and include all cardname functions
  def simple?()     cardname.simple?       end
  def junction?()   cardname.junction?     end
  def key()         cardname.key           end
  def css_name()    cardname.css_name      end

  def left()      Card[cardname.left_name]  end
  def right()     Card[cardname.tag_name]   end
  def pieces()    simple? ? [self] : ([self] + trunk.pieces + tag.pieces).uniq end
  def particles() cardname.particle_names.map {|part| Card.fetch(part) }       end
  def key()       cardname.key                                                 end

  def junctions(args={})
    return [] if new_record? #because lookup is done by id, and the new_records don't have ids yet.  so no point.
    args[:conditions] = ["trash=?", false] unless args.has_key?(:conditions)
    args[:order] = 'id' unless args.has_key?(:order)
    # aparently find f***s up your args. if you don't clone them, the next find is busted.
    left_junctions.find(:all, args.clone) + right_junctions.find(:all, args.clone)
  end

  def dependents(*args)
    # all plus cards, plusses of plus cards, etc
    jcts = junctions(*args)
    jcts.delete(self) if jcts.include?(self)
    return [] if new_record? #because lookup is done by id, and the new_records don't have ids yet.  so no point.
    jcts.map { |r| [r ] + r.dependents(*args) }.flatten
  end

  def repair_key
    Session.as_bot do
      correct_key = cardname.to_key
      current_key = key
      return self if current_key==correct_key

      if key_blocker = Card.find_by_key_and_trash(correct_key, true)
        key_blocker.cardname = key_blocker.cardname + "*trash#{rand(4)}"
        key_blocker.save
      end

      saved =   ( self.key  = correct_key and self.save! )
      saved ||= ( self.cardname = current_key and self.save! )

      if saved
        self.dependents.each { |c| c.repair_key }
      else
        Rails.logger.debug "FAILED TO REPAIR BROKEN KEY: #{key}"
        self.name = "BROKEN KEY: #{name}"
      end
      self
    end
  rescue
    Rails.logger.info "BROKE ATTEMPTING TO REPAIR BROKEN KEY: #{key}"
    self
  end


  # ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  # TYPE

  def type_card() Card[type_id.to_i]     end
  def typecode()  Wagn::Codename[type_id.to_i] end # Should we not fallback to key?
  def typename()
    return if type_id.nil?
    card=Card.fetch(type_id, :skip_modules=>true, :skip_virtual=>true) and card.name
  end

  def type=(typename) self.type_id = Card.fetch_id(typename)        end

  # ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  # CONTENT / REVISIONS

  def content
    #warn "content called for #{name}"
    #new_card? ? template(reset=true).content : cached_revision.content
    new_card? ? template.content : cached_revision.content
  end
  
  def raw_content() hard_template ? template.content : content        end

  def selected_rev_id() @selected_rev_id || (cr=cached_revision)&&cr.id || 0 end

  def cached_revision
    #return current_revision || Card::Revision.new
    if @cached_revision and @cached_revision.id==current_revision_id
    elsif ( Card::Revision.cache &&
       @cached_revision=Card::Revision.cache.read("#{cardname.css_name}-content") and
       @cached_revision.id==current_revision_id )
    else
      rev = current_revision_id ? Card::Revision.find(current_revision_id) : Card::Revision.new()
      @cached_revision = Card::Revision.cache ?
        Card::Revision.cache.write("#{cardname.css_name}-content", rev) : rev
    end
    @cached_revision
  end

  def previous_revision revision
    if !new_card?
      rev_index = revisions.find_index { |rev| rev.id == revision.id }
      revisions[rev_index - 1] if rev_index.to_i != 0
    end
  end

  def revised_at
    (cached_revision && cached_revision.created_at) || Time.now
  end

  def author
    c=Card[creator_id]
    #warn "c author #{creator_id}, #{c}, #{self}"; c
  end

  def updater
    #warn "updater #{updater_id}, #{updater_id}"
    c=Card[updater_id|| Card::AnonID]
    #warn "c upd #{updater_id}, #{c}, #{self}"; c
  end

  def drafts
    revisions.find(:all, :conditions=>["id > ?", current_revision_id])
  end

  def save_draft( content )
    clear_drafts
    revisions.create(:content=>content)
  end

  protected
  def clear_drafts
    connection.execute(%{delete from card_revisions where card_id=#{id} and id > #{current_revision_id} })
  end

  public


  # ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  # METHODS FOR OVERRIDE

  def post_render( content )     content  end
  def clean_html?()                 true  end
  def collection?()                false  end
  def on_type_change()                    end
  def validate_type_change()        true  end
  def validate_content( content )         end


  # ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  # MISCELLANEOUS

  def to_s()  "#<#{self.class.name}[#{type_id < 1 ? 'bogus': typename}:#{type_id}]#{self.attributes['name']}>" end
  #def inspect()  "#<#{self.class.name}##{self.id}[#{type_id < 1 ? 'bogus': typename}:#{type_id}]!#{self.name}!{n:#{new_card?}:v:#{virtual}:I:#{@set_mods_loaded}:O##{object_id}:rv#{current_revision_id}} U:#{updater_id} C:#{creator_id}>" end
  def inspect()  "#<#{self.class.name}(#{object_id})##{self.id}[#{type_id < 1 ? 'bogus': typename}:#{type_id}]!#{
     self.name}!{n:#{new_card?}:v:#{virtual}:I:#{@set_mods_loaded}} R:#{
      @rule_cards.nil? ? 'nil' : @rule_cards.map{|k,v| "#{k} >> #{v.nil? ? 'nil' : v.name}"}*", "}>"
  end
  def mocha_inspect()     to_s                                   end

#  def trash
    # needs special handling because default rails cache lookup uses `@attributes_cache['trash'] ||=`, which fails on "false" every time
#    ac= @attributes_cache
#    ac['trash'].nil? ? (ac['trash'] = read_attribute('trash')) : ac['trash']
#  end





  # ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  # INCLUDED MODULES

  include Wagn::Model

  after_save :after_save_hooks
  # moved this after Wagn::Model inclusions because aikido module needs to come after Paperclip triggers,
  # which are set up in attach model.  CLEAN THIS UP!!!

  def after_save_hooks # don't move unless you know what you're doing, see above.
    Wagn::Hook.call :after_save, self
  end

  #bail out when not recording userstamps (eg updating read rule)
  #skip_callback :save, :after, :after_save_hooks, :save_attached_files,
  # :if => lambda { !Card.record_userstamps }

  # Because of the way it chains methods, 'tracks' needs to come after
  # all the basic method definitions, and validations have to come after
  # that because they depend on some of the tracking methods.
  tracks :name, :type_id, :content, :comment

  # this method piggybacks on the name tracking method and
  # must therefore be defined after the #tracks call


  def cardname() @cardname ||= name_without_cardname.to_cardname end

  alias cardname= name=
  def name_with_cardname=(newname)
    newname = newname.to_s
    if name != newname
      #warn "name_change (reset if rule) #{name_without_tracking}, #{newname}, #{inspect}" unless name_without_tracking.blank?
      reset_patterns_if_rule() # reset the old name

      @cardname = nil
      updates.add :name, newname
      reset_patterns
    end
    newname
  end
  alias_method_chain :name=, :cardname
  def cardname() @cardname ||= name.to_cardname end

  # ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  # VALIDATIONS

  def validate_destroy
    if code=self.codename
      errors.add :destroy, "#{name}'s is a system card. (#{code})<br>  Deleting this card would mess up our revision records."
      return false
    elsif type_id== Card::UserID and Card::Revision.find_by_creator_id( self.id )
      errors.add :destroy, "Edits have been made with #{name}'s user account.<br>  Deleting this card would mess up our revision records."
      return false
    end
    #should collect errors from dependent destroys here.
    true
  end

  protected

  validate do |rec|
    return true if @nested_edit
    return true unless Wagn::Conf[:recaptcha_on] && Card.toggle( rec.rule(:captcha) )
    c = Wagn::Conf[:controller]
    return true if (c.recaptcha_count += 1) > 1
    c.verify_recaptcha( :model=>rec ) || rec.error_status = 449
  end

  validates_each :name do |rec, attr, value|
    if rec.new_card? && value.blank?
      if autoname_card = rec.rule_card(:autoname)
        Session.as_bot do
          autoname_card = autoname_card.refresh if autoname_card.frozen?
          value = rec.name = Card.autoname(autoname_card.content)
          autoname_card.content = value  #fixme, should give placeholder on new, do next and save on create
          autoname_card.save!
        end
      end
    end

    cdname = value.to_cardname
    if cdname.blank?
      rec.errors.add :name, "can't be blank"
    elsif rec.updates.for?(:name)
      #Rails.logger.debug "valid name #{rec.name.inspect} New #{value.inspect}"

      unless cdname.valid?
        rec.errors.add :name,
          "may not contain any of the following characters: #{
          Wagn::Cardname::CARDNAME_BANNED_CHARACTERS}"
      end
      # this is to protect against using a junction card as a tag-- although it is technically possible now.
      if (cdname.junction? and rec.simple? and rec.left_junctions.size>0)
        rec.errors.add :name, "#{value} in use as a tag"
      end

      # validate uniqueness of name
      condition_sql = "cards.key = ? and trash=?"
      condition_params = [ cdname.to_key, false ]
      unless rec.new_record?
        condition_sql << " AND cards.id <> ?"
        condition_params << rec.id
      end
      if c = Card.find(:first, :conditions=>[condition_sql, *condition_params])
        rec.errors.add :name, "must be unique-- A card named '#{c.name}' already exists"
      end

      # require confirmation for renaming multiple cards
      if !rec.confirm_rename
        pass = true
        if !rec.dependents.empty?
          pass = false
          rec.errors.add :confirmation_required, "#{rec.name} has #{rec.dependents.size} dependents"
        end

        if rec.update_referencers.nil? and !rec.extended_referencers.empty?
          pass = false
          rec.errors.add :confirmation_required, "#{rec.name} has #{rec.extended_referencers.size} referencers"
        end

        if !pass
          rec.error_view = :edit
          rec.error_status = 200 #I like 401 better, but would need special processing
        end
      end
    end
  end

  validates_each :content do |rec, attr, value|
    if rec.new_card? && !rec.updates.for?(:content)
      value = rec.content = rec.content #this is not really a validation.  is the double rec.content meaningful?  tracked attributes issue?
    end

    if rec.updates.for? :content
      rec.reset_patterns_if_rule
      rec.send :validate_content, value
    end
  end

  validates_each :current_revision_id do |rec, attrib, value|
    if !rec.new_card? && rec.current_revision_id_changed? && value.to_i != rec.current_revision_id_was.to_i
      rec.current_revision_id = rec.current_revision_id_was
      rec.errors.add :conflict, "changes not based on latest revision"
      rec.error_view = :conflict
      rec.error_status = 409
    end
  end

  validates_each :type_id do |rec, attr, value|
    # validate on update
    #warn "validate type #{rec.inspect}, #{attr}, #{value}"
    if rec.updates.for?(:type_id) and !rec.new_card?
      if !rec.validate_type_change
        rec.errors.add :type, "of #{ rec.name } can't be changed; errors changing from #{ rec.typename }"
      end
      if c = Card.new(:name=>'*validation dummy', :type_id=>value, :content=>'') and !c.valid?
        rec.errors.add :type, "of #{ rec.name } can't be changed; errors creating new #{ value }: #{ c.errors.full_messages * ', ' }"
      end
    end

    # validate on update and create
    if rec.updates.for?(:type_id) or rec.new_record?
      # invalid type recorded on create
      if rec.broken_type
        rec.errors.add :type, "won't work.  There's no cardtype named '#{rec.broken_type}'"
      end      
      
      # invalid to change type when type is hard_templated
      if rt = rec.hard_template and !rt.type_template? and value!=rt.type_id and !rec.allow_type_change
        rec.errors.add :type, "can't be changed because #{rec.name} is hard templated to #{rt.typename}"
      end        
    end
  end

  validates_each :key do |rec, attr, value|
    if value.empty?
      rec.errors.add :key, "cannot be blank"
    elsif value != rec.cardname.to_key
      rec.errors.add :key, "wrong key '#{value}' for name #{rec.name}"
    end
  end

  class << self
    def setting name
      Session.as_bot  do
        card=Card[name] and !card.content.strip.empty? and card.content
      end
    end

    def path_setting name
      name ||= '/'
      return name if name =~ /^(http|mailto)/
      Wagn::Conf[:root_path] + name
    end

    def toggle(val) val == '1' end
  end


  # these old_modules should be refactored out
  require_dependency 'flexmail.rb'
  require_dependency 'google_maps_addon.rb'
  require_dependency 'notification.rb'
end

