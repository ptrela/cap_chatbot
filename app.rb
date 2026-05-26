require "sinatra"
require "json"
require "openssl"
require "httparty"
require "dotenv/load"
require_relative "db"
require_relative "jira_oauth"

set :bind, "0.0.0.0"
set :port, ENV.fetch("PORT", 3000)
set :protection, false

ANTHROPIC_API = "https://api.anthropic.com/v1/messages"
SLACK_API     = "https://slack.com/api"

# ---------------------------------------------------------------------------
# Slack signature verification
# ---------------------------------------------------------------------------

def verify_slack_signature!(request, body)
  timestamp = request.env["HTTP_X_SLACK_REQUEST_TIMESTAMP"].to_i
  halt 403 if (Time.now.to_i - timestamp).abs > 300

  sig_base = "v0:#{timestamp}:#{body}"
  expected = "v0=" + OpenSSL::HMAC.hexdigest("SHA256", ENV.fetch("SLACK_SIGNING_SECRET"), sig_base)
  received = request.env["HTTP_X_SLACK_SIGNATURE"].to_s

  halt 403 unless Rack::Utils.secure_compare(expected, received)
end

# ---------------------------------------------------------------------------
# Slack events (mentions)
# ---------------------------------------------------------------------------

post "/slack/events" do
  content_type :json
  body_str = request.body.read
  payload  = JSON.parse(body_str)

  return { challenge: payload["challenge"] }.to_json if payload["type"] == "url_verification"

  verify_slack_signature!(request, body_str)

  event = payload["event"] || {}

  if event["type"] == "app_mention" && event["bot_id"].nil?
    Thread.new { handle_mention(event) }
  end

  status 200
  "ok"
end

# ---------------------------------------------------------------------------
# Slack slash command: /jira-connect
# ---------------------------------------------------------------------------

post "/slack/commands/jira-connect" do
  body_str = request.body.read
  verify_slack_signature!(request, body_str)

  params   = URI.decode_www_form(body_str).to_h
  user_id  = params["user_id"]
  state    = Base64.urlsafe_encode64(user_id)
  auth_url = JiraOAuth.authorize_url(state)

  content_type :json
  {
    response_type: "ephemeral",
    text:          ":jira: Connect your Jira account:",
    attachments:   [{ text: auth_url, color: "#0052CC" }]
  }.to_json
end

# ---------------------------------------------------------------------------
# Jira OAuth callback
# ---------------------------------------------------------------------------

get "/auth/jira/callback" do
  code     = params["code"]
  state    = params["state"]
  halt 400, "Missing params" if code.nil? || state.nil?

  slack_user_id = Base64.urlsafe_decode64(state)
  tokens        = JiraOAuth.exchange(code)
  halt 500, "OAuth exchange failed" unless tokens

  JiraTokens.upsert(
    slack_user_id: slack_user_id,
    access_token:  tokens[:access_token],
    refresh_token: tokens[:refresh_token],
    cloud_id:      tokens[:cloud_id],
    expires_in:    tokens[:expires_in]
  )

  "<h2>Connected! Return to Slack.</h2>"
end

# ---------------------------------------------------------------------------
# Health check
# ---------------------------------------------------------------------------

get "/health" do
  content_type :json
  { status: "ok", time: Time.now.iso8601 }.to_json
end

# ---------------------------------------------------------------------------
# Core logic
# ---------------------------------------------------------------------------

def handle_mention(event)
  channel   = event["channel"]
  thread_ts = event["thread_ts"] || event["ts"]
  user_id   = event["user"]
  user_text = event["text"].gsub(/<@[^>]+>/, "").strip

  slack_post(channel, thread_ts, ":hourglass_flowing_sand: Thinking...")

  begin
    jira_token = JiraTokens.fresh_token(user_id)

    if jira_token.nil? && ENV["JIRA_MCP_URL"] && !ENV["JIRA_MCP_URL"].empty?
      slack_post(channel, thread_ts,
        ":warning: Your Jira account is not connected. Run `/jira-connect` to link it.")
      return
    end

    result   = call_claude(user_text, jira_token)
    text_out = result[:text]
    csv_data = result[:csv]

    slack_post(channel, thread_ts, text_out) unless text_out.empty?
    slack_upload_csv(channel, thread_ts, csv_data) if csv_data
  rescue => e
    slack_post(channel, thread_ts, ":x: Error: #{e.message}")
  end
