require "logger"
require "marky_markov"
require "slack-ruby-bot"
require "slack-ruby-client"

# Note: generate statics with something like
# find stallman.org -name '*.html' | ruby -rloofah -ne 'puts Loofah.fragment(File.read($_.chomp)).to_text rescue ""' > static/rms

Thread.abort_on_exception = true

class MarkovBot < SlackRubyBot::Bot
  LEARNING = Mutex.new

  command "learn" do |client, data, match|
    client.say(text: "Learning...", channel: data.channel)
    Thread.new do
      learn(data.channel, client)
      client.say(text: "Done learning", channel: data.channel)
    end
  end

  command "forget" do |client, data, match|
    @markovs = nil
    @users = nil
    client.say(text: "All is forgotten", channel: data.channel)
  end

  command "imitate" do |client, data, match|
    user = match["expression"] == "me" ? users[data["user"]] : match["expression"]
    if response = markov_response(user)
      client.say(text: response, channel: data.channel)
    else
      client.say(
        text: "Sorry, I don't understand `#{data['text']}`",
        channel: data.channel,
      )
    end
  end

  class << self
    def learn_static
      logger.info("Learning static files")
      threads = Dir.glob(File.join(File.dirname(__FILE__), "static", "*")).map do |file|
        Thread.new do
          logger.info("Learning #{file}")
          markovs[File.basename(file)].parse_string(File.read(file))
        end
      end
      threads.each(&:join)
      logger.info("Done learning static files")
    end

    private

    def logger
      @logger ||= Logger.new(STDOUT)
    end

    def learn(channel, client)
      LEARNING.synchronize do
        logger.info("Learning channel #{channel}")

        bot_id = SlackRubyBot.config.user_id || client.self.id
        history(channel)
          .select { |m| m["text"] }
          .reject { |m| m["user"] == bot_id }
          .each do |message|
            scrubbed = message["text"].gsub(/<.*?>/, "")
            markovs["us"].parse_string(scrubbed)
            if user = users[message["user"]]
              markovs[user].parse_string(scrubbed)
            end
          end
        logger.info("Done learning channel")
      end
    end

    def markov_response(user)
      if markovs.has_key?(user)
        markovs[user].generate_n_sentences(2)
      end
    end

    def markovs
      @markovs ||= Hash.new do |h, k|
        h[k] = MarkyMarkov::TemporaryDictionary.new
      end
    end

    def users
      return @users if @users

      response = slack_web_client.users_list(limit: 1000)
      if response["ok"]
        @users = response["members"]
          .map { |m| [m["id"], m["name"]] }
          .to_h
          .tap { |u| logger.info("Users: #{u}") }
      else
        {}
      end
    end

    def history(channel)
      return enum_for(:history, channel) unless block_given?

      cursor = nil
      while(true) do
        logger.info("Fetching conversation history for #{channel} (#{cursor})")
        response = slack_web_client.conversations_history(
          channel: channel,
          cursor: cursor,
          limit: 1000,
        )
        break unless response["ok"]
        response["messages"].each { |m| yield m }

        break if !response["has_more"]
        cursor = response["response_metadata"]["next_cursor"]
      end
    end

    def slack_web_client
      @slack_web_client ||= Slack::Web::Client.new(
        user_agent: "Slack Ruby Client/1.0",
        token: ENV["SLACK_API_TOKEN"],
      )
    end
  end
end

if __FILE__ == $0
  bot = Thread.new(&MarkovBot.method(:run))
  MarkovBot.learn_static
  bot.join
end
