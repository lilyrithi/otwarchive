# For exporting to Excel CSV format
require 'iconv'
require 'csv'

class ChallengeSignupsController < ApplicationController

  before_filter :users_only, :except => [:summary, :display_summary, :requests_summary]
  before_filter :load_collection, :except => [:index]
  before_filter :load_challenge, :except => [:index]
  before_filter :load_signup_from_id, :only => [:show, :edit, :update, :destroy]
  before_filter :allowed_to_destroy, :only => [:destroy]
  before_filter :signup_owner_only, :only => [:edit, :update]
  before_filter :maintainer_or_signup_owner_only, :only => [:show]
  before_filter :check_signup_open, :only => [:new, :create, :edit, :update]

  def load_challenge
    @challenge = @collection.challenge
    no_challenge and return unless @challenge
  end

  def no_challenge
    flash[:error] = t('challenges.no_challenge', :default => "What challenge did you want to sign up for?")
    redirect_to collection_path(@collection) rescue redirect_to '/'
    false
  end

  def check_signup_open
    signup_closed and return unless (@challenge.signup_open || @collection.user_is_owner?(current_user) || @collection.user_is_moderator?(current_user))
  end

  def signup_closed
    flash[:error] = t('challenge_signups.signup_closed', :default => "Signup is currently closed: please contact a moderator for help.")
    redirect_to @collection rescue redirect_to '/'
    false
  end

  def signup_owner_only
    not_signup_owner and return unless (@challenge_signup.pseud.user == current_user || (!@challenge.signup_open && @collection.user_is_owner?(current_user)) || (@collection.challenge_type == "PromptMeme" && @collection.user_is_maintainer?(current_user)))
  end

  def maintainer_or_signup_owner_only
    not_allowed and return unless (@challenge_signup.pseud.user == current_user || @collection.user_is_maintainer?(current_user))
  end

  def not_signup_owner
    flash[:error] = t('challenge_signups.not_owner', :default => "You can't edit someone else's signup!")
    redirect_to @collection
    false
  end

  def allowed_to_destroy
    @challenge_signup.user_allowed_to_destroy?(current_user) || not_allowed
  end

  def not_allowed
    flash[:error] = t('challenge_signups.not_allowed', :default => "Sorry, you're not allowed to do that.")
    redirect_to collection_path(@collection) rescue redirect_to '/'
    false
  end

  def load_signup_from_id
    @challenge_signup = ChallengeSignup.find(params[:id])
    no_signup and return unless @challenge_signup
  end

  def no_signup
    flash[:error] = t('challenge_signups.no_signup', :default => "What signup did you want to work on?")
    redirect_to collection_path(@collection) rescue redirect_to '/'
    false
  end

  #### ACTIONS

  def index
    if params[:user_id] && (@user = User.find_by_login(params[:user_id]))
      if current_user == @user
        @challenge_signups = @user.challenge_signups.order_by_date
        render :action => :index and return
      else
        flash[:error] = ts("You aren't allowed to see that user's signups.")
        redirect_to '/' and return
      end
    else
      load_collection
      load_challenge if @collection
      return false unless @challenge
    end

    # using respond_to in order to provide Excel output
    # see below for export_csv method
    respond_to do |format|
      format.html {
          if @challenge.user_allowed_to_see_signups?(current_user)
            @challenge_signups = @collection.signups.joins(:pseud).paginate(:page => params[:page], :per_page => 20, :order => "pseuds.name")
          elsif params[:user_id] && (@user = User.find_by_login(params[:user_id]))
            @challenge_signups = @collection.signups.by_user(current_user)
          else
            not_allowed
          end
      }
      format.csv {
        if (@collection.challenge_type == "GiftExchange" && @challenge.user_allowed_to_see_signups?(current_user)) || 
        (@collection.challenge_type == "PromptMeme" && (
        @collection.user_is_moderator?(current_user) || @collection.user_is_owner?(current_user) || @collection.user_is_maintainer?(current_user)
        ))
          export_csv
        else
          flash[:error] = ts("You aren't allowed to see the CSV summary.")
          redirect_to collection_path(@collection) rescue redirect_to '/' and return
        end
      }
    end
  end

  def summary
    if @collection.signups.count < (ArchiveConfig.ANONYMOUS_THRESHOLD_COUNT/2)
      flash.now[:notice] = ts("Summary does not appear until at least %{count} signups have been made!", :count => ((ArchiveConfig.ANONYMOUS_THRESHOLD_COUNT/2)))
    elsif @collection.signups.count > ArchiveConfig.MAX_SIGNUPS_FOR_LIVE_SUMMARY
      # too many signups in this collection to show the summary page "live"
      if !File.exists?(ChallengeSignup.summary_file(@collection)) ||
          (@collection.challenge.signup_open? && File.mtime(ChallengeSignup.summary_file(@collection)) < 1.hour.ago)
        # either the file is missing, or signup is open and the last regeneration was more than an hour ago.

        # touch the file so we don't generate a second request
        summary_dir = ChallengeSignup.summary_dir
        FileUtils.mkdir_p(summary_dir) unless File.directory?(summary_dir)
        FileUtils.touch(ChallengeSignup.summary_file(@collection))

        # generate the page
        ChallengeSignup.generate_summary(@collection)
      end
    else
      # generate it on the fly
      @tag_type, @summary_tags = ChallengeSignup.generate_summary_tags(@collection)
      @generated_live = true
    end
  end

  def show
  end

  def new
    if (@challenge_signup = ChallengeSignup.in_collection(@collection).by_user(current_user).first)
      flash[:notice] = ts("You are already signed up for this challenge. You can edit your signup below.")
      redirect_to edit_collection_signup_path(@collection, @challenge_signup)
    else
      @challenge_signup = ChallengeSignup.new
    end
  end

  def edit
  end

  def create
    @challenge_signup = ChallengeSignup.new(params[:challenge_signup])
    @challenge_signup.pseud = current_user.default_pseud unless @challenge_signup.pseud
    @challenge_signup.collection = @collection
    # we check validity first to prevent saving tag sets if invalid
    if @challenge_signup.valid? && @challenge_signup.save
      flash[:notice] = 'Signup was successfully created.'
      redirect_to collection_signup_path(@collection, @challenge_signup)
    else
      render :action => :new
    end
  end

  def update
    if @challenge_signup.update_attributes(params[:challenge_signup])
      flash[:notice] = 'Signup was successfully updated.'
      redirect_to collection_signup_path(@collection, @challenge_signup)
    else
      render :action => :edit
    end
  end

  def destroy
    unless @challenge.signup_open || @collection.user_is_maintainer?(current_user)
      flash[:error] = ts("You cannot delete your signup after signups are closed. Please contact a moderator for help.")
    else
      @challenge_signup.destroy
      flash[:notice] = ts("Challenge signup was deleted.")
    end
    if @collection.user_is_maintainer?(current_user)
      redirect_to collection_signups_path(@collection)
    else
      redirect_to @collection
    end
  end


