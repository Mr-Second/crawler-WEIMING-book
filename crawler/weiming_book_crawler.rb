require 'crawler_rocks'

require 'json'
require 'iconv'

require 'pry'

require 'thread'
require 'thwait'

class WeimingBookCrawler
  include CrawlerRocks::DSL

  def initialize
    @query_url = "http://www.wmbook.com.tw/index.php"
    # @ic = Iconv.new("utf-8//IGNORE//translit","utf-8")
  end

  def books
    @books = {}
    @threads = []

    visit @query_url

    r = RestClient.post(@query_url + "?php_mode=search", {
      "kindid" => nil,
      "kind" => " 書籍類別",
      "name" => nil,
      "serial" => nil,
      "isbn" => nil,
      "author" => nil,
      "publisher" => nil,
      "Submit" => "送出",
    }, cookies: @cookies) { |response, request, result, &block|
      if [301, 302, 307].include? response.code
        response.follow_redirection(request, result, &block)
      else
        response.return!(request, result, &block)
      end
    }

    r = get_page(0)
    doc = Nokogiri::HTML(r)

    page_num = doc.xpath('//input[@name="Input"]/parent::td').text.match(/共(\d+)頁/)[1].to_i

    finished_page = 0

    (1..page_num).each do |i|
      sleep(1) until (
        @threads.delete_if { |t| !t.status };  # remove dead (ended) threads
        @threads.count < (ENV['MAX_THREADS'] || 20)
      )
      @threads << Thread.new do
        start_book_id = (i - 1) * 30
        r = get_page start_book_id
        doc = Nokogiri::HTML(r)

        doc.xpath(
          '//table[@width="563"][@border="0"][@cellpadding="0"][@cellspacing="0"][@align="LEFT"]/tr[@onmouseover]'
        ).each do |row|
          datas = row.xpath('td')

          edition = datas[1] && datas[1].text.to_i
          edition = nil if edition == 0

          url = URI.join(@query_url, datas[0] && datas[0].xpath('a/@href').to_s).to_s
          id = url.match(/(?<=id=)\d+/).to_s

          price = datas[4] && datas[4].text.gsub(/[^\d]/, '').to_i

          @books[id] = {
            name: datas[0] && datas[0].text,
            author: datas[1] && datas[1].text.strippp,
            edition: edition,
            # internal_code: internal_code,
            url: url,
            price: price,
          }
        end
        finished_page += 1
        print "#{finished_page} / #{page_num}\n"
      end # end new Thread
    end

    ThreadsWait.all_waits(*@threads)

    @books.values
  end

  def get_page start_book_id
      RestClient.get( @query_url + "?" + {
        "php_mode" => 'booklist',
        "StartBookId" => start_book_id,
      }.map{|k, v| "#{k}=#{v}"}.join('&'),
        cookies: @cookies
      )
  end

end

class String
  def strippp
    self.gsub(/^\u{20}+/, '').gsub(/\u{20}+$/, '')
  end
end

cc = WeimingBookCrawler.new
File.write('wm_books.json', JSON.pretty_generate(cc.books))