end

def call_claude(user_message, jira_token = nil)
  body = {
    model:      "claude-sonnet-4-6",
    max_tokens: 4096,
    system:     system_prompt,
    messages:   [{ role: "user", content: user_message }]
  }

  jira_url = ENV["JIRA_MCP_URL"]
  if jira_url && !jira_url.empty? && jira_token
    body[:mcp_servers] = [{
      type:    "url",
      url:     jira_url,
      name:    "jira",
      headers: { "Authorization" => "Bearer #{jira_token}" }
    }]
  end

  response = HTTParty.post(
    ANTHROPIC_API,
    headers: {
      "Content-Type"      => "application/json",
      "x-api-key"         => ENV.fetch("ANTHROPIC_API_KEY"),
      "anthropic-version" => "2023-06-01",
      "anthropic-beta"    => "mcp-client-2025-04-04"
    },
    body:    body.to_json,
    timeout: 120
  )

  raise "Anthropic API error #{response.code}: #{response.body}" unless response.success?

  parse_claude_response(response.parsed_response)
end

def parse_claude_response(data)
  text_parts = []
  csv_data   = nil

  Array(data["content"]).each do |block|
    next unless block["type"] == "text"

    raw = block["text"]

    if (match = raw.match(/```csv\n(.*?)```/m))
      csv_data = match[1]
      raw      = raw.sub(match[0], "").strip
    end

    text_parts << raw unless raw.empty?
  end

  { text: text_parts.join("\n\n"), csv: csv_data }
end

def system_prompt
  <<~PROMPT
    You are a helpful assistant integrated into Slack.
    When the user asks for data from Jira (issues, sprints, epics, reports), use the Jira MCP tools to fetch it.
    If the result is tabular data (multiple issues, tasks, tickets), format it as a CSV code block:
    ```csv
    column1,column2,column3
    value1,value2,value3
    ```
    Keep text responses concise — this is a chat interface.
    Respond in the same language the user uses.
  PROMPT
end

# ---------------------------------------------------------------------------
# Slack helpers
# ---------------------------------------------------------------------------

def slack_post(channel, thread_ts, text)
  HTTParty.post(
    "#{SLACK_API}/chat.postMessage",
    headers: {
      "Content-Type"  => "application/json; charset=utf-8",
      "Authorization" => "Bearer #{ENV.fetch('SLACK_BOT_TOKEN')}"
    },
    body: { channel: channel, thread_ts: thread_ts, text: text }.to_json
  )
end

def slack_upload_csv(channel, thread_ts, csv_data)
  url_response = HTTParty.post(
    "#{SLACK_API}/files.getUploadURLExternal",
    headers: { "Authorization" => "Bearer #{ENV.fetch('SLACK_BOT_TOKEN')}" },
    body:    { filename: "report_#{Time.now.strftime('%Y%m%d_%H%M%S')}.csv", length: csv_data.bytesize }
  )
  return unless url_response.parsed_response["ok"]

  upload_url = url_response.parsed_response["upload_url"]
  file_id    = url_response.parsed_response["file_id"]

  HTTParty.post(upload_url, body: csv_data, headers: { "Content-Type" => "text/csv" })

  HTTParty.post(
    "#{SLACK_API}/files.completeUploadExternal",
    headers: {
      "Content-Type"  => "application/json",
      "Authorization" => "Bearer #{ENV.fetch('SLACK_BOT_TOKEN')}"
    },
    body: {
      files:           [{ id: file_id }],
      channel_id:      channel,
      thread_ts:       thread_ts,
      initial_comment: ":page_facing_up: CSV report generated"
    }.to_json
  )
end
