# encoding: UTF-8
require 'fileutils'

module Earthquake
  module Core
    def config
      @config ||= {}
    end

    def preferred_config
      @preferred_config ||= {}
    end

    def item_queue
      @item_queue ||= []
    end

    def inits
      @inits ||= []
    end

    def init(&block)
      inits << block
    end

    def onces
      @once ||= []
    end

    def once(&block)
      onces << block
    end

    def _once
      onces.each { |block| class_eval(&block) }
    end

    def _init
      load_config
      load_plugins
      inits.each { |block| class_eval(&block) }
      inits.clear
    end

    def reload
      Gem.refresh
      loaded = ActiveSupport::Dependencies.loaded.dup
      ActiveSupport::Dependencies.clear
      loaded.each { |lib| require_dependency lib }
    rescue Exception => e
      error e
    ensure
      _init
    end

    def default_config
      consumer = YAML.load_file(File.expand_path('../../../consumer.yml', __FILE__))
      dir = config[:dir] || File.expand_path('~/.earthquake')
      {
        dir:             dir,
        time_format:     Time::DATE_FORMATS[:short],
        plugin_dir:      File.join(dir, 'plugin'),
        file:            File.join(dir, 'config'),
        prompt:          '⚡ ',
        consumer_key:    consumer['key'],
        consumer_secret: consumer['secret'],
        api_version:     '1.1',
        secure:          true,
        output_interval: 1,
        history_size:    1000,
        api:             { :host => 'userstream.twitter.com', :path => '/2/user.json', :ssl => true },
        confirm_type:    :y,
        expand_url:      false,
        thread_indent:   "  ",
        no_data_timeout: 30
      }
    end

    def load_config
      config.reverse_update(default_config)

      [config[:dir], config[:plugin_dir]].each do |dir|
        unless File.exists?(dir)
          FileUtils.mkdir_p(dir)
        end
      end

      if File.exists?(config[:file])
        load config[:file]
      else
        File.open(config[:file], mode: 'w', perm: 0600).close
      end

      config.update(preferred_config) do |key, cur, new|
        if Hash === cur and Hash === new
          cur.merge(new)
        else
          new
        end
      end

      get_access_token unless self.config[:token] && self.config[:secret]
    end

    def load_plugins
      Dir[File.join(config[:plugin_dir], '*.rb')].each do |lib|
        begin
          require_dependency lib
        rescue Exception => e
          error e
        end
      end
    end

    def __init(options)
      config.merge!(options)
      _init
      _once
    end

    def invoke(command, options = {})
      __init(options)
      input(command)
    end

    def start(options = {})
      __init(options)
      restore_history

      start_output

      unless options[:'no-stream'] == true
        start_stream
        start_timer
      end

      trap('INT') { stop }
      start_readline.join
    end

    def start_timer
      Thread.start do
        loop do
          if @last_data_received_at && Time.now - @last_data_received_at > config[:no_data_timeout]
            reconnect
          end
          if Readline.line_buffer.nil? || Readline.line_buffer.empty?
            sync { output }
          end
          sleep config[:output_interval]
        end
      end
    end

    def start_readline
      @readline_thread = Thread.start do
        while buf = Readline.readline(config[:prompt], true)
          unless Readline::HISTORY.count == 1
            Readline::HISTORY.pop if buf.empty? || Readline::HISTORY[-1] == Readline::HISTORY[-2]
          end
          sync {
            reload unless config[:reload] == false
            store_history
            input(buf.strip)
          }
        end
        # unexpected
        stop
      end
    end

    def start_output
      Thread.start do
        loop do
          if Readline.line_buffer.nil? || Readline.line_buffer.empty?
            sync { output }
          end

          sleep config[:output_interval]
        end
      end
    end

    def reconnect
      stop_stream
      item_queue.clear
      start_stream
    end

    def start_stream(options = nil)
      @stream_thread = Thread.start do
        options = config[:api] unless options
        options = {
          :oauth => config.slice(:consumer_key, :consumer_secret).merge(
            :access_token => config[:token], :access_token_secret => config[:secret]#,
            # :proxy => ENV['http_proxy']
          )
        }.merge(options)

        stream = ::Twitter::Streaming::Client.new(options[:oauth])
        stream.user do |object|
          @last_data_received_at = Time.now
          begin
            item_queue << object.to_h.deep_stringify_keys
          rescue => e
            # ignore
          end
        end
      end
    end

    def stop_stream
      @stream_thread.kill if @stream_thread
    end

    def stop
      stop_stream
      @readline_thread.kill if @readline_thread
    end

    def store_history
      history_size = config[:history_size]
      File.open(File.join(config[:dir], 'history'), 'w') do |file|
        lines = Readline::HISTORY.to_a[([Readline::HISTORY.size - history_size, 0].max)..-1]
        file.print(lines.join("\n"))
      end
    end

    def restore_history
      history_file = File.join(config[:dir], 'history')
      begin
        File.read(history_file, :encoding => "BINARY").
          encode!(:invalid => :replace, :undef => :replace).
          split(/\n/).
          each { |line| Readline::HISTORY << line }
      rescue Errno::ENOENT
      rescue Errno::EACCES => e
        error(e)
      end
    end

    def mutex
      @mutex ||= Mutex.new
    end

    def sync(&block)
      mutex.synchronize do
        block.call
      end
    end

    def async(&block)
      Thread.start do
        begin
          block.call
        rescue Exception => e
          error e
        end
      end
    end

    def error(e)
      case e
      when Exception
        insert "[ERROR] #{e.message}\n    #{e.backtrace.join("\n    ")}".c(:notice)
      else
        insert "[ERROR] #{e}".c(:notice)
      end
    end

    def notify(message, options = {})
      title = options.delete(:title) || 'earthquake'
      message = message.is_a?(String) ? message : message.inspect
      Notify.notify title, message, options
    end
    alias_method :n, :notify

    def browse(url)
      Launchy.open(url)
    end
  end

  extend Core
end
