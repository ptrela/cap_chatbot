require "httparty"
require "json"

module JiraOAuth
  AUTHORIZE_URL = "https://auth.atlassian.com/authorize"
  TOKEN_URL     = "https://auth.atlassian.com/oauth/token"
  RESOURCES_URL = "https://api.atlassian.com/oauth/token/accessible-resources"
  SCOPES        = "read:jira-work read:jira-user offline_access"

  def self.authorize_url(state)
    params = URI.encode_www_form(
      audience:      "api.atlassian.com",
      client_id:     ENV.fetch("JIRA_CLIENT_ID"),
      scope:         SCOPES,
      redirect_uri:  ENV.fetch("JIRA_REDIRECT_URI"),
      state:         state,
      response_type: "code",
      prompt:        "consent"
    )
    "#{AUTHORIZE_URL}?#{params}"
  end

  def self.exchange(code)
    response = HTTParty.post(TOKEN_URL,
      headers: { "Content-Type" => "application/json" },
      body: {
        grant_type:    "authorization_code",
        client_id:     ENV.fetch("JIRA_CLIENT_ID"),
        client_secret: ENV.fetch("JIRA_CLIENT_SECRET"),
        code:          code,
        redirect_uri:  ENV.fetch("JIRA_REDIRECT_URI")
      }.to_json
    )
    return nil unless response.success?

    data = response.parsed_response
    cloud_id = fetch_cloud_id(data["access_token"])

    {
      access_token:  data["access_token"],
      refresh_token: data["refresh_token"],
      expires_in:    data["expires_in"],
      cloud_id:      cloud_id
    }
  end

  def self.refresh(refresh_token)
    response = HTTParty.post(TOKEN_URL,
      headers: { "Content-Type" => "application/json" },
      body: {
        grant_type:    "refresh_token",
        client_id:     ENV.fetch("JIRA_CLIENT_ID"),
        client_secret: ENV.fetch("JIRA_CLIENT_SECRET"),
        refresh_token: refresh_token
      }.to_json
    )
    return nil unless response.success?

    data = response.parsed_response
    {
      access_token:  data["access_token"],
      refresh_token: data["refresh_token"],
      expires_in:    data["expires_in"]
    }
  end

  def self.fetch_cloud_id(access_token)
    response = HTTParty.get(RESOURCES_URL,
      headers: { "Authorization" => "Bearer #{access_token}" }
    )
    return nil unless response.success?

    resources = response.parsed_response
    resources.first&.dig("id")
  end
end