protected

  def request_to_array(type, request)
    any_types = TagSet::TAG_TYPES.select {|type| request && request.send("any_#{type}")}
    any_types.map! { |type| ts("Any %{type}", :type => type.capitalize) }
    tags = request.nil? ? [] : request.tag_set.tags.map {|tag| tag.name}
    rarray = [(tags + any_types).join(", ")]
            
    if @challenge.send("#{type}_restriction").optional_tags_allowed
      rarray << (request.nil? ? "" : request.optional_tag_set.tags.map {|tag| tag.name}.join(", "))
    end
            
    if @challenge.send("#{type}_restriction").description_allowed
      description = (request.nil? ? "" : sanitize_field(request, :description))
      # Didn't find a way to get Excel 2007 to accept line breaks
      # withing a field; not even when the row delimiter is set to
      # \r\n and linebreaks within the field are only \n. :-(
      #
      # Thus stripping linebreaks.
      rarray << description.gsub(/[\n\r]/, " ")
    end
     
    rarray << (request.nil? ? "" : request.url) if
      @challenge.send("#{type}_restriction").url_allowed

    return rarray
  end
  

  def gift_exchange_to_csv
    header = ["Pseud", "Email", "Signup URL"]

    ["request", "offer"].each do |type|
      @challenge.send("#{type.pluralize}_num_allowed").times do |i|
        header << "#{type.capitalize} #{i+1} Tags"
        header << "#{type.capitalize} #{i+1} Optional Tags" if
          @challenge.send("#{type}_restriction").optional_tags_allowed
        header << "#{type.capitalize} #{i+1} Description" if
          @challenge.send("#{type}_restriction").description_allowed
        header << "#{type.capitalize} #{i+1} URL" if
          @challenge.send("#{type}_restriction").url_allowed
      end
    end

    csv_data = CSV.generate(:col_sep => "\t", :encoding => "utf-8") do |csv|
      csv << header
      
      @collection.signups.each do |signup|
        row = [signup.pseud.name, signup.pseud.user.email,
               collection_signup_url(@collection, signup)]

        ["request", "offer"].each do |type|
          @challenge.send("#{type.pluralize}_num_allowed").times do |i|
            row += request_to_array(type, signup.send(type.pluralize)[i])
          end
        end
        csv << row
      end
    end

    return csv_data
  end

  
  def prompt_meme_to_csv
    header = ["Pseud", "Email", "Signup URL", "Tags"]
    header << "Optional Tags" if @challenge.request_restriction.optional_tags_allowed
    header << "Description" if @challenge.request_restriction.description_allowed
    header << "URL" if @challenge.request_restriction.url_allowed

    csv_data = CSV.generate(:col_sep => "\t", :encoding => "utf-8") do |csv|
      csv << header
      @collection.prompts.where(:type => 'Request').each do |request|
        if request.anonymous?
          row = ["(Anonymous)", "", ""]
        else
          row = [request.challenge_signup.pseud.name,
                 request.challenge_signup.pseud.user.email,
                 collection_signup_url(@collection, request.challenge_signup)]
        end

        csv << (row + request_to_array("request", request))
      end
    end

    return csv_data
  end

  
  # Tab-separated CSV with utf-16le encoding (unicode) and byte order
  # mark. This seems to be the only variant Excel can get
  # automatically into proper table format. OpenOffice handles it
  # well, too.
  def export_csv
    csv_data = self.send("#{@challenge.class.name.underscore}_to_csv")
    filename = "#{@collection.name}_signups_#{Time.now.strftime('%Y-%m-%d-%H%M')}.csv"

    byte_order_mark = "\uFEFF"
    csv_data = Iconv.conv("utf-16le", "utf-8", byte_order_mark + csv_data)
    send_data(csv_data, :filename => filename, :type => :csv)
  end
  
end
