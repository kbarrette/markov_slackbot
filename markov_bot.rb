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
    Thread.new do
      learn_static
      client.say(text: "Done learning static", channel: data.channel)
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
    private

    def logger
      @logger ||= Logger.new(STDOUT)
    end

    def learn_static
      logger.info("Learning static files")

      Dir
        .glob(File.join(File.dirname(__FILE__), "static", "*"))
        .map(&method(:learn_static_file))
        .each(&:join)

      logger.info("Done learning static files")
    end

    def learn_static_file(file)
      Thread.new do
        logger.info("Learning #{file}")

        name = File.basename(file)
        dictionary = File.join("dictionaries", name)

        markovs[name] = MarkyMarkov::Dictionary.new(dictionary)
        if !File.exist?("#{dictionary}.mmd")
          markovs[name].parse_file(file)
          markovs[name].save_dictionary!
        end

        logger.info("Done learning #{file}")
      end
    end

    def learn(channel, client)
      LEARNING.synchronize do
        logger.info("Learning channel #{channel}")

        markovs["us"] ||= MarkyMarkov::TemporaryDictionary.new
        bot_id = SlackRubyBot.config.user_id || client.self.id
        history(channel)
          .select { |m| m["text"] }
          .reject { |m| m["user"] == bot_id }
          .each do |message|
            scrubbed = message["text"].gsub(/<.*?>/, "")

            markovs["us"].parse_string(scrubbed)

            if user = users[message["user"]]
              markovs[user] ||= MarkyMarkov::TemporaryDictionary.new
              markovs[user].parse_string(scrubbed)
            end
          end

        logger.info("Done learning channel")
      end
    end

    def markov_response(user)
      if markovs.has_key?(user)
        markovs[user].generate_n_sentences(Random.rand(3) + 1)
      end
    end

    def markovs
      @markovs ||= {}
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
  MarkovBot.run
end
