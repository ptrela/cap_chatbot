require "sequel"
require "fileutils"

db_path = ENV.fetch("DB_PATH", "data/chatbot.db")
FileUtils.mkdir_p(File.dirname(db_path))

DB = Sequel.connect("sqlite://#{db_path}")

DB.create_table?(:jira_tokens) do
  String  :slack_user_id, primary_key: true
  String  :access_token,  null: false
  String  :refresh_token
  String  :cloud_id
  Integer :expires_at
  Integer :created_at,    default: Sequel.function(:unixepoch)
end

module JiraTokens
  def self.find(slack_user_id)
    DB[:jira_tokens].where(slack_user_id: slack_user_id).first
  end

  def self.upsert(slack_user_id:, access_token:, refresh_token:, cloud_id:, expires_in:)
    record = {
      slack_user_id: slack_user_id,
      access_token:  access_token,
      refresh_token: refresh_token,
      cloud_id:      cloud_id,
      expires_at:    Time.now.to_i + expires_in.to_i
    }
    if find(slack_user_id)
      DB[:jira_tokens].where(slack_user_id: slack_user_id).update(record)
    else
      DB[:jira_tokens].insert(record)
    end
  end

  def self.delete(slack_user_id)
    DB[:jira_tokens].where(slack_user_id: slack_user_id).delete
  end

  def self.fresh_token(slack_user_id)
    row = find(slack_user_id)
    return nil unless row

    if row[:expires_at] && Time.now.to_i > row[:expires_at] - 60
      refreshed = JiraOAuth.refresh(row[:refresh_token])
      return nil unless refreshed

      upsert(
        slack_user_id: slack_user_id,
        access_token:  refreshed[:access_token],
        refresh_token: refreshed[:refresh_token] || row[:refresh_token],
        cloud_id:      row[:cloud_id],
        expires_in:    refreshed[:expires_in]
      )
      return refreshed[:access_token]
    end

    row[:access_token]
  end
end
