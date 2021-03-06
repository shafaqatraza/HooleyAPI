class Post < ApplicationRecord
  include JsonBuilder
  include AppConstants
  include PgSearch

  belongs_to :member_profile
  belongs_to :event
  
  has_many   :post_members,       dependent: :destroy
  has_many   :post_users,         dependent: :destroy
  has_many   :post_attachments,   dependent: :destroy
  has_many   :comments,           dependent: :destroy, as: :commentable
  has_many   :likes,              dependent: :destroy, as: :likable
  has_one    :user,                                    as: :profile
  has_many   :recent_comments, -> { order(created_at: :desc).limit(10) }, class_name: 'Comment', as: :commentable
  has_many   :recent_likes,    -> { order(created_at: :desc).limit(10) }, class_name: 'Like',    as: :likable
  

  accepts_nested_attributes_for  :post_attachments, :post_members, :post_users

  acts_as_mappable default_units: :miles, lat_column_name: :latitude, lng_column_name: :longitude

  validates :is_post_public, inclusion: {in: [true, false]}
  validates_presence_of :event_id, presence: true

  after_commit :process_hashtags
  @@limit = 10
  @@current_profile = nil

  pg_search_scope :search_by_title,
    against: [:post_description, :post_title],
    using: {
        tsearch:{
            any_word: true,
            dictionary: 'english'
        }
    }

  def process_hashtags
    arr = []
    hashtag_regex, current_user = /\B#\w\w+/
    text_hashtags_title = post_title.scan(hashtag_regex) if post_title.present?
    text_hashtags_description = post_description.scan(hashtag_regex) if post_description.present?
    arr << text_hashtags_title
    arr << text_hashtags_description
    tags = (arr.flatten).uniq
    tags.each do |ar|
      tag_name = Hashtag.find_by_name(ar)
      if tag_name.present?
        tag_name.count = tag_name.count+1
        tag_name.save!
      else
        Hashtag.create name: ar
      end
    end
  end

  def self.post_response(post, current_user)
    post = post.to_xml(
        only: [:id, :post_title, :post_description, :datetime, :post_datetime, :is_post_public, :post_type, :location, :latitude, :longitude, :created_at, :updated_at],
        methods: [:likes_count, :comments_count, :post_members_counts],
        :procs => Proc.new { |options, post|
          options[:builder].tag!('liked_by_me',  Like.liked_by_me(post, current_user.profile_id))
          options[:builder].tag!('is_favourite', Favourite.is_my_favourite(post, current_user.profile_id))
          options[:builder].tag!('is_reported',  ReportPost.is_reported_by_me(post, current_user.profile_id))
        },
        include: {
            member_profile: {
                only: [:id, :photo, :country_id, :is_profile_public, :gender, :dob],
                include: {
                    user: {
                        only: [:id, :first_name, :last_name]
                    }
                }
            },
            event:{
                only:[:id, :event_name]
            },
            post_attachments: {
                only: [:id, :attachment_url, :thumbnail_url, :attachment_type],
                include:{
                    post_photo_users:{
                        only:[:id, :x_coordinate, :y_coordinate, :member_profile_id],
                        include: {
                            member_profile: {
                                only: [:id],
                                include: {
                                    user: {
                                        only: [:id, :first_name, :last_name]
                                    }
                                }
                            }
                        }
                    }
                }
            },
            recent_comments: {
                only: [:id, :comment],
                methods:[:is_co_host_or_host],
                include: {
                    member_profile: {
                        only: [:id, :photo],
                        include: {
                            user: {
                                only: [:id, :first_name, :last_name]
                            }
                        }
                    }
                }
            }
        }
    )
    Hash.from_xml(post).as_json
  end

  def post_members_counts
    self.post_members.count
  end

  def likes_count
    self.likes.where(is_like: true, is_deleted: false).count
  end

  def comments_count
    # self.post_comments.where(is_deleted: false).count
    self.comments.where(is_deleted: false).count
  end

  def count
    # self.post_likes.where(like_status: true, is_deleted: false) + self.post_comments.where(is_deleted: false).count
    self.likes.where(is_like: true, is_deleted: false) + self.comments.where(is_deleted: false).count
  end

  def liked_by_me
    post_like = self.likes.where(member_profile_id: @@current_profile.id).try(:first)
    if post_like && post_like.is_like
      true
    else
      false
    end
  end
  
  def self.post_create(data, current_user, session_id=nil)
    begin
      data    = data.with_indifferent_access
      profile = current_user.profile
      post = profile.posts.build(data[:post])
      if post.save
        resp_data       = post_response(post, current_user)
        resp_status     = 1
        resp_message    = 'Post Created'
        resp_errors     = ''
      else
        resp_data       = {}
        resp_status     = 0
        resp_message    = 'Errors'
        resp_errors     = post.errors.messages
      end
    rescue Exception => e
      resp_data       = {}
      resp_status     = 0
      paging_data     = ''
      resp_message    = 'error'
      resp_errors     = e
    end
    if session_id.present?
      resp_data = resp_data.merge!(session_id: session_id)
    end
    resp_request_id = data[:request_id]
    JsonBuilder.json_builder(resp_data, resp_status, resp_message, resp_request_id, errors: resp_errors)
  end

  def self.post_sync(post_id, current_user)
    posts = Post.where(id: post_id)
    member_profile_ids = []
    member_profile_ids << posts.first.post_members.pluck(:member_profile_id)
    
    # Followers
    member_profile_ids << MemberFollowing.where("following_profile_id = ? AND following_status = ? ", current_user.profile_id, AppConstants::ACCEPTED).pluck(:member_profile_id)
    users    = User.where(profile_id: member_profile_ids.flatten.uniq)
    user_ids = []
    user_ids << current_user.id
    user_ids << users.pluck(:id)
    user_ids  = user_ids.flatten.uniq
    open_sessions = OpenSession.where(user_id: user_ids)
    open_sessions.each do |open_session|
      profile = User.find_by_id(open_session.user_id).profile
      if open_session.media_type == AppConstants::FOLLOWING
        sync_post_to_following_response(open_session.user_id, profile, posts, open_session.session_id)
      elsif open_session.media_type == AppConstants::NEAR_ME
        near_post = Post.within(profile.near_event_search, :origin => [profile.latitude, profile.longitude]).where(id: post_id)
        if near_post.present?
          sync_post_to_following_response(open_session.user_id, profile, posts, open_session.session_id)
        end
      end
    end
  end

  def self.sync_post_to_following_response(user_id, profile, posts, session_id)
    sync_object             = profile.synchronizations.build
    sync_object.sync_token  = SecureRandom.uuid
    sync_object.sync_type   = AppConstants::FOLLOWING
    sync_object.synced_date = posts.first.updated_at
    sync_object.save!

    resp_data       = posts_array_response(posts, profile, sync_object.sync_token)
    resp_data       = resp_data.merge!(session_id: session_id)
    resp_status     = 1
    resp_request_id = ''
    resp_message    = 'Posts'
    resp_errors     = ''
    response        = JsonBuilder.json_builder(resp_data, resp_status, resp_message, resp_request_id, errors: resp_errors, type: "Sync")
    PostJob.perform_later response, user_id
  end

  def self.post_destroy(data, current_user)
    begin
      data = data.with_indifferent_access
      post = Post.find_by_id(data[:post][:id])
      post.is_deleted = true
      post.save!
      resp_status   = 1
      resp_message  = 'Post deleted'
      resp_errors   = ''
      resp_data     = {}
    rescue Exception => e
      resp_data     = ''
      resp_status   = 0
      paging_data   = ''
      resp_message  = 'error'
      resp_errors   = e
    end
    resp_request_id   = data[:request_id]
    JsonBuilder.json_builder(resp_data, resp_status, resp_message, resp_request_id, errors: resp_errors)
  end

  def self.post_show(data, current_user)
    begin
      data = data.with_indifferent_access
      post = Post.find_by_id(data[:post][:id])
      if post
        resp_data    = post_response(post, current_user)
        resp_status  = 1
        resp_message = 'success'
        resp_errors  = ''
      else
        resp_data    = ''
        resp_status  = 0
        resp_message = 'Errors'
        resp_errors  = 'Post Does not exist'
      end
    rescue Exception => e
      resp_data       = ''
      resp_status     = 0
      paging_data     = ''
      resp_message    = 'error'
      resp_errors     = e
    end
    resp_request_id   = data[:request_id]
    JsonBuilder.json_builder(resp_data, resp_status, resp_message, resp_request_id, errors: resp_errors)
  end

  def self.post_update(data, current_user)
    begin
      data = data.with_indifferent_access
      post = current_user.profile.posts.where(id: data[:post][:id]).try(:first)
      if post
        post.update_attributes(data[:post])
        resp_data = post_response(post, current_user)
        resp_status = 1
        resp_message = 'Updated Successfully'
        resp_errors = ''
      else
        resp_data = ''
        resp_status = 0
        resp_message = 'Errors'
        resp_errors = 'Post Does not exist'
      end
    rescue Exception => e
      resp_data       = ''
      resp_status     = 0
      paging_data     = ''
      resp_message    = 'error'
      resp_errors     = e
    end
    resp_request_id   = data[:request_id]
    JsonBuilder.json_builder(resp_data, resp_status, resp_message, resp_request_id, errors: resp_errors)
  end
  # Not in Use
  def self.post_list(data, current_user)
    begin
      data = data.with_indifferent_access
      max_post_date = data[:max_post_date] || Time.now
      min_post_date = data[:min_post_date] || Time.now

      profile = current_user.profile
      following_ids= profile.member_followings.where(following_status: AppConstants::ACCEPTED).pluck(:following_profile_id)

      # posts = Post.where("member_profile_id = ? OR is_post_public = ? OR member_profile_id IN (?) OR is_deleted = ?", current_user.profile_id, true, following_ids, false)
      following_ids << profile.id
      post_ids      = PostMember.where(member_profile_id: profile.id).pluck(:post_id)
      posts = Post.where("(member_profile_id IN (?) OR id IN (?)) AND is_deleted = ?", following_ids, post_ids, false).distinct
      
      if data[:max_post_date].present?
        posts = posts.where("created_at > ?", max_post_date)
      elsif data[:min_post_date].present?
        posts = posts.where("created_at < ?", min_post_date)
      end
      posts = posts.order("created_at DESC")
      posts = posts.limit(@@limit)

      if posts.present?
        Post.where("created_at > ?", posts.first.created_at).present? ? previous_page_exist = true : previous_page_exist = false
        Post.where("created_at < ?", posts.last.created_at).present? ? next_page_exist = true : next_page_exist = false
      end
      resp_data = posts_array_response(posts, profile)
      resp_status = 1
      resp_message = 'Post list'
      resp_errors = ''
    rescue Exception => e
      resp_data       = ''
      resp_status     = 0
      paging_data     = ''
      resp_message    = 'error'
      resp_errors     = e
    end
    resp_request_id   = data[:request_id]
    JsonBuilder.json_builder(resp_data, resp_status, resp_message, resp_request_id, errors: resp_errors, next_page_exist: next_page_exist, previous_page_exist: previous_page_exist, post_list: true)
  end

  def self.newly_created_following_posts(current_user, session_id, is_start_sync)
    begin
      last_subs_date = current_user.last_subscription_time
      profile        = current_user.profile
      @limit         = 20
      following_ids = profile.member_followings.where(following_status: AppConstants::ACCEPTED).pluck(:following_profile_id)
      following_ids << profile.id
      post_ids      = PostMember.where(member_profile_id: profile.id).pluck(:post_id)
      posts = Post.where("(member_profile_id IN (?) OR id IN (?)) AND is_deleted = ? OR is_post_public = ?", following_ids, post_ids, false, true).distinct
      
      if is_start_sync.present?
        posts = posts.order("created_at DESC")
        posts = posts.limit(@limit)
        start = 'start_sync'
      elsif last_subs_date.present? && TimeDifference.between(Time.now, last_subs_date).in_minutes < 30
        if current_user.following_sync_datetime.present?
          posts = posts.where("created_at > ?", current_user.following_sync_datetime)
          posts = posts.order("created_at DESC")
          start = false
        else
          posts = posts.order("created_at DESC")
          posts = posts.limit(@limit)
          start = 'start_sync'
        end
      else
        posts = posts.order("created_at DESC")
        posts = posts.limit(@limit)
        start = 'start_sync'
      end

      # if current_user.following_sync_datetime.blank?
      #   current_user.following_sync_datetime = Time.now
      #   current_user.save!
      # end
      
      if start == 'start_sync' && posts.present?
        Post.where("created_at < ?", posts.last.created_at).present? ? next_page_exist = true : next_page_exist = false
      end

      if posts.present?
        sync_object             = profile.synchronizations.first ||  profile.synchronizations.build
        sync_object.sync_token  = SecureRandom.uuid
        sync_object.sync_type   = AppConstants::FOLLOWING
        sync_object.synced_date = posts.first.updated_at
        sync_object.save!

        resp_data       = posts_array_response(posts, profile, sync_object.sync_token)
        resp_data       = resp_data.merge!(session_id: session_id)
        paging_data     = {next_page_exist: next_page_exist}
        resp_status     = 1
        resp_request_id = ''
        resp_message    = 'Posts'
        resp_errors     = ''
        if start == 'start_sync'
          JsonBuilder.json_builder(resp_data, resp_status, resp_message, resp_request_id, errors: resp_errors, start: start, type: 'Sync', paging_data: paging_data)
        else
          JsonBuilder.json_builder(resp_data, resp_status, resp_message, resp_request_id, errors: resp_errors, start: start, type: 'Sync')
        end
      else
        resp_data       = {session_id: session_id}
        resp_status     = 0
        resp_request_id = ''
        resp_message    = 'Posts Not Found'
        resp_errors     = ''
        JsonBuilder.json_builder(resp_data, resp_status, resp_message, resp_request_id, errors: resp_errors)
      end
    rescue Exception => e
      resp_data       = {session_id: session_id}
      resp_status     = 0
      paging_data     = ''
      resp_message    = 'error'
      resp_errors     = e
      JsonBuilder.json_builder(resp_data, resp_status, resp_message, resp_request_id, errors: resp_errors)
    end
  end

  def self.newly_created_nearest_posts(current_user, session_id, is_start_sync)
    begin
      last_subs_date = current_user.last_subscription_time
      profile        = current_user.profile
      @limit         = 20
      # posts = Post.within(profile.near_event_search, :origin => [profile.latitude, profile.longitude])
      event_ids = Event.within(profile.near_event_search, :origin => [profile.latitude, profile.longitude]).pluck(:id)
      posts     = Post.where(event_id: event_ids, is_deleted: false, is_post_public: true)
    
      if is_start_sync.present?
        posts = posts.order("created_at DESC")
        posts = posts.limit(@limit)
        start = 'start_sync'
      elsif last_subs_date.present? && TimeDifference.between(Time.now, last_subs_date).in_minutes < 30
        if current_user.nearme_sync_datetime.present?
          posts = posts.where("created_at > ?", current_user.nearme_sync_datetime)
          posts = posts.order("created_at DESC")
          start = false
        else
          posts = posts.order("created_at DESC")
          posts = posts.limit(@limit)
          start = 'start_sync'
        end
      else
        posts = posts.order("created_at DESC")
        posts = posts.limit(@limit)
        start = 'start_sync'
      end
    
      # if current_user.nearme_sync_datetime.blank?
      #   current_user.nearme_sync_datetime = Time.now
      #   current_user.save!
      # end

      if start == 'start_sync' && posts.present?
        Post.where("created_at < ?", posts.last.created_at).present? ? next_page_exist = true : next_page_exist = false
      end
    
      if posts.present?
        sync_object             = profile.synchronizations.first ||  profile.synchronizations.build
        sync_object.sync_token  = SecureRandom.uuid
        sync_object.sync_type   = AppConstants::NEAR_ME
        sync_object.synced_date = posts.first.created_at
        sync_object.save!
      
        resp_data       = posts_array_response(posts, profile, sync_object.sync_token)
        resp_data       = resp_data.merge!(session_id: session_id)
        paging_data     = {next_page_exist: next_page_exist}
        resp_status     = 1
        resp_request_id = ''
        resp_message    = 'Posts'
        resp_errors     = ''
        if start == 'start_sync'
          JsonBuilder.json_builder(resp_data, resp_status, resp_message, resp_request_id, errors: resp_errors, start: start, type: 'Sync', paging_data: paging_data)
        else
          JsonBuilder.json_builder(resp_data, resp_status, resp_message, resp_request_id, errors: resp_errors, start: start, type: 'Sync')
        end
      else
        resp_data       = {session_id: session_id}
        resp_status     = 0
        resp_request_id = ''
        resp_message    = 'Posts Not Found'
        resp_errors     = ''
        JsonBuilder.json_builder(resp_data, resp_status, resp_message, resp_request_id, errors: resp_errors)
      end
    rescue Exception => e
      resp_data       = {session_id: session_id}
      resp_status     = 0
      paging_data     = ''
      resp_message    = 'error'
      resp_errors     = e
      JsonBuilder.json_builder(resp_data, resp_status, resp_message, resp_request_id, errors: resp_errors)
    end
  end

  def self.newly_created_trending_posts(current_user, session_id, is_start_sync)
    begin
      last_subs_date = current_user.last_subscription_time
      profile        = current_user.profile
      @limit         = 20
      posts      = Post.order("RANDOM()")
      posts      = posts.where(is_post_public: true)
      hash_tags  = Hashtag.order("RANDOM()").order("created_at DESC")
      
      if is_start_sync.present?
        posts = posts.order("created_at DESC")
        posts = posts.limit(@limit)
        start = 'start_sync'
      elsif last_subs_date.present? && TimeDifference.between(Time.now, last_subs_date).in_minutes < 30
        if current_user.trending_sync_datetime.present?
          posts = posts.where("created_at > ?", current_user.trending_sync_datetime)
          posts = posts.order("created_at DESC")
          start = false
        else
          posts = posts.order("created_at DESC")
          posts = posts.limit(@limit)
          start = 'start_sync'
        end
      else
        posts = posts.order("created_at DESC")
        posts = posts.limit(@limit)
        start = 'start_sync'
      end
    
      # if current_user.trending_sync_datetime.blank?
      #   current_user.trending_sync_datetime = Time.now
      #   current_user.save!
      # end

      if start == 'start_sync' && posts.present?
        Post.where("created_at < ?", posts.last.created_at).present? ? next_page_exist = true : next_page_exist = false
      end
    
      if posts.present?
        sync_object             = profile.synchronizations.first ||  profile.synchronizations.build
        sync_object.sync_token  = SecureRandom.uuid
        sync_object.sync_type   = AppConstants::NEAR_ME
        sync_object.synced_date = posts.first.created_at
        sync_object.save!
      
        resp_data       = posts_array_response(posts, profile, sync_object.sync_token)
        # resp_data       = trending_api_loop_response(posts, hash_tags, false, current_user)
        resp_data       = resp_data.merge!(session_id: session_id, sync_token: sync_object.sync_token)
        paging_data     = {next_page_exist: next_page_exist}
        resp_status     = 1
        resp_request_id = ''
        resp_message    = 'Posts'
        resp_errors     = ''
        if start == 'start_sync'
          JsonBuilder.json_builder(resp_data, resp_status, resp_message, resp_request_id, errors: resp_errors, start: start, type: 'Sync', paging_data: paging_data)
        else
          JsonBuilder.json_builder(resp_data, resp_status, resp_message, resp_request_id, errors: resp_errors, start: start, type: 'Sync')
        end
      else
        resp_data       = {session_id: session_id}
        resp_status     = 0
        resp_request_id = ''
        resp_message    = 'Posts Not Found'
        resp_errors     = ''
        JsonBuilder.json_builder(resp_data, resp_status, resp_message, resp_request_id, errors: resp_errors)
      end
    rescue Exception => e
      resp_data       = {session_id: session_id}
      resp_status     = 0
      paging_data     = ''
      resp_message    = 'error'
      resp_errors     = e
      JsonBuilder.json_builder(resp_data, resp_status, resp_message, resp_request_id, errors: resp_errors)
    end
  end

  def self.trending_list(data, current_user)
    begin
      data     = data.with_indifferent_access
      per_page = (data[:per_page] || @@limit).to_i
      page     = (data[:page] || 1).to_i

      country_name = current_user.profile.try(:country).try(:country_name)
      if data[:search].present? && data[:search][:key].present?
        search_key = data[:search][:key]
        posts      = Post.where("(lower(post_title) like ? OR lower(post_description) like ?) AND is_deleted = false", "%#{search_key}%".downcase, "%#{search_key}%".downcase)
        hash_tags  = Hashtag.where("lower(name) like ?", "%#{search_key}%".downcase)
      elsif country_name.present?
        member_ids = MemberProfile.where(country_id: current_user.profile.country_id).pluck(:id)
        posts      = Post.where(member_profile_id: member_ids, is_deleted: false)
        hash_tags  = Hashtag.where("lower(name) like ?", "%#{country_name}%".downcase)
      else
        posts      = Post.order("RANDOM()").order("created_at DESC")
        hash_tags  = Hashtag.order("RANDOM()").order("created_at DESC")
      end

      posts       = posts.page(page.to_i).per_page(per_page.to_i)
      hash_tags   = hash_tags.page(page.to_i).per_page(per_page.to_i)
      paging_data = JsonBuilder.get_paging_data(page, per_page, posts)

      resp_data    = trending_api_loop_response(posts, hash_tags, false, current_user)
      resp_status  = 1
      resp_message = 'Trending list'
      resp_errors  = ''
    rescue Exception => e
      resp_data    = {}
      resp_status  = 0
      paging_data  = ''
      resp_message = 'error'
      resp_errors  = e
    end
    resp_request_id   = data[:request_id]
    JsonBuilder.json_builder(resp_data, resp_status, resp_message, resp_request_id, errors: resp_errors, paging_data: paging_data)
  end

  def self.trending_api_loop_response(posts, hash_tags, status, current_user, member_profiles=nil)
    resp_array = []
    posts_array = []
    hash_tags_array = []
    profiles_array = []
    posts && posts.each do |post|
      member_profile   = post.member_profile
      post_attachments = post.post_attachments.as_json(
         only: [:id, :attachment_url, :thumbnail_url, :attachment_type],
         include:{
            post_photo_users: {
                only: [:id, :x_coordinate, :y_coordinate],
                include:{
                    member_profile:{
                        only:[:id],
                        include:{
                            user:{
                                only: [:id, :first_name, :last_name]
                            }
                        }
                    }
                }
            }
         }
      )
      user  = member_profile.user
      posts_array << {
          type: 'Post',
          id: post.id,
          post_title:       post.post_title,
          post_description: post.post_description,
          is_post_public:   post.is_post_public,
          post_type:        post.post_type,
          location:         post.location,
          latitude:         post.latitude,
          longitude:        post.longitude,
          likes_count:      post.likes.count,
          comments_count:   post.comments.count,
          post_members_counts: post.post_members.count,
          liked_by_me: Like.liked_by_me(post, current_user.profile_id),
          is_favourite: Favourite.is_my_favourite(post, current_user.profile_id),
          count: post.likes.where(is_like: true, is_deleted: false).count + post.comments.where(is_deleted: false).count,
          member_profile: {
              id:     member_profile.id,
              photo:  member_profile.photo,
              gender: member_profile.gender,
              user: {
                  id:         user.id,
                  first_name: user.first_name,
                  last_name:  user.last_name
              }
          },
          post_attachments:  post_attachments
      }
    end

    # Hashtag
    hash_tags && hash_tags.each do |hash_tag|
      hash_tags_array << {
          type:  'HashTag',
          id:    hash_tag.id,
          name:  hash_tag.name,
          count: hash_tag.count
      }
    end

    if status.present?
      member_profiles && member_profiles.each do |profile|
        user = profile.user
        profiles_array << {
            type:  'MemberProfile',
            id:    profile.id,
            photo: profile.photo,
            is_im_following:  MemberProfile.is_following(profile, current_user),
            is_my_follower:   MemberProfile.is_follower(profile, current_user),
            user: {
                id:         user.id,
                first_name: user.first_name,
                last_name:  user.last_name,
            }
        }
      end
      resp_array << profiles_array
      resp_array << posts_array
      resp_array << hash_tags_array
      response = resp_array.flatten
      {dicsover_list: response}.as_json
    else
      resp_array << posts_array.take(10)
      # resp_array << hash_tags_array.take(2)
      response = resp_array.flatten.sort_by { |hsh| hsh[:count] }.reverse
      {trending: response}.as_json
    end
  end

  def self.posts_array_response(post_array, profile, sync_token=nil)
    if post_array.present?
      posts = post_array.to_xml(
          only: [:id, :post_title, :event_id, :post_description, :is_post_public, :is_deleted, :created_at, :updated_at, :post_type, :location, :latitude, :longitude],
          methods: [:likes_count, :comments_count],
          :procs => Proc.new { |options, post|
            options[:builder].tag!('liked_by_me', Like.liked_by_me(post, profile.id))
            options[:builder].tag!('is_favourite', Favourite.is_my_favourite(post, profile.id))
            options[:builder].tag!('is_reported', ReportPost.is_reported_by_me(post, profile.id))
          },
          include: {
              member_profile: {
                  only: [:id, :photo, :country_id, :is_profile_public, :gender],
                  include: {
                      user: {
                          only: [:id, :first_name, :last_name]
                      }
                  }
              },
              event:{
                  only:[:id, :event_name]
              },
              recent_likes: {
                  only: [:id, :created_at, :updated_at],
                  include: {
                      member_profile: {
                          only: [:id, :photo],
                          include: {
                              user: {
                                  only: [:id, :first_name, :last_name]
                              }
                          }
                      }
                  }
              },
              recent_comments: {
                  only: [:id, :comment],
                  methods:[:is_co_host_or_host],
                  include: {
                      member_profile: {
                          only: [:id, :photo],
                          include: {
                              user: {
                                  only: [:id, :first_name, :last_name],
                              }
                          }
                      }
                  }
              },
              post_attachments: {
                  only: [:id, :attachment_url, :thumbnail_url, :created_at, :updated_at, :attachment_type],
                  include:{
                      post_photo_users:{
                          only:[:id, :x_coordinate, :y_coordinate, :member_profile_id, :post_attachment_id],
                          include: {
                              member_profile: {
                                  only: [:id],
                                  include: {
                                      user: {
                                          only: [:id, :first_name, :last_name]
                                      }
                                  }
                              }
                          }
                      }
                  }
              },
              post_members:{
                  only:[:id],
                  include:{
                      member_profile:{
                          only:[:id, :photo],
                          include:{
                              user:{
                                  only:[:id, :first_name, :last_name]
                              }
                          }
                      }
                  }
              }
          }
      )
      
      if sync_token.present?
        Hash.from_xml(posts).as_json.merge!(sync_token: sync_token)
      else
        Hash.from_xml(posts).as_json
      end
    else
      {posts: []}.as_json
    end
  end

  def self.paging_records(member_profiles, posts, hash_tags, larger_array_type)
    if larger_array_type == 'Member'
      member_profiles
    elsif larger_array_type == 'Post'
      posts
    elsif larger_array_type == 'Hashtag'
      hash_tags
    end
  end

  def self.sync_ack(data,current_user)
    data        =  data.with_indifferent_access
    sync_object =  Synchronization.find_by_sync_token(data[:synchronization][:sync_token])
    if sync_object.present? && sync_object.media_type == "MemberProfile"
      if sync_object.sync_type    ==  AppConstants::FOLLOWING
        current_user.following_sync_datetime = sync_object.synced_date
      elsif sync_object.sync_type == AppConstants::NEAR_ME
        current_user.nearme_sync_datetime    = sync_object.synced_date
      elsif sync_object.sync_type == AppConstants::TRENDING
        current_user.trending_sync_datetime  = sync_object.synced_date
      end
      if current_user.save
        sync_object.destroy
      end
    else
      sync_object.destroy
    end
  end

  def self.timeline_posts_array_response(posts, profile, current_user)
    @@current_profile  = current_user.profile
    posts = posts.as_json(
        ony: [:id, :post_title, :post_description, :datetime, :is_post_public, :is_deleted, :created_at, :updated_at, :post_type, :location, :latitude, :longitude],
        methods: [:likes_count, :comments_count, :liked_by_me],
        include:{
            member_profile: {
                only: [:id, :photo, :country_id, :is_profile_public, :gender],
                include: {
                    user: {
                        only: [:id, :first_name, :last_name]
                    }
                }
            },
            event:{
                only:[:id, :event_name]
            },
            recent_likes: {
                only: [:id, :created_at, :updated_at],
                include: {
                    member_profile: {
                        only: [:id, :photo],
                        include: {
                            user: {
                                only: [:id, :first_name, :last_name]
                            }
                        }
                    }
                }
            },
            recent_comments: {
                only: [:id, :comment],
                methods:[:is_co_host_or_host],
                include: {
                    member_profile: {
                        only: [:id, :photo],
                        include: {
                            user: {
                                only: [:id, :first_name, :last_name],
                            }
                        }
                    }
                }
            },
            post_attachments: {
                only: [:id, :attachment_url, :thumbnail_url, :created_at, :updated_at, :attachment_type],
                include:{
                    post_photo_users:{
                        only:[:id, :x_coordinate, :y_coordinate, :member_profile_id, :post_attachment_id],
                        include: {
                            member_profile: {
                                only: [:id],
                                include: {
                                    user: {
                                        only: [:id, :first_name, :last_name]
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    )
    is_following = MemberProfile.is_following(profile, current_user)
    member_profile = profile.as_json(
        only: [:id, :photo, :country_id, :is_profile_public, :gender, :banner_image],
        include: {
            user: {
                only: [:id, :first_name, :last_name]
            }
        }
    ).merge!(is_im_following: is_following)
    {posts: posts, member_profile: member_profile}.as_json
  end

  def self.discover(data, current_user)
    begin
      data     = data.with_indifferent_access
      per_page = (data[:per_page] || @@limit).to_i
      page     = (data[:page] || 1).to_i
    
      if data[:search_key].present?
        search_key = data[:search_key]
        # search_records = PgSearch.multisearch(search_key)
        posts     = Post.search_by_title(search_key)
        users     = User.search_by_title(search_key)
        hash_tags = Hashtag.search_by_title(search_key)
        if posts.present? || users.present? || hash_tags.present?
          paging_data, resp_data = discover_search_new(posts, users, hash_tags, page, per_page, data[:type], current_user)
          resp_status = 1
          resp_message = 'Discover list'
          resp_errors = ''
        else
          resp_data    = {}
          resp_status  = 0
          resp_message = 'error'
          resp_errors  = 'No Record found'
          paging_data  = {}
        end
      else
        resp_data    = {}
        resp_status  = 0
        resp_message = 'error'
        resp_errors  = 'No Key found'
        paging_data  = {}
      end
    rescue Exception => e
      resp_data       = {}
      resp_status     = 0
      paging_data     = {}
      resp_message    = 'error'
      resp_errors     = e
    end
    resp_request_id   = ''
    resp_request_id   = data[:request_id] if data[:request_id].present?
    JsonBuilder.json_builder(resp_data, resp_status, resp_message, resp_request_id, errors: resp_errors, paging_data: paging_data)
  end

  def self.discover_search_new(posts, users, hash_tags, page, per_page, type, current_user)
    larger_array_type = ''
  
    if type.blank? || type == 'Member'
      profile_ids     = users.pluck(:profile_id)
      member_profiles = MemberProfile.where(id: profile_ids)
      member_profiles = member_profiles.page(page.to_i).per_page(per_page.to_i)
    end
  
    if type.blank? || type == 'Post'
      posts = posts.page(page.to_i).per_page(per_page.to_i)
    end
  
    if type.blank? || type == 'Hashtag'
      hash_tags = hash_tags.page(page.to_i).per_page(per_page.to_i)
    end
  
    if type.present?
      larger_array_type = type
    else
      if member_profiles.count > posts.count || member_profiles.count > hash_tags.count
        larger_array_type = 'Member'
      elsif posts.count > member_profiles.count || posts.count > hash_tags.count
        larger_array_type = 'Post'
      elsif hash_tags.count > member_profiles.count || hash_tags.count > posts.count
        larger_array_type = 'Hashtag'
      end
    end
  
    paging_data = JsonBuilder.get_paging_data(page, per_page, paging_records(member_profiles, posts, hash_tags, larger_array_type))
    resp_data = trending_api_loop_response(posts, hash_tags, true, current_user, member_profiles)
    [paging_data, resp_data]
  end
end

# == Schema Information
#
# Table name: posts
#
#  id                :integer          not null, primary key
#  member_profile_id :integer
#  post_title        :string
#  post_datetime     :datetime
#  post_description  :text
#  is_post_public    :boolean
#  is_deleted        :boolean          default(FALSE)
#  created_at        :datetime         not null
#  updated_at        :datetime         not null
#  post_type         :string
#  location          :string
#  latitude          :float
#  longitude         :float
#
