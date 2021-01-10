require "digest/sha1"
require "kramdown"
require "danger/helpers/comments_parsing_helper"
require "danger/helpers/emoji_mapper"
require "danger/helpers/find_max_num_violations"

module Danger
  module Helpers
    module CommentsHelper
      # This might be a bit weird, but table_kind_from_title is a shared dependency for
      # parsing and generating. And rubocop was adamant about file size so...
      include Danger::Helpers::CommentsParsingHelper

      def markdown_parser(text)
        Kramdown::Document.new(text, input: "GFM")
      end

      # !@group Extension points
      # Produces a markdown link to the file the message points to
      #
      # request_source implementations are invited to override this method with their
      # vendor specific link.
      #
      # @param [Violation or Markdown] message
      # @param [Bool] Should hide any generated link created
      #
      # @return [String] The Markdown compatible link
      def markdown_link_to_message(message, _)
        "#{message.file}#L#{message.line}"
      end

      # !@group Extension points
      # Determine whether two messages are equivalent
      #
      # request_source implementations are invited to override this method.
      # This is mostly here to enable sources to detect when inlines change only in their
      # commit hash and not in content per-se. since the link is implementation dependant
      # so should be the comparision.
      #
      # @param [Violation or Markdown] m1
      # @param [Violation or Markdown] m2
      #
      # @return [Boolean] whether they represent the same message
      def messages_are_equivalent(m1, m2)
        m1 == m2
      end

      def process_markdown(violation, hide_link = false)
        message = violation.message
        message = "#{markdown_link_to_message(violation, hide_link)}#{message}" if violation.file && violation.line

        html = markdown_parser(message).to_html
        # Remove the outer `<p>`, the -5 represents a newline + `</p>`
        html = html[3...-5] if html.start_with? "<p>"
        Violation.new(html, violation.sticky, violation.file, violation.line)
      end

      def table(name, emoji, violations, all_previous_violations, issue_comments, template: "github")
        content = violations
        content = content.map { |v| process_markdown(v) } unless ["bitbucket_server", "vsts"].include?(template)

        kind = table_kind_from_title(name)
        # previous_violations includes all resolved and unresolved violations in one kind
        # so, previous_violations = content (unresolved violations) + resolved_violations
        previous_violations = all_previous_violations[kind] || []
        # Need to find resolved violations
        # 1. one previous violation does not exist in the current violation (students may resolve these violations)
        resolved_violations = previous_violations.reject do |pv|
          content.count { |v| messages_are_equivalent(v, pv) } > 0
        end
        # 2. violations caneled or confirmed by teaching staff
        previous_violations_dict = {} # key: UUID, value: violation object 
        previous_violations.each do |pv|
          # Remove html tags
          msg = pv.message.gsub(/<\/?[0-9a-z]+>/, "")
          # Make the last 4-digit hex hash code as UUID
          uuid = Digest::SHA1.hexdigest(msg)[-4..-1]
          previous_violations_dict[uuid] = pv
        end

        issue_comments.each do |issue_comment|
          next if !issue_comment.body.start_with?("/cancel") and !issue_comment.body.start_with?("/confirm")
          # Split one or more whitespaces and commas
          issue_comment_arr = issue_comment.body.split(/[\s,]+/)
          puts "issue_comment_arr: " + issue_comment_arr.to_s
          issue_comment_arr[1..-1].each do |uuid|
            pv = previous_violations_dict[uuid]
            next if not pv
            if issue_comment_arr[0] == "/cancel"
              resolved_violations << pv if !resolved_violations.include? pv
              content.reject!{ |v| messages_are_equivalent(v, pv) }
            elsif issue_comment_arr[0] == "/confirm"
              content << pv if !content.include? pv
              resolved_violations.reject!{ |v| messages_are_equivalent(v, pv) }
            end
          end
        end
        puts "content: " + content.inspect
        puts "resolved_violations: " + resolved_violations.inspect
        resolved_messages = resolved_violations.map(&:message).uniq
        count = content.uniq.count

        {
          name: name,
          emoji: emoji,
          content: content.uniq,
          resolved: resolved_messages,
          count: count
        }
      end

      def apply_template(tables: [], markdowns: [], danger_id: "danger", template: "github")
        require "erb"

        md_template = File.join(Danger.gem_path, "lib/danger/comment_generators/#{template}.md.erb")

        # erb: http://www.rrn.dk/rubys-erb-templating-system
        # for the extra args: http://stackoverflow.com/questions/4632879/erb-template-removing-the-trailing-line
        @tables = tables
        @markdowns = markdowns.map(&:message)
        @danger_id = danger_id
        @emoji_mapper = EmojiMapper.new(template)

        return ERB.new(File.read(md_template), 0, "-").result(binding)
      end

      def generate_comment(warnings: [], errors: [], messages: [], markdowns: [], previous_violations: {}, issue_comments: [], danger_id: "danger", template: "github")
        apply_template(
          tables: [
            table("Message", "speech_balloon", messages, previous_violations, issue_comments, template: template),
            table("Warning", "warning", warnings, previous_violations, issue_comments, template: template),
            table("Error", "boom", errors, previous_violations, issue_comments, template: template)
          ],
          markdowns: markdowns,
          danger_id: danger_id,
          template: template
        )
      end

      def generate_inline_comment_body(emoji, message, danger_id: "danger", resolved: false, template: "github")
        apply_template(
          tables: [{ content: [message], resolved: resolved, emoji: emoji }],
          danger_id: danger_id,
          template: "#{template}_inline"
        )
      end

      def generate_inline_markdown_body(markdown, danger_id: "danger", template: "github")
        apply_template(
          markdowns: [markdown],
          danger_id: danger_id,
          template: "#{template}_inline"
        )
      end

      def generate_description(warnings: nil, errors: nil)
        if errors.empty? && warnings.empty?
          return "All green. #{random_compliment}"
        else
          message = "⚠️ "
          message += "#{'Error'.danger_pluralize(errors.count)}. " unless errors.empty?
          message += "#{'Warning'.danger_pluralize(warnings.count)}. " unless warnings.empty?
          message += "Don't worry, everything is fixable."
          return message
        end
      end

      def random_compliment
        ["Well done.", "Congrats.", "Woo!",
         "Yay.", "Jolly good show.", "Good on 'ya.", "Nice work."].sample
      end

      private

      def pluralize(string, count)
        string.danger_pluralize(count)
      end

      def truncate(string)
        max_message_length = 30
        string.danger_truncate(max_message_length)
      end
    end
  end
end
