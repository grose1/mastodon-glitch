# frozen_string_literal: true

class FeedInsertWorker
  include Sidekiq::Worker

  def perform(status_id, id, type = 'home', options = {})
    ApplicationRecord.connected_to(role: :primary) do
      @type      = type.to_sym
      @status    = Status.find(status_id)
      @options   = options.symbolize_keys

      case @type
      when :home, :tags
        @follower = Account.find(id)
      when :list
        @list     = List.find(id)
        @follower = @list.account
      when :direct
        @account  = Account.find(id)
      end
    end

    ApplicationRecord.connected_to(role: :read, prevent_writes: true) do
      check_and_insert
    end
  rescue ActiveRecord::RecordNotFound
    true
  end

  private

  def check_and_insert
    if feed_filtered?
      perform_unpush if update?
    else
      perform_push
      perform_notify if notify?
    end
  end

  def feed_filtered?
    case @type
    when :home
      FeedManager.instance.filter?(:home, @status, @follower)
    when :tags
      FeedManager.instance.filter?(:tags, @status, @follower)
    when :list
      FeedManager.instance.filter?(:list, @status, @list)
    when :direct
      FeedManager.instance.filter?(:direct, @status, @account)
    end
  end

  def notify?
    return false if @type != :home || @status.reblog? || (@status.reply? && @status.in_reply_to_account_id != @status.account_id)

    Follow.find_by(account: @follower, target_account: @status.account)&.notify?
  end

  def perform_push
    case @type
    when :home, :tags
      FeedManager.instance.push_to_home(@follower, @status, update: update?)
    when :list
      FeedManager.instance.push_to_list(@list, @status, update: update?)
    when :direct
      FeedManager.instance.push_to_direct(@account, @status, update: update?)
    end
  end

  def perform_unpush
    case @type
    when :home, :tags
      FeedManager.instance.unpush_from_home(@follower, @status, update: true)
    when :list
      FeedManager.instance.unpush_from_list(@list, @status, update: true)
    when :direct
      FeedManager.instance.unpush_from_direct(@account, @status, update: true)
    end
  end

  def perform_notify
    LocalNotificationWorker.perform_async(@follower.id, @status.id, 'Status', 'status')
  end

  def update?
    @options[:update]
  end
end
